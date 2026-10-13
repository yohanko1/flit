import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// What the tap tells the controller. Keys are only delivered while a session
/// is active; `open` starts one.
enum SwitcherInput {
    case next, previous, up, down, left, right
    case commit, cancel
    case modifierReleased          // controller decides: commit, or ignore when sticky
    case close, minimize, fullscreen, hide, quit
    case togglePreview
    case typed(Character), backspace
}

@MainActor
protocol KeyTapDelegate: AnyObject {
    func keyTapOpen(profile: ShortcutProfile, reverse: Bool)
    func keyTapInput(_ input: SwitcherInput)
    var keyTapIsActive: Bool { get }
}

/// One session-level CGEvent tap. Idle: looks for a profile trigger. Active:
/// swallows every key and routes it to the delegate; commits when the hold
/// modifier is released.
@MainActor
final class KeyTap {
    weak var delegate: KeyTapDelegate?
    var profiles: () -> [ShortcutProfile] = { [] }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activeProfile: ShortcutProfile?
    private var disabledNativeKeys: Set<PrivateAPI.SymbolicHotKey> = []
    private var nativeKeysApplied = false

    var isInstalled: Bool { tap != nil }

    /// Installs the tap. Returns false if the process isn't trusted for Accessibility.
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: KeyTap.callback, userInfo: refcon) else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("event tap installed")
        return true
    }

    func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil
        setNativeHotKeys(disabled: [])
    }

    /// Disables the given native hotkeys (⌘-Tab, ⌘-`) so the tap sees them,
    /// and restores any that are no longer wanted. The first call always
    /// writes both states, so a previous crash can't leave ⌘-Tab dead.
    func setNativeHotKeys(disabled wanted: Set<PrivateAPI.SymbolicHotKey>) {
        let all: Set<PrivateAPI.SymbolicHotKey> = [.commandTab, .commandShiftTab, .commandGrave, .commandShiftGrave]
        let toDisable = nativeKeysApplied ? wanted.subtracting(disabledNativeKeys) : wanted
        let toRestore = nativeKeysApplied ? disabledNativeKeys.subtracting(wanted) : all.subtracting(wanted)
        if !toDisable.isEmpty, PrivateAPI.setNativeHotKeys(Array(toDisable), enabled: false) {
            Log.info("native hotkeys disabled: \(toDisable)")
        }
        if !toRestore.isEmpty, PrivateAPI.setNativeHotKeys(Array(toRestore), enabled: true) {
            Log.info("native hotkeys restored: \(toRestore)")
        }
        disabledNativeKeys = wanted
        nativeKeysApplied = true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated { me.handle(type: type, event: event) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let active = delegate?.keyTapIsActive ?? false

        if !active {
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard let profile = profiles().first(where: { $0.triggers(keyCode: keyCode, flags: flags) }) else {
                return Unmanaged.passUnretained(event)
            }
            activeProfile = profile
            delegate?.keyTapOpen(profile: profile, reverse: flags.contains(.maskShift))
            return nil
        }

        guard let profile = activeProfile else { return Unmanaged.passUnretained(event) }

        if type == .flagsChanged {
            if !flags.contains(profile.holdModifier.flag) {
                delegate?.keyTapInput(.modifierReleased)
            }
            // Let modifier changes through so other apps' modifier state stays consistent.
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return nil }   // swallow keyUps while active

        let shift = flags.contains(.maskShift)
        let input: SwitcherInput?
        switch Int(keyCode) {
        case _ where keyCode == profile.keyCode: input = shift ? .previous : .next
        case kVK_Tab: input = shift ? .previous : .next
        case kVK_ANSI_Grave: input = shift ? .next : .previous
        case kVK_RightArrow: input = .right
        case kVK_LeftArrow: input = .left
        case kVK_UpArrow: input = .up
        case kVK_DownArrow: input = .down
        case kVK_Escape: input = .cancel
        case kVK_Return, kVK_ANSI_KeypadEnter: input = .commit
        case kVK_Space: input = .togglePreview
        case kVK_Delete, kVK_ForwardDelete: input = .backspace
        default:
            // The hold modifier is down, so the event's own string would be "∑"
            // for W; map the physical key instead.
            input = Self.plainCharacters[Int(keyCode)].map { .typed($0) }
        }
        if let input { delegate?.keyTapInput(input) }
        return nil
    }

    static let plainCharacters: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Period: ".",
    ]
}
