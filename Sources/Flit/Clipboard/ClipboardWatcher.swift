import AppKit
import ImageIO

/// Notices pasteboard changes and reads what was copied. macOS has no
/// notification for this, so the change counter has to be read. It is read
/// for a few seconds after each key press or click (see `PollSchedule`) and
/// not at all while the keyboard and mouse are quiet; the content itself is
/// read only when the counter has moved.
@MainActor
final class ClipboardWatcher {
    var onCopy: ((ClipContent, String?) -> Void)?
    var ignoreConcealed: () -> Bool = { true }
    var ignoredApps: () -> Set<String> = { [] }
    /// True while flit is being told about key presses (`noteInput`).
    var hasKeySignal: () -> Bool = { false }

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var lastChange = 0
    private var lastInput: TimeInterval = 0
    private(set) var isRunning = false

    /// Larger images and rich-text variants are not kept.
    private static let maxImageBytes = 30_000_000
    private static let maxRichBytes = 1_000_000

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChange = pasteboard.changeCount
        // Copies made from a menu or a button follow a click. Watching clicks needs no permission.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteInput() }
        }
        noteInput()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// The user pressed a key or clicked: a copy may follow.
    func noteInput() {
        guard isRunning else { return }
        lastInput = ProcessInfo.processInfo.systemUptime
        if timer == nil { schedule(after: PollSchedule.first) }
    }

    /// Looks right now, for a caller about to show the history.
    func pollNow() {
        if isRunning { poll() }
    }

    /// Call after flit writes to the pasteboard itself, so its own write is
    /// not recorded as a new copy.
    func sync() {
        lastChange = pasteboard.changeCount
    }

    private func schedule(after delay: TimeInterval) {
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        // Lets the system line this up with other wakeups instead of waking for it alone.
        t.tolerance = delay / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        timer = nil
        guard isRunning else { return }
        poll()
        let signal = hasKeySignal()
        // Without key presses to go by, fall back on the system's own idle clock.
        let quiet = signal
            ? ProcessInfo.processInfo.systemUptime - lastInput
            : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if let delay = PollSchedule.next(quietFor: quiet, hasInputSignal: signal) { schedule(after: delay) }
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        let types = pasteboard.types ?? []
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard ClipboardPolicy.shouldRecord(types: types.map(\.rawValue), sourceApp: app,
                                           ignoreConcealed: ignoreConcealed(), ignoredApps: ignoredApps()),
              let content = autoreleasepool(invoking: { read(types) }) else { return }
        onCopy?(content, app)
    }

    /// Files first (Finder also puts the file name on as text), then text
    /// (spreadsheets also put a picture of the cells on), then images.
    private func read(_ types: [NSPasteboard.PasteboardType]) -> ClipContent? {
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text, rtf: rich(.rtf, in: types), html: rich(.html, in: types))
        }
        var png: Data?
        if types.contains(.png) {
            png = pasteboard.data(forType: .png)
        } else if types.contains(.tiff), let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png, png.count <= Self.maxImageBytes,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return .image(png: png, width: width, height: height)
    }

    private func rich(_ type: NSPasteboard.PasteboardType, in types: [NSPasteboard.PasteboardType]) -> Data? {
        guard types.contains(type), let data = pasteboard.data(forType: type), data.count <= Self.maxRichBytes else { return nil }
        return data
    }
}

/// Puts history entries back on the pasteboard and pastes them.
@MainActor
enum Paster {
    static func write(text: String, rtf: Data?, html: Data?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let rtf { item.setData(rtf, forType: .rtf) }
        if let html { item.setData(html, forType: .html) }
        pb.writeObjects([item])
    }

    static func write(imageAt url: URL) {
        guard let png = try? Data(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // Older apps only take TIFF, which is many times larger; make it only if one asks.
        let provider = TIFFProvider(url: url)
        tiffProvider = provider
        item.setDataProvider(provider, forTypes: [.tiff])
        pb.writeObjects([item])
    }

    static func write(files paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    /// Sends ⌘V to the frontmost app. Needs the Accessibility grant.
    static func pasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(9)   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Kept alive until the next image is written; the pasteboard may call it later.
    private static var tiffProvider: TIFFProvider?

    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        let url: URL
        init(url: URL) { self.url = url }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let tiff = NSImage(contentsOf: url)?.tiffRepresentation else { return }
            item.setData(tiff, forType: .tiff)
        }
    }
}
