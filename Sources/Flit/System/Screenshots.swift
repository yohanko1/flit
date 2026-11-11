import AppKit
import ScreenCaptureKit

/// ScreenCaptureKit window captures with a per-window cache. Captures run
/// concurrently; callers get the cached image immediately and a callback when
/// a fresh one lands.
@MainActor
final class Screenshots {
    static let shared = Screenshots()

    private var cache: [CGWindowID: CGImage] = [:]
    private var content: SCShareableContent?
    private var contentFetchedAt: Date = .distantPast
    private var inflight: Set<CGWindowID> = []

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    func forget(_ id: CGWindowID) { cache.removeValue(forKey: id) }

    func store(_ image: CGImage, for id: CGWindowID) { cache[id] = image }

    /// Drops thumbnails of windows that no longer exist.
    func prune(keeping live: Set<CGWindowID>) {
        cache = cache.filter { live.contains($0.key) }
    }

    /// Drops every thumbnail and the window list they were captured from.
    func clear() {
        cache.removeAll()
        content = nil
        contentFetchedAt = .distantPast
    }

    /// Refreshes the shareable-content list at most every 2 s.
    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentFetchedAt) < 2 { return content }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            content = c
            contentFetchedAt = Date()
            return c
        } catch {
            Log.info("shareable content failed: \(error)")
            return nil
        }
    }

    /// Captures `ids` concurrently, calling `onImage` on the main actor for each.
    func capture(_ ids: [CGWindowID], maxPixels: Int = 640, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        guard Self.hasPermission else { return }
        let todo = ids.filter { !inflight.contains($0) }
        guard !todo.isEmpty else { return }
        todo.forEach { inflight.insert($0) }
        Task { [weak self] in
            guard let self, let content = await self.shareableContent() else {
                await MainActor.run { todo.forEach { self?.inflight.remove($0) } }
                return
            }
            let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in todo {
                    guard let w = byID[id] else { continue }
                    group.addTask { (id, await Self.captureWindow(w, maxPixels: maxPixels)) }
                }
                for await (id, img) in group {
                    self.inflight.remove(id)
                    if let img {
                        self.store(img, for: id)
                        onImage(id, img)
                    }
                }
            }
            todo.forEach { self.inflight.remove($0) }
        }
    }

    /// Full-resolution capture for the preview panel.
    func captureFull(_ id: CGWindowID) async -> CGImage? {
        guard Self.hasPermission, let content = await shareableContent(),
              let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        return await Self.captureWindow(w, maxPixels: 0)
    }

    nonisolated private static func captureWindow(_ w: SCWindow, maxPixels: Int) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.captureResolution = .best
        let scale = (NSScreen.main?.backingScaleFactor ?? 2)
        var size = CGSize(width: max(w.frame.width, 1) * scale, height: max(w.frame.height, 1) * scale)
        if maxPixels > 0, max(size.width, size.height) > CGFloat(maxPixels) {
            let f = CGFloat(maxPixels) / max(size.width, size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }
}
