import AppKit
import Carbon.HIToolbox

/// A one-shot global shortcut: any modifier combination plus one key.
struct Hotkey: Codable, Equatable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)

        init(rawValue: Int) { self.rawValue = rawValue }

        /// Keeps the four real modifiers; drops caps lock, fn and the
        /// numeric-pad bit that arrow keys carry.
        init(_ flags: NSEvent.ModifierFlags) {
            var m: Modifiers = []
            if flags.contains(.control) { m.insert(.control) }
            if flags.contains(.option) { m.insert(.option) }
            if flags.contains(.shift) { m.insert(.shift) }
            if flags.contains(.command) { m.insert(.command) }
            self = m
        }

        /// Same, for an event seen by the event tap.
        init(_ flags: CGEventFlags) {
            var m: Modifiers = []
            if flags.contains(.maskControl) { m.insert(.control) }
            if flags.contains(.maskAlternate) { m.insert(.option) }
            if flags.contains(.maskShift) { m.insert(.shift) }
            if flags.contains(.maskCommand) { m.insert(.command) }
            self = m
        }

        /// The mask `RegisterEventHotKey` expects.
        var carbon: UInt32 {
            var c = 0
            if contains(.control) { c |= controlKey }
            if contains(.option) { c |= optionKey }
            if contains(.shift) { c |= shiftKey }
            if contains(.command) { c |= cmdKey }
            return UInt32(c)
        }

        /// Menu order: ⌃⌥⇧⌘.
        var symbols: String {
            var s = ""
            if contains(.control) { s += "⌃" }
            if contains(.option) { s += "⌥" }
            if contains(.shift) { s += "⇧" }
            if contains(.command) { s += "⌘" }
            return s
        }
    }

    var keyCode: UInt16
    var modifiers: Modifiers

    var description: String { modifiers.symbols + Self.keyLabel(keyCode) }

    /// A plain or shift-only letter would swallow normal typing, so a hotkey
    /// needs ⌃, ⌥ or ⌘ — unless the key is a function key.
    var isValid: Bool {
        if Self.functionKeys.contains(Int(keyCode)) { return true }
        return !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func keyLabel(_ code: UInt16) -> String {
        labels[Int(code)] ?? "key \(code)"
    }

    private static let labels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// The parts of flit a hotkey can belong to. A disabled feature's hotkeys are
/// not registered, so the keys reach the frontmost app again.
enum Feature: String, CaseIterable {
    case tiling, clipboard, keepAwake, dimming, breaks
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case tileLeft, tileRight, tileMaximize, tileRestore
    case tileLeftThird, tileCenterThird, tileRightThird
    case tileNextDisplay, tilePreviousDisplay
    case clipboard
    case keepAwake
    case dimming
    case breakNow

    var id: String { rawValue }

    var feature: Feature {
        switch self {
        case .tileLeft, .tileRight, .tileMaximize, .tileRestore, .tileLeftThird, .tileCenterThird,
             .tileRightThird, .tileNextDisplay, .tilePreviousDisplay: return .tiling
        case .clipboard: return .clipboard
        case .keepAwake: return .keepAwake
        case .dimming: return .dimming
        case .breakNow: return .breaks
        }
    }

    var title: String {
        switch self {
        case .tileLeft: return "Left half"
        case .tileRight: return "Right half"
        case .tileMaximize: return "Maximize"
        case .tileRestore: return "Restore"
        case .tileLeftThird: return "Left third"
        case .tileCenterThird: return "Center third"
        case .tileRightThird: return "Right third"
        case .tileNextDisplay: return "Next display"
        case .tilePreviousDisplay: return "Previous display"
        case .clipboard: return "Show clipboard history"
        case .keepAwake: return "Toggle keep awake"
        case .dimming: return "Toggle dimming"
        case .breakNow: return "Start a break now"
        }
    }

    var defaultHotkey: Hotkey? {
        func k(_ code: Int, _ mods: Hotkey.Modifiers) -> Hotkey { Hotkey(keyCode: UInt16(code), modifiers: mods) }
        switch self {
        case .tileLeft: return k(kVK_LeftArrow, [.control, .option])
        case .tileRight: return k(kVK_RightArrow, [.control, .option])
        case .tileMaximize: return k(kVK_UpArrow, [.control, .option])
        case .tileRestore: return k(kVK_DownArrow, [.control, .option])
        case .tileLeftThird: return k(kVK_ANSI_D, [.control, .option])
        case .tileCenterThird: return k(kVK_ANSI_F, [.control, .option])
        case .tileRightThird: return k(kVK_ANSI_G, [.control, .option])
        case .tileNextDisplay: return k(kVK_RightArrow, [.control, .option, .command])
        case .tilePreviousDisplay: return k(kVK_LeftArrow, [.control, .option, .command])
        case .clipboard: return k(kVK_ANSI_V, [.command, .shift])
        case .dimming: return k(kVK_ANSI_H, [.control, .option, .command])
        case .keepAwake, .breakNow: return nil
        }
    }
}

/// Which hotkey each action has. Only changes are stored: an action the user
/// never touched follows its default, and one they cleared stays cleared.
struct HotkeyBindings: Codable, Equatable {
    private var overrides: [String: Hotkey?] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        overrides = try decoder.singleValueContainer().decode([String: Hotkey?].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(overrides)
    }

    subscript(action: HotkeyAction) -> Hotkey? {
        if let override = overrides[action.rawValue] { return override }
        return action.defaultHotkey
    }

    /// Binds `hotkey` to `action`. A hotkey can drive one action only, so any
    /// other action that had it loses it.
    mutating func set(_ hotkey: Hotkey?, for action: HotkeyAction) {
        if let hotkey {
            for other in HotkeyAction.allCases where other != action && self[other] == hotkey {
                overrides[other.rawValue] = .some(nil)
            }
        }
        overrides[action.rawValue] = .some(hotkey)
    }

    mutating func reset(_ action: HotkeyAction) {
        // Take the default back from any action that borrowed it, then follow it.
        set(action.defaultHotkey, for: action)
        overrides.removeValue(forKey: action.rawValue)
    }

    /// Bound actions of the given features, in declaration order.
    func active(features: Set<Feature>) -> [(action: HotkeyAction, hotkey: Hotkey)] {
        HotkeyAction.allCases.compactMap { action in
            guard features.contains(action.feature), let hotkey = self[action] else { return nil }
            return (action, hotkey)
        }
    }
}
