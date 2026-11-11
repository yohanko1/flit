import Foundation
import Carbon.HIToolbox
import Combine
import CoreGraphics

enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, appIcons, titles
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .appIcons: return "App icons"
        case .titles: return "Titles"
        }
    }
}

enum SwitcherTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SwitcherScreen: String, Codable, CaseIterable, Identifiable {
    case active, cursor, main
    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: return "Screen with the focused window"
        case .cursor: return "Screen with the cursor"
        case .main: return "Main screen"
        }
    }
}

/// All user settings. Persisted to UserDefaults on every change.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    @Published var profiles: [ShortcutProfile]
    @Published var blacklist: [String]            // bundle IDs
    @Published var style: SwitcherStyle
    @Published var theme: SwitcherTheme
    @Published var screen: SwitcherScreen
    @Published var scale: Double                  // 0.5 … 1.5
    @Published var animate: Bool
    @Published var showBadges: Bool
    @Published var showHints: Bool                // key hints under the switcher
    @Published var replaceCommandTab: Bool
    @Published var showMenuBarIcon: Bool
    @Published var launchAtLogin: Bool
    @Published var quickSwitchOnTap: Bool         // tap (no cycling) focuses previous window
    @Published var previewOnSpace: Bool

    @Published var hotkeys: HotkeyBindings
    @Published var tilingEnabled: Bool
    @Published var keepAwake: KeepAwakeSetting
    @Published var dimEnabled: Bool
    @Published var dimIntensity: Double           // 0.05 … 0.9, the overlay's opacity
    @Published var clipboardEnabled: Bool
    @Published var clipboardRetentionDays: Int
    @Published var clipboardMaxItems: Int
    @Published var clipboardIgnoreConcealed: Bool // skip what password managers mark as secret
    @Published var clipboardIgnoredApps: [String] // bundle IDs
    @Published var breaks: BreakSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return v
        }
        var loaded = load("profiles", ShortcutProfile.defaults)
        // v2 added the sticky ⌥-Space search profile; add it once to existing setups.
        if defaults.integer(forKey: "profilesVersion") < 2 {
            if let search = ShortcutProfile.defaults.first(where: { $0.mode == .sticky }),
               !loaded.contains(where: { $0.keyCode == search.keyCode && $0.holdModifier == search.holdModifier }) {
                loaded.append(search)
            }
            defaults.set(2, forKey: "profilesVersion")
        }
        profiles = loaded
        blacklist = load("blacklist", [String]())
        style = load("style", SwitcherStyle.thumbnails)
        theme = load("theme", SwitcherTheme.system)
        screen = load("screen", SwitcherScreen.active)
        scale = load("scale", 1.0)
        animate = load("animate", true)
        showBadges = load("showBadges", true)
        showHints = load("showHints", true)
        replaceCommandTab = load("replaceCommandTab", false)
        showMenuBarIcon = load("showMenuBarIcon", true)
        launchAtLogin = load("launchAtLogin", false)
        quickSwitchOnTap = load("quickSwitchOnTap", true)
        previewOnSpace = load("previewOnSpace", true)

        hotkeys = load("hotkeys", HotkeyBindings())
        tilingEnabled = load("tilingEnabled", true)
        // A timer that ran out while flit wasn't running counts as off.
        keepAwake = load("keepAwake", KeepAwakeSetting(on: true, until: nil)).resolved(at: Date())
        dimEnabled = load("dimEnabled", true)
        dimIntensity = load("dimIntensity", 0.35)
        clipboardEnabled = load("clipboardEnabled", true)
        clipboardRetentionDays = load("clipboardRetentionDays", 30)
        clipboardMaxItems = load("clipboardMaxItems", 1000)
        clipboardIgnoreConcealed = load("clipboardIgnoreConcealed", true)
        clipboardIgnoredApps = load("clipboardIgnoredApps", [String]())
        breaks = load("breaks", BreakSettings())
        if replaceCommandTab { Self.moveTabProfiles(&profiles, to: .command) }

        func persist<T: Encodable>(_ pub: Published<T>.Publisher, _ key: String) {
            pub.dropFirst().sink { v in
                if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
            }.store(in: &cancellables)
        }
        persist($profiles, "profiles")
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
        persist($blacklist, "blacklist")
        persist($style, "style")
        persist($theme, "theme")
        persist($screen, "screen")
        persist($scale, "scale")
        persist($animate, "animate")
        persist($showBadges, "showBadges")
        persist($showHints, "showHints")
        persist($replaceCommandTab, "replaceCommandTab")
        $replaceCommandTab.dropFirst().sink { [weak self] on in
            guard let self else { return }
            Self.moveTabProfiles(&self.profiles, to: on ? .command : .option)
        }.store(in: &cancellables)
        persist($showMenuBarIcon, "showMenuBarIcon")
        persist($launchAtLogin, "launchAtLogin")
        persist($quickSwitchOnTap, "quickSwitchOnTap")
        persist($previewOnSpace, "previewOnSpace")

        persist($hotkeys, "hotkeys")
        persist($tilingEnabled, "tilingEnabled")
        persist($keepAwake, "keepAwake")
        persist($dimEnabled, "dimEnabled")
        persist($dimIntensity, "dimIntensity")
        persist($clipboardEnabled, "clipboardEnabled")
        persist($clipboardRetentionDays, "clipboardRetentionDays")
        persist($clipboardMaxItems, "clipboardMaxItems")
        persist($clipboardIgnoreConcealed, "clipboardIgnoreConcealed")
        persist($clipboardIgnoredApps, "clipboardIgnoredApps")
        persist($breaks, "breaks")
    }

    /// The hotkeys to register right now. A feature that is off gives its
    /// keys back to other apps; the keep-awake and dimming toggles always work.
    var activeHotkeys: [(action: HotkeyAction, hotkey: Hotkey)] {
        var features: Set<Feature> = [.keepAwake, .dimming]
        if tilingEnabled { features.insert(.tiling) }
        if clipboardEnabled { features.insert(.clipboard) }
        if breaks.enabled { features.insert(.breaks) }
        return hotkeys.active(features: features)
    }

    var blacklistSet: Set<String> { Set(blacklist) }

    /// "Replace ⌘-Tab" means: the Tab and ` hold-profiles use ⌘ instead of ⌥.
    /// Other keys (⌥-Space search) are left alone — ⌘-Space is Spotlight.
    static func moveTabProfiles(_ profiles: inout [ShortcutProfile], to modifier: ShortcutProfile.HoldModifier) {
        let from: ShortcutProfile.HoldModifier = modifier == .command ? .option : .command
        let keys: Set<UInt16> = [UInt16(kVK_Tab), UInt16(kVK_ANSI_Grave)]
        for i in profiles.indices where profiles[i].mode == .hold && keys.contains(profiles[i].keyCode) && profiles[i].holdModifier == from {
            profiles[i].holdModifier = modifier
        }
    }

    func resetProfiles() { profiles = ShortcutProfile.defaults }
}
