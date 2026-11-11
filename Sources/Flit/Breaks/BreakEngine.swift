import Foundation

struct BreakSettings: Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case overlay, toast
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overlay: return "Cover the screen"
            case .toast: return "Small reminder"
            }
        }
    }

    var enabled = true
    var intervalMinutes = 28
    var lengthSeconds = 120
    var style: Style = .overlay
    /// Heads-up shown this long before a break; 0 turns it off.
    var warningSeconds = 30
    var allowSkip = true
    var allowSnooze = true
    var snoozeMinutes = 5
    /// Being away this long restarts the countdown; 0 turns it off.
    var idleResetMinutes = 5
    var message = "Time for a break."
    var sound = true
    var workingHoursOnly = false
    /// Minutes after midnight.
    var workStartMinute = 9 * 60
    var workEndMinute = 18 * 60
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    var workDays: Set<Int> = [2, 3, 4, 5, 6]

    init() {}

    // Tolerant decoding: a field added later just takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BreakSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        lengthSeconds = try c.decodeIfPresent(Int.self, forKey: .lengthSeconds) ?? d.lengthSeconds
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? d.style
        warningSeconds = try c.decodeIfPresent(Int.self, forKey: .warningSeconds) ?? d.warningSeconds
        allowSkip = try c.decodeIfPresent(Bool.self, forKey: .allowSkip) ?? d.allowSkip
        allowSnooze = try c.decodeIfPresent(Bool.self, forKey: .allowSnooze) ?? d.allowSnooze
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        idleResetMinutes = try c.decodeIfPresent(Int.self, forKey: .idleResetMinutes) ?? d.idleResetMinutes
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? d.message
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
        workingHoursOnly = try c.decodeIfPresent(Bool.self, forKey: .workingHoursOnly) ?? d.workingHoursOnly
        workStartMinute = try c.decodeIfPresent(Int.self, forKey: .workStartMinute) ?? d.workStartMinute
        workEndMinute = try c.decodeIfPresent(Int.self, forKey: .workEndMinute) ?? d.workEndMinute
        workDays = try c.decodeIfPresent(Set<Int>.self, forKey: .workDays) ?? d.workDays
    }
}

/// The break timer's state machine. Pure: the caller supplies the clock and
/// the idle time, and carries out the returned effects.
struct BreakEngine {
    enum Phase: Equatable {
        case off
        case waiting(until: Date)       // the next break starts at `until`
        case warning(breakAt: Date)     // the heads-up is showing
        case onBreak(until: Date)
        case paused(until: Date?)       // nil: until resumed by hand
    }

    enum Effect: Equatable {
        case showWarning, hideWarning, startBreak, endBreak
    }

    private(set) var phase: Phase = .off
    private(set) var settings: BreakSettings
    var calendar: Calendar

    init(settings: BreakSettings, calendar: Calendar = .current) {
        self.settings = settings
        self.calendar = calendar
    }

    private var interval: TimeInterval { TimeInterval(max(settings.intervalMinutes, 1) * 60) }
    private var length: TimeInterval { TimeInterval(max(settings.lengthSeconds, 1)) }
    private var warning: TimeInterval { TimeInterval(max(settings.warningSeconds, 0)) }
    private var snoozeLength: TimeInterval { TimeInterval(max(settings.snoozeMinutes, 1) * 60) }

    mutating func start(now: Date) {
        phase = settings.enabled ? .waiting(until: now + interval) : .off
    }

    /// Takes new settings: starts or stops the timer, and restarts the
    /// countdown when the interval changed.
    mutating func apply(_ new: BreakSettings, now: Date) -> [Effect] {
        let old = settings
        settings = new
        if !new.enabled {
            let effects = dismiss()
            phase = .off
            return effects
        }
        if phase == .off {
            start(now: now)
        } else if case .waiting = phase, old.intervalMinutes != new.intervalMinutes {
            phase = .waiting(until: now + interval)
        }
        return []
    }

    mutating func tick(now: Date, idleSeconds: TimeInterval) -> [Effect] {
        switch phase {
        case .off:
            return []
        case .paused(let until):
            if let until, now >= until { phase = .waiting(until: now + interval) }
            return []
        case .waiting(let until):
            let away = settings.idleResetMinutes > 0 && idleSeconds >= TimeInterval(settings.idleResetMinutes * 60)
            if away || !isWorkingTime(now) {
                phase = .waiting(until: now + interval)
                return []
            }
            if now >= until {
                phase = .onBreak(until: now + length)
                return [.startBreak]
            }
            if warning > 0, now >= until - warning {
                phase = .warning(breakAt: until)
                return [.showWarning]
            }
            return []
        case .warning(let breakAt):
            guard now >= breakAt else { return [] }
            phase = .onBreak(until: now + length)
            return [.hideWarning, .startBreak]
        case .onBreak(let until):
            guard now >= until else { return [] }
            phase = .waiting(until: now + interval)
            return [.endBreak]
        }
    }

    /// Ends whatever is showing and waits a full interval.
    mutating func skip(now: Date) -> [Effect] { postpone(by: interval, now: now) }

    /// Ends whatever is showing and brings the break back after the snooze length.
    mutating func snooze(now: Date) -> [Effect] { postpone(by: snoozeLength, now: now) }

    private mutating func postpone(by delay: TimeInterval, now: Date) -> [Effect] {
        let effects = dismiss()
        guard !effects.isEmpty else { return [] }
        phase = .waiting(until: now + delay)
        return effects
    }

    /// Starts a fresh countdown, taking down anything on screen. Used when the
    /// Mac wakes or is unlocked: time away already was the break. A pause or
    /// an off timer is left alone.
    mutating func restart(now: Date) -> [Effect] {
        switch phase {
        case .off, .paused: return []
        case .waiting, .warning, .onBreak:
            let effects = dismiss()
            phase = .waiting(until: now + interval)
            return effects
        }
    }

    mutating func startNow(now: Date) -> [Effect] {
        if case .onBreak = phase { return [] }
        let effects = dismiss()
        phase = .onBreak(until: now + length)
        return effects + [.startBreak]
    }

    mutating func pause(until: Date?) -> [Effect] {
        let effects = dismiss()
        phase = .paused(until: until)
        return effects
    }

    mutating func resume(now: Date) {
        guard case .paused = phase else { return }
        start(now: now)
    }

    /// The effect that takes the current heads-up or break off screen.
    private func dismiss() -> [Effect] {
        switch phase {
        case .warning: return [.hideWarning]
        case .onBreak: return [.endBreak]
        default: return []
        }
    }

    func isWorkingTime(_ date: Date) -> Bool {
        guard settings.workingHoursOnly else { return true }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, settings.workDays.contains(weekday) else { return false }
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minute >= settings.workStartMinute && minute < settings.workEndMinute
    }

    /// When `tick` next needs to run; nil means nothing is scheduled.
    ///
    /// While waiting that is the heads-up time, or earlier only to watch for
    /// time away: with the user active, the first moment they could count as
    /// away; with the user already away, once a minute until they are back.
    func nextWake(after now: Date, idleSeconds: TimeInterval) -> Date? {
        switch phase {
        case .off: return nil
        case .paused(let until): return until
        case .warning(let breakAt): return breakAt
        case .onBreak(let until): return until
        case .waiting(let until):
            let due = until - warning
            guard settings.idleResetMinutes > 0 else { return due }
            let threshold = TimeInterval(settings.idleResetMinutes * 60)
            let check = idleSeconds >= threshold ? 60 : max(threshold - idleSeconds, 1)
            return min(due, now + check)
        }
    }

    /// One line for the menu.
    func status(now: Date) -> String {
        switch phase {
        case .off: return "Breaks off"
        case .paused: return "Breaks paused"
        case .warning: return "Break starting soon"
        case .onBreak: return "On a break"
        case .waiting(let until):
            let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
            return "Next break in \(minutes) min"
        }
    }
}
