#if DEBUG
import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt

/// End-to-end check for the parts unit tests can't reach. Debug builds only:
///
///     Flit --selftest <report file> <probe pid> <probe text file> [section]
///
/// The probe is a throwaway app with one window and a text view that writes
/// its text to `<probe text file>` (see `scripts/selftest.sh`). The test
/// presses flit's real hotkeys with synthetic key events and reports what the
/// probe window, the clipboard and the screen did. It runs inside flit because
/// flit holds the Accessibility grant that posting keys and reading window
/// frames need.
@MainActor
enum SelfTest {
    private static var report: [String] = []
    private static var passed = 0
    private static var failed = 0
    private static var probe: pid_t = 0
    /// A single section to run instead of everything (currently "dimming").
    private static var only: String?

    private struct Abort: Error { let reason: String }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 3, let pid = pid_t(args[i + 2]) else { return }
        let reportPath = args[i + 1], textPath = args[i + 3]
        only = args.count > i + 4 ? args[i + 4] : nil
        probe = pid
        Task { @MainActor in
            await pause(1.5)
            do {
                try await run(textPath: textPath)
            } catch let abort as Abort {
                note("ABORTED: \(abort.reason)")
                failed += 1
            } catch {
                note("ABORTED: \(error)")
                failed += 1
            }
            note("RESULT: \(passed) passed, \(failed) failed")
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Steps

    private static func run(textPath: String) async throws {
        let prefs = Preferences.shared
        note("accessibility: \(Permissions.accessibility)  clipboard access: \(Permissions.pasteboard)")
        note("usable display frames: \(Screens.usableFramesCG)")

        guard let window = WindowStore.shared.refresh().first(where: { $0.pid == probe && !$0.isAppPlaceholder }) else {
            throw Abort(reason: "probe window not found")
        }
        WindowActions.focus(window)
        await pause(0.8)
        try requireProbeInFront()
        guard let original = probeFrame() else { throw Abort(reason: "cannot read the probe window frame") }
        note("probe window starts at \(original)")

        note("memory \(String(format: "%.1f", footprintMB())) MB — start")
        // --- Tiling ---------------------------------------------------------
        let displays = Screens.usableFramesCG
        let home = TileGeometry.displayIndex(containing: original, in: displays)
        let visible = displays[home]
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]

        // --- Dimming --------------------------------------------------------
        func dimmingSection() async throws {
            /// Flit's dimming overlays on screen, and where the probe window is in the front-to-back order.
            func overlays() -> (frames: [CGRect], indexes: [Int], probeIndex: Int?) {
                let layerZero = onScreenWindows().filter { $0.layer == 0 }
                let indexes = layerZero.indices.filter { layerZero[$0].pid == getpid() }
                return (indexes.map { layerZero[$0].bounds }, indexes, layerZero.firstIndex { $0.pid == probe })
            }
            // Whole displays, in the same coordinates as window bounds.
            let screens = NSScreen.screens.map { Screens.appKitRect(fromCG: $0.frame) }
            func displayOfProbe() -> CGRect {
                screens[TileGeometry.displayIndex(containing: probeFrame() ?? .zero, in: screens)]
            }

            let dimWas = prefs.dimEnabled
            prefs.dimEnabled = true
            await pause(1.0)
            var now = overlays()
            check("dimming: only the display with the front window is dimmed", now.frames == [displayOfProbe()],
                  "overlays at \(now.frames), front window's display is \(displayOfProbe())")
            if let probeIndex = now.probeIndex {
                check("dimming: the overlay sits directly under the front window", now.indexes == [probeIndex + 1],
                      "front window at \(probeIndex), overlays at \(now.indexes)")
            } else {
                check("dimming: the front window is on screen", false)
            }
            if screens.count > 1 {
                let before = displayOfProbe()
                try await press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand], wait: 1.0)
                now = overlays()
                check("dimming: follows the window to another display", displayOfProbe() != before && now.frames == [displayOfProbe()],
                      "overlays at \(now.frames), front window's display is \(displayOfProbe())")
                for _ in 1..<screens.count { try await press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand], wait: 1.0) }
                now = overlays()
                check("dimming: and back again", displayOfProbe() == before && now.frames == [before],
                      "overlays at \(now.frames), front window's display is \(displayOfProbe())")
            } else {
                note("SKIP dimming across displays: only one display attached")
            }
            prefs.dimEnabled = false
            await pause(1.0)
            check("dimming: turning it off removes the overlay", overlays().frames.isEmpty)
            prefs.dimEnabled = dimWas
            await pause(0.5)
        }
        if only == "dimming" {
            try await dimmingSection()
            return
        }

        func expectTile(_ name: String, key: Int, _ expected: CGRect) async throws {
            try await press(key, ctrlOpt)
            let actual = probeFrame() ?? .zero
            check("tiling: \(name)", TileGeometry.approxEqual(actual, expected), "wanted \(expected), got \(actual)")
        }
        let left = TileGeometry.frames(for: .left, in: visible)
        try await expectTile("⌃⌥← left half", key: kVK_LeftArrow, left[0])
        try await expectTile("⌃⌥← again, two thirds", key: kVK_LeftArrow, left[1])
        try await expectTile("⌃⌥← again, one third", key: kVK_LeftArrow, left[2])
        try await expectTile("⌃⌥← again, back to half", key: kVK_LeftArrow, left[0])
        try await expectTile("⌃⌥→ right half", key: kVK_RightArrow, TileGeometry.frames(for: .right, in: visible)[0])
        try await expectTile("⌃⌥↑ maximize", key: kVK_UpArrow, visible)
        try await expectTile("⌃⌥D left third", key: kVK_ANSI_D, TileGeometry.frames(for: .leftThird, in: visible)[0])
        try await expectTile("⌃⌥F center third", key: kVK_ANSI_F, TileGeometry.frames(for: .centerThird, in: visible)[0])
        try await expectTile("⌃⌥G right third", key: kVK_ANSI_G, TileGeometry.frames(for: .rightThird, in: visible)[0])
        if displays.count > 1 {
            let away = TileGeometry.displayIndex(after: home, count: displays.count, forward: true)
            try await press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand])
            var actual = probeFrame() ?? .zero
            check("tiling: ⌃⌥⌘→ moves to the next display as a right third",
                  TileGeometry.approxEqual(actual, TileGeometry.frames(for: .rightThird, in: displays[away])[0]),
                  "wanted \(TileGeometry.frames(for: .rightThird, in: displays[away])[0]), got \(actual)")
            for _ in 1..<displays.count { try await press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand]) }
            actual = probeFrame() ?? .zero
            check("tiling: cycling displays comes back home",
                  TileGeometry.displayIndex(containing: actual, in: displays) == home, "got \(actual)")
        } else {
            note("SKIP tiling: only one display attached")
        }
        try await press(kVK_DownArrow, ctrlOpt)
        let restored = probeFrame() ?? .zero
        check("tiling: ⌃⌥↓ restores the original frame", TileGeometry.approxEqual(restored, original), "wanted \(original), got \(restored)")

        note("memory \(String(format: "%.1f", footprintMB())) MB — after tiling")
        // --- Clipboard ------------------------------------------------------
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let controller = ClipboardController.shared
        guard let store = controller.store else { throw Abort(reason: "clipboard store unavailable") }
        let tag = String(UUID().uuidString.prefix(8))
        let older = "flit-selftest-older-\(tag)", newer = "flit-selftest-newer-\(tag)"

        // A real copy is a key press or click followed by a pasteboard change;
        // flit only looks at the pasteboard around input. F17 types nothing.
        func nudge() async {
            postKey(kVK_F17, [])
            await pause(1.3)
        }
        func copy(_ text: String) async {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            await nudge()
        }
        // Let the launch-time polling burst run out first.
        await pause(9)
        pasteboard.clearContents()
        pasteboard.setString("flit-selftest-silent-\(tag)", forType: .string)
        await pause(2.5)
        check("power: with no input, flit does not look at the clipboard",
              store.entries(matching: "flit-selftest-silent-\(tag)").isEmpty)
        await nudge()
        check("power: the next key press makes it catch up",
              store.entries(limit: 1).first?.text == "flit-selftest-silent-\(tag)")
        await copy(older)
        check("clipboard: a copy is recorded", store.entries(limit: 1).first?.text == older)
        await copy(newer)
        check("clipboard: the newest copy is first", store.entries(limit: 2).map(\.text) == [newer, older])

        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        check("clipboard: ⇧⌘V opens the panel", controller.isVisible)
        check("clipboard: the panel opens on the newest copy", controller.selectedRow?.id == controller.rows.first?.id
              && controller.rows.first.map(title) == newer)
        check("clipboard: the panel does not activate flit", NSWorkspace.shared.frontmostApplication?.processIdentifier == probe)
        try await press(kVK_DownArrow, [], wait: 0.3, allowPanel: true)
        check("clipboard: ↓ selects the older copy", controller.selectedRow.map(title) == older)
        try? "".write(toFile: textPath, atomically: true, encoding: .utf8)
        try await press(kVK_Return, [], wait: 0.9, allowPanel: true)
        check("clipboard: Return closes the panel", !controller.isVisible)
        let pasted = (try? String(contentsOfFile: textPath, encoding: .utf8)) ?? ""
        check("clipboard: Return pastes the selected entry into the front app", pasted == older, "probe text is \"\(pasted)\"")
        check("clipboard: the pasted entry moved to the top", store.entries(limit: 1).first?.text == older)

        // ⌘Return copies without pasting.
        try? "".write(toFile: textPath, atomically: true, encoding: .utf8)
        await pause(0.6)
        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        try await press(kVK_DownArrow, [], wait: 0.3, allowPanel: true)
        try await press(kVK_Return, [.maskCommand], wait: 0.8, allowPanel: true)
        let untouched = (try? String(contentsOfFile: textPath, encoding: .utf8)) ?? ""
        check("clipboard: ⌘Return puts the entry on the clipboard without pasting",
              pasteboard.string(forType: .string) == newer && untouched.isEmpty, "probe text is \"\(untouched)\"")

        // Formatting is kept by default and dropped by ⇧Return.
        let richText = "flit-selftest-rich-\(tag)"
        pasteboard.clearContents()
        let richItem = NSPasteboardItem()
        richItem.setString(richText, forType: .string)
        richItem.setData(Data("{\\rtf1\\ansi \\b \(richText)}".utf8), forType: .rtf)
        pasteboard.writeObjects([richItem])
        await nudge()
        await copy(newer)
        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        try await press(kVK_DownArrow, [], wait: 0.3, allowPanel: true)
        check("clipboard: the formatted copy is in history", controller.selectedRow.map(title) == richText)
        try await press(kVK_Return, [.maskCommand], wait: 0.6, allowPanel: true)
        check("clipboard: formatting comes back with the entry", pasteboard.types?.contains(.rtf) == true)
        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        try await press(kVK_Return, [.maskCommand, .maskShift], wait: 0.6, allowPanel: true)
        check("clipboard: ⇧Return leaves formatting behind",
              pasteboard.string(forType: .string) == richText && pasteboard.types?.contains(.rtf) != true)

        // ⌘S saves the selected copy as a snippet; ⌃X deletes it from history.
        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        try await press(kVK_ANSI_S, [.maskCommand], wait: 0.4, allowPanel: true)
        let savedSnippets = store.snippets(matching: richText)
        check("clipboard: ⌘S saves the entry as a snippet", savedSnippets.count == 1 && savedSnippets.first?.text == richText)
        try await press(kVK_ANSI_X, [.maskControl], wait: 0.4, allowPanel: true)
        check("clipboard: ⌃X deletes the entry", store.entries(matching: richText).isEmpty)
        try await press(kVK_Tab, [], wait: 0.4, allowPanel: true)
        var onlySnippets = !controller.rows.isEmpty
        for row in controller.rows { if case .entry = row { onlySnippets = false } }
        check("clipboard: Tab switches to the snippets list", onlySnippets)
        try await press(kVK_Escape, [], wait: 0.4, allowPanel: true)
        check("clipboard: Esc closes the panel", !controller.isVisible)
        for snippet in savedSnippets { store.deleteSnippet(id: snippet.id) }

        // A file copied in Finder.
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/etc/hosts") as NSURL])
        await nudge()
        let fileEntry = store.entries(limit: 1).first
        check("clipboard: a copied file is recorded", fileEntry?.kind == .file && fileEntry?.title == "hosts",
              "first entry: \(String(describing: fileEntry))")
        if let fileEntry, fileEntry.kind == .file { store.delete(id: fileEntry.id) }

        // Snippet: search for it by typing, paste it, placeholder filled.
        let snippetName = "flitsnip\(tag.lowercased())"
        let snippetID = store.addSnippet(name: snippetName, text: "[{date}]")
        try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.6)
        for ch in "flitsnip" {
            if let code = KeyTap.plainCharacters.first(where: { $0.value == ch })?.key {
                try await press(code, [], wait: 0.05, allowPanel: true)
            }
        }
        await pause(0.4)
        let typed = controller.query
        check("clipboard: typing goes into the search field", typed == "flitsnip", "query is \"\(typed)\" (a non-Latin input source changes this)")
        if typed != "flitsnip" { controller.query = "flitsnip"; await pause(0.3) }
        var snippetFirst = false
        if case .snippet(let s) = controller.rows.first { snippetFirst = s.id == snippetID }
        check("clipboard: a search lists the matching snippet first", snippetFirst)
        // The probe empties its text view when it sees the file emptied; give it time to.
        try? "".write(toFile: textPath, atomically: true, encoding: .utf8)
        await pause(0.6)
        try await press(kVK_Return, [], wait: 0.9, allowPanel: true)
        let today = SnippetExpander.expand("[{date}]", now: Date(), calendar: .current, clipboard: nil)
        let snippetPasted = (try? String(contentsOfFile: textPath, encoding: .utf8)) ?? ""
        check("clipboard: the snippet pastes with {date} filled in", snippetPasted == today, "probe text is \"\(snippetPasted)\"")

        // Image copy.
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            await nudge()
            let first = store.entries(limit: 1).first
            check("clipboard: a copied image is recorded with its size", first?.kind == .image && first?.width == 3 && first?.height == 2,
                  "first entry: \(String(describing: first))")
            if let first, first.kind == .image { store.delete(id: first.id) }
        }

        // Clean up the test rows and put the clipboard back.
        for entry in store.entries(matching: "flit-selftest-", limit: 50) where entry.text.hasSuffix(tag) { store.delete(id: entry.id) }
        for entry in store.entries(matching: today, limit: 5) where entry.text == today { store.delete(id: entry.id) }
        store.deleteSnippet(id: snippetID)
        pasteboard.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        await pause(0.8)

        note("memory \(String(format: "%.1f", footprintMB())) MB — after clipboard")
        try await dimmingSection()

        note("memory \(String(format: "%.1f", footprintMB())) MB — after dimming")
        // --- Break timer ----------------------------------------------------
        let breaksWere = prefs.breaks
        let hotkeysWere = prefs.hotkeys
        prefs.breaks.enabled = true
        prefs.breaks.sound = false
        prefs.breaks.style = .overlay
        prefs.breaks.allowSkip = true
        prefs.hotkeys.set(Hotkey(keyCode: UInt16(kVK_ANSI_B), modifiers: [.control, .option, .command]), for: .breakNow)
        await pause(0.6)
        try await press(kVK_ANSI_B, [.maskControl, .maskAlternate, .maskCommand], wait: 1.0)
        let screenSaver = Int(CGWindowLevelForKey(.screenSaverWindow))
        var covers = onScreenWindows().filter { $0.pid == getpid() && $0.layer == screenSaver }
        check("breaks: the hotkey starts a break covering every display", covers.count == NSScreen.screens.count,
              "\(covers.count) cover windows, \(NSScreen.screens.count) displays")
        check("breaks: flit takes the keyboard during the break",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())
        postKey(kVK_Escape, [])
        await pause(1.0)
        covers = onScreenWindows().filter { $0.pid == getpid() && $0.layer == screenSaver }
        check("breaks: Esc skips the break", covers.isEmpty)
        check("breaks: the app you were in gets the keyboard back",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == probe)
        prefs.hotkeys = hotkeysWere
        prefs.breaks = breaksWere

        note("memory \(String(format: "%.1f", footprintMB())) MB — after breaks")
        // --- Keep awake -----------------------------------------------------
        let awakeWas = prefs.keepAwake
        prefs.keepAwake = KeepAwakeSetting(on: true, until: nil)
        await pause(0.4)
        check("keep awake: on holds a display-sleep assertion", holdsAssertion())
        prefs.keepAwake = KeepAwakeSetting(on: false, until: nil)
        await pause(0.4)
        check("keep awake: off releases it", !holdsAssertion())
        prefs.keepAwake = awakeWas
        await pause(0.4)

        // --- Break as a small reminder --------------------------------------
        guard let app = NSApp.delegate as? AppDelegate else { throw Abort(reason: "no app delegate") }
        prefs.breaks.enabled = true
        prefs.breaks.sound = false
        prefs.breaks.style = .toast
        await pause(0.6)
        app.breaks.startNow()
        await pause(0.8)
        func reminders() -> Int {
            onScreenWindows().filter { $0.pid == getpid() && $0.bounds.size == BreakToastPanel.size }.count
        }
        check("breaks: the small-reminder style shows a reminder, not a cover", reminders() == 1
              && onScreenWindows().filter { $0.pid == getpid() && $0.layer == screenSaver }.isEmpty)
        check("breaks: the reminder leaves the front app alone",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == probe)
        app.breaks.snooze()
        await pause(0.6)
        check("breaks: snooze takes the reminder away", reminders() == 0)
        if case .waiting(let until) = app.breaks.phase {
            let minutes = until.timeIntervalSinceNow / 60
            check("breaks: snooze brings the break back after the snooze length",
                  abs(minutes - Double(prefs.breaks.snoozeMinutes)) < 0.2, "next break in \(minutes) min")
        } else {
            check("breaks: snooze goes back to waiting", false, "phase is \(app.breaks.phase)")
        }
        prefs.breaks = breaksWere
        await pause(0.4)

        note("memory \(String(format: "%.1f", footprintMB())) MB — before preferences")
        // --- Preferences ----------------------------------------------------
        let bindingsWere = prefs.hotkeys
        app.showPreferences(pane: .general)
        await pause(0.9)
        // Looked up each time, so the test itself doesn't keep the closed window alive.
        var settings: NSWindow? { NSApp.windows.first { $0 is PreferencesWindow } }
        check("preferences: the window opens in front", settings?.isVisible == true
              && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())
        for pane in PreferencesPane.allCases {
            PreferencesRoute.shared.pane = pane
            await pause(0.35)
        }
        check("preferences: every pane renders", settings?.isVisible == true)

        // Recording a shortcut, including one that another action already has.
        func record(_ action: HotkeyAction, _ key: Int, _ flags: CGEventFlags) async {
            HotkeyRecording.shared.start(action) { prefs.hotkeys.set($0, for: action) }
            await pause(0.2)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { postKey(key, flags) }
            await pause(0.5)
        }
        await record(.tileLeft, kVK_ANSI_L, [.maskControl, .maskAlternate, .maskCommand])
        check("preferences: a recorded shortcut is stored",
              prefs.hotkeys[.tileLeft] == Hotkey(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option, .command]),
              "left half is now \(String(describing: prefs.hotkeys[.tileLeft]?.description))")
        await record(.tileLeft, kVK_RightArrow, [.maskControl, .maskAlternate])
        check("preferences: a shortcut in use can be recorded and moves to the new action",
              prefs.hotkeys[.tileLeft] == HotkeyAction.tileRight.defaultHotkey && prefs.hotkeys[.tileRight] == nil,
              "left half \(String(describing: prefs.hotkeys[.tileLeft]?.description)), right half \(String(describing: prefs.hotkeys[.tileRight]?.description))")
        check("preferences: recording ends after one shortcut", HotkeyRecording.shared.action == nil)
        prefs.hotkeys = bindingsWere

        settings?.performClose(nil)
        await pause(0.6)
        check("memory: closing Preferences frees its views", settings?.contentView == nil)
        app.showPreferences()
        await pause(0.6)
        NSApp.windows.first { $0 is PreferencesWindow }?.performClose(nil)
        await pause(0.6)
        check("memory: reopening Preferences reuses the one window", NSApp.windows.filter { $0 is PreferencesWindow }.count == 1)

        // Nothing flit showed during the run may still be holding a view tree.
        func leftovers(_ kind: String, _ match: (NSWindow) -> Bool) {
            let live = NSApp.windows.filter(match)
            check("memory: no \(kind) left behind", live.allSatisfy { $0.contentView == nil } && live.count <= 1,
                  "\(live.count) alive, \(live.filter { $0.contentView != nil }.count) still holding views")
        }
        leftovers("clipboard panel") { $0 is ClipboardPanel }
        leftovers("break cover") { $0 is BreakOverlayWindow }
        leftovers("break reminder") { $0 is BreakToastPanel }

        // The moved shortcuts are back where they were and live again.
        WindowActions.focus(window)
        await pause(0.9)
        try await press(kVK_UpArrow, ctrlOpt)
        check("hotkeys: defaults work again after the settings round trip",
              TileGeometry.approxEqual(probeFrame() ?? .zero, visible), "got \(probeFrame() ?? .zero)")
        try await press(kVK_DownArrow, ctrlOpt)
        note("memory \(String(format: "%.1f", footprintMB())) MB — after preferences")

        // --- Memory: repeated use must not keep growing ---------------------
        // The first use of each window pays one-time framework costs; what
        // matters is that the tenth use costs no more than the second.
        func growth(_ name: String, cycles: Int, _ body: () async throws -> Void) async rethrows {
            try await body()
            await pause(0.5)
            let before = footprintMB()
            for _ in 0..<cycles { try await body() }
            await pause(0.5)
            let perCycle = (footprintMB() - before) / Double(cycles)
            check("memory: \(name) does not grow with use", perCycle < 0.15,
                  String(format: "%.2f MB per use over %d uses", perCycle, cycles))
            note(String(format: "memory %.1f MB — after %d× %@ (%.3f MB per use)", footprintMB(), cycles, name, perCycle))
        }
        try await growth("the clipboard panel", cycles: 10) {
            try await press(kVK_ANSI_V, [.maskCommand, .maskShift], wait: 0.35)
            try await press(kVK_DownArrow, [], wait: 0.1, allowPanel: true)
            try await press(kVK_Escape, [], wait: 0.25, allowPanel: true)
        }
        await growth("copying text", cycles: 10) {
            pasteboard.clearContents()
            pasteboard.setString("flit-selftest-loop-\(UUID().uuidString)-\(tag)", forType: .string)
            postKey(kVK_F17, [])
            await pause(0.8)
        }
        for entry in store.entries(matching: "flit-selftest-loop-", limit: 50) where entry.text.hasSuffix(tag) { store.delete(id: entry.id) }
        await growth("Preferences", cycles: 5) {
            app.showPreferences(pane: .clipboard)
            await pause(0.5)
            NSApp.windows.first { $0 is PreferencesWindow }?.performClose(nil)
            await pause(0.4)
        }
        prefs.breaks.enabled = true
        prefs.breaks.sound = false
        prefs.breaks.style = .overlay
        await pause(0.5)
        await growth("a break", cycles: 5) {
            app.breaks.startNow()
            await pause(0.5)
            app.breaks.skip()
            await pause(0.4)
        }
        prefs.breaks = breaksWere
        WindowActions.focus(window)
        await pause(0.8)
        try await growth("tiling", cycles: 10) {
            try await press(kVK_LeftArrow, ctrlOpt, wait: 0.25)
        }
        try await press(kVK_DownArrow, ctrlOpt)
        await pause(3)
        note("memory \(String(format: "%.1f", footprintMB())) MB — settled at the end")
    }

    // MARK: Helpers

    private static func title(_ row: ClipRow) -> String {
        switch row {
        case .snippet(let s): return s.name
        case .entry(let e): return e.text
        }
    }

    private static func note(_ line: String) { report.append(line) }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        note((ok ? "PASS " : "FAIL ") + name + (ok || detail.isEmpty ? "" : " — " + detail))
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Keys must only ever go to the probe (or to flit's own clipboard panel
    /// in front of it), never into whatever the user switched to meanwhile.
    private static func requireProbeInFront() throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == probe else {
            throw Abort(reason: "the probe window is no longer in front; stopped before typing into another app")
        }
    }

    private static func press(_ key: Int, _ flags: CGEventFlags, wait: Double = 0.45, allowPanel: Bool = false) async throws {
        try requireProbeInFront()
        if allowPanel, !ClipboardController.shared.isVisible {
            throw Abort(reason: "the clipboard panel is not open; stopped before typing into the front app")
        }
        postKey(key, flags)
        await pause(wait)
    }

    private static func postKey(_ key: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Real keyboards send arrow keys with these two bits set, and the
        // system only matches a registered arrow hotkey when they are there.
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        let flags = arrows.contains(key) ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func probeFrame() -> CGRect? {
        let app = AXUIElement.application(probe, timeout: 1)
        guard let window = app.focusedWindow ?? app.mainWindow ?? app.windows.first,
              let position = window.position, let size = window.size else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// On-screen windows, front to back.
    private static func onScreenWindows() -> [(pid: pid_t, layer: Int, bounds: CGRect)] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { e in
            guard let pid = e[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = e[kCGWindowLayer as String] as? Int,
                  let b = e[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return (pid, layer, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }

    /// What Activity Monitor shows as this process's memory.
    private static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }

    private static func holdsAssertion() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let all = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.contains { ($0["AssertName"] as? String) == "Flit keep awake" }
    }
}
#endif
