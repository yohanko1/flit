import Foundation

/// What the menu-bar menu contains, as plain data: `StatusBar` turns it into
/// menu items. A section with several items carries a title saying what it
/// is for. Dimming is a single on/off line, and the closing section
/// (Preferences, Quit) sits under a plain divider.
enum StatusMenu {
    enum Command: Equatable {
        case toggleKeepAwake
        case keepAwakeFor(TimeInterval)
        case toggleDimming
        case breakNow
        /// nil pauses until resumed by hand.
        case pauseBreaks(minutes: Int?)
        case resumeBreaks
        case grantAccessibility
        case grantScreenRecording
        case preferences
        case quit
    }

    struct Item: Equatable {
        var title: String
        /// nil with no children: a plain line of text.
        var command: Command?
        var checked = false
        var key = ""
        /// Non-empty: this item opens a submenu.
        var children: [Item] = []
    }

    struct Section: Equatable {
        /// nil: no heading, just the divider.
        var title: String?
        var items: [Item]
    }

    /// The break timer's state, or nil when breaks are switched off.
    struct Breaks {
        var status: String
        var paused: Bool
    }

    static func sections(keepAwake: KeepAwakeSetting, dimming: Bool, breaks: Breaks?,
                         accessibility: Bool, screenRecording: Bool, time: (Date) -> String) -> [Section] {
        var sections: [Section] = []

        if let breaks {
            let pauses: [(String, Int?)] = [("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("Until I Resume", nil)]
            sections.append(Section(title: "Breaks", items: [
                Item(title: breaks.status),
                Item(title: "Start Break Now", command: .breakNow),
                breaks.paused
                    ? Item(title: "Resume Breaks", command: .resumeBreaks)
                    : Item(title: "Pause Breaks", children: pauses.map { Item(title: $0.0, command: .pauseBreaks(minutes: $0.1)) }),
            ]))
        }

        var awake = "Keep Mac Awake"
        if keepAwake.on, let until = keepAwake.until { awake += " (until \(time(until)))" }
        let durations: [(String, TimeInterval)] = [
            ("15 Minutes", 900), ("30 Minutes", 1800), ("1 Hour", 3600), ("2 Hours", 7200), ("5 Hours", 18_000),
        ]
        sections.append(Section(title: "Keep Awake", items: [
            Item(title: awake, command: .toggleKeepAwake, checked: keepAwake.on),
            Item(title: "Turn On For", children: durations.map { Item(title: $0.0, command: .keepAwakeFor($0.1)) }),
        ]))

        // One line, so it needs no heading: the item itself is the on/off toggle.
        sections.append(Section(title: nil, items: [
            Item(title: "Dimming", command: .toggleDimming, checked: dimming),
        ]))

        var app: [Item] = []
        if !accessibility { app.append(Item(title: "Grant Accessibility Access…", command: .grantAccessibility)) }
        if !screenRecording { app.append(Item(title: "Grant Screen Recording (thumbnails)…", command: .grantScreenRecording)) }
        app.append(Item(title: "Preferences…", command: .preferences, key: ","))
        app.append(Item(title: "Quit Flit", command: .quit, key: "q"))
        sections.append(Section(title: nil, items: app))

        return sections
    }
}
