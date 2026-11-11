import AppKit
import Combine

/// The switcher's state machine. Owns the visible list, the selection, the
/// search query, and drives the panels.
@MainActor
final class SwitcherController: ObservableObject, KeyTapDelegate {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var query = ""
    @Published private(set) var isVisible = false
    @Published private(set) var previewVisible = false
    /// Sticky: releasing the modifier no longer commits (sticky profile, or the
    /// user started typing a search). Return commits, Esc cancels.
    @Published private(set) var pinned = false
    @Published private(set) var columns = 1
    @Published private(set) var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]

    private let store = WindowStore.shared
    private let prefs = Preferences.shared
    private var profile: ShortcutProfile?
    private var allWindows: [WindowInfo] = []
    private lazy var panel = SwitcherPanel(controller: self)
    private lazy var preview = PreviewPanel()
    private var previewTask: Task<Void, Never>?
    private var eviction: DispatchWorkItem?

    /// How long thumbnails are kept after the switcher closes. Long enough
    /// that switching back and forth shows them at once; after that their
    /// memory is given back.
    private static let thumbnailLifetime: TimeInterval = 120

    var keyTapIsActive: Bool { isVisible }

    /// "⌥" / "⌘" … of the profile that opened the current session, for hints.
    var profileModifierSymbol: String { profile?.holdModifier.symbol ?? "⌥" }

    var selected: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    // MARK: Open / close

    func keyTapOpen(profile: ShortcutProfile, reverse: Bool) {
        self.profile = profile
        eviction?.cancel()
        query = ""
        allWindows = store.refresh()
        screen = Screens.screen(for: prefs.screen, focusedWindowDisplay: store.focusedWindowDisplay)
        applyFilter()
        selectedIndex = windows.count > 1 ? (reverse ? windows.count - 1 : 1) : 0
        pinned = profile.mode == .sticky
        isVisible = true
        panel.show(on: screen)
        captureThumbnails()
    }

    func keyTapInput(_ input: SwitcherInput) {
        guard isVisible else { return }
        switch input {
        case .next: move(by: 1)
        case .previous: move(by: -1)
        case .right: move(by: 1)
        case .left: move(by: -1)
        case .down: move(by: columns)
        case .up: move(by: -columns)
        case .commit: commit()
        case .cancel: cancel()
        case .modifierReleased: if !pinned { commit() }
        case .togglePreview:
            // In a sticky session Space is just a character; preview lives on hold sessions.
            if pinned && profile?.mode == .sticky { return }
            togglePreview()
        case .typed(let ch):
            // Action letters only while holding with no search started; once a
            // search begins (or in a sticky profile) every letter is text.
            if query.isEmpty, !pinned, let action = Self.actionKeys[Character(ch.lowercased())] {
                perform(action)
            } else {
                query.append(ch)
                pinned = true
                applyFilter()
                selectedIndex = 0
                captureThumbnails()
            }
        case .backspace:
            guard !query.isEmpty else { return }
            query.removeLast()
            applyFilter()
            selectedIndex = min(selectedIndex, max(windows.count - 1, 0))
        case .close: perform(.close)
        case .minimize: perform(.minimize)
        case .fullscreen: perform(.fullscreen)
        case .hide: perform(.hide)
        case .quit: perform(.quit)
        }
    }

    private static let actionKeys: [Character: SwitcherInput] = [
        "w": .close, "m": .minimize, "f": .fullscreen, "h": .hide, "q": .quit,
    ]

    func select(index: Int) {
        guard windows.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        refreshPreview()
    }

    func commit() {
        if let w = selected {
            WindowActions.focus(w)
            store.markFocused(w.id)
        }
        hide()
    }

    func cancel() { hide() }

    private func hide() {
        isVisible = false
        pinned = false
        previewVisible = false
        preview.hide()
        panel.hide()
        profile = nil
        query = ""
        // The lists hold a thumbnail per window; nothing reads them while hidden.
        windows = []
        allWindows = []
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            Screenshots.shared.clear()
            self.store.dropThumbnails()
        }
        eviction = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbnailLifetime, execute: work)
    }

    // MARK: Selection

    private func move(by delta: Int) {
        guard !windows.isEmpty else { return }
        let n = windows.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
        refreshPreview()
    }

    // MARK: Filtering and layout

    private func applyFilter() {
        guard let profile else { return }
        let ctx = WindowFilter.Context(
            cursorScreenID: Screens.cursorDisplayID,
            frontmostPID: store.frontmostPID,
            blacklist: prefs.blacklistSet,
            query: query)
        windows = profile.filter.apply(allWindows, context: ctx)
        columns = Self.columns(for: windows.count, style: prefs.style, scale: prefs.scale, screen: screen)
    }

    static func columns(for count: Int, style: SwitcherStyle, scale: Double, screen: NSScreen) -> Int {
        guard count > 0 else { return 1 }
        let usable = screen.visibleFrame.width * 0.9 - 40
        let cell: CGFloat
        switch style {
        case .thumbnails: cell = Layout.thumbCellWidth(scale) + Layout.spacing
        case .appIcons: cell = Layout.iconCellWidth(scale) + Layout.spacing
        case .titles: return 1
        }
        return max(1, min(count, Int(usable / cell)))
    }

    private func captureThumbnails() {
        guard prefs.style == .thumbnails else { return }
        let ids = windows.filter { !$0.isAppPlaceholder }.map(\.id)
        Screenshots.shared.capture(ids, maxPixels: Int(Layout.thumbCellWidth(prefs.scale) * 2)) { [weak self] id, img in
            guard let self else { return }
            self.store.setThumbnail(img, for: id)
            if let i = self.windows.firstIndex(where: { $0.id == id }) { self.windows[i].thumbnail = img }
            if let i = self.allWindows.firstIndex(where: { $0.id == id }) { self.allWindows[i].thumbnail = img }
        }
    }

    // MARK: Window actions

    private func perform(_ action: SwitcherInput) {
        guard let w = selected else { return }
        switch action {
        case .close: WindowActions.close(w); Screenshots.shared.forget(w.id)
        case .minimize: WindowActions.toggleMinimize(w)
        case .fullscreen: WindowActions.toggleFullscreen(w)
        case .hide: WindowActions.toggleHide(w)
        case .quit: WindowActions.quit(w)
        default: return
        }
        // Give the app a moment to apply the change, then re-list.
        let keepID = w.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isVisible else { return }
            self.allWindows = self.store.refresh()
            self.applyFilter()
            if let i = self.windows.firstIndex(where: { $0.id == keepID }) {
                self.selectedIndex = i
            } else {
                self.selectedIndex = min(self.selectedIndex, max(self.windows.count - 1, 0))
            }
        }
    }

    // MARK: Preview

    private func togglePreview() {
        guard prefs.previewOnSpace else { return }
        previewVisible.toggle()
        if previewVisible { refreshPreview() } else { preview.hide() }
    }

    private func refreshPreview() {
        guard previewVisible, let w = selected, !w.isAppPlaceholder else { preview.hide(); return }
        previewTask?.cancel()
        preview.show(window: w, image: w.thumbnail)
        guard Screenshots.hasPermission else { return }
        previewTask = Task { [weak self] in
            guard let img = await Screenshots.shared.captureFull(w.id), !Task.isCancelled else { return }
            guard let self, self.previewVisible, self.selected?.id == w.id else { return }
            self.preview.show(window: w, image: img)
        }
    }
}

/// Shared sizing constants so the controller's grid math and the view agree.
enum Layout {
    static let spacing: CGFloat = 12
    static func thumbCellWidth(_ scale: Double) -> CGFloat { 220 * scale }
    static func thumbCellHeight(_ scale: Double) -> CGFloat { 150 * scale }
    static func iconCellWidth(_ scale: Double) -> CGFloat { 110 * scale }
    static func iconSize(_ scale: Double) -> CGFloat { 80 * scale }
}
