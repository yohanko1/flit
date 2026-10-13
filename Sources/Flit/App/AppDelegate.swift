import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let controller = SwitcherController()
    private let keyTap = KeyTap()
    private lazy var statusBar = StatusBar { [weak self] in self?.showPreferences() }
    private var preferencesWindow: PreferencesWindow?
    private var retryTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        keyTap.delegate = controller
        keyTap.profiles = { [prefs] in prefs.profiles }

        statusBar.setVisible(prefs.showMenuBarIcon)
        prefs.$showMenuBarIcon.dropFirst().sink { [weak self] in self?.statusBar.setVisible($0) }.store(in: &cancellables)
        prefs.$profiles.dropFirst().sink { [weak self] _ in self?.applyNativeSwitcherSetting(); self?.statusBar.update() }.store(in: &cancellables)
        prefs.$replaceCommandTab.dropFirst().sink { [weak self] _ in self?.applyNativeSwitcherSetting() }.store(in: &cancellables)
        prefs.$launchAtLogin.dropFirst().sink { [weak self] in self?.setLaunchAtLogin($0) }.store(in: &cancellables)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap.uninstall()
    }

    private func tryInstallTap() -> Bool {
        guard Permissions.accessibility else { return false }
        let ok = keyTap.install()
        if ok { applyNativeSwitcherSetting() }
        statusBar.update()
        return ok
    }

    private func applyNativeSwitcherSetting() {
        let usesCommandTab = prefs.profiles.contains { $0.enabled && $0.holdModifier == .command && $0.keyCode == 48 }
        keyTap.setNativeSwitcher(disabled: prefs.replaceCommandTab && usesCommandTab && keyTap.isInstalled)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
    }

    func showPreferences() {
        if preferencesWindow == nil { preferencesWindow = PreferencesWindow() }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
