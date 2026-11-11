import AppKit
import ApplicationServices

/// Moves and resizes the focused window through Accessibility.
@MainActor
final class Tiler {
    enum Command {
        case tile(TileAction)
        case restore
        case display(forward: Bool)
    }

    /// What flit last did to each window, for cycling and restore.
    private var states: [CGWindowID: TileState] = [:]

    func perform(_ command: Command) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElement.application(app.processIdentifier, timeout: 0.5)
        guard let window = axApp.focusedWindow ?? axApp.mainWindow,
              window.role == kAXWindowRole, !window.isFullscreen,
              let position = window.position, let size = window.size else { return }
        let current = CGRect(origin: position, size: size)
        let displays = Screens.usableFramesCG
        guard !displays.isEmpty else { return }
        let index = TileGeometry.displayIndex(containing: current, in: displays)
        let visible = displays[index]
        // Without a window ID there is nothing to key the memory on: tiling
        // still works, cycling and restore do not.
        let id = window.windowID
        let last = id.flatMap { states[$0] }

        switch command {
        case .tile(let action):
            var state = TileGeometry.plan(action, current: current, visible: visible, last: last)
            state.frame = place(window, of: axApp, at: state.frame, within: visible)
            if let id { remember(state, for: id) }
        case .restore:
            guard let id, let frame = TileGeometry.restoreFrame(current: current, last: last) else { return }
            _ = place(window, of: axApp, at: frame, within: nil)
            states[id] = nil
        case .display(let forward):
            guard displays.count > 1 else { return }
            let target = displays[TileGeometry.displayIndex(after: index, count: displays.count, forward: forward)]
            let actual = place(window, of: axApp, at: TileGeometry.move(current, from: visible, to: target), within: target)
            // A tiled window stays tiled on the new display, so its cycle continues there.
            if let id, var state = last, TileGeometry.approxEqual(current, state.frame) {
                state.frame = actual
                states[id] = state
            }
        }
    }

    /// Applies `frame` and returns the frame the window really took.
    private func place(_ window: AXUIElement, of app: AXUIElement, at frame: CGRect, within visible: CGRect?) -> CGRect {
        // Apps with "enhanced user interface" on (set by VoiceOver and some
        // tools) animate AX moves, which makes them slow and imprecise.
        let enhanced = app.attribute("AXEnhancedUserInterface", as: Bool.self) ?? false
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        window.setFrame(frame)
        var actual = CGRect(origin: window.position ?? frame.origin, size: window.size ?? frame.size)
        // A window that can't shrink to the tile must not hang off the display.
        if let visible {
            var origin = actual.origin
            if actual.maxX > visible.maxX { origin.x = max(visible.minX, visible.maxX - actual.width) }
            if actual.maxY > visible.maxY { origin.y = max(visible.minY, visible.maxY - actual.height) }
            if origin != actual.origin {
                window.setPosition(origin)
                actual.origin = window.position ?? origin
            }
        }
        return actual
    }

    private func remember(_ state: TileState, for id: CGWindowID) {
        // Closed windows leave entries behind; start over rather than track closes.
        if states.count > 200 { states.removeAll() }
        states[id] = state
    }
}
