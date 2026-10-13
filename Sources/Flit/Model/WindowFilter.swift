import Foundation
import CoreGraphics

/// Which windows the switcher shows, and in what order. Pure: no system calls.
struct WindowFilter: Codable, Equatable {
    enum DisplayScope: String, Codable, CaseIterable, Identifiable {
        case all, cursorScreen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All displays"
            case .cursorScreen: return "Display with the cursor"
            }
        }
    }

    var showMinimized = true
    var showHidden = true
    var showOtherSpaces = true
    var showFullscreen = true
    var showWindowlessApps = false
    var displayScope: DisplayScope = .all
    var currentAppOnly = false

    /// Not persisted per-profile; passed in at apply time.
    struct Context {
        var cursorScreenID: CGDirectDisplayID?
        var frontmostPID: pid_t?
        var blacklist: Set<String> = []      // bundle IDs
        var query: String = ""
    }

    func apply(_ windows: [WindowInfo], context: Context) -> [WindowInfo] {
        var out = windows.filter { w in
            if let b = w.bundleID, context.blacklist.contains(b) { return false }
            if w.isAppPlaceholder && !showWindowlessApps { return false }
            if !showMinimized && w.isMinimized { return false }
            if !showHidden && w.isHidden { return false }
            if !showOtherSpaces && !w.isOnActiveSpace && !w.isMinimized && !w.isHidden { return false }
            if !showFullscreen && w.isFullscreen { return false }
            if displayScope == .cursorScreen, let cursor = context.cursorScreenID,
               let screen = w.screenID, screen != cursor, !w.isMinimized { return false }
            if currentAppOnly, let front = context.frontmostPID, w.pid != front { return false }
            return true
        }
        let q = context.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter { Self.matches($0, query: q) }
        }
        return out.sorted { a, b in
            if a.lastFocused != b.lastFocused { return a.lastFocused > b.lastFocused }
            return a.id < b.id
        }
    }

    /// Case-insensitive subsequence match on "app title" — "chr ma" matches "Chrome — Mail".
    static func matches(_ w: WindowInfo, query: String) -> Bool {
        let hay = (w.appName + " " + w.title).lowercased()
        for term in query.lowercased().split(separator: " ") {
            if !hay.contains(term) && !isSubsequence(term, of: hay) { return false }
        }
        return true
    }

    private static func isSubsequence(_ needle: Substring, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() { if h == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
