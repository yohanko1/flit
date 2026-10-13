import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// A trigger with its own filter overrides. `hold` profiles commit when the
/// modifier is released; `sticky` ones stay open until Return / Esc / click.
struct ShortcutProfile: Codable, Equatable, Identifiable {
    enum HoldModifier: String, Codable, CaseIterable, Identifiable {
        case option, command, control, function
        var id: String { rawValue }
        var label: String {
            switch self {
            case .option: return "⌥ Option"
            case .command: return "⌘ Command"
            case .control: return "⌃ Control"
            case .function: return "fn / 🌐"
            }
        }
        var symbol: String {
            switch self {
            case .option: return "⌥"
            case .command: return "⌘"
            case .control: return "⌃"
            case .function: return "fn"
            }
        }
        var flag: CGEventFlags {
            switch self {
            case .option: return .maskAlternate
            case .command: return .maskCommand
            case .control: return .maskControl
            case .function: return .maskSecondaryFn
            }
        }
    }

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case hold, sticky
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hold: return "Hold: release the modifier to switch"
            case .sticky: return "Sticky: stays open, Return switches"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var enabled = true
    var holdModifier: HoldModifier = .option
    var keyCode: UInt16 = UInt16(kVK_Tab)
    var mode: Mode = .hold
    var filter = WindowFilter()

    init(id: UUID = UUID(), name: String, enabled: Bool = true, holdModifier: HoldModifier = .option,
         keyCode: UInt16 = UInt16(kVK_Tab), mode: Mode = .hold, filter: WindowFilter = WindowFilter()) {
        self.id = id; self.name = name; self.enabled = enabled; self.holdModifier = holdModifier
        self.keyCode = keyCode; self.mode = mode; self.filter = filter
    }

    // Tolerant decoding so settings saved by an older build keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Shortcut"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        holdModifier = try c.decodeIfPresent(HoldModifier.self, forKey: .holdModifier) ?? .option
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? UInt16(kVK_Tab)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .hold
        filter = try c.decodeIfPresent(WindowFilter.self, forKey: .filter) ?? WindowFilter()
    }

    static let allKeys: [(code: UInt16, label: String)] = [
        (UInt16(kVK_Tab), "Tab"), (UInt16(kVK_ANSI_Grave), "`"), (UInt16(kVK_Space), "Space"),
        (UInt16(kVK_Escape), "Esc"), (UInt16(kVK_ANSI_Q), "Q"), (UInt16(kVK_ANSI_W), "W"),
        (UInt16(kVK_ANSI_E), "E"), (UInt16(kVK_ANSI_A), "A"), (UInt16(kVK_ANSI_S), "S"),
        (UInt16(kVK_ANSI_1), "1"), (UInt16(kVK_ANSI_2), "2"), (UInt16(kVK_F1), "F1"),
        (UInt16(kVK_F2), "F2"), (UInt16(kVK_F3), "F3"), (UInt16(kVK_F4), "F4"),
    ]

    var keyLabel: String {
        Self.allKeys.first { $0.code == keyCode }?.label ?? "key \(keyCode)"
    }

    var description: String { "\(holdModifier.symbol) + \(keyLabel)" }

    /// True if a key-down with these flags/keycode should open this profile.
    func triggers(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard enabled, keyCode == self.keyCode else { return false }
        let relevant: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskSecondaryFn]
        let held = flags.intersection(relevant)
        // Allow shift (reverse direction) but no other extra modifier.
        return held == holdModifier.flag
    }

    static var defaults: [ShortcutProfile] {
        var current = WindowFilter()
        current.currentAppOnly = true
        return [
            ShortcutProfile(name: "All windows", holdModifier: .option, keyCode: UInt16(kVK_Tab)),
            ShortcutProfile(name: "Current app", holdModifier: .option, keyCode: UInt16(kVK_ANSI_Grave), filter: current),
            ShortcutProfile(name: "Search", holdModifier: .option, keyCode: UInt16(kVK_Space), mode: .sticky),
        ]
    }
}
