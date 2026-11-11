import AppKit
import SwiftUI

/// The clipboard window. It takes keyboard focus without activating flit, so
/// the app you were typing in stays frontmost and receives the paste.
@MainActor
final class ClipboardPanel: NSPanel, NSWindowDelegate {
    private weak var controller: ClipboardController?
    static let size = NSSize(width: 760, height: 470)

    init(controller: ClipboardController) {
        self.controller = controller
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .none
        contentView = NSHostingView(rootView: ClipboardView(controller: controller))
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the panel a little above the middle of the screen you are working on.
    func present() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.midX - Self.size.width / 2,
                             y: area.midY - Self.size.height / 2 + area.height * 0.08)
        setFrame(NSRect(origin: origin, size: Self.size), display: true)
        makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        controller?.hide()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if controller?.handleKey(event, composing: composing) == true { return }
        }
        super.sendEvent(event)
    }
}

struct ClipboardView: View {
    @ObservedObject var controller: ClipboardController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(width: ClipboardPanel.size.width, height: ClipboardPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            SearchField(text: $controller.query,
                        placeholder: controller.mode == .history ? "Search clipboard history and snippets" : "Search snippets")
            Picker("", selection: Binding(get: { controller.mode }, set: { controller.setMode($0) })) {
                Text("History").tag(ClipRow.Mode.history)
                Text("Snippets").tag(ClipRow.Mode.snippets)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var list: some View {
        Group {
            if controller.rows.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                                if let title = sectionTitle(at: index) {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, index == 0 ? 2 : 8)
                                }
                                ClipRowView(row: row, selected: index == controller.selection, controller: controller)
                                    .id(row.id)
                                    .onTapGesture(count: 2) { controller.select(index: index); controller.activate() }
                                    .onTapGesture { controller.select(index: index) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: controller.selection) { _, new in
                        if controller.rows.indices.contains(new) { proxy.scrollTo(controller.rows[new].id) }
                    }
                }
            }
        }
    }

    /// "Snippets" / "History" headings, shown only when a search mixes the two.
    private func sectionTitle(at index: Int) -> String? {
        let rows = controller.rows
        guard case .snippet = rows.first, case .entry = rows.last else { return nil }
        if index == 0 { return "Snippets" }
        if case .entry = rows[index], case .snippet = rows[index - 1] { return "History" }
        return nil
    }

    private var emptyMessage: String {
        if !controller.query.isEmpty { return "No matches" }
        switch controller.mode {
        case .history: return "Nothing copied yet"
        case .snippets: return "No snippets yet.\nPress ⌘S on a history entry to save it, or ⌘E to write one."
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch controller.preview {
                case .none:
                    Color.clear
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                case .image(let image):
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .files(let paths):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(paths, id: \.self) { path in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    Text(path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !controller.details.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(controller.details, id: \.label) { item in
                        HStack {
                            Text(item.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(item.value).lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let notice = controller.notice {
                Text(notice).font(.caption.weight(.medium))
            }
            Spacer()
            hint("↩", "Paste")
            hint("⌘↩", "Copy")
            hint("⇧↩", "Plain text")
            if controller.mode == .history { hint("⌘S", "Save as snippet") }
            hint("⌘E", "Edit snippets")
            hint("⌃X", "Delete")
            hint("⇥", controller.mode == .history ? "Snippets" : "History")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ClipRowView: View {
    let row: ClipRow
    let selected: Bool
    let controller: ClipboardController

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 20, height: 20)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var title: String {
        switch row {
        case .snippet(let s): return s.name.isEmpty ? "Untitled snippet" : s.name
        case .entry(let e): return e.title
        }
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .snippet:
            Image(systemName: "text.quote").foregroundStyle(.secondary)
        case .entry(let e):
            switch e.kind {
            case .text: Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            case .link: Image(systemName: "link").foregroundStyle(.secondary)
            case .image:
                if let thumb = controller.thumbnail(for: e) {
                    Image(nsImage: thumb).resizable().scaledToFill().frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .file: Image(systemName: "doc").foregroundStyle(.secondary)
            }
        }
    }
}

/// An AppKit text field: it reports text while an input method is
/// composing, and takes keyboard focus the moment it lands in the panel
/// (SwiftUI's own focus handling does not, in a panel that never activates
/// the app).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }

    private final class AutoFocusTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After the current layout pass, when the field can accept focus.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
