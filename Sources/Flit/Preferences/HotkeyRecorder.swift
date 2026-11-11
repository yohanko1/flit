import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The one hotkey being recorded in Preferences, if any. While recording,
/// the next key press is the new shortcut instead of a command: the event tap
/// hands it over ahead of every app's hotkeys, and flit's own registered
/// hotkeys are released so the press also arrives when the tap is not running.
@MainActor
final class HotkeyRecording: ObservableObject {
    static let shared = HotkeyRecording()

    @Published private(set) var action: HotkeyAction?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var commit: ((Hotkey?) -> Void)?

    private init() {}

    /// `commit` receives the new hotkey, or nil when Delete was pressed to clear it.
    func start(_ action: HotkeyAction, commit: @escaping (Hotkey?) -> Void) {
        cancel()
        self.action = action
        self.commit = commit
        HotkeyCenter.shared.paused = true
        HotkeyCenter.shared.capture = { [weak self] keyCode, flags in
            self?.handle(keyCode: keyCode, modifiers: Hotkey.Modifiers(flags))
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode, modifiers = Hotkey.Modifiers(event.modifierFlags)
            MainActor.assumeIsolated { self?.handle(keyCode: keyCode, modifiers: modifiers) }
            return nil
        }
        // Recording must never eat keys typed into another app.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        commit = nil
        action = nil
        HotkeyCenter.shared.capture = nil
        HotkeyCenter.shared.paused = false
    }

    private func handle(keyCode: UInt16, modifiers: Hotkey.Modifiers) {
        guard action != nil else { return }
        if modifiers.isEmpty, Int(keyCode) == kVK_Escape { cancel(); return }
        if modifiers.isEmpty, Int(keyCode) == kVK_Delete {
            commit?(nil)
            cancel()
            return
        }
        let hotkey = Hotkey(keyCode: keyCode, modifiers: modifiers)
        guard hotkey.isValid else { NSSound.beep(); return }
        commit?(hotkey)
        cancel()
    }
}

/// One settings row: the action's name and a button that records its hotkey.
struct HotkeyRow: View {
    let action: HotkeyAction
    @ObservedObject var prefs: Preferences
    @ObservedObject private var recording = HotkeyRecording.shared

    private var isRecording: Bool { recording.action == action }

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            Button {
                if isRecording {
                    recording.cancel()
                } else {
                    recording.start(action) { prefs.hotkeys.set($0, for: action) }
                }
            } label: {
                Text(isRecording ? "Type shortcut…" : (prefs.hotkeys[action]?.description ?? "None"))
                    .frame(minWidth: 96)
                    .foregroundStyle(isRecording ? Color.accentColor : (prefs.hotkeys[action] == nil ? .secondary : .primary))
            }
            .help("Click, then press the new shortcut. Delete clears it, Esc cancels.")
            Button {
                recording.cancel()
                prefs.hotkeys.reset(action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(prefs.hotkeys[action] == action.defaultHotkey)
            .help("Back to the default")
        }
        .onDisappear { if isRecording { recording.cancel() } }
    }
}
