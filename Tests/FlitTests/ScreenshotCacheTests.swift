import Testing
import CoreGraphics
@testable import Flit

struct ScreenshotCacheTests {
    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test @MainActor func thumbnailsOfClosedWindowsAreDropped() {
        let shots = Screenshots()
        shots.store(image(), for: 1)
        shots.store(image(), for: 2)
        shots.prune(keeping: [1])
        #expect(shots.cached(1) != nil)
        #expect(shots.cached(2) == nil)
    }

    @Test @MainActor func clearDropsEveryThumbnail() {
        let shots = Screenshots()
        shots.store(image(), for: 1)
        shots.store(image(), for: 2)
        shots.clear()
        #expect(shots.cached(1) == nil)
        #expect(shots.cached(2) == nil)
    }
}
