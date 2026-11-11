import AppKit

/// The menu-bar icon. Its menu is rebuilt from `StatusMenu` each time it
/// opens, so the state it shows (keep-awake, next break, permissions) is
/// current without anything updating it in the background.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var app: AppDelegate?
    private let prefs = Preferences.shared

    init(app: AppDelegate) {
        self.app = app
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            update()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Reflects permission state in the icon.
    func update() {
        guard let button = item?.button else { return }
        let ok = Permissions.accessibility
        button.image = NSImage(systemSymbolName: ok ? "bird.fill" : "exclamationmark.triangle",
                               accessibilityDescription: "Flit")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        update()
        let breaks = prefs.breaks.enabled ? app.map { StatusMenu.Breaks(status: $0.breaks.status, paused: $0.breaks.isPaused) } : nil
        let sections = StatusMenu.sections(
            keepAwake: prefs.keepAwake, dimming: prefs.dimEnabled, breaks: breaks,
            accessibility: Permissions.accessibility, screenRecording: Permissions.screenRecording,
            time: { $0.formatted(date: .omitted, time: .shortened) })
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(.sectionHeader(title: title)) }
            for entry in section.items { menu.addItem(menuItem(entry)) }
        }
    }

    private func menuItem(_ entry: StatusMenu.Item) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key)
        item.state = entry.checked ? .on : .off
        if !entry.children.isEmpty {
            let submenu = NSMenu()
            for child in entry.children { submenu.addItem(menuItem(child)) }
            item.submenu = submenu
        } else if let command = entry.command {
            item.target = self
            item.action = #selector(run(_:))
            item.representedObject = command
        } else {
            item.isEnabled = false
        }
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? StatusMenu.Command else { return }
        switch command {
        case .toggleKeepAwake: prefs.keepAwake = prefs.keepAwake.toggled()
        case .keepAwakeFor(let seconds): prefs.keepAwake = .on(for: seconds, now: Date())
        case .toggleDimming: prefs.dimEnabled.toggle()
        case .breakNow: app?.breaks.startNow()
        case .pauseBreaks(let minutes): app?.breaks.pause(minutes: minutes)
        case .resumeBreaks: app?.breaks.resume()
        case .grantAccessibility:
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        case .grantScreenRecording:
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        case .preferences: app?.showPreferences()
        case .quit: NSApp.terminate(nil)
        }
    }
}
