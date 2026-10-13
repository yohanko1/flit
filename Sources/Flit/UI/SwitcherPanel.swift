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

/// Shows the selected window's capture at its real position, under the switcher.
@MainActor
final class PreviewPanel: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    override var canBecomeKey: Bool { false }

    func show(window w: WindowInfo, image: CGImage?) {
        guard let image else { hide(); return }
        var frame = Screens.appKitRect(fromCG: w.frame)
        if w.isMinimized || !w.isOnActiveSpace, let screen = NSScreen.main {
            // Not visible anywhere on the current Space: center on the main screen.
            let s = screen.visibleFrame
            let size = CGSize(width: min(w.frame.width, s.width * 0.8), height: min(w.frame.height, s.height * 0.8))
            frame = CGRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
        }
        imageView.image = NSImage(cgImage: image, size: frame.size)
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
