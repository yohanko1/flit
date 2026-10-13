import AppKit
import ApplicationServices

/// Thin optional-returning wrappers over AXUIElement.
extension AXUIElement {
    static func application(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    func attribute<T>(_ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var windows: [AXUIElement] {
        attribute(kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    }

    var title: String { attribute(kAXTitleAttribute, as: String.self) ?? "" }
    var subrole: String? { attribute(kAXSubroleAttribute, as: String.self) }
    var role: String? { attribute(kAXRoleAttribute, as: String.self) }
    var isMinimized: Bool { attribute(kAXMinimizedAttribute, as: Bool.self) ?? false }
    var isFullscreen: Bool { attribute("AXFullScreen", as: Bool.self) ?? false }
    var focusedWindow: AXUIElement? { attribute(kAXFocusedWindowAttribute, as: AXUIElement.self) }

    var windowID: CGWindowID? { PrivateAPI.windowID(of: self) }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }

    var position: CGPoint? {
        guard let v = attribute(kAXPositionAttribute, as: AXValue.self) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = attribute(kAXSizeAttribute, as: AXValue.self) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// Windows the switcher should list: standard windows and dialogs, not
    /// popovers, sheets, or floating palettes.
    var isSwitchable: Bool {
        guard role == kAXWindowRole else { return false }
        switch subrole {
        case kAXStandardWindowSubrole, kAXDialogSubrole, nil: return true
        default: return false
        }
    }
}

/// Observes focus changes inside one application so MRU order stays right
/// even when windows are switched without flit.
final class AXFocusObserver {
    private var observer: AXObserver?
    let pid: pid_t
    private let handler: (CGWindowID?) -> Void

    init?(pid: pid_t, handler: @escaping (CGWindowID?) -> Void) {
        self.pid = pid
        self.handler = handler
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(element.windowID)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let app = AXUIElement.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
