import Foundation
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
    @Published var replaceCommandTab: Bool
    @Published var showMenuBarIcon: Bool
    @Published var launchAtLogin: Bool
    @Published var quickSwitchOnTap: Bool         // tap (no cycling) focuses previous window
    @Published var previewOnSpace: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return v
        }
        profiles = load("profiles", ShortcutProfile.defaults)
        blacklist = load("blacklist", [String]())
        style = load("style", SwitcherStyle.thumbnails)
        theme = load("theme", SwitcherTheme.system)
        screen = load("screen", SwitcherScreen.active)
        scale = load("scale", 1.0)
        animate = load("animate", true)
        showBadges = load("showBadges", true)
        replaceCommandTab = load("replaceCommandTab", false)
        showMenuBarIcon = load("showMenuBarIcon", true)
        launchAtLogin = load("launchAtLogin", false)
        quickSwitchOnTap = load("quickSwitchOnTap", true)
        previewOnSpace = load("previewOnSpace", true)

        func persist<T: Encodable>(_ pub: Published<T>.Publisher, _ key: String) {
            pub.dropFirst().sink { v in
                if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
            }.store(in: &cancellables)
        }
        persist($profiles, "profiles")
        persist($blacklist, "blacklist")
        persist($style, "style")
        persist($theme, "theme")
        persist($screen, "screen")
        persist($scale, "scale")
        persist($animate, "animate")
        persist($showBadges, "showBadges")
        persist($replaceCommandTab, "replaceCommandTab")
        persist($showMenuBarIcon, "showMenuBarIcon")
        persist($launchAtLogin, "launchAtLogin")
        persist($quickSwitchOnTap, "quickSwitchOnTap")
        persist($previewOnSpace, "previewOnSpace")
    }

    var blacklistSet: Set<String> { Set(blacklist) }

    func resetProfiles() { profiles = ShortcutProfile.defaults }
}
