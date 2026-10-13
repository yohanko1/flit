import AppKit

@MainActor
final class StatusBar {
    private var item: NSStatusItem?
    private let onPreferences: () -> Void

    init(onPreferences: @escaping () -> Void) {
        self.onPreferences = onPreferences
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Flit")
            item.menu = buildMenu()
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
        button.image = NSImage(systemSymbolName: ok ? "rectangle.on.rectangle" : "exclamationmark.triangle",
                               accessibilityDescription: "Flit")
        item?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let shortcuts = Preferences.shared.profiles.filter(\.enabled).map(\.description).joined(separator: "   ")
        let title = NSMenuItem(title: shortcuts.isEmpty ? "No shortcut enabled" : shortcuts, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        if !Permissions.accessibility {
            menu.addItem(withTitle: "Grant Accessibility access…", action: #selector(grantAX), keyEquivalent: "").target = self
        }
        if !Permissions.screenRecording {
            menu.addItem(withTitle: "Grant Screen Recording (thumbnails)…", action: #selector(grantSR), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Preferences…", action: #selector(prefs), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Flit", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func grantAX() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }
    @objc private func grantSR() { Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings() }
    @objc private func prefs() { onPreferences() }
    @objc private func quit() { NSApp.terminate(nil) }
}
