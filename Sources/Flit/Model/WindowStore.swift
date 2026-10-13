import AppKit
import ApplicationServices

/// Enumerates windows across apps, displays and Spaces, and tracks
/// most-recently-used order. Call `refresh()` on the main thread.
@MainActor
final class WindowStore {
    static let shared = WindowStore()

    private(set) var windows: [WindowInfo] = []
    private var lastFocused: [CGWindowID: Date] = [:]
    private var observers: [pid_t: AXFocusObserver] = [:]
    private var knownElements: [CGWindowID: AXUIElement] = [:]

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.noteActivation(of: app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.observers.removeValue(forKey: app.processIdentifier) }
        }
        // Seed MRU with the current frontmost window and start observing.
        if let front = NSWorkspace.shared.frontmostApplication { noteActivation(of: front) }
    }

    func markFocused(_ id: CGWindowID) {
        lastFocused[id] = Date()
    }

    private func noteActivation(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        ensureObserver(pid)
        if let wid = AXUIElement.application(pid).focusedWindow?.windowID {
            markFocused(wid)
        }
    }

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil, AXIsProcessTrusted() else { return }
        observers[pid] = AXFocusObserver(pid: pid) { [weak self] wid in
            guard let wid else { return }
            Task { @MainActor in self?.markFocused(wid) }
        }
    }

    private static let cgKeys = (
        id: kCGWindowNumber as String, pid: kCGWindowOwnerPID as String,
        layer: kCGWindowLayer as String, bounds: kCGWindowBounds as String,
        alpha: kCGWindowAlpha as String, onscreen: kCGWindowIsOnscreen as String,
        name: kCGWindowName as String
    )

    /// Rebuilds `windows`. Roughly 10–50 ms with a dozen apps.
    @discardableResult
    func refresh() -> [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        let trusted = AXIsProcessTrusted()
        let activeSpaces = PrivateAPI.currentSpacesOnAllDisplays
        let now = Date()

        // 1. CG window list (front-to-back) gives IDs, bounds, z-order on all Spaces.
        let cgList = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        struct CGEntry { let id: CGWindowID; let pid: pid_t; let bounds: CGRect; let onScreen: Bool; let name: String; let z: Int }
        var cgEntries: [CGEntry] = []
        for (z, e) in cgList.enumerated() {
            guard let id = e[Self.cgKeys.id] as? CGWindowID,
                  let pid = e[Self.cgKeys.pid] as? pid_t, appsByPID[pid] != nil,
                  (e[Self.cgKeys.layer] as? Int ?? 0) == 0,
                  (e[Self.cgKeys.alpha] as? Double ?? 1) > 0,
                  let b = e[Self.cgKeys.bounds] as? [String: CGFloat] else { continue }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard bounds.width >= 50, bounds.height >= 50 else { continue }
            cgEntries.append(CGEntry(id: id, pid: pid, bounds: bounds,
                                     onScreen: e[Self.cgKeys.onscreen] as? Bool ?? false,
                                     name: e[Self.cgKeys.name] as? String ?? "", z: z))
        }

        // 2. AX windows per app, keyed by window ID.
        var axByID: [CGWindowID: AXUIElement] = [:]
        if trusted {
            for app in apps {
                let pid = app.processIdentifier
                ensureObserver(pid)
                for el in AXUIElement.application(pid).windows {
                    if let wid = el.windowID { axByID[wid] = el }
                }
            }
        }

        // 3. Join.
        var result: [WindowInfo] = []
        var seenPIDs = Set<pid_t>()
        for e in cgEntries {
            let app = appsByPID[e.pid]!
            var el = axByID[e.id] ?? knownElements[e.id]
            if el == nil, trusted { el = PrivateAPI.axElement(pid: e.pid, windowID: e.id) }
            if let el, !el.isSwitchable {
                // Popovers, sheets, tooltips: skip. But keep if AX can't tell us (role nil).
                if el.role != nil { continue }
            }
            if let el { knownElements[e.id] = el }
            let spaces = PrivateAPI.spaces(for: e.id)
            let onActive = spaces.isEmpty ? e.onScreen : !Set(spaces).isDisjoint(with: activeSpaces)
            let minimized = el?.isMinimized ?? false
            // Heuristic when AX is unavailable: off-screen on the active Space and not hidden → minimized.
            let minimizedGuess = el == nil && !e.onScreen && onActive && !app.isHidden
            let title = el?.title ?? ""
            let info = WindowInfo(
                id: e.id, pid: e.pid,
                appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
                title: title.isEmpty ? e.name : title,
                frame: e.bounds,
                isMinimized: minimized || minimizedGuess,
                isHidden: app.isHidden,
                isFullscreen: el?.isFullscreen ?? false,
                spaceIDs: spaces, isOnActiveSpace: onActive,
                screenID: Screens.displayID(containing: e.bounds),
                isOnScreen: e.onScreen,
                axElement: el,
                thumbnail: Screenshots.shared.cached(e.id),
                lastFocused: lastFocused[e.id] ?? now.addingTimeInterval(-Double(e.z) - 60)
            )
            // Seed MRU from z-order for windows we have never seen focused.
            if lastFocused[e.id] == nil { lastFocused[e.id] = info.lastFocused }
            seenPIDs.insert(e.pid)
            result.append(info)
        }

        // 4. Placeholder entries for apps with no windows (filtered later by preference).
        for app in apps where !seenPIDs.contains(app.processIdentifier) {
            let pid = app.processIdentifier
            let fakeID = CGWindowID(UInt32.max - UInt32(pid))
            result.append(WindowInfo(
                id: fakeID, pid: pid, appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
                title: "", frame: .zero, isMinimized: false, isHidden: app.isHidden, isFullscreen: false,
                spaceIDs: [], isOnActiveSpace: true, screenID: nil, isOnScreen: false, axElement: nil,
                thumbnail: nil, lastFocused: lastFocused[fakeID] ?? now.addingTimeInterval(-3600),
                isAppPlaceholder: true))
        }

        // Prune stale state.
        let live = Set(result.map(\.id))
        lastFocused = lastFocused.filter { live.contains($0.key) }
        knownElements = knownElements.filter { live.contains($0.key) }

        windows = result
        return result
    }

    /// Updates the cached thumbnail on an entry without a full refresh.
    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].thumbnail = image }
    }

    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    var focusedWindowDisplay: CGDirectDisplayID? {
        guard let pid = frontmostPID,
              let wid = AXUIElement.application(pid).focusedWindow?.windowID,
              let w = windows.first(where: { $0.id == wid }) else { return nil }
        return w.screenID
    }
}
