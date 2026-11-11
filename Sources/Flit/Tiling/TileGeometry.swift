import CoreGraphics

/// A tile position. `left` and `right` step through three widths on repeated
/// presses; the others have one frame.
enum TileAction: String, CaseIterable {
    case left, right, maximize, leftThird, centerThird, rightThird
}

/// What flit last did to a window: enough to continue a cycle and to put the
/// window back.
struct TileState: Equatable {
    var action: TileAction
    var step: Int
    /// Where the window ended up. The caller overwrites this with the frame
    /// the app actually accepted, which can differ from the one requested.
    var frame: CGRect
    /// Where the window was before flit first tiled it.
    var restore: CGRect
}

/// Pure tiling math. All rects are in CG coordinates (top-left origin).
enum TileGeometry {
    /// Horizontal spans as fractions of the usable width.
    private static func spans(for action: TileAction) -> [(from: (CGFloat, CGFloat), to: (CGFloat, CGFloat))] {
        switch action {
        case .left: return [((0, 1), (1, 2)), ((0, 1), (2, 3)), ((0, 1), (1, 3))]
        case .right: return [((1, 2), (1, 1)), ((1, 3), (1, 1)), ((2, 3), (1, 1))]
        case .maximize: return [((0, 1), (1, 1))]
        case .leftThird: return [((0, 1), (1, 3))]
        case .centerThird: return [((1, 3), (2, 3))]
        case .rightThird: return [((2, 3), (1, 1))]
        }
    }

    /// The frames `action` steps through. Edges land on whole points, so
    /// neighbouring tiles neither overlap nor leave a gap.
    static func frames(for action: TileAction, in visible: CGRect) -> [CGRect] {
        spans(for: action).map { span in
            let x0 = (visible.minX + visible.width * span.from.0 / span.from.1).rounded()
            let x1 = (visible.minX + visible.width * span.to.0 / span.to.1).rounded()
            return CGRect(x: x0, y: visible.minY, width: x1 - x0, height: visible.height)
        }
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The next state for `action`. Pressing the same action again while the
    /// window is still where flit put it advances the cycle; anything else
    /// starts at the first frame. The pre-tile frame is carried along until
    /// the user moves the window themselves.
    static func plan(_ action: TileAction, current: CGRect, visible: CGRect, last: TileState?) -> TileState {
        let frames = frames(for: action, in: visible)
        if let last, approxEqual(current, last.frame) {
            let step = last.action == action ? (last.step + 1) % frames.count : 0
            return TileState(action: action, step: step, frame: frames[step], restore: last.restore)
        }
        return TileState(action: action, step: 0, frame: frames[0], restore: current)
    }

    /// The frame to put the window back to, or nil if flit didn't place it
    /// where it is now.
    static func restoreFrame(current: CGRect, last: TileState?) -> CGRect? {
        guard let last, approxEqual(current, last.frame) else { return nil }
        return last.restore
    }

    /// Maps a frame from one display's usable area to another's, keeping its
    /// relative position and size.
    static func move(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return to }
        let x = to.minX + (frame.minX - from.minX) / from.width * to.width
        let y = to.minY + (frame.minY - from.minY) / from.height * to.height
        let w = frame.width / from.width * to.width
        let h = frame.height / from.height * to.height
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    static func displayIndex(after index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return ((index + (forward ? 1 : -1)) % count + count) % count
    }

    /// The display holding the largest part of `frame`; the first one if the
    /// window is on none.
    static func displayIndex(containing frame: CGRect, in displays: [CGRect]) -> Int {
        var best = 0
        var bestArea: CGFloat = 0
        for (i, d) in displays.enumerated() {
            let overlap = d.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { best = i; bestArea = area }
        }
        return best
    }
}
