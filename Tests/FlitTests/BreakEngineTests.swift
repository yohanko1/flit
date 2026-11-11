import Testing
import Foundation
@testable import Flit

struct BreakEngineTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-11-11 is a Wednesday.
    func wednesday(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute, second: second))!
    }

    /// 28 min apart, 2 min long, 30 s heads-up, 5 min snooze, 5 min idle reset.
    func engine(_ change: (inout BreakSettings) -> Void = { _ in }) -> BreakEngine {
        var s = BreakSettings()
        s.enabled = true
        s.intervalMinutes = 28
        s.lengthSeconds = 120
        s.warningSeconds = 30
        s.snoozeMinutes = 5
        s.idleResetMinutes = 5
        s.workingHoursOnly = false
        change(&s)
        return BreakEngine(settings: s, calendar: utc)
    }

    @Test func startSchedulesTheFirstBreakOneIntervalAway() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.phase == .waiting(until: wednesday(10, 28)))
    }

    @Test func disabledEngineStaysOff() {
        var e = engine { $0.enabled = false }
        e.start(now: wednesday(10, 0))
        #expect(e.phase == .off)
        #expect(e.tick(now: wednesday(11, 0), idleSeconds: 0) == [])
    }

    @Test func headsUpAppearsThirtySecondsBeforeTheBreak() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.tick(now: wednesday(10, 27, 29), idleSeconds: 0) == [])
        #expect(e.tick(now: wednesday(10, 27, 30), idleSeconds: 0) == [.showWarning])
        #expect(e.phase == .warning(breakAt: wednesday(10, 28)))
    }

    @Test func breakStartsWhenTheHeadsUpRunsOutAndEndsAfterItsLength() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        _ = e.tick(now: wednesday(10, 27, 30), idleSeconds: 0)
        #expect(e.tick(now: wednesday(10, 28), idleSeconds: 0) == [.hideWarning, .startBreak])
        #expect(e.phase == .onBreak(until: wednesday(10, 30)))
        #expect(e.tick(now: wednesday(10, 29, 59), idleSeconds: 0) == [])
        #expect(e.tick(now: wednesday(10, 30), idleSeconds: 0) == [.endBreak])
        #expect(e.phase == .waiting(until: wednesday(10, 58)))
    }

    @Test func withNoHeadsUpTheBreakStartsDirectly() {
        var e = engine { $0.warningSeconds = 0 }
        e.start(now: wednesday(10, 0))
        #expect(e.tick(now: wednesday(10, 27, 59), idleSeconds: 0) == [])
        #expect(e.tick(now: wednesday(10, 28), idleSeconds: 0) == [.startBreak])
    }

    @Test func beingAwayLongEnoughRestartsTheCountdown() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.tick(now: wednesday(10, 10), idleSeconds: 299) == [])
        #expect(e.phase == .waiting(until: wednesday(10, 28)))
        #expect(e.tick(now: wednesday(10, 10), idleSeconds: 300) == [])
        #expect(e.phase == .waiting(until: wednesday(10, 38)))
    }

    @Test func idleResetCanBeTurnedOff() {
        var e = engine { $0.idleResetMinutes = 0 }
        e.start(now: wednesday(10, 0))
        _ = e.tick(now: wednesday(10, 10), idleSeconds: 3600)
        #expect(e.phase == .waiting(until: wednesday(10, 28)))
    }

    @Test func skipEndsTheBreakAndWaitsAFullInterval() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        _ = e.startNow(now: wednesday(10, 5))
        #expect(e.skip(now: wednesday(10, 6)) == [.endBreak])
        #expect(e.phase == .waiting(until: wednesday(10, 34)))
    }

    @Test func skipDuringTheHeadsUpHidesItAndWhileWaitingDoesNothing() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.skip(now: wednesday(10, 1)) == [])
        #expect(e.phase == .waiting(until: wednesday(10, 28)))
        _ = e.tick(now: wednesday(10, 27, 30), idleSeconds: 0)
        #expect(e.skip(now: wednesday(10, 27, 40)) == [.hideWarning])
        #expect(e.phase == .waiting(until: wednesday(10, 55, 40)))
    }

    @Test func snoozeBringsTheBreakBackAfterTheSnoozeLength() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        _ = e.tick(now: wednesday(10, 27, 30), idleSeconds: 0)
        #expect(e.snooze(now: wednesday(10, 27, 40)) == [.hideWarning])
        #expect(e.phase == .waiting(until: wednesday(10, 32, 40)))
        _ = e.startNow(now: wednesday(10, 33))
        #expect(e.snooze(now: wednesday(10, 33, 10)) == [.endBreak])
        #expect(e.phase == .waiting(until: wednesday(10, 38, 10)))
    }

    @Test func startNowBeginsABreakFromWaitingOrFromTheHeadsUp() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.startNow(now: wednesday(10, 5)) == [.startBreak])
        #expect(e.phase == .onBreak(until: wednesday(10, 7)))

        var f = engine()
        f.start(now: wednesday(10, 0))
        _ = f.tick(now: wednesday(10, 27, 30), idleSeconds: 0)
        #expect(f.startNow(now: wednesday(10, 27, 35)) == [.hideWarning, .startBreak])
    }

    @Test func timedPauseHoldsBreaksThenStartsAFreshCountdown() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.pause(until: wednesday(11, 0)) == [])
        #expect(e.tick(now: wednesday(10, 59), idleSeconds: 0) == [])
        #expect(e.phase == .paused(until: wednesday(11, 0)))
        _ = e.tick(now: wednesday(11, 0), idleSeconds: 0)
        #expect(e.phase == .waiting(until: wednesday(11, 28)))
    }

    @Test func openEndedPauseLastsUntilResumeAndEndsARunningBreak() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        _ = e.startNow(now: wednesday(10, 5))
        #expect(e.pause(until: nil) == [.endBreak])
        _ = e.tick(now: wednesday(23, 0), idleSeconds: 0)
        #expect(e.phase == .paused(until: nil))
        e.resume(now: wednesday(23, 30))
        #expect(e.phase == .waiting(until: wednesday(23, 58)))
    }

    @Test func workingHoursCoverWeekdaysFromStartUpToButNotIncludingEnd() {
        let e = engine { $0.workingHoursOnly = true; $0.workStartMinute = 9 * 60; $0.workEndMinute = 18 * 60; $0.workDays = [2, 3, 4, 5, 6] }
        #expect(e.isWorkingTime(wednesday(10, 0)))
        #expect(e.isWorkingTime(wednesday(9, 0)))
        #expect(!e.isWorkingTime(wednesday(8, 59)))
        #expect(!e.isWorkingTime(wednesday(18, 0)))
        let saturday = utc.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))!
        #expect(!e.isWorkingTime(saturday))
    }

    @Test func outsideWorkingHoursNoBreakAppearsAndTheCountdownKeepsRestarting() {
        var e = engine { $0.workingHoursOnly = true; $0.workStartMinute = 9 * 60; $0.workEndMinute = 18 * 60 }
        e.start(now: wednesday(17, 50))
        #expect(e.tick(now: wednesday(18, 17, 30), idleSeconds: 0) == [])
        #expect(e.phase == .waiting(until: wednesday(18, 45, 30)))
    }

    @Test func changingSettingsStartsStopsOrReschedules() {
        var e = engine { $0.enabled = false }
        var s = e.settings
        s.enabled = true
        #expect(e.apply(s, now: wednesday(10, 0)) == [])
        #expect(e.phase == .waiting(until: wednesday(10, 28)))

        s.intervalMinutes = 10
        _ = e.apply(s, now: wednesday(10, 5))
        #expect(e.phase == .waiting(until: wednesday(10, 15)))

        _ = e.startNow(now: wednesday(10, 6))
        s.enabled = false
        #expect(e.apply(s, now: wednesday(10, 7)) == [.endBreak])
        #expect(e.phase == .off)
    }

    @Test func whileYouAreActiveItNextChecksWhenYouCouldFirstCountAsAway() {
        var e = engine()   // away after 5 min
        e.start(now: wednesday(10, 0))
        #expect(e.nextWake(after: wednesday(10, 0), idleSeconds: 0) == wednesday(10, 5))
        #expect(e.nextWake(after: wednesday(10, 0), idleSeconds: 200) == wednesday(10, 1, 40))
    }

    @Test func whileYouAreAwayItChecksOnceAMinuteForYourReturn() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.nextWake(after: wednesday(10, 10), idleSeconds: 300) == wednesday(10, 11))
        #expect(e.nextWake(after: wednesday(10, 10), idleSeconds: 4000) == wednesday(10, 11))
    }

    @Test func theHeadsUpTimeWinsWhenItComesFirst() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.nextWake(after: wednesday(10, 27, 10), idleSeconds: 0) == wednesday(10, 27, 30))
    }

    @Test func withIdleResetOffItSleepsUntilTheHeadsUpEvenWithWorkingHours() {
        var e = engine { $0.idleResetMinutes = 0; $0.workingHoursOnly = true }
        e.start(now: wednesday(10, 0))
        #expect(e.nextWake(after: wednesday(10, 0), idleSeconds: 0) == wednesday(10, 27, 30))
    }

    @Test func wakesWhenTheCurrentPhaseEndsAndNeverWhenOff() {
        var e = engine()
        #expect(e.nextWake(after: wednesday(10, 0), idleSeconds: 0) == nil)
        e.start(now: wednesday(10, 0))
        _ = e.tick(now: wednesday(10, 27, 30), idleSeconds: 0)
        #expect(e.nextWake(after: wednesday(10, 27, 31), idleSeconds: 0) == wednesday(10, 28))
        _ = e.startNow(now: wednesday(10, 27, 40))
        #expect(e.nextWake(after: wednesday(10, 27, 41), idleSeconds: 0) == wednesday(10, 29, 40))
        _ = e.pause(until: wednesday(11, 0))
        #expect(e.nextWake(after: wednesday(10, 6), idleSeconds: 0) == wednesday(11, 0))
        _ = e.pause(until: nil)
        #expect(e.nextWake(after: wednesday(10, 7), idleSeconds: 0) == nil)
    }

    @Test func statusRoundsTheRemainingTimeUpToWholeMinutes() {
        var e = engine()
        e.start(now: wednesday(10, 0))
        #expect(e.status(now: wednesday(10, 16, 30)).contains("12 min"))
        #expect(e.status(now: wednesday(10, 27, 30)).contains("1 min"))
    }
}

struct KeepAwakeSettingTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func withoutATimerItStaysOn() {
        let s = KeepAwakeSetting(on: true, until: nil)
        #expect(s.resolved(at: t0.addingTimeInterval(86_400 * 365)) == KeepAwakeSetting(on: true, until: nil))
    }

    @Test func aTimerTurnsItOffAtItsEndAndNotBefore() {
        let s = KeepAwakeSetting.on(for: 900, now: t0)
        #expect(s == KeepAwakeSetting(on: true, until: t0.addingTimeInterval(900)))
        #expect(s.resolved(at: t0.addingTimeInterval(899)).on)
        #expect(s.resolved(at: t0.addingTimeInterval(900)) == KeepAwakeSetting(on: false, until: nil))
    }

    @Test func toggleTurnsATimedSessionOffAndOffIntoOpenEndedOn() {
        #expect(KeepAwakeSetting.on(for: 900, now: t0).toggled() == KeepAwakeSetting(on: false, until: nil))
        #expect(KeepAwakeSetting(on: false, until: nil).toggled() == KeepAwakeSetting(on: true, until: nil))
    }
}

struct BreakRestartTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func engine() -> BreakEngine {
        var s = BreakSettings()
        s.enabled = true; s.intervalMinutes = 28; s.lengthSeconds = 120; s.warningSeconds = 30
        s.idleResetMinutes = 0; s.workingHoursOnly = false
        var e = BreakEngine(settings: s)
        e.start(now: t0)
        return e
    }

    @Test func restartBeginsAFreshCountdownAndTakesDownWhateverIsShowing() {
        var waiting = engine()
        #expect(waiting.restart(now: t0 + 600) == [])
        #expect(waiting.phase == .waiting(until: t0 + 600 + 1680))

        var onBreak = engine()
        _ = onBreak.startNow(now: t0 + 60)
        #expect(onBreak.restart(now: t0 + 90) == [.endBreak])
        #expect(onBreak.phase == .waiting(until: t0 + 90 + 1680))
    }

    @Test func restartLeavesAPauseAndAnOffTimerAlone() {
        var paused = engine()
        _ = paused.pause(until: nil)
        #expect(paused.restart(now: t0 + 600) == [])
        #expect(paused.phase == .paused(until: nil))

        var s = BreakSettings()
        s.enabled = false
        var off = BreakEngine(settings: s)
        #expect(off.restart(now: t0) == [])
        #expect(off.phase == .off)
    }
}
