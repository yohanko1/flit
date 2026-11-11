import AppKit
import Carbon.HIToolbox

/// One-shot hotkeys. Each is delivered by whichever of two routes gets it:
///
/// - The event tap (`KeyTap`) asks `action(keyCode:flags:)` for every key
///   press and swallows a match. The tap sits ahead of every app's registered
///   hotkeys, so flit's binding wins when another app (Raycast, Rectangle)
///   holds the same combination — the system otherwise hands a shared hotkey
///   to whoever registered it first.
/// - System registration (Carbon `RegisterEventHotKey`) covers the moments
///   the tap sees no keys: before Accessibility is granted, and while a
///   password field has focus.
///
/// A press is never delivered twice: what the tap swallows never reaches the
/// system's hotkey matching.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((HotkeyAction) -> Void)?

    /// While true nothing is registered, so the settings recorder can see
    /// combinations that are already taken.
    var paused = false {
        didSet { if paused != oldValue { register() } }
    }

    /// Set while Preferences records a shortcut. The event tap then hands
    /// every key press here instead of to any hotkey, so a combination that
    /// another app holds can be recorded too.
    var capture: ((UInt16, CGEventFlags) -> Void)?

    private var bindings: [(action: HotkeyAction, hotkey: Hotkey)] = []
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handler: EventHandlerRef?

    private static let signature: OSType = 0x464C_4954   // 'FLIT'

    private init() {}

    /// Replaces the registered set. A call with the set already in place does nothing.
    func set(_ new: [(action: HotkeyAction, hotkey: Hotkey)]) {
        let same = new.count == bindings.count && zip(new, bindings).allSatisfy { $0.action == $1.action && $0.hotkey == $1.hotkey }
        guard !same else { return }
        bindings = new
        register()
    }

    /// The action bound to exactly this key and these modifiers.
    nonisolated static func match(keyCode: UInt16, flags: CGEventFlags,
                                  in bindings: [(action: HotkeyAction, hotkey: Hotkey)]) -> HotkeyAction? {
        let modifiers = Hotkey.Modifiers(flags)
        return bindings.first { $0.hotkey.keyCode == keyCode && $0.hotkey.modifiers == modifiers }?.action
    }

    /// What a key press would trigger right now; nil while recording a shortcut.
    func action(keyCode: UInt16, flags: CGEventFlags) -> HotkeyAction? {
        paused ? nil : Self.match(keyCode: keyCode, flags: flags, in: bindings)
    }

    func trigger(_ action: HotkeyAction) {
        onAction?(action)
    }

    private func register() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        actions = [:]
        guard !paused, !bindings.isEmpty else { return }
        installHandler()
        for (i, binding) in bindings.enumerated() {
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.hotkey.keyCode), binding.hotkey.modifiers.carbon, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = binding.action
            } else {
                Log.info("hotkey \(binding.hotkey.description) for \(binding.action.rawValue) not registered: \(status)")
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let pressed = id.id
            MainActor.assumeIsolated { center.fire(pressed) }
            return noErr
        }, 1, &spec, me, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        trigger(action)
    }
}
