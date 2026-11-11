import AppKit
import SwiftUI

/// Which settings pane is showing; lets other parts of flit open one directly.
@MainActor
final class PreferencesRoute: ObservableObject {
    static let shared = PreferencesRoute()
    @Published var pane: PreferencesPane? = .general
    private init() {}
}

enum PreferencesPane: String, CaseIterable, Identifiable {
    case general, switcher, tiling, clipboard, snippets, breaks, dimming, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .switcher: return "Switcher"
        case .tiling: return "Tiling"
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        case .breaks: return "Breaks"
        case .dimming: return "Dimming"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .switcher: return "rectangle.on.rectangle"
        case .tiling: return "rectangle.split.2x1"
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.quote"
        case .breaks: return "cup.and.saucer"
        case .dimming: return "circle.lefthalf.filled"
        case .permissions: return "lock.shield"
        }
    }
}

@MainActor
final class PreferencesWindow: NSWindow {
    static let size = NSSize(width: 780, height: 560)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = "Flit Preferences"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: PreferencesView(prefs: Preferences.shared))
        center()
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var route = PreferencesRoute.shared

    var body: some View {
        HStack(spacing: 0) {
            List(PreferencesPane.allCases, selection: $route.pane) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            Group {
                switch route.pane ?? .general {
                case .general: GeneralPane(prefs: prefs)
                case .switcher: SwitcherPane(prefs: prefs)
                case .tiling: TilingPane(prefs: prefs)
                case .clipboard: ClipboardPane(prefs: prefs)
                case .snippets: SnippetsPane()
                case .breaks: BreaksPane(prefs: prefs)
                case .dimming: DimmingPane(prefs: prefs)
                case .permissions: PermissionsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: PreferencesWindow.size.width, height: PreferencesWindow.size.height)
    }
}

struct GeneralPane: View {
    @ObservedObject var prefs: Preferences

    private static let durations: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("5 hours", 18_000),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Toggle("Show menu bar icon", isOn: $prefs.showMenuBarIcon)
            }
            Section("Keep awake") {
                Toggle("Keep the display on and the Mac awake", isOn: Binding(
                    get: { prefs.keepAwake.on },
                    set: { prefs.keepAwake = KeepAwakeSetting(on: $0, until: nil) }))
                HStack {
                    if prefs.keepAwake.on, let until = prefs.keepAwake.until {
                        Text("Turns off at \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    } else {
                        Text(prefs.keepAwake.on ? "Stays on until you turn it off" : "Off").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Turn on for…") {
                        ForEach(Self.durations, id: \.seconds) { d in
                            Button(d.label) { prefs.keepAwake = .on(for: d.seconds, now: Date()) }
                        }
                    }
                    .fixedSize()
                }
                HotkeyRow(action: .keepAwake, prefs: prefs)
                Text("Closing the lid with no external display still puts the Mac to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SwitcherPane: View {
    @ObservedObject var prefs: Preferences
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Behavior").tag(0)
                Text("Appearance").tag(1)
                Text("Shortcuts").tag(2)
                Text("Blacklist").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            switch tab {
            case 0: SwitcherBehaviorTab(prefs: prefs)
            case 1: AppearanceTab(prefs: prefs)
            case 2: ShortcutsTab(prefs: prefs).padding(12)
            default: BlacklistTab(prefs: prefs).padding(16)
            }
        }
    }
}

struct SwitcherBehaviorTab: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Toggle("Replace the system ⌘-Tab", isOn: $prefs.replaceCommandTab)
            Text("Moves the Tab and ` shortcuts from ⌥ to ⌘ and turns off the native app switcher while Flit runs; it comes back when Flit quits. ⌥-Space search is unchanged.")
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
            Toggle("Show key hints under the switcher", isOn: $prefs.showHints)
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
    @State private var paste = Permissions.pasteboard
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            row("Accessibility", ok: ax, warn: false,
                detail: "Required. Lists, raises, moves and resizes windows, reads the switcher keys, and pastes from clipboard history.",
                button: ax ? nil : "Grant…",
                request: { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() })
            row("Screen Recording", ok: sr, warn: false,
                detail: "Optional. Needed for live window thumbnails; without it the switcher shows a card in each window's shape with its app icon and title, and Space outlines the window's position.",
                button: sr ? nil : "Grant…",
                request: { Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings() })
            row("Clipboard access", ok: paste == .allowed || paste == .notAsked, warn: paste == .asks,
                detail: pasteDetail,
                button: paste == .asks || paste == .denied ? "Open Settings…" : nil,
                request: { Permissions.openPrivacySettings() })
            Text("If a permission stays off after granting it, remove Flit from the list in System Settings, re-add it, and relaunch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            ax = Permissions.accessibility
            sr = Permissions.screenRecording
            paste = Permissions.pasteboard
        }
    }

    private var pasteDetail: String {
        switch paste {
        case .allowed: return "Flit may read what you copy, which clipboard history needs."
        case .notAsked: return "macOS has not asked about Flit reading the clipboard. If it does, choose Allow."
        case .asks: return "macOS asks each time Flit reads a copy. Set Flit to Allow under Privacy & Security to keep history without prompts."
        case .denied: return "Flit is not allowed to read the clipboard, so history stays empty. Change it under Privacy & Security."
        }
    }

    private func row(_ name: String, ok: Bool, warn: Bool, detail: String, button: String?, request: @escaping () -> Void) -> some View {
        Section {
            HStack {
                Image(systemName: warn ? "exclamationmark.triangle.fill" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(warn ? .orange : (ok ? .green : .red))
                VStack(alignment: .leading) {
                    Text(name).bold()
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let button { Button(button, action: request) }
            }
        }
    }
}
