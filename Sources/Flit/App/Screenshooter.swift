#if DEBUG
import AppKit
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Makes the README screenshots. Debug builds only:
///
///     Flit --screenshots <output dir> <demo app pid> --data-dir <empty dir>
///
/// Nothing of the real desktop is in the pictures. Each window is captured on
/// its own — flit's panels, and the windows of the throwaway demo app from
/// `scripts/screenshots.sh` — and the captures are drawn over a plain
/// gradient at their real positions. Clipboard history comes from a store in
/// `--data-dir` filled with sample entries, never from the real one.
@MainActor
enum Screenshooter {
    private static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var demo: pid_t = 0
    private static var report: [String] = []
    private static let scale: CGFloat = 2

    static var isRequested: Bool { CommandLine.arguments.contains("--screenshots") }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), args.count > i + 2, let pid = pid_t(args[i + 2]) else { return }
        out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        demo = pid
        Task { @MainActor in
            await pause(2)
            await run()
            report.append("DONE")
            try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Scenes

    private static func run() async {
        guard let app = NSApp.delegate as? AppDelegate, let store = ClipboardController.shared.store else {
            report.append("ABORTED: app not ready")
            return
        }
        let prefs = Preferences.shared
        let saved = (dim: prefs.dimEnabled, breaks: prefs.breaks)
        let previous = NSWorkspace.shared.frontmostApplication

        // Clipboard: sample history and snippets.
        seed(store)
        ClipboardController.shared.show()
        await pause(0.6)
        await stageWindow { $0 is ClipboardPanel }
        await shoot("clipboard", own { $0 is ClipboardPanel }, margin: 70)
        ClipboardController.shared.query = "add"
        await pause(0.6)
        await shoot("clipboard-search", own { $0 is ClipboardPanel }, margin: 70)
        ClipboardController.shared.hide()
        await pause(0.4)

        // Tiling and dimming act on the front app, so the demo app has to be in front.
        if let first = WindowStore.shared.refresh().first(where: { $0.pid == demo && !$0.isAppPlaceholder }) {
            WindowActions.focus(first)
            await pause(0.9)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == demo {
            prefs.dimEnabled = false
            await pause(0.5)
            // Switcher, through a temporary shortcut that lists only the front
            // app's windows — so nothing but the demo windows can be in the picture.
            let profilesWere = prefs.profiles
            var onlyFrontApp = WindowFilter()
            onlyFrontApp.currentAppOnly = true
            prefs.profiles = [ShortcutProfile(name: "Demo", holdModifier: .control, keyCode: UInt16(kVK_ANSI_Grave),
                                              filter: onlyFrontApp)]
            await pause(0.3)
            post(flags: .maskControl)
            post(key: kVK_ANSI_Grave, flags: .maskControl)
            await pause(1.8)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == demo {
                await shoot("switcher", own { $0 is SwitcherPanel && $0.isVisible }, margin: 60, trim: true)
            }
            post(key: kVK_Escape, flags: .maskControl)
            post(flags: [])
            prefs.profiles = profilesWere
            await pause(0.5)
            let windows = AXUIElement.application(demo, timeout: 1).windows
            if windows.count >= 2 {
                // Left half with the real hotkey, then the next window to the right half.
                post(key: kVK_LeftArrow, flags: [.maskControl, .maskAlternate])
                await pause(0.5)
                windows[1].perform(kAXRaiseAction)
                windows[1].set(kAXMainAttribute, kCFBooleanTrue)
                await pause(0.5)
                post(key: kVK_RightArrow, flags: [.maskControl, .maskAlternate])
                await pause(0.6)
                let tiled = demoWindows().filter { $0.frame.height > 500 }
                if let area = tiled.map(\.frame).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) {
                    await shoot("tiling", tiled, canvas: area.insetBy(dx: -40, dy: -40))
                }
                post(key: kVK_DownArrow, flags: [.maskControl, .maskAlternate])
                await pause(0.4)
                windows[0].perform(kAXRaiseAction)
                windows[0].set(kAXMainAttribute, kCFBooleanTrue)
                await pause(0.4)
                post(key: kVK_DownArrow, flags: [.maskControl, .maskAlternate])
                await pause(0.5)
            }
            prefs.dimEnabled = true
            await pause(1.2)
            let overlay = ownLayers { $0.level == .normal && $0.ignoresMouseEvents && $0.isVisible }
            if let area = demoWindows().map(\.frame).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }), let dimmed = overlay.first?.frame {
                // Stay inside the dimmed display, or its edge shows up as a bright band.
                await shoot("dimming", zOrdered(demoWindows() + overlay), canvas: area.insetBy(dx: -70, dy: -70).intersection(dimmed))
            }
        } else {
            report.append("SKIP switcher, tiling, dimming: the demo app could not be brought to the front (machine in use)")
        }
        prefs.dimEnabled = saved.dim

        // Break: full cover, then the small reminder.
        prefs.breaks.enabled = true
        prefs.breaks.sound = false
        prefs.breaks.style = .overlay
        await pause(0.5)
        app.breaks.startNow()
        await pause(1.0)
        let stageFrame = Screens.appKitRect(fromCG: stage.frame)
        if let cover = own({ $0 is BreakOverlayWindow }).first(where: { $0.frame == stageFrame }) {
            await shoot("break", [cover], canvas: cover.frame)
        }
        app.breaks.skip()
        await pause(0.6)
        prefs.breaks.style = .toast
        await pause(0.5)
        app.breaks.startNow()
        await pause(0.6)
        await stageWindow { $0 is BreakToastPanel }
        await shoot("break-reminder", own { $0 is BreakToastPanel }, margin: 50)
        app.breaks.skip()
        prefs.breaks = saved.breaks
        await pause(0.5)

        // Preferences.
        for (pane, name) in [(PreferencesPane.tiling, "preferences-tiling"), (.breaks, "preferences-breaks")] {
            app.showPreferences(pane: pane)
            await pause(0.7)
            await stageWindow { $0 is PreferencesWindow && $0.isVisible }
            await shoot(name, own { $0 is PreferencesWindow && $0.isVisible }, margin: 50)
        }
        NSApp.windows.first { $0 is PreferencesWindow }?.performClose(nil)
        await pause(0.4)
        if let previous, !previous.isTerminated { previous.activate() }
    }

    // MARK: Sample data

    private static func seed(_ store: ClipboardStore) {
        let now = Date()
        let texts = [
            "The quick brown fox jumps over the lazy dog.",
            "func greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}",
            "https://developer.apple.com/documentation/appkit",
            "Meeting moved to Thursday 14:00, room 4B",
            "SELECT name, total FROM orders WHERE total > 100 ORDER BY total DESC;",
            "1 Infinite Loop, Cupertino, CA 95014",
            "git commit -m \"Add clipboard history\"",
            "https://github.com/rxhanson/Rectangle",
            "Remember: tickets for Saturday",
            "#4F8EF7",
        ]
        for (i, text) in texts.enumerated().reversed() {
            store.add(.text(text, rtf: nil, html: nil), app: "com.apple.Safari", now: now.addingTimeInterval(-Double(i) * 420 - 90))
        }
        store.add(.files(["/Applications/Safari.app", "/System/Applications/Notes.app"]), app: "com.apple.finder",
                  now: now.addingTimeInterval(-200))
        if let png = samplePNG() {
            store.add(.image(png: png, width: 640, height: 400), app: "com.apple.Preview", now: now.addingTimeInterval(-60))
        }
        store.add(.text("Lunch at 12:30 with the design team — add it to the calendar.", rtf: nil, html: nil),
                  app: "com.apple.Notes", now: now.addingTimeInterval(-20))
        store.addSnippet(name: "Address", text: "1 Infinite Loop\nCupertino, CA 95014")
        store.addSnippet(name: "Email signature", text: "Best regards,\nSam")
        store.addSnippet(name: "Daily note", text: "# {date}\n\n- \n")
    }

    private static func samplePNG() -> Data? {
        let w = 640, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), from: (1.0, 0.62, 0.35), to: (0.93, 0.28, 0.55))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 420, y: 230, width: 110, height: 110))
        return ctx.makeImage().flatMap { png($0) }
    }

    // MARK: Capture and compose

    /// One window to draw: its ID and where it is, in CG coordinates.
    private struct Layer {
        let id: CGWindowID
        let frame: CGRect
    }

    private static func own(_ match: (NSWindow) -> Bool) -> [Layer] { ownLayers(match) }

    private static func ownLayers(_ match: (NSWindow) -> Bool) -> [Layer] {
        NSApp.windows.filter(match).map { Layer(id: CGWindowID($0.windowNumber), frame: Screens.appKitRect(fromCG: $0.frame)) }
    }

    /// The demo app's windows, back to front.
    private static func demoWindows() -> [Layer] {
        zOrdered(onScreen().filter { $0.pid == demo && $0.layer == 0 }.map { Layer(id: $0.id, frame: $0.bounds) })
    }

    /// Sorts layers back to front, as they are stacked on screen.
    private static func zOrdered(_ layers: [Layer]) -> [Layer] {
        let order = onScreen().map(\.id)
        return layers.sorted { (order.firstIndex(of: $0.id) ?? 0) > (order.firstIndex(of: $1.id) ?? 0) }
    }

    private static func onScreen() -> [(id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect)] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { e in
            guard let id = e[kCGWindowNumber as String] as? CGWindowID, let pid = e[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = e[kCGWindowLayer as String] as? Int,
                  let b = e[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return (id, pid, layer, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }

    /// Captures `layers` (back to front) and draws them over a gradient.
    /// The canvas is `canvas` if given, else the layers' bounds plus `margin`.
    /// `trim` shrinks a mostly transparent window (the switcher's full-screen
    /// panel) to its visible content first.
    private static func shoot(_ name: String, _ layers: [Layer], margin: CGFloat = 0, canvas: CGRect? = nil, trim: Bool = false) async {
        guard !layers.isEmpty else {
            report.append("SKIP \(name): window not on screen")
            return
        }
        var images: [(image: CGImage, frame: CGRect)] = []
        for layer in layers {
            guard let image = await capture(layer.id, frame: layer.frame) else { continue }
            if trim, let (cropped, rect) = trimmed(image, frame: layer.frame) {
                images.append((cropped, rect))
            } else {
                images.append((image, layer.frame))
            }
        }
        guard !images.isEmpty else {
            report.append("SKIP \(name): capture failed")
            return
        }
        let bounds = images.map(\.frame).reduce(images[0].frame) { $0.union($1) }
        let area = canvas ?? bounds.insetBy(dx: -margin, dy: -margin)
        let w = Int(area.width * scale), h = Int(area.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        drawGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), from: (0.55, 0.70, 0.93), to: (0.80, 0.72, 0.93))
        for item in images {
            // CG window coordinates grow downward; the bitmap context grows upward.
            let rect = CGRect(x: (item.frame.minX - area.minX) * scale, y: (area.maxY - item.frame.maxY) * scale,
                              width: item.frame.width * scale, height: item.frame.height * scale)
            ctx.saveGState()
            if canvas == nil || images.count > 1 {
                ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            }
            ctx.draw(item.image, in: rect)
            ctx.restoreGState()
        }
        guard let full = ctx.makeImage(), let data = png(downscaled(full, maxWidth: 1800)) else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? data.write(to: out.appendingPathComponent("\(name).png"))
        report.append("OK \(name): \(images.count) window(s), \(data.count / 1024) KB")
    }

    /// The display to shoot on: the sharpest one.
    private static var stage: NSScreen {
        NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.screens[0]
    }

    /// Moves one of flit's windows to the middle of the stage display.
    private static func stageWindow(_ match: (NSWindow) -> Bool) async {
        guard let window = NSApp.windows.first(where: match) else { return }
        let area = stage.visibleFrame
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        await pause(0.5)
    }

    /// One window by itself, corners and see-through parts transparent.
    private static func capture(_ id: CGWindowID, frame: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        // A window is rendered at the scale of the display it is on; asking
        // for more leaves the picture in a corner of a larger, empty image.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let native = NSScreen.screens.first { Screens.appKitRect(fromCG: $0.frame).contains(center) }?.backingScaleFactor ?? 1
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.backgroundColor = .clear
        config.width = Int(frame.width * native)
        config.height = Int(frame.height * native)
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                           configuration: config)
    }

    /// Crops to the pixels that aren't transparent; returns the crop and its place on screen.
    private static func trimmed(_ image: CGImage, frame: CGRect) -> (CGImage, CGRect)? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Bitmap rows run top to bottom, like CG window coordinates.
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = image.cropping(to: crop) else { return nil }
        let sx = frame.width / CGFloat(w), sy = frame.height / CGFloat(h)
        return (cropped, CGRect(x: frame.minX + crop.minX * sx, y: frame.minY + crop.minY * sy,
                                width: crop.width * sx, height: crop.height * sy))
    }

    private static func drawGradient(_ ctx: CGContext, _ rect: CGRect, from: (CGFloat, CGFloat, CGFloat), to: (CGFloat, CGFloat, CGFloat)) {
        let colors = [CGColor(srgbRed: from.0, green: from.1, blue: from.2, alpha: 1),
                      CGColor(srgbRed: to.0, green: to.1, blue: to.2, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    private static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let h = image.height * maxWidth / image.width
        guard let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        return ctx.makeImage() ?? image
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Input

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func post(key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        let flags = arrows.contains(key) ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// A modifier going down or up, which is what opens and releases the switcher.
    private static func post(flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: !flags.isEmpty)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
#endif
