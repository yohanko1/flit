import Testing
import AppKit
import Carbon.HIToolbox
@testable import Flit

struct WindowFilterTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func sampleSet() -> [WindowInfo] {
        [
            .sample(id: 1, pid: 10, app: "Safari", title: "Apple", bundleID: "com.apple.Safari", lastFocused: t0.addingTimeInterval(3)),
            .sample(id: 2, pid: 10, app: "Safari", title: "GitHub", bundleID: "com.apple.Safari", minimized: true, lastFocused: t0.addingTimeInterval(2)),
            .sample(id: 3, pid: 20, app: "Terminal", title: "zsh", bundleID: "com.apple.Terminal", hidden: true, lastFocused: t0.addingTimeInterval(1)),
            .sample(id: 4, pid: 30, app: "Code", title: "flit", bundleID: "com.ms.code", onActiveSpace: false, screen: 2, lastFocused: t0.addingTimeInterval(4)),
            .sample(id: 5, pid: 40, app: "Finder", bundleID: "com.apple.finder", lastFocused: t0, placeholder: true),
            .sample(id: 6, pid: 50, app: "Music", title: "Player", bundleID: "com.apple.Music", fullscreen: true, lastFocused: t0.addingTimeInterval(5)),
        ]
    }

    @Test func testDefaultFilterOrdersByMRUAndDropsPlaceholders() {
        let out = WindowFilter().apply(sampleSet(), context: .init())
        #expect(out.map(\.id) == [6, 4, 1, 2, 3])
    }

    @Test func testFlags() {
        var f = WindowFilter()
        f.showMinimized = false
        #expect(!(f.apply(sampleSet(), context: .init()).contains { $0.id == 2 }))
        f = WindowFilter(); f.showHidden = false
        #expect(!(f.apply(sampleSet(), context: .init()).contains { $0.id == 3 }))
        f = WindowFilter(); f.showOtherSpaces = false
        #expect(!(f.apply(sampleSet(), context: .init()).contains { $0.id == 4 }))
        f = WindowFilter(); f.showFullscreen = false
        #expect(!(f.apply(sampleSet(), context: .init()).contains { $0.id == 6 }))
        f = WindowFilter(); f.showWindowlessApps = true
        #expect(f.apply(sampleSet(), context: .init()).contains { $0.id == 5 })
    }

    @Test func testMinimizedWindowsIgnoreSpaceAndDisplayScope() {
        var f = WindowFilter()
        f.showOtherSpaces = false
        f.displayScope = .cursorScreen
        let out = f.apply(sampleSet(), context: .init(cursorScreenID: 1))
        #expect(out.contains { $0.id == 2 })
        #expect(!(out.contains { $0.id == 4 }))
    }

    @Test func testCurrentAppOnlyAndBlacklist() {
        var f = WindowFilter()
        f.currentAppOnly = true
        #expect(f.apply(sampleSet(), context: .init(frontmostPID: 10)).map(\.id) == [1, 2])
        let out = WindowFilter().apply(sampleSet(), context: .init(blacklist: ["com.apple.Safari"]))
        #expect(!(out.contains { $0.pid == 10 }))
    }

    @Test func testSearch() {
        let all = sampleSet()
        #expect(WindowFilter().apply(all, context: .init(query: "git")).map(\.id) == [2])
        #expect(WindowFilter().apply(all, context: .init(query: "saf")).map(\.id) == [1, 2])
        // subsequence: "tml" → Terminal
        #expect(WindowFilter().apply(all, context: .init(query: "tml")).map(\.id) == [3])
        #expect(WindowFilter().apply(all, context: .init(query: "zzz")).count == 0)
    }
}

struct ShortcutProfileTests {
    @Test func testTriggerMatching() {
        let p = ShortcutProfile(name: "x", holdModifier: .option, keyCode: UInt16(kVK_Tab))
        #expect(p.triggers(keyCode: UInt16(kVK_Tab), flags: [.maskAlternate]))
        #expect(p.triggers(keyCode: UInt16(kVK_Tab), flags: [.maskAlternate, .maskShift]))
        #expect(!(p.triggers(keyCode: UInt16(kVK_Tab), flags: [.maskCommand])))
        #expect(!(p.triggers(keyCode: UInt16(kVK_Tab), flags: [.maskAlternate, .maskCommand])))
        #expect(!(p.triggers(keyCode: UInt16(kVK_ANSI_Grave), flags: [.maskAlternate])))
        var off = p; off.enabled = false
        #expect(!(off.triggers(keyCode: UInt16(kVK_Tab), flags: [.maskAlternate])))
    }

    @Test func testCodableRoundTrip() throws {
        let original = ShortcutProfile.defaults
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode([ShortcutProfile].self, from: data)
        #expect(back == original)
        #expect(back[1].filter.currentAppOnly)
    }

    @Test func testPlainCharacterTable() {
        #expect(KeyTap.plainCharacters[kVK_ANSI_W] == "w")
        #expect(KeyTap.plainCharacters[kVK_ANSI_1] == "1")
        #expect(KeyTap.plainCharacters[kVK_Space] == nil)
    }
}

struct LayoutTests {
    @Test @MainActor func testColumnsNeverExceedCountOrScreen() {
        guard let screen = NSScreen.screens.first else { return }
        #expect(SwitcherController.columns(for: 1, style: .thumbnails, scale: 1, screen: screen) == 1)
        #expect(SwitcherController.columns(for: 3, style: .titles, scale: 1, screen: screen) == 1)
        let many = SwitcherController.columns(for: 100, style: .thumbnails, scale: 1, screen: screen)
        #expect(many >= 1)
        #expect(CGFloat(many) * (Layout.thumbCellWidth(1) + Layout.spacing) <= screen.visibleFrame.width * 0.9)
    }
}
