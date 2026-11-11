import AppKit

enum Screens {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    /// Display containing the center of a CG-coordinate (top-left origin) rect.
    static func displayID(containing cgRect: CGRect) -> CGDirectDisplayID? {
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 16, &ids, &count) == .success, count > 0 else {
            var c: UInt32 = 0
            guard CGGetDisplaysWithRect(cgRect, 16, &ids, &c) == .success, c > 0 else { return nil }
            return ids[0]
        }
        return ids[0]
    }

    static var cursorScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }
    }

    static var cursorDisplayID: CGDirectDisplayID? { cursorScreen.flatMap(displayID(of:)) }

    /// Converts a CG rect (origin top-left of main display) to AppKit coordinates.
    static func appKitRect(fromCG r: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return r }
        let h = main.frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The usable area of every display — below the menu bar, clear of the
    /// Dock — in CG coordinates, ordered left to right.
    static var usableFramesCG: [CGRect] {
        // The conversion is its own inverse: both systems share x and flip y about the main display.
        NSScreen.screens.map { appKitRect(fromCG: $0.visibleFrame) }
            .sorted { $0.minX != $1.minX ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    static func screen(for preference: SwitcherScreen, focusedWindowDisplay: CGDirectDisplayID?) -> NSScreen {
        switch preference {
        case .cursor: return cursorScreen ?? NSScreen.main ?? NSScreen.screens[0]
        case .main: return NSScreen.screens.first ?? NSScreen.main!
        case .active:
            return screen(for: focusedWindowDisplay) ?? NSScreen.main ?? NSScreen.screens[0]
        }
    }
}
