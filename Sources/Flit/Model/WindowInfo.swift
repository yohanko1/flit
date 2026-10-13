import AppKit
import ApplicationServices

/// One entry in the switcher. Value type so it can be filtered and sorted
/// freely; the `axElement` and `thumbnail` are reference handles.
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var appName: String
    var bundleID: String?
    var title: String
    var frame: CGRect              // CG coordinates (top-left origin)
    var isMinimized: Bool
    var isHidden: Bool             // owning app is hidden
    var isFullscreen: Bool
    var isTab: Bool                // background tab of a native tab group
    var spaceIDs: [UInt64]
    var isOnActiveSpace: Bool
    var screenID: CGDirectDisplayID?
    var isOnScreen: Bool
    var axElement: AXUIElement?
    var thumbnail: CGImage?
    var lastFocused: Date
    /// Placeholder entry for an app with no windows (Finder with nothing open).
    var isAppPlaceholder: Bool = false

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isHidden == rhs.isHidden
            && lhs.isFullscreen == rhs.isFullscreen
            && lhs.isOnActiveSpace == rhs.isOnActiveSpace
            && lhs.lastFocused == rhs.lastFocused
            && lhs.thumbnail === rhs.thumbnail
    }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var appIcon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// Small test/preview helper.
    static func sample(id: CGWindowID, pid: pid_t = 1, app: String = "App", title: String = "",
                       bundleID: String? = nil, minimized: Bool = false, hidden: Bool = false,
                       fullscreen: Bool = false, tab: Bool = false, onActiveSpace: Bool = true,
                       screen: CGDirectDisplayID? = 1, lastFocused: Date = Date(),
                       placeholder: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: pid, appName: app, bundleID: bundleID, title: title,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                   isMinimized: minimized, isHidden: hidden, isFullscreen: fullscreen, isTab: tab,
                   spaceIDs: [], isOnActiveSpace: onActiveSpace, screenID: screen,
                   isOnScreen: !minimized && onActiveSpace, axElement: nil, thumbnail: nil,
                   lastFocused: lastFocused, isAppPlaceholder: placeholder)
    }
}
