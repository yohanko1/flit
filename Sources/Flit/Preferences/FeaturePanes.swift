import AppKit
import SwiftUI

struct TilingPane: View {
    @ObservedObject var prefs: Preferences

    private static let actions: [HotkeyAction] = [
        .tileLeft, .tileRight, .tileMaximize, .tileRestore,
        .tileLeftThird, .tileCenterThird, .tileRightThird,
        .tileNextDisplay, .tilePreviousDisplay,
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Tile windows with keyboard shortcuts", isOn: $prefs.tilingEnabled)
                Text("Acts on the focused window, on the display it is on. Press Left half or Right half again to step through ½, ⅔ and ⅓ of the width. Restore puts the window back where it was before tiling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                ForEach(Self.actions) { HotkeyRow(action: $0, prefs: prefs) }
            }
            .disabled(!prefs.tilingEnabled)
        }
        .formStyle(.grouped)
    }
}

struct DimmingPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Dim everything behind the front window", isOn: $prefs.dimEnabled)
                HStack {
                    Text("Strength")
                    Slider(value: $prefs.dimIntensity, in: 0.05...0.9)
                    Text("\(Int((prefs.dimIntensity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .disabled(!prefs.dimEnabled)
                Text("The front window stays bright; other windows and the desktop on its display darken. Other displays are not dimmed. Clicking the desktop lifts the dimming. Fullscreen Spaces are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                HotkeyRow(action: .dimming, prefs: prefs)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClipboardPane: View {
    @ObservedObject var prefs: Preferences
    @State private var picked = ""
    @State private var confirmClear = false
    @State private var count = ClipboardController.shared.store?.count ?? 0

    private static let retention: [(label: String, days: Int)] = [
        ("1 day", 1), ("1 week", 7), ("1 month", 30), ("3 months", 90), ("1 year", 365),
    ]
    private static let limits = [200, 500, 1000, 2000, 5000]

    private var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !prefs.clipboardIgnoredApps.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Keep clipboard history", isOn: $prefs.clipboardEnabled)
                HotkeyRow(action: .clipboard, prefs: prefs)
                Text("Text, links, images and copied files are kept. In the panel: Return pastes, ⌘Return only copies, ⇧Return pastes without formatting, Tab switches to snippets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Picker("Keep entries for", selection: $prefs.clipboardRetentionDays) {
                    ForEach(Self.retention, id: \.days) { Text($0.label).tag($0.days) }
                }
                Picker("Keep at most", selection: $prefs.clipboardMaxItems) {
                    ForEach(Self.limits, id: \.self) { Text("\($0.formatted()) entries").tag($0) }
                }
                HStack {
                    Text("\(count.formatted()) entries stored").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClear = true }.disabled(count == 0)
                }
            }
            Section("Privacy") {
                Toggle("Skip passwords and other items apps mark as secret", isOn: $prefs.clipboardIgnoreConcealed)
                ForEach(prefs.clipboardIgnoredApps, id: \.self) { id in
                    HStack {
                        Text(ClipboardController.appName(id) ?? id)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { prefs.clipboardIgnoredApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    Picker("Never record copies made in", selection: $picked) {
                        Text("Choose…").tag("")
                        ForEach(runningApps, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Button("Add") {
                        if !picked.isEmpty { prefs.clipboardIgnoredApps.append(picked); picked = "" }
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { count = ClipboardController.shared.store?.count ?? 0 }
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear) {
            Button("Delete History", role: .destructive) {
                ClipboardController.shared.store?.clear()
                count = 0
            }
        } message: {
            Text("Snippets are kept. This cannot be undone.")
        }
    }
}

/// The snippets list as the settings pane edits it; every change is written through.
@MainActor
final class SnippetsModel: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    private let store = ClipboardController.shared.store

    var available: Bool { store != nil }

    func load() { snippets = store?.snippets() ?? [] }

    func add() -> Int64? {
        guard let store else { return nil }
        let id = store.addSnippet(name: "New snippet", text: "")
        load()
        return id
    }

    func update(_ snippet: Snippet) {
        store?.updateSnippet(snippet)
        // Edit in place: re-sorting by name on every keystroke would move the row under the cursor.
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i] = snippet }
    }

    func delete(_ id: Int64) {
        store?.deleteSnippet(id: id)
        load()
    }
}

struct SnippetsPane: View {
    @StateObject private var model = SnippetsModel()
    @State private var selection: Int64?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.snippets) { s in
                        Text(s.name.isEmpty ? "Untitled snippet" : s.name).tag(s.id)
                    }
                }
                HStack {
                    Button { selection = model.add() } label: { Image(systemName: "plus") }
                    Button {
                        if let selection { model.delete(selection) }
                        selection = model.snippets.first?.id
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 240)

            if let snippet = model.snippets.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: Binding(
                        get: { snippet.name },
                        set: { model.update(Snippet(id: snippet.id, name: $0, text: snippet.text)) }))
                    TextEditor(text: Binding(
                        get: { snippet.text },
                        set: { model.update(Snippet(id: snippet.id, name: snippet.name, text: $0)) }))
                        .font(.system(size: 12, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    Text("{date}, {time} and {clipboard} are filled in when the snippet is pasted. Open the clipboard panel and press Tab, or just search, to use a snippet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(minWidth: 320)
            } else {
                Text(model.available ? "Select a snippet, or add one with +" : "Snippets are unavailable: the history folder could not be opened.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            model.load()
            if selection == nil { selection = model.snippets.first?.id }
        }
    }
}

struct BreaksPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Remind me to take breaks", isOn: $prefs.breaks.enabled)
                Stepper("Every \(prefs.breaks.intervalMinutes) minutes", value: $prefs.breaks.intervalMinutes, in: 1...240)
                Stepper("For \(Self.duration(prefs.breaks.lengthSeconds))", value: $prefs.breaks.lengthSeconds, in: 10...1800, step: 10)
                Picker("During a break", selection: $prefs.breaks.style) {
                    ForEach(BreakSettings.Style.allCases) { Text($0.label).tag($0) }
                }
                TextField("Message", text: $prefs.breaks.message)
                Toggle("Play a sound when a break starts and ends", isOn: $prefs.breaks.sound)
            }
            Section("Before and during") {
                Stepper(prefs.breaks.warningSeconds == 0 ? "No heads-up before a break"
                        : "Heads-up \(prefs.breaks.warningSeconds) seconds before",
                        value: $prefs.breaks.warningSeconds, in: 0...300, step: 10)
                Toggle("Allow skipping a break", isOn: $prefs.breaks.allowSkip)
                Toggle("Allow snoozing a break", isOn: $prefs.breaks.allowSnooze)
                Stepper("Snooze for \(prefs.breaks.snoozeMinutes) minutes", value: $prefs.breaks.snoozeMinutes, in: 1...60)
                    .disabled(!prefs.breaks.allowSnooze)
                Stepper(prefs.breaks.idleResetMinutes == 0 ? "Don't restart the countdown when I'm away"
                        : "Restart the countdown after \(prefs.breaks.idleResetMinutes) minutes away",
                        value: $prefs.breaks.idleResetMinutes, in: 0...60)
            }
            Section("Working hours") {
                Toggle("Only during working hours", isOn: $prefs.breaks.workingHoursOnly)
                Group {
                    DatePicker("From", selection: minutes($prefs.breaks.workStartMinute), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutes($prefs.breaks.workEndMinute), displayedComponents: .hourAndMinute)
                    HStack {
                        Text("On")
                        Spacer()
                        ForEach(1...7, id: \.self) { day in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                get: { prefs.breaks.workDays.contains(day) },
                                set: { on in
                                    if on { prefs.breaks.workDays.insert(day) } else { prefs.breaks.workDays.remove(day) }
                                }))
                                .toggleStyle(.button)
                        }
                    }
                }
                .disabled(!prefs.breaks.workingHoursOnly)
            }
            Section("Shortcut") {
                HotkeyRow(action: .breakNow, prefs: prefs)
            }
        }
        .formStyle(.grouped)
    }

    private static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m == 0 { return "\(s) seconds" }
        return s == 0 ? "\(m) min" : "\(m) min \(s) s"
    }

    /// Bridges "minutes after midnight" to the date a time picker edits.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: { calendar.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = calendar.dateComponents([.hour, .minute], from: date)
                value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
