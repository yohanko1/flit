import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let controller = SwitcherController()
    private let keyTap = KeyTap()
    private lazy var statusBar = StatusBar(app: self)
    private let tiler = Tiler()
    private let keepAwake = KeepAwake()
    private let dimmer = Dimmer()
    private(set) lazy var breaks = BreakController(settings: prefs.breaks)
    private var preferencesWindow: PreferencesWindow?
    private var preferencesCloseObserver: NSObjectProtocol?
    private var retryTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build()
        keyTap.delegate = controller
        keyTap.profiles = { [prefs] in prefs.profiles }

        statusBar.setVisible(prefs.showMenuBarIcon)
        prefs.$showMenuBarIcon.dropFirst().sink { [weak self] in self?.statusBar.setVisible($0) }.store(in: &cancellables)
        prefs.$profiles.dropFirst().sink { [weak self] _ in self?.applyNativeSwitcherSetting(); self?.statusBar.update() }.store(in: &cancellables)
        prefs.$replaceCommandTab.dropFirst().sink { [weak self] _ in self?.applyNativeSwitcherSetting() }.store(in: &cancellables)
        prefs.$launchAtLogin.dropFirst().sink { [weak self] in self?.setLaunchAtLogin($0) }.store(in: &cancellables)

        HotkeyCenter.shared.onAction = { [weak self] in self?.perform($0) }
        keepAwake.onExpire = { [weak self] in
            guard let self else { return }
            self.prefs.keepAwake = self.prefs.keepAwake.resolved(at: Date())
        }
        ClipboardController.shared.onEditSnippets = { [weak self] in self?.showPreferences(pane: .snippets) }
        // The clipboard is only looked at around input. Key presses come from
        // the tap, which sees none while a password field holds the keyboard.
        keyTap.onKeyDown = { ClipboardController.shared.noteInput() }
        ClipboardController.shared.hasKeySignal = { [keyTap] in keyTap.isInstalled && !IsSecureEventInputEnabled() }
        // One pass brings every feature in line with the settings. It runs
        // after the change has landed (a @Published sink fires before the
        // property is set) and each step is a no-op when nothing changed.
        prefs.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFeatures() }
            .store(in: &cancellables)
        syncFeatures()

        if !tryInstallTap() {
            Permissions.requestAccessibility()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.tryInstallTap() { self.retryTimer?.invalidate(); self.retryTimer = nil }
                }
            }
        }
        if !Permissions.screenRecording {
            Permissions.requestScreenRecording()
        }
        // Warm the window list so the first open is fast and the AX observers are live.
        WindowStore.shared.refresh()
        if ProcessInfo.processInfo.arguments.contains("--prefs") || !Permissions.accessibility {
            showPreferences()
        }
        #if DEBUG
        SelfTest.runIfRequested()
        Screenshooter.runIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap.uninstall()
    }

    private func tryInstallTap() -> Bool {
        guard Permissions.accessibility else { return false }
        let ok = keyTap.install()
        if ok {
            applyNativeSwitcherSetting()
            dimmer.refresh()
        }
        statusBar.update()
        return ok
    }

    private func applyNativeSwitcherSetting() {
        guard keyTap.isInstalled else { return }
        var wanted: Set<PrivateAPI.SymbolicHotKey> = []
        if prefs.replaceCommandTab {
            let cmd = prefs.profiles.filter { $0.enabled && $0.holdModifier == .command }
            if cmd.contains(where: { $0.keyCode == UInt16(kVK_Tab) }) { wanted.formUnion([.commandTab, .commandShiftTab]) }
            if cmd.contains(where: { $0.keyCode == UInt16(kVK_ANSI_Grave) }) { wanted.formUnion([.commandGrave, .commandShiftGrave]) }
        }
        keyTap.setNativeHotKeys(disabled: wanted)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
    }

    private func syncFeatures() {
        HotkeyCenter.shared.set(prefs.activeHotkeys)
        keepAwake.apply(prefs.keepAwake)
        dimmer.configure(enabled: prefs.dimEnabled, intensity: prefs.dimIntensity)
        ClipboardController.shared.setRecording(prefs.clipboardEnabled)
        breaks.apply(prefs.breaks)
        applyNativeSwitcherSetting()
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .tileLeft: tiler.perform(.tile(.left))
        case .tileRight: tiler.perform(.tile(.right))
        case .tileMaximize: tiler.perform(.tile(.maximize))
        case .tileRestore: tiler.perform(.restore)
        case .tileLeftThird: tiler.perform(.tile(.leftThird))
        case .tileCenterThird: tiler.perform(.tile(.centerThird))
        case .tileRightThird: tiler.perform(.tile(.rightThird))
        case .tileNextDisplay: tiler.perform(.display(forward: true))
        case .tilePreviousDisplay: tiler.perform(.display(forward: false))
        case .clipboard: ClipboardController.shared.toggle()
        case .keepAwake: prefs.keepAwake = prefs.keepAwake.toggled()
        case .dimming: prefs.dimEnabled.toggle()
        case .breakNow: breaks.startNow()
        }
    }

    func showPreferences(pane: PreferencesPane? = nil) {
        if let pane { PreferencesRoute.shared.pane = pane }
        if preferencesWindow == nil {
            let window = PreferencesWindow()
            preferencesWindow = window
            preferencesCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.preferencesClosed() }
            }
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lets go of the window so its views, and the timer the Permissions pane
    /// runs, don't stay alive for the rest of the session.
    private func preferencesClosed() {
        HotkeyRecording.shared.cancel()
        if let preferencesCloseObserver { NotificationCenter.default.removeObserver(preferencesCloseObserver) }
        preferencesCloseObserver = nil
        let window = preferencesWindow
        preferencesWindow = nil
        // Still closing: let go once this notification has returned. The
        // SwiftUI hosting view and its window hold on to each other, so the
        // view tree has to be detached for either to be freed.
        DispatchQueue.main.async { window?.contentView = nil }
    }
}
