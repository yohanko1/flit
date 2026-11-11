// A throwaway target app for `make selftest` and `make screenshots`.
//
// Self-test: one window with a text view. Whatever lands in the text view is
// written to the file given as the first argument, so the test can see what
// flit pasted.
//
// Screenshots (`Probe <file> demo`): three windows with sample text, so the
// pictures show something without showing anyone's real windows.
//
// Quits by itself.
import AppKit

final class Probe: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let path: String
    let demo: Bool
    var window: NSWindow!
    var textView: NSTextView!
    var extras: [NSWindow] = []

    init(path: String, demo: Bool) {
        self.path = path
        self.demo = demo
    }

    static let samples: [(title: String, text: String)] = [
        ("Trip notes", """
            Lisbon, 12–16 May

            • Flight lands 10:40
            • Tram 28 to Alfama
            • Pastéis de Belém before noon
            • Sunset at Miradouro da Graça

            Pack: adapter, walking shoes, sunscreen.

            Day trips
            • Sintra: Pena Palace, Quinta da Regaleira
            • Cascais: beach, fish market
            • Óbidos: castle walls, ginjinha

            To book: train to Sintra, dinner on Friday.
            """),
        ("Budget", """
            Month        Planned    Spent
            January        1,200    1,140
            February       1,200    1,265
            March          1,250    1,198
            April          1,250      940
            May            1,300    1,312
            June           1,300    1,255
            July           1,400    1,480
            August         1,400    1,371
            September      1,300    1,204
            October        1,300    1,290
            November       1,250    1,118
            December       1,500    1,466

            Under plan for the year: 111
            """),
        ("Reading list", """
            1. The Design of Everyday Things
            2. A Pattern Language
            3. Thinking in Systems
            4. The Pragmatic Programmer
            5. Structure and Interpretation of Computer Programs
            6. The Mythical Man-Month
            7. How Buildings Learn
            8. The Timeless Way of Building
            9. Gödel, Escher, Bach
            10. The Elements of Typographic Style
            11. Seeing Like a State
            12. The Art of Doing Science and Engineering
            13. Understanding Comics
            14. Notes on the Synthesis of Form
            15. A Philosophy of Software Design
            """),
    ]

    func makeWindow(title: String, text: String, frame: NSRect) -> (NSWindow, NSTextView) {
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.string = text
        w.contentView = view
        return (w, view)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(NSMenuItem(title: "Probe", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main

        // The demo opens on the sharpest display, where the screenshots are taken.
        let sharpest = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let visible = ((demo ? sharpest : NSScreen.main) ?? NSScreen.screens[0]).visibleFrame
        let frame = NSRect(x: visible.minX + 180, y: visible.minY + 160, width: 640, height: 420)
        if demo {
            // Back windows first, so the first sample ends up in front.
            for (i, sample) in Self.samples.enumerated().dropFirst().reversed() {
                let (w, _) = makeWindow(title: sample.title, text: sample.text,
                                        frame: frame.offsetBy(dx: CGFloat(i) * 150, dy: CGFloat(i) * -70))
                w.orderFront(nil)
                extras.append(w)
            }
            (window, textView) = makeWindow(title: Self.samples[0].title, text: Self.samples[0].text, frame: frame)
        } else {
            (window, textView) = makeWindow(title: "Flit self-test probe (closes by itself)", text: "", frame: frame)
            textView.font = .systemFont(ofSize: 12)
            textView.textContainerInset = .zero
        }
        textView.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        print("PID \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)

        // Each paste replaces the text; the file being emptied by the test clears the view.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.path + ".quit") { NSApp.terminate(nil) }
            if !self.demo, let onDisk = try? String(contentsOfFile: self.path, encoding: .utf8), onDisk.isEmpty, !self.textView.string.isEmpty {
                self.textView.string = ""
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { NSApp.terminate(nil) }
    }

    func textDidChange(_ notification: Notification) {
        try? textView.string.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

guard CommandLine.arguments.count > 1 else { fatalError("usage: Probe <text file>") }
let app = NSApplication.shared
let delegate = Probe(path: CommandLine.arguments[1], demo: CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "demo")
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
