import Testing
import AppKit
import Carbon.HIToolbox
@testable import Flit

private func key(_ code: Int, _ mods: Hotkey.Modifiers) -> Hotkey {
    Hotkey(keyCode: UInt16(code), modifiers: mods)
}

struct HotkeyTests {
    @Test func describesModifiersInMenuOrder() {
        #expect(key(kVK_ANSI_V, [.command, .shift]).description == "⇧⌘V")
        #expect(key(kVK_LeftArrow, [.control, .option]).description == "⌃⌥←")
        #expect(key(kVK_Return, [.command, .option, .control]).description == "⌃⌥⌘↩")
    }

    @Test func carbonMaskUsesCarbonModifierBits() {
        // controlKey 0x1000 | optionKey 0x0800, cmdKey 0x0100 | shiftKey 0x0200
        #expect(Hotkey.Modifiers([.control, .option]).carbon == 6144)
        #expect(Hotkey.Modifiers([.command, .shift]).carbon == 768)
    }

    @Test func eventFlagsDropBitsThatAreNotModifiers() {
        // Arrow keys arrive with .function and .numericPad set.
        let flags: NSEvent.ModifierFlags = [.control, .option, .function, .numericPad, .capsLock]
        #expect(Hotkey.Modifiers(flags) == [.control, .option])
    }

    @Test func needsControlOptionOrCommandUnlessFunctionKey() {
        #expect(!key(kVK_ANSI_A, []).isValid)
        #expect(!key(kVK_ANSI_A, [.shift]).isValid)
        #expect(key(kVK_ANSI_A, [.control]).isValid)
        #expect(key(kVK_F5, []).isValid)
    }
}

struct HotkeyBindingsTests {
    @Test func untouchedActionsUseTheirDefaults() {
        let b = HotkeyBindings()
        #expect(b[.tileLeft] == key(kVK_LeftArrow, [.control, .option]))
        #expect(b[.tileMaximize] == key(kVK_UpArrow, [.control, .option]))
        #expect(b[.clipboard] == key(kVK_ANSI_V, [.command, .shift]))
        #expect(b[.keepAwake] == nil)
    }

    @Test func clearedActionStaysClearedAfterSaveAndLoad() throws {
        var b = HotkeyBindings()
        b.set(nil, for: .tileLeft)
        let back = try JSONDecoder().decode(HotkeyBindings.self, from: JSONEncoder().encode(b))
        #expect(back[.tileLeft] == nil)
        #expect(back[.tileRight] == key(kVK_RightArrow, [.control, .option]))
    }

    @Test func customHotkeySurvivesSaveAndLoad() throws {
        var b = HotkeyBindings()
        b.set(key(kVK_ANSI_C, [.control, .command]), for: .clipboard)
        let back = try JSONDecoder().decode(HotkeyBindings.self, from: JSONEncoder().encode(b))
        #expect(back[.clipboard] == key(kVK_ANSI_C, [.control, .command]))
    }

    @Test func assigningATakenHotkeyUnbindsTheOtherAction() {
        var b = HotkeyBindings()
        let left = key(kVK_LeftArrow, [.control, .option])
        b.set(left, for: .tileRight)
        #expect(b[.tileRight] == left)
        #expect(b[.tileLeft] == nil)
    }

    @Test func activeSkipsUnboundActionsAndDisabledFeatures() {
        var b = HotkeyBindings()
        b.set(nil, for: .tileRestore)
        let tiling = b.active(features: [.tiling]).map(\.action)
        #expect(tiling.contains(.tileLeft))
        #expect(!tiling.contains(.tileRestore))
        #expect(!tiling.contains(.clipboard))
        #expect(b.active(features: [.clipboard]).map(\.action) == [.clipboard])
    }

    @Test func resetRestoresTheDefault() {
        var b = HotkeyBindings()
        b.set(nil, for: .clipboard)
        b.reset(.clipboard)
        #expect(b[.clipboard] == key(kVK_ANSI_V, [.command, .shift]))
    }
}

struct HotkeyMatchTests {
    let bindings = HotkeyBindings().active(features: [.tiling, .clipboard])

    @Test func aKeyPressMatchesTheActionBoundToExactlyThoseModifiers() {
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_LeftArrow), flags: [.maskControl, .maskAlternate], in: bindings) == .tileLeft)
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_LeftArrow), flags: [.maskControl, .maskAlternate, .maskCommand], in: bindings) == .tilePreviousDisplay)
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand, .maskShift], in: bindings) == .clipboard)
    }

    @Test func missingOrExtraModifiersDoNotMatch() {
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_LeftArrow), flags: [.maskControl], in: bindings) == nil)
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand], in: bindings) == nil)
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand, .maskShift, .maskAlternate], in: bindings) == nil)
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_ANSI_Z), flags: [.maskControl, .maskAlternate], in: bindings) == nil)
    }

    @Test func arrowKeyAndCapsLockBitsAreIgnored() {
        // Hardware arrow presses carry the numeric-pad and fn bits.
        let real: CGEventFlags = [.maskControl, .maskAlternate, .maskNumericPad, .maskSecondaryFn, .maskAlphaShift]
        #expect(HotkeyCenter.match(keyCode: UInt16(kVK_RightArrow), flags: real, in: bindings) == .tileRight)
    }
}
