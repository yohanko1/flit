import Testing
import Foundation
@testable import Flit

struct StatusMenuTests {
    private func sections(keepAwake: KeepAwakeSetting = KeepAwakeSetting(on: true, until: nil), dimming: Bool = true,
                          breaks: StatusMenu.Breaks? = StatusMenu.Breaks(status: "Next break in 12 min", paused: false),
                          accessibility: Bool = true, screenRecording: Bool = true) -> [StatusMenu.Section] {
        StatusMenu.sections(keepAwake: keepAwake, dimming: dimming, breaks: breaks,
                            accessibility: accessibility, screenRecording: screenRecording, time: { _ in "14:30" })
    }

    private func titles(_ section: StatusMenu.Section) -> [String] { section.items.map(\.title) }

    @Test func breaksComeFirstAndOnlyMultiItemFeaturesGetAHeading() {
        // Dimming is a single on/off line; Preferences and Quit sit under a plain divider.
        #expect(sections().map(\.title) == ["Breaks", "Keep Awake", nil, nil])
    }

    @Test func theMenuHoldsOnlyTheseItems() {
        // No shortcut summary and no clipboard entry: shortcuts live in Preferences.
        let all = sections()
        #expect(titles(all[0]) == ["Next break in 12 min", "Start Break Now", "Pause Breaks"])
        #expect(titles(all[1]) == ["Keep Mac Awake", "Turn On For"])
        #expect(titles(all[2]) == ["Dimming"])
        #expect(titles(all[3]) == ["Preferences…", "Quit Flit"])
    }

    @Test func checkmarksFollowTheSettings() {
        let on = sections(keepAwake: KeepAwakeSetting(on: true, until: nil), dimming: true)
        #expect(on[1].items[0].checked)
        #expect(on[2].items[0].checked)
        let off = sections(keepAwake: KeepAwakeSetting(on: false, until: nil), dimming: false)
        #expect(!off[1].items[0].checked)
        #expect(!off[2].items[0].checked)
    }

    @Test func dimmingIsOneToggle() {
        let dimming = sections()[2]
        #expect(dimming.items.count == 1)
        #expect(dimming.items[0].command == .toggleDimming)
    }

    @Test func aTimedKeepAwakeSaysWhenItEnds() {
        let timed = sections(keepAwake: KeepAwakeSetting(on: true, until: Date(timeIntervalSince1970: 1_000)))
        #expect(timed[1].items[0].title == "Keep Mac Awake (until 14:30)")
    }

    @Test func keepAwakeOffersTheFiveDurations() {
        let durations = sections()[1].items[1].children.map(\.command)
        #expect(durations == [.keepAwakeFor(900), .keepAwakeFor(1800), .keepAwakeFor(3600), .keepAwakeFor(7200), .keepAwakeFor(18_000)])
    }

    @Test func theBreaksSectionGoesAwayWhenBreaksAreOff() {
        #expect(sections(breaks: nil).map(\.title) == ["Keep Awake", nil, nil])
    }

    @Test func pausedBreaksOfferResumeInsteadOfPause() {
        let paused = sections(breaks: StatusMenu.Breaks(status: "Breaks paused", paused: true))
        #expect(titles(paused[0]) == ["Breaks paused", "Start Break Now", "Resume Breaks"])
        #expect(paused[0].items[2].command == .resumeBreaks)
    }

    @Test func pauseOffersTimedPausesAndAnOpenEndedOne() {
        let pause = sections()[0].items[2].children.map(\.command)
        #expect(pause == [.pauseBreaks(minutes: 30), .pauseBreaks(minutes: 60), .pauseBreaks(minutes: 120), .pauseBreaks(minutes: nil)])
    }

    @Test func missingPermissionsGetAnItemUntilGranted() {
        let missing = sections(accessibility: false, screenRecording: false)
        #expect(titles(missing[3]) == ["Grant Accessibility Access…", "Grant Screen Recording (thumbnails)…", "Preferences…", "Quit Flit"])
        #expect(missing[3].items[0].command == .grantAccessibility)
    }

    @Test func theStatusLineIsALabelNotACommand() {
        #expect(sections()[0].items[0].command == nil)
        #expect(sections()[0].items[1].command == .breakNow)
    }
}
