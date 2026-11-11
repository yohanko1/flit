import Testing
import CoreGraphics
@testable import Flit

struct TileGeometryTests {
    /// A 1440×900 display with a 25 pt menu bar and no Dock.
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let floating = CGRect(x: 200, y: 150, width: 800, height: 600)

    @Test func leftStepsThroughHalfTwoThirdsThird() {
        #expect(TileGeometry.frames(for: .left, in: visible) == [
            CGRect(x: 0, y: 25, width: 720, height: 875),
            CGRect(x: 0, y: 25, width: 960, height: 875),
            CGRect(x: 0, y: 25, width: 480, height: 875),
        ])
    }

    @Test func rightStepsStayAnchoredToTheRightEdge() {
        #expect(TileGeometry.frames(for: .right, in: visible) == [
            CGRect(x: 720, y: 25, width: 720, height: 875),
            CGRect(x: 480, y: 25, width: 960, height: 875),
            CGRect(x: 960, y: 25, width: 480, height: 875),
        ])
    }

    @Test func maximizeAndThirdsHaveOneFrameEach() {
        #expect(TileGeometry.frames(for: .maximize, in: visible) == [visible])
        #expect(TileGeometry.frames(for: .leftThird, in: visible) == [CGRect(x: 0, y: 25, width: 480, height: 875)])
        #expect(TileGeometry.frames(for: .centerThird, in: visible) == [CGRect(x: 480, y: 25, width: 480, height: 875)])
        #expect(TileGeometry.frames(for: .rightThird, in: visible) == [CGRect(x: 960, y: 25, width: 480, height: 875)])
    }

    @Test func oddWidthsSplitOnWholePointsWithoutGapOrOverlap() {
        let odd = CGRect(x: 0, y: 25, width: 1441, height: 875)
        #expect(TileGeometry.frames(for: .left, in: odd)[0] == CGRect(x: 0, y: 25, width: 721, height: 875))
        #expect(TileGeometry.frames(for: .right, in: odd)[0] == CGRect(x: 721, y: 25, width: 720, height: 875))
    }

    @Test func secondDisplayOffsetIsRespected() {
        let external = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        #expect(TileGeometry.frames(for: .right, in: external)[0] == CGRect(x: 2720, y: 0, width: 1280, height: 1415))
    }

    @Test func firstPressStartsAtStepZeroAndRemembersWhereTheWindowWas() {
        let s = TileGeometry.plan(.left, current: floating, visible: visible, last: nil)
        #expect(s.frame == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(s.step == 0)
        #expect(s.restore == floating)
    }

    @Test func repeatedPressAdvancesAndWrapsWhileKeepingTheOriginalFrame() {
        var s = TileGeometry.plan(.left, current: floating, visible: visible, last: nil)
        s = TileGeometry.plan(.left, current: s.frame, visible: visible, last: s)
        #expect(s.frame == CGRect(x: 0, y: 25, width: 960, height: 875))
        s = TileGeometry.plan(.left, current: s.frame, visible: visible, last: s)
        #expect(s.frame == CGRect(x: 0, y: 25, width: 480, height: 875))
        s = TileGeometry.plan(.left, current: s.frame, visible: visible, last: s)
        #expect(s.frame == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(s.restore == floating)
    }

    @Test func switchingActionStartsThatActionOverButKeepsTheOriginalFrame() {
        var s = TileGeometry.plan(.left, current: floating, visible: visible, last: nil)
        s = TileGeometry.plan(.left, current: s.frame, visible: visible, last: s)
        s = TileGeometry.plan(.right, current: s.frame, visible: visible, last: s)
        #expect(s.frame == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(s.step == 0)
        #expect(s.restore == floating)
    }

    @Test func movingTheWindowByHandStartsTheCycleOver() {
        let first = TileGeometry.plan(.left, current: floating, visible: visible, last: nil)
        let dragged = CGRect(x: 300, y: 300, width: 720, height: 600)
        let s = TileGeometry.plan(.left, current: dragged, visible: visible, last: first)
        #expect(s.step == 0)
        #expect(s.restore == dragged)
    }

    @Test func cycleContinuesWhenTheAppRoundedTheFrameSlightly() {
        // Terminal-style apps snap to character cells; the caller stores what the window really took.
        var first = TileGeometry.plan(.left, current: floating, visible: visible, last: nil)
        first.frame = CGRect(x: 0, y: 25, width: 714, height: 868)
        let s = TileGeometry.plan(.left, current: CGRect(x: 0, y: 25, width: 714, height: 868), visible: visible, last: first)
        #expect(s.step == 1)
    }

    @Test func restoreReturnsTheOriginalFrameOnlyWhileTheWindowIsStillTiled() {
        let s = TileGeometry.plan(.maximize, current: floating, visible: visible, last: nil)
        #expect(TileGeometry.restoreFrame(current: s.frame, last: s) == floating)
        let dragged = CGRect(x: 10, y: 40, width: 500, height: 400)
        #expect(TileGeometry.restoreFrame(current: dragged, last: s) == nil)
        #expect(TileGeometry.restoreFrame(current: floating, last: nil) == nil)
    }

    @Test func movingToAnotherDisplayKeepsTheSameProportions() {
        let external = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)
        #expect(TileGeometry.move(rightHalf, from: visible, to: external) == CGRect(x: 2720, y: 0, width: 1280, height: 1415))
    }

    @Test func nextDisplayWrapsInBothDirections() {
        #expect(TileGeometry.displayIndex(after: 0, count: 2, forward: true) == 1)
        #expect(TileGeometry.displayIndex(after: 1, count: 3, forward: true) == 2)
        #expect(TileGeometry.displayIndex(after: 2, count: 3, forward: true) == 0)
        #expect(TileGeometry.displayIndex(after: 0, count: 3, forward: false) == 2)
        #expect(TileGeometry.displayIndex(after: 0, count: 1, forward: true) == 0)
    }

    @Test func picksTheDisplayHoldingMostOfTheWindow() {
        let screens = [visible, CGRect(x: 1440, y: 0, width: 2560, height: 1415)]
        #expect(TileGeometry.displayIndex(containing: CGRect(x: 1300, y: 100, width: 800, height: 600), in: screens) == 1)
        #expect(TileGeometry.displayIndex(containing: CGRect(x: 900, y: 100, width: 600, height: 600), in: screens) == 0)
        #expect(TileGeometry.displayIndex(containing: CGRect(x: 9000, y: 9000, width: 10, height: 10), in: screens) == 0)
    }
}
