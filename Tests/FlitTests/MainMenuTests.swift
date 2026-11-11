import Testing
import AppKit
@testable import Flit

struct MainMenuTests {
    /// Flit has no menu bar of its own, so without these items ⌘V and friends
    /// do nothing in its text fields (snippet editor, clipboard search).
    @Test @MainActor func editShortcutsReachTheStandardTextActions() {
        let menu = MainMenu.build()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func action(_ key: String, _ mods: NSEvent.ModifierFlags = .command) -> Selector? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }?.action
        }
        #expect(action("x") == #selector(NSText.cut(_:)))
        #expect(action("c") == #selector(NSText.copy(_:)))
        #expect(action("v") == #selector(NSText.paste(_:)))
        #expect(action("a") == #selector(NSText.selectAll(_:)))
        #expect(action("z") == Selector(("undo:")))
        #expect(action("z", [.command, .shift]) == Selector(("redo:")))
    }

    @Test @MainActor func closingAndQuittingHaveTheirUsualShortcuts() {
        let items = MainMenu.build().items.flatMap { $0.submenu?.items ?? [] }
        #expect(items.first { $0.keyEquivalent == "w" }?.action == #selector(NSWindow.performClose(_:)))
        #expect(items.first { $0.keyEquivalent == "q" }?.action == #selector(NSApplication.terminate(_:)))
    }
}
