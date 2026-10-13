import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// A "hold modifier, tap key" trigger with its own filter overrides.
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

    var id: UUID = UUID()
    var name: String
    var enabled = true
    var holdModifier: HoldModifier = .option
    var keyCode: UInt16 = UInt16(kVK_Tab)
    var filter = WindowFilter()

    static let allKeys: [(code: UInt16, label: String)] = [
        (UInt16(kVK_Tab), "Tab"), (UInt16(kVK_ANSI_Grave), "`"), (UInt16(kVK_Escape), "Esc"),
        (UInt16(kVK_Space), "Space"), (UInt16(kVK_ANSI_Q), "Q"), (UInt16(kVK_ANSI_W), "W"),
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
        ]
    }
}
