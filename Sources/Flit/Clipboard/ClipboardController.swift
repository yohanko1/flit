import AppKit
import Carbon.HIToolbox
import ImageIO

/// Clipboard history and snippets: owns the store, the pasteboard watcher and
/// the panel, and holds the panel's state while it is open.
@MainActor
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    enum Preview: Equatable {
        case none
        case text(String)
        case image(NSImage)
        case files([String])
    }

    @Published var query = "" {
        didSet { if query != oldValue { reload(keepSelection: false) } }
    }
    @Published private(set) var mode: ClipRow.Mode = .history
    @Published private(set) var rows: [ClipRow] = []
    @Published private(set) var selection = 0
    @Published private(set) var preview: Preview = .none
    @Published private(set) var details: [(label: String, value: String)] = []
    @Published private(set) var notice: String?
    /// Opens Preferences on the Snippets pane.
    var onEditSnippets: (() -> Void)?

    /// nil if the history folder could not be opened; the feature is then off.
    let store: ClipboardStore?
    private let watcher = ClipboardWatcher()
    private let prefs = Preferences.shared
    private var panel: ClipboardPanel?
    private var noticeClear: DispatchWorkItem?
    private let thumbnails = NSCache<NSNumber, NSImage>()

    private static let previewCharacters = 20_000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var directory = support.appendingPathComponent("Flit", isDirectory: true)
        #if DEBUG
        // Screenshots run on sample data in a directory of their own, never on the real history.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), args.count > i + 1 {
            directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        #endif
        do {
            store = try ClipboardStore(directory: directory)
        } catch {
            Log.info("clipboard store unavailable: \(error)")
            store = nil
        }
        thumbnails.countLimit = 60
        watcher.ignoreConcealed = { [prefs] in prefs.clipboardIgnoreConcealed }
        watcher.ignoredApps = { [prefs] in Set(prefs.clipboardIgnoredApps) }
        watcher.onCopy = { [weak self] content, app in
            guard let self, let store = self.store else { return }
            store.add(content, app: app, now: Date())
            if self.isVisible { self.reload(keepSelection: true) }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// A key was pressed somewhere: a copy may follow. Called by the event tap.
    func noteInput() { watcher.noteInput() }

    /// Whether `noteInput` is being fed right now; without it the watcher keeps polling.
    var hasKeySignal: () -> Bool {
        get { watcher.hasKeySignal }
        set { watcher.hasKeySignal = newValue }
    }

    /// Starts or stops recording copies.
    func setRecording(_ on: Bool) {
        guard store != nil else { return }
        #if DEBUG
        // What gets copied while screenshots are taken must not end up in them.
        if Screenshooter.isRequested { return }
        #endif
        if on, !watcher.isRunning {
            watcher.start()
            prune()
        } else if !on, watcher.isRunning {
            watcher.stop()
            hide()
        }
    }

    private func prune() {
        let days = max(prefs.clipboardRetentionDays, 1)
        store?.prune(olderThan: Date().addingTimeInterval(-Double(days) * 86_400), max: max(prefs.clipboardMaxItems, 1))
    }

    // MARK: Panel

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard store != nil else { return }
        // Pick up a copy made without any key press or click (a script, another tool).
        watcher.pollNow()
        prune()
        mode = .history
        query = ""
        reload(keepSelection: false)
        if panel == nil { panel = ClipboardPanel(controller: self) }
        panel?.present()
    }

    func hide() {
        guard let panel else { return }
        // The panel, its view tree and the decoded images go away with it;
        // rebuilding takes a few milliseconds on the next open. Dropping the
        // reference first also stops the resign-key callback from re-entering.
        self.panel = nil
        panel.orderOut(nil)
        // hide() can run from inside the panel's own event handling: keep it alive until that returns.
        DispatchQueue.main.async { _ = panel }
        rows = []
        preview = .none
        details = []
        thumbnails.removeAllObjects()
    }

    // MARK: Rows and selection

    var selectedRow: ClipRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func setMode(_ new: ClipRow.Mode) {
        guard new != mode else { return }
        mode = new
        reload(keepSelection: false)
    }

    func select(index: Int) {
        guard rows.indices.contains(index), index != selection else { return }
        selection = index
        refreshPreview()
    }

    func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
        refreshPreview()
    }

    private func reload(keepSelection: Bool) {
        guard let store else { return }
        let keep = keepSelection ? selectedRow?.id : nil
        rows = ClipRow.build(store: store, mode: mode, query: query)
        selection = keep.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        refreshPreview()
    }

    // MARK: Keys

    /// Returns true if the key was handled; false lets the search field have it.
    func handleKey(_ event: NSEvent, composing: Bool) -> Bool {
        let mods = Hotkey.Modifiers(event.modifierFlags)
        // While an input method is composing, Return and the arrows belong to it.
        if composing { return false }
        switch Int(event.keyCode) {
        case kVK_DownArrow: move(by: 1)
        case kVK_UpArrow: move(by: -1)
        case kVK_ANSI_N where mods == .control: move(by: 1)
        case kVK_ANSI_P where mods == .control: move(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            activate(plain: mods.contains(.shift), copyOnly: mods.contains(.command))
        case kVK_Escape:
            if query.isEmpty { hide() } else { query = "" }
        case kVK_Tab:
            setMode(mode == .history ? .snippets : .history)
        case kVK_ANSI_S where mods == .command: saveSelectedAsSnippet()
        case kVK_ANSI_E where mods == .command:
            hide()
            onEditSnippets?()
        case kVK_ANSI_X where mods == .control: deleteSelected()
        case kVK_Delete where mods == .command && query.isEmpty: deleteSelected()
        default: return false
        }
        return true
    }

    // MARK: Actions

    /// Puts the selected row on the pasteboard and, unless `copyOnly`, pastes
    /// it into the app that was in front. `plain` leaves formatting behind.
    func activate(plain: Bool = false, copyOnly: Bool = false) {
        guard let store, let row = selectedRow else { return }
        switch row {
        case .snippet(let snippet):
            let text = SnippetExpander.expand(snippet.text, now: Date(), calendar: .current,
                                              clipboard: NSPasteboard.general.string(forType: .string))
            Paster.write(text: text, rtf: nil, html: nil)
        case .entry(let entry):
            switch entry.kind {
            case .text, .link:
                guard let text = store.fullText(id: entry.id) else { return }
                let rich = plain ? (rtf: nil, html: nil) : store.rich(id: entry.id)
                Paster.write(text: text, rtf: rich.rtf, html: rich.html)
            case .image:
                guard let url = store.imageURL(entry) else { return }
                Paster.write(imageAt: url)
            case .file:
                guard let paths = store.fullText(id: entry.id) else { return }
                Paster.write(files: paths.split(separator: "\n").map(String.init))
            }
            store.touch(id: entry.id, now: Date())
        }
        watcher.sync()
        hide()
        guard !copyOnly else { return }
        // Give the front app a moment to take keyboard focus back from the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.pasteKeystroke() }
    }

    func saveSelectedAsSnippet() {
        guard let store, case .entry(let entry) = selectedRow else { return }
        guard entry.kind == .text || entry.kind == .link, let text = store.fullText(id: entry.id) else {
            show(notice: "Only text can be saved as a snippet")
            return
        }
        store.addSnippet(name: String(entry.title.prefix(40)), text: text)
        show(notice: "Saved to snippets")
        if !query.isEmpty || mode == .snippets { reload(keepSelection: true) }
    }

    func deleteSelected() {
        guard let store, let row = selectedRow else { return }
        switch row {
        case .snippet(let s): store.deleteSnippet(id: s.id)
        case .entry(let e): store.delete(id: e.id)
        }
        let index = selection
        reload(keepSelection: false)
        selection = min(index, max(rows.count - 1, 0))
        refreshPreview()
    }

    private func show(notice text: String) {
        noticeClear?.cancel()
        notice = text
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Preview

    private func refreshPreview() {
        guard let store, let row = selectedRow else {
            preview = .none
            details = []
            return
        }
        switch row {
        case .snippet(let s):
            preview = .text(String(s.text.prefix(Self.previewCharacters)))
            details = [("Snippet", s.name), ("Size", Self.characters(s.text.count))]
        case .entry(let e):
            var info: [(String, String)] = []
            switch e.kind {
            case .text, .link:
                let full = e.length > e.text.count ? (store.fullText(id: e.id) ?? e.text) : e.text
                preview = .text(String(full.prefix(Self.previewCharacters)))
                info.append(("Type", e.kind == .link ? "Link" : "Text"))
                info.append(("Size", Self.characters(e.length)))
            case .image:
                preview = store.imageURL(e).flatMap { Self.downsampled($0, maxPixel: 1000) }.map(Preview.image) ?? .none
                info.append(("Type", "Image"))
                info.append(("Size", "\(e.width)×\(e.height) · \(ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file))"))
            case .file:
                let paths = (store.fullText(id: e.id) ?? e.text).split(separator: "\n").map(String.init)
                preview = .files(paths)
                info.append(("Type", paths.count == 1 ? "File" : "\(paths.count) files"))
            }
            if let app = e.app, let name = Self.appName(app) { info.append(("Source", name)) }
            info.append(("Copied", Self.relative.localizedString(for: e.used, relativeTo: Date())))
            details = info
        }
    }

    /// A small picture for an image row, decoded at list size and cached while the panel is open.
    func thumbnail(for entry: ClipEntry) -> NSImage? {
        let key = NSNumber(value: entry.id)
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let url = store?.imageURL(entry), let image = Self.downsampled(url, maxPixel: 64) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// Decodes straight to the wanted size, so a 5K screenshot never sits in memory at full size.
    private static func downsampled(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func characters(_ n: Int) -> String {
        n == 1 ? "1 character" : "\(n.formatted()) characters"
    }

    static func appName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
    }
}
