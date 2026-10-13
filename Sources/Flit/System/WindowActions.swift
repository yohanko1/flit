import AppKit
import ApplicationServices

/// Focus and window-management actions. Every call is best-effort; results are
/// reflected by the next `WindowStore.refresh()`.
enum WindowActions {
    static func app(_ w: WindowInfo) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: w.pid)
    }

    static func focus(_ w: WindowInfo) {
        guard let app = app(w) else { return }
        if w.isAppPlaceholder {
            app.activate(options: [])
            app.unhide()
            return
        }
        if w.isHidden { app.unhide() }
        if let el = w.axElement {
            if w.isMinimized { el.set(kAXMinimizedAttribute, kCFBooleanFalse) }
            PrivateAPI.makeKeyWindow(pid: w.pid, windowID: w.id)
            el.perform(kAXRaiseAction)
            el.set(kAXMainAttribute, kCFBooleanTrue)
            el.set(kAXFocusedAttribute, kCFBooleanTrue)
        } else {
            PrivateAPI.makeKeyWindow(pid: w.pid, windowID: w.id)
        }
        app.activate(options: [])
        // Raise again after activation: some apps ignore the raise while in background.
        if let el = w.axElement {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                el.perform(kAXRaiseAction)
            }
        }
    }

    static func close(_ w: WindowInfo) {
        guard let el = w.axElement else { return }
        if let button = el.attribute(kAXCloseButtonAttribute, as: AXUIElement.self) {
            button.perform(kAXPressAction)
        }
    }

    static func toggleMinimize(_ w: WindowInfo) {
        guard let el = w.axElement else { return }
        el.set(kAXMinimizedAttribute, w.isMinimized ? kCFBooleanFalse : kCFBooleanTrue)
    }

    static func toggleFullscreen(_ w: WindowInfo) {
        guard let el = w.axElement else { return }
        el.set("AXFullScreen", w.isFullscreen ? kCFBooleanFalse : kCFBooleanTrue)
    }

    static func toggleHide(_ w: WindowInfo) {
        guard let app = app(w) else { return }
        if app.isHidden { app.unhide() } else { app.hide() }
    }

    static func quit(_ w: WindowInfo) {
        app(w)?.terminate()
    }
}
