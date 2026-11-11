import Testing
import Foundation
import Carbon.HIToolbox
@testable import Flit

struct PreferencesTests {
    /// A private defaults domain, removed when the test ends.
    private final class Suite {
        let name = "flit-test-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: name)!
        deinit { UserDefaults().removePersistentDomain(forName: name) }
    }

    @Test func aFreshInstallHasEveryFeatureOnAndKeepAwakeOpenEnded() {
        let suite = Suite()
        let p = Preferences(defaults: suite.defaults)
        #expect(p.tilingEnabled)
        #expect(p.clipboardEnabled)
        #expect(p.dimEnabled)
        #expect(p.breaks.enabled)
        #expect(p.keepAwake == KeepAwakeSetting(on: true, until: nil))
    }

    @Test func featureSettingsSurviveARelaunch() {
        let suite = Suite()
        let first = Preferences(defaults: suite.defaults)
        first.tilingEnabled = false
        first.dimIntensity = 0.6
        first.breaks.intervalMinutes = 45
        first.clipboardRetentionDays = 7
        first.clipboardIgnoredApps = ["com.example.vault"]
        first.keepAwake = KeepAwakeSetting(on: false, until: nil)
        first.hotkeys.set(Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .command]), for: .clipboard)

        let second = Preferences(defaults: suite.defaults)
        #expect(!second.tilingEnabled)
        #expect(second.dimIntensity == 0.6)
        #expect(second.breaks.intervalMinutes == 45)
        #expect(second.clipboardRetentionDays == 7)
        #expect(second.clipboardIgnoredApps == ["com.example.vault"])
        #expect(second.keepAwake == KeepAwakeSetting(on: false, until: nil))
        #expect(second.hotkeys[.clipboard] == Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .command]))
    }

    @Test func aKeepAwakeTimerThatRanOutWhileFlitWasClosedLoadsAsOff() {
        let suite = Suite()
        let first = Preferences(defaults: suite.defaults)
        first.keepAwake = KeepAwakeSetting(on: true, until: Date(timeIntervalSinceNow: -60))
        let second = Preferences(defaults: suite.defaults)
        #expect(second.keepAwake == KeepAwakeSetting(on: false, until: nil))
    }

    @Test func registeredHotkeysFollowWhichFeaturesAreOn() {
        let suite = Suite()
        let p = Preferences(defaults: suite.defaults)
        p.tilingEnabled = false
        p.clipboardEnabled = false
        p.breaks.enabled = false
        let actions = p.activeHotkeys.map(\.action)
        #expect(!actions.contains(.tileLeft))
        #expect(!actions.contains(.clipboard))
        // Toggles stay reachable even while their feature is off.
        #expect(actions.contains(.dimming))
        p.clipboardEnabled = true
        #expect(p.activeHotkeys.map(\.action).contains(.clipboard))
    }
}
