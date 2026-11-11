import AppKit
import IOKit.pwr_mgt

/// Whether keep-awake is on, and when it turns itself off (nil: never).
struct KeepAwakeSetting: Codable, Equatable {
    var on: Bool
    var until: Date?

    static func on(for seconds: TimeInterval?, now: Date) -> KeepAwakeSetting {
        KeepAwakeSetting(on: true, until: seconds.map { now.addingTimeInterval($0) })
    }

    /// The setting as it stands at `now`: a timer that has run out is off.
    func resolved(at now: Date) -> KeepAwakeSetting {
        if on, let until, now >= until { return KeepAwakeSetting(on: false, until: nil) }
        return on ? self : KeepAwakeSetting(on: false, until: nil)
    }

    func toggled() -> KeepAwakeSetting {
        KeepAwakeSetting(on: !on, until: nil)
    }
}

/// Holds a power assertion that keeps the display lit and the Mac awake.
/// Costs nothing while off: no assertion, no timer.
@MainActor
final class KeepAwake {
    /// Called when a timed session runs out.
    var onExpire: (() -> Void)?

    private var assertion = IOPMAssertionID(0)
    private var timer: Timer?
    private var current = KeepAwakeSetting(on: false, until: nil)

    init() {
        // Timers don't run during sleep, so a session can end while the lid is shut.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }

    var isActive: Bool { assertion != 0 }

    func apply(_ setting: KeepAwakeSetting, now: Date = Date()) {
        current = setting.resolved(at: now)
        timer?.invalidate()
        timer = nil
        hold(current.on)
        guard current.on, let until = current.until else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func recheck() {
        let wasOn = current.on
        apply(current)
        if wasOn && !current.on { onExpire?() }
    }

    private func hold(_ on: Bool) {
        if on, assertion == 0 {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Flit keep awake" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id } else { Log.info("keep awake failed: \(result)") }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
