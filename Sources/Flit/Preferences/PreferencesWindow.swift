import AppKit
import SwiftUI

@MainActor
final class PreferencesWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = "Flit Preferences"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: PreferencesView(prefs: Preferences.shared))
        center()
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        TabView {
            GeneralTab(prefs: prefs).tabItem { Label("General", systemImage: "gear") }
            AppearanceTab(prefs: prefs).tabItem { Label("Appearance", systemImage: "paintbrush") }
            ShortcutsTab(prefs: prefs).tabItem { Label("Shortcuts", systemImage: "keyboard") }
            BlacklistTab(prefs: prefs).tabItem { Label("Blacklist", systemImage: "eye.slash") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding()
        .frame(width: 560, height: 460)
    }
}

struct GeneralTab: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            Toggle("Show menu bar icon", isOn: $prefs.showMenuBarIcon)
            Toggle("Replace the system ⌘-Tab", isOn: $prefs.replaceCommandTab)
            Text("Only takes effect when a shortcut below uses ⌘ + Tab. The native switcher is restored when Flit quits.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Space shows a full-size preview of the selected window", isOn: $prefs.previewOnSpace)
            Divider()
            Text("While the switcher is open: Tab / Shift-Tab and arrows move, W closes, M minimizes, F toggles fullscreen, H hides the app, Q quits it, Esc cancels. Any other letter starts a search; the switcher then stays open after you release the modifier — Return switches. ⌥-Space opens straight into search.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct AppearanceTab: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Picker("Style", selection: $prefs.style) {
                ForEach(SwitcherStyle.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Theme", selection: $prefs.theme) {
                ForEach(SwitcherTheme.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Show on", selection: $prefs.screen) {
                ForEach(SwitcherScreen.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Size")
                Slider(value: $prefs.scale, in: 0.5...1.6, step: 0.1)
                Text(String(format: "%.0f%%", prefs.scale * 100)).monospacedDigit().frame(width: 44)
            }
            Toggle("Animate", isOn: $prefs.animate)
            Toggle("Show state badges (minimized, hidden, other Space)", isOn: $prefs.showBadges)
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsTab: View {
    @ObservedObject var prefs: Preferences
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(prefs.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Text(p.description).foregroundStyle(.secondary)
                        }
                        .opacity(p.enabled ? 1 : 0.5)
                        .tag(p.id)
                    }
                }
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                    Button("Reset") { prefs.resetProfiles(); selection = prefs.profiles.first?.id }
                }
                .padding(6)
            }
            .frame(minWidth: 200)
            if let i = prefs.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileEditor(profile: $prefs.profiles[i]).frame(minWidth: 280)
            } else {
                Text("Select a shortcut").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = prefs.profiles.first?.id }
    }

    private func add() {
        let p = ShortcutProfile(name: "New shortcut", holdModifier: .control, keyCode: 48)
        prefs.profiles.append(p)
        selection = p.id
    }

    private func remove() {
        prefs.profiles.removeAll { $0.id == selection }
        selection = prefs.profiles.first?.id
    }
}

struct ProfileEditor: View {
    @Binding var profile: ShortcutProfile
    var body: some View {
        Form {
            TextField("Name", text: $profile.name)
            Toggle("Enabled", isOn: $profile.enabled)
            Picker("Hold", selection: $profile.holdModifier) {
                ForEach(ShortcutProfile.HoldModifier.allCases) { Text($0.label).tag($0) }
            }
            Picker("Then press", selection: $profile.keyCode) {
                ForEach(ShortcutProfile.allKeys, id: \.code) { Text($0.label).tag($0.code) }
            }
            Picker("Behavior", selection: $profile.mode) {
                ForEach(ShortcutProfile.Mode.allCases) { Text($0.label).tag($0) }
            }
            Text("Either way, typing a letter makes the switcher sticky so you can release the modifier and keep typing.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Show") {
                Toggle("Minimized windows", isOn: $profile.filter.showMinimized)
                Toggle("Windows of hidden apps", isOn: $profile.filter.showHidden)
                Toggle("Windows on other Spaces", isOn: $profile.filter.showOtherSpaces)
                Toggle("Fullscreen windows", isOn: $profile.filter.showFullscreen)
                Toggle("Background tabs of tabbed windows", isOn: $profile.filter.showTabs)
                Toggle("Apps with no windows", isOn: $profile.filter.showWindowlessApps)
                Toggle("Only the current app's windows", isOn: $profile.filter.currentAppOnly)
                Picker("Displays", selection: $profile.filter.displayScope) {
                    ForEach(WindowFilter.DisplayScope.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct BlacklistTab: View {
    @ObservedObject var prefs: Preferences
    @State private var picked: String = ""

    private var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !prefs.blacklist.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Windows of these apps never appear in the switcher.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(prefs.blacklist, id: \.self) { id in
                    HStack {
                        Text(appName(id)); Text(id).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button { prefs.blacklist.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Picker("Add running app", selection: $picked) {
                    Text("Choose…").tag("")
                    ForEach(runningApps, id: \.id) { Text($0.name).tag($0.id) }
                }
                Button("Add") {
                    if !picked.isEmpty { prefs.blacklist.append(picked); picked = "" }
                }.disabled(picked.isEmpty)
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }
}

struct PermissionsTab: View {
    @State private var ax = Permissions.accessibility
    @State private var sr = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            row("Accessibility", granted: ax,
                detail: "Required. Lists windows, raises them, and reads the shortcut keys.",
                request: { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() })
            row("Screen Recording", granted: sr,
                detail: "Optional. Needed for live window thumbnails; without it the switcher shows a card in each window's shape with its app icon and title, and Space outlines the window's position.",
                request: { Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings() })
            Text("If a permission stays off after granting it, remove Flit from the list in System Settings, re-add it, and relaunch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in ax = Permissions.accessibility; sr = Permissions.screenRecording }
    }

    private func row(_ name: String, granted: Bool, detail: String, request: @escaping () -> Void) -> some View {
        Section {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                VStack(alignment: .leading) {
                    Text(name).bold()
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !granted { Button("Grant…", action: request) }
            }
        }
    }
}
