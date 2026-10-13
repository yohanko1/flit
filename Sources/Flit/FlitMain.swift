import AppKit

@main
struct FlitMain {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--dump") {
            // Launch via `open -n Flit.app --args --dump /path` so TCC attributes
            // the run to Flit, not the terminal.
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            Diagnostics.dump(to: path)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// `Flit --dump`: prints permissions, the raw CG window list, the joined
/// store entries, and tries one screenshot. For debugging from a terminal.
@MainActor
enum Diagnostics {
    static var out = ""
    static func print(_ s: String) { out += s + "\n"; Swift.print(s) }

    static func dump(to path: String?) {
        defer { if let path { try? out.write(toFile: path, atomically: true, encoding: .utf8) } }
        print("accessibility: \(Permissions.accessibility)  screenRecording: \(Permissions.screenRecording)")
        print("active spaces: \(PrivateAPI.currentSpacesOnAllDisplays)")

        let raw = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        print("\n== raw CG windows (layer 0, regular apps) ==")
        for e in raw {
            guard (e[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let pid = e[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            let id = e[kCGWindowNumber as String] as? CGWindowID ?? 0
            let b = e[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            print(String(format: "%6d %-20@ on=%d a=%.2f %4.0fx%-4.0f spaces=%@ cgname=%@",
                         id, (app.localizedName ?? "?") as NSString,
                         (e[kCGWindowIsOnscreen as String] as? Bool ?? false) ? 1 : 0,
                         e[kCGWindowAlpha as String] as? Double ?? -1,
                         b["Width"] ?? 0, b["Height"] ?? 0,
                         String(describing: PrivateAPI.spaces(for: id)) as NSString,
                         (e[kCGWindowName as String] as? String ?? "") as NSString))
        }

        print("\n== native ⌘-Tab hotkey ==")
        print("before: \(String(describing: PrivateAPI.isNativeHotKeyEnabled(.commandTab)))")
        print("disable ok: \(PrivateAPI.setNativeSwitcher(enabled: false))")
        print("after disable: \(String(describing: PrivateAPI.isNativeHotKeyEnabled(.commandTab)))")
        print("restore ok: \(PrivateAPI.setNativeSwitcher(enabled: true))")
        print("after restore: \(String(describing: PrivateAPI.isNativeHotKeyEnabled(.commandTab)))")

        print("\n== store entries ==")
        let ws = WindowStore.shared.refresh()
        for w in ws {
            print("\(w.id) \(w.appName) | \(w.title) | min=\(w.isMinimized) hid=\(w.isHidden) fs=\(w.isFullscreen) tab=\(w.isTab) active=\(w.isOnActiveSpace) spaces=\(w.spaceIDs) ax=\(w.axElement != nil) ph=\(w.isAppPlaceholder)")
        }

        if let first = ws.first(where: { !$0.isAppPlaceholder && $0.isOnScreen }) {
            print("\n== screenshot of \(first.id) \(first.appName) ==")
            let sem = DispatchSemaphore(value: 0)
            Screenshots.shared.capture([first.id]) { id, img in
                print("got \(img.width)x\(img.height) for \(id)")
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(5)
            while sem.wait(timeout: .now()) == .timedOut && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if Date() >= deadline { print("no image after 5 s") }
        }
    }
}
