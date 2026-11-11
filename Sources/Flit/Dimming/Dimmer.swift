import AppKit
import ApplicationServices

/// Dims everything behind the front window on the display that window is on.
/// Other displays are left alone. There is one click-through overlay per
/// display; only the front window's display has its overlay showing, placed
/// directly under that window in the z-order.
///
/// Nothing runs on a timer. The overlay is re-placed only when the front app,
/// its main window, or that window's display changes, and while dimming is
/// off there are no windows and no observers at all.
@MainActor
final class Dimmer {
    private var overlays: [NSWindow] = []
    /// Each overlay's display in CG coordinates, parallel to `overlays`.
    private var displayFrames: [CGRect] = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var watcher: AXWatcher?
    private var watchedPID: pid_t = 0
    private var anchorElement: AXUIElement?
    /// The window the overlay is under, and which display's overlay that is.
    private var placed: (window: Int, display: Int)?
    private var pending: DispatchWorkItem?
    private var intensity = 0.35
    private(set) var isOn = false

    /// What to do a moment after placing the overlay.
    private enum FollowUp {
        case none
        /// Order the overlay under the same window again: the window may be
        /// raised just after its app reports the change.
        case reorder
        /// Work the front window out again: right after an app switch,
        /// Accessibility can still describe the previous state.
        case resolve
    }

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    /// On the anchored window itself. The app-level notifications don't fire
    /// when the last window closes or the window is minimized, and nothing
    /// else says the window went to another display.
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowMovedNotification,
    ]

    func configure(enabled: Bool, intensity: Double) {
        let clamped = min(max(intensity, 0.05), 0.9)
        if clamped != self.intensity {
            self.intensity = clamped
            for w in overlays { w.contentView?.layer?.backgroundColor = color }
        }
        if enabled && !isOn { start() } else if !enabled && isOn { stop() }
    }

    /// Re-evaluates the front window; call when Accessibility has just been granted.
    func refresh() {
        guard isOn else { return }
        watchedPID = 0
        followFrontApp()
    }

    private var color: CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: intensity) }

    // MARK: Lifecycle

    private func start() {
        isOn = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.followFrontApp() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.update(then: .resolve) }
        let local = NotificationCenter.default
        observe(local, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.rebuild() }
        // Flit's own windows (Preferences) can't be watched through AX from inside the process.
        observe(local, NSWindow.didBecomeMainNotification) { [weak self] in self?.update(then: .none) }
        observe(local, NSWindow.didMoveNotification) { [weak self] in self?.windowMoved() }
        observe(local, NSWindow.willCloseNotification) { [weak self] in self?.update(then: .resolve) }
        rebuild()
        followFrontApp()
    }

    private func stop() {
        isOn = false
        pending?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
        watcher = nil
        watchedPID = 0
        anchorElement = nil
        placed = nil
        let closing = overlays
        overlays = []
        displayFrames = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            for w in closing { w.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { for w in closing { w.orderOut(nil) } }
        })
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
        tokens.append((center, token))
    }

    // MARK: Overlays

    private func rebuild() {
        for w in overlays { w.orderOut(nil) }
        let screens = NSScreen.screens
        overlays = screens.map(makeOverlay)
        // The conversion is its own inverse: both systems share x and flip y about the main display.
        displayFrames = screens.map { Screens.appKitRect(fromCG: $0.frame) }
        placed = nil
        update(then: .none)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for w in overlays { w.animator().alphaValue = 1 }
        }
    }

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.animationBehavior = .none
        w.alphaValue = 0
        // A plain colored layer: the window server blends one solid quad, and
        // there is no full-screen bitmap to keep in memory.
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        return w
    }

    // MARK: Following the front window

    private func followFrontApp() {
        guard isOn, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        if pid != watchedPID {
            watchedPID = pid
            anchorElement = nil
            watcher = nil
            if pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() {
                watcher = AXWatcher(pid: pid, notifications: Self.appNotifications) { [weak self] name in
                    if name == kAXWindowMovedNotification { self?.windowMoved() } else { self?.update(then: .reorder) }
                }
            }
        }
        update(then: .resolve)
    }

    /// Puts the overlay of the front window's display under that window and
    /// takes the others away; with no front window (the desktop is in front)
    /// nothing is dimmed.
    private func update(then followUp: FollowUp) {
        guard isOn else { return }
        pending?.cancel()
        place(frontWindow())
        switch followUp {
        case .none: break
        case .reorder: after(0.15) { $0.reorder() }
        case .resolve: after(0.15) { $0.update(then: .none) }
        }
    }

    private func place(_ front: (window: Int, frame: CGRect)?) {
        guard let front, !overlays.isEmpty else {
            for w in overlays where w.isVisible { w.orderOut(nil) }
            placed = nil
            return
        }
        let display = TileGeometry.displayIndex(containing: front.frame, in: displayFrames)
        for (i, w) in overlays.enumerated() {
            if i == display {
                w.order(.below, relativeTo: front.window)
            } else if w.isVisible {
                w.orderOut(nil)
            }
        }
        placed = (front.window, display)
    }

    private func reorder() {
        guard isOn, let placed, overlays.indices.contains(placed.display) else { return }
        overlays[placed.display].order(.below, relativeTo: placed.window)
    }

    /// A drag reports every step. Wait for it to pause, then look only at
    /// which display the window is on now — no Accessibility round trips.
    private func windowMoved() {
        guard isOn, placed != nil else { return }
        pending?.cancel()
        after(0.25) { me in
            guard let placed = me.placed, let frame = Self.bounds(ofWindow: placed.window) else { return }
            if TileGeometry.displayIndex(containing: frame, in: me.displayFrames) != placed.display {
                me.place((placed.window, frame))
            }
        }
    }

    private func after(_ delay: TimeInterval, _ body: @escaping @MainActor (Dimmer) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOn else { return }
            body(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The window to keep lit and where it is (CG coordinates), or nil.
    private func frontWindow() -> (window: Int, frame: CGRect)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let own = NSApp.mainWindow ?? NSApp.keyWindow, !overlays.contains(own) else { return nil }
            return (own.windowNumber, Screens.appKitRect(fromCG: own.frame))
        }
        guard AXIsProcessTrusted() else { return nil }
        let ax = AXUIElement.application(app.processIdentifier, timeout: 0.2)
        // Finder's desktop is its focused "window" but not a real one: show the desktop undimmed.
        if app.bundleIdentifier == "com.apple.finder", ax.focusedWindow?.role == kAXScrollAreaRole {
            watch(nil)
            return nil
        }
        // Prefer the main window: with a sheet or panel focused, the document under it stays lit.
        func usable(_ window: AXUIElement?) -> AXUIElement? {
            guard let window, window.role == kAXWindowRole, !window.isMinimized else { return nil }
            return window
        }
        guard let target = usable(ax.mainWindow) ?? usable(ax.focusedWindow), let id = target.windowID else {
            watch(nil)
            return nil
        }
        watch(target)
        let frame = Self.bounds(ofWindow: Int(id))
            ?? CGRect(origin: target.position ?? .zero, size: target.size ?? .zero)
        return (Int(id), frame)
    }

    /// A window's bounds from the window server; needs no permission.
    private static func bounds(ofWindow number: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    /// Moves the per-window notifications to the new anchor.
    private func watch(_ element: AXUIElement?) {
        if let old = anchorElement, old != element {
            watcher?.remove(Self.windowNotifications, from: old)
        }
        if let element, anchorElement != element {
            watcher?.add(Self.windowNotifications, to: element)
        }
        anchorElement = element
    }
}

/// AX notifications from one app, delivered on the main run loop with the
/// notification's name.
final class AXWatcher {
    private var observer: AXObserver?
    private let handler: @MainActor (String) -> Void

    init?(pid: pid_t, notifications: [String], handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { me.handler(name) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        add(notifications, to: AXUIElement.application(pid))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func add(_ notifications: [String], to element: AXUIElement) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications { AXObserverAddNotification(observer, element, n as CFString, refcon) }
    }

    func remove(_ notifications: [String], from element: AXUIElement) {
        guard let observer else { return }
        for n in notifications { AXObserverRemoveNotification(observer, element, n as CFString) }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
