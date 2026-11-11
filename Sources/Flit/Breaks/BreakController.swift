import AppKit
import SwiftUI

/// Runs the break timer: feeds the clock and idle time to `BreakEngine` and
/// puts its effects on screen.
///
/// One timer is armed for the engine's next wake-up and nothing else runs.
/// While waiting that is one coalesced wake every few minutes; the on-screen
/// countdowns are drawn by SwiftUI only while they are visible.
@MainActor
final class BreakController: ObservableObject {
    @Published private(set) var phase: BreakEngine.Phase = .off
    private(set) var settings: BreakSettings

    private var engine: BreakEngine
    private var timer: Timer?
    private var overlays: [BreakOverlayWindow] = []
    private var toast: BreakToastPanel?
    private var previousApp: NSRunningApplication?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: BreakSettings) {
        self.settings = settings
        engine = BreakEngine(settings: settings)
        engine.start(now: Date())
        phase = engine.phase
        // Time asleep or locked already was a break: begin a fresh countdown.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.run { $0.restart(now: Date()) } }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.run { $0.restart(now: Date()) }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, !self.overlays.isEmpty else { return }
            self.showOverlays()
        }
        schedule()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
        tokens.append((center, token))
    }

    // MARK: Commands

    func apply(_ new: BreakSettings) {
        guard new != settings else { return }
        settings = new
        run { $0.apply(new, now: Date()) }
    }

    func skip() { run { $0.skip(now: Date()) } }
    func snooze() { run { $0.snooze(now: Date()) } }
    func startNow() { run { $0.startNow(now: Date()) } }
    func resume() { run { $0.resume(now: Date()); return [] } }

    /// nil pauses until resumed by hand.
    func pause(minutes: Int?) {
        let until = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        run { $0.pause(until: until) }
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    var status: String { engine.status(now: Date()) }

    /// When the heads-up or break on screen ends, for the countdowns.
    var deadline: Date? {
        switch phase {
        case .warning(let breakAt): return breakAt
        case .onBreak(let until): return until
        default: return nil
        }
    }

    // MARK: Engine plumbing

    private func run(_ change: (inout BreakEngine) -> [BreakEngine.Effect]) {
        let effects = change(&engine)
        phase = engine.phase
        for effect in effects { perform(effect) }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        guard let wake = engine.nextWake(after: now, idleSeconds: Self.idleSeconds) else { return }
        let delay = max(wake.timeIntervalSince(now), 0.2)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A check for time away can slide to share a wakeup; the moments a
        // break appears or ends stay on time.
        t.tolerance = delay >= 55 ? 10 : 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        run { $0.tick(now: Date(), idleSeconds: Self.idleSeconds) }
    }

    /// Seconds since the last key, click, scroll or pointer move.
    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func perform(_ effect: BreakEngine.Effect) {
        switch effect {
        case .showWarning:
            showToast()
        case .hideWarning:
            hideToast()
        case .startBreak:
            if settings.sound { NSSound(named: "Glass")?.play() }
            if settings.style == .overlay { showOverlays() } else { showToast() }
        case .endBreak:
            if settings.sound { NSSound(named: "Hero")?.play() }
            hideOverlays()
            hideToast()
        }
    }

    // MARK: Windows

    private func showToast() {
        if toast == nil { toast = BreakToastPanel(controller: self) }
        toast?.present()
    }

    private func hideToast() {
        toast?.orderOut(nil)
        toast = nil
    }

    private func showOverlays() {
        if overlays.isEmpty { previousApp = NSWorkspace.shared.frontmostApplication }
        for w in overlays { w.orderOut(nil) }
        overlays = NSScreen.screens.map { BreakOverlayWindow(controller: self, screen: $0) }
        // Flit takes the keyboard for the break so typing doesn't land in the app underneath.
        NSApp.activate(ignoringOtherApps: true)
        for (i, w) in overlays.enumerated() {
            if i == 0 { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        }
    }

    private func hideOverlays() {
        guard !overlays.isEmpty else { return }
        for w in overlays { w.orderOut(nil) }
        overlays = []
        if let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }
}

/// Covers one display for the length of a break.
@MainActor
final class BreakOverlayWindow: NSWindow {
    private weak var controller: BreakController?

    init(controller: BreakController, screen: NSScreen) {
        self.controller = controller
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = NSHostingView(rootView: BreakOverlayView(controller: controller))
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc skips, when skipping is allowed. Every other key is swallowed.
        if event.keyCode == 53, controller?.settings.allowSkip == true { controller?.skip() }
    }
}

/// The small reminder in the top-right corner: the heads-up before a break,
/// and the whole break when the style is "small reminder".
@MainActor
final class BreakToastPanel: NSPanel {
    static let size = NSSize(width: 340, height: 96)

    init(controller: BreakController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = NSHostingView(rootView: BreakToastView(controller: controller))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 16, y: area.maxY - Self.size.height - 16))
        orderFrontRegardless()
    }
}

/// "1:45" until `deadline`, redrawn once a second while on screen.
private struct Countdown: View {
    let deadline: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(deadline.map { $0.timeIntervalSince(context.date) } ?? 0))
                .monospacedDigit()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct BreakOverlayView: View {
    @ObservedObject var controller: BreakController

    var body: some View {
        ZStack {
            Color.black.opacity(0.86)
            VStack(spacing: 22) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.9))
                Text(controller.settings.message.isEmpty ? "Time for a break." : controller.settings.message)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                Countdown(deadline: controller.deadline)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    if controller.settings.allowSnooze {
                        Button("Snooze \(controller.settings.snoozeMinutes) min") { controller.snooze() }
                    }
                    if controller.settings.allowSkip {
                        Button("Skip") { controller.skip() }
                    }
                }
                .controlSize(.large)
                if controller.settings.allowSkip {
                    Text("Esc skips this break").font(.callout).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

struct BreakToastView: View {
    @ObservedObject var controller: BreakController

    private var onBreak: Bool {
        if case .onBreak = controller.phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 26)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(onBreak ? (controller.settings.message.isEmpty ? "Time for a break." : controller.settings.message) : "Break in")
                        .lineLimit(1)
                    Countdown(deadline: controller.deadline)
                    if onBreak { Text("left").foregroundStyle(.secondary) }
                }
                .font(.headline)
                HStack(spacing: 8) {
                    if !onBreak { Button("Start now") { controller.startNow() } }
                    if controller.settings.allowSnooze {
                        Button("Snooze \(controller.settings.snoozeMinutes) min") { controller.snooze() }
                    }
                    if controller.settings.allowSkip {
                        Button(onBreak ? "Done" : "Skip") { controller.skip() }
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: BreakToastPanel.size.width, height: BreakToastPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }
}
