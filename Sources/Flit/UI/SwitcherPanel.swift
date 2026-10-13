import AppKit
import SwiftUI

/// Transparent, non-activating panel that covers the chosen screen. The
/// SwiftUI content centers the switcher box; clicks outside it cancel.
@MainActor
final class SwitcherPanel: NSPanel {
    private let hosting: NSHostingView<SwitcherView>

    init(controller: SwitcherController) {
        hosting = NSHostingView(rootView: SwitcherView(controller: controller, prefs: Preferences.shared))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen) {
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// Shows the selected window at its real position, under the switcher: its
/// capture when Screen Recording is granted, otherwise a highlighted outline
/// with the app icon so you can still see *where* the window is.
@MainActor
final class PreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private let outline = NSView()
    private let iconView = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = true

        let root = NSView()
        root.wantsLayer = true
        contentView = root

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        root.addSubview(imageView)

        outline.wantsLayer = true
        outline.layer?.cornerRadius = 12
        outline.layer?.borderWidth = 3
        outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        outline.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        outline.autoresizingMask = [.width, .height]
        root.addSubview(outline)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        outline.addSubview(iconView)
    }

    override var canBecomeKey: Bool { false }

    func show(window w: WindowInfo, image: CGImage?) {
        var frame = Screens.appKitRect(fromCG: w.frame)
        if w.isMinimized || !w.isOnActiveSpace, let screen = NSScreen.main {
            // Not visible anywhere on the current Space: center on the main screen.
            let s = screen.visibleFrame
            let size = CGSize(width: min(w.frame.width, s.width * 0.8), height: min(w.frame.height, s.height * 0.8))
            frame = CGRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
        }
        setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        imageView.frame = bounds
        outline.frame = bounds
        if let image {
            imageView.image = NSImage(cgImage: image, size: frame.size)
            imageView.isHidden = false
            outline.isHidden = true
        } else {
            imageView.isHidden = true
            outline.isHidden = false
            let side = min(160, frame.width * 0.4, frame.height * 0.4)
            iconView.image = w.appIcon
            iconView.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        }
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
