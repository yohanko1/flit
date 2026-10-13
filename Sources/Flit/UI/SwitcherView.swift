import SwiftUI

struct SwitcherView: View {
    @ObservedObject var controller: SwitcherController
    @ObservedObject var prefs: Preferences

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { controller.cancel() }
            if controller.isVisible {
                box
                    .transition(prefs.animate ? .opacity.combined(with: .scale(scale: 0.96)) : .identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(prefs.animate ? .easeOut(duration: 0.12) : nil, value: controller.isVisible)
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch prefs.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var box: some View {
        VStack(spacing: 10) {
            if prefs.showHints { hints }
            if controller.pinned || !controller.query.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    if controller.query.isEmpty {
                        Text("Type to search").foregroundStyle(.secondary)
                    } else {
                        Text(controller.query)
                    }
                    Spacer()
                    Text("\(controller.windows.count)").foregroundStyle(.secondary)
                    if controller.pinned {
                        Text("↩ switch · esc cancel").font(.system(size: 11 * prefs.scale)).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 14 * prefs.scale))
                .padding(.horizontal, 8)
            }
            if controller.windows.isEmpty {
                Text(controller.query.isEmpty ? "No windows" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding(30)
            } else {
                switch prefs.style {
                case .thumbnails: thumbnailGrid
                case .appIcons: iconRow
                case .titles: titleList
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .frame(maxWidth: controller.screen.visibleFrame.width * 0.9, maxHeight: controller.screen.visibleFrame.height * 0.9)
    }

    /// One line of key hints. Before a search: how to start one and the
    /// action keys. During a search (sticky): how to finish it.
    private var hints: some View {
        let mod = controller.profileModifierSymbol
        let items: [(String, String)] = controller.pinned
            ? [("type", "search"), ("↩", "switch"), ("esc", "cancel"), ("⌫", "erase"), ("⇥ ↑↓←→", "move")]
            : [("type", "search"), ("W", "close"), ("M", "minimize"), ("H", "hide"), ("Q", "quit"),
               ("space", "preview"), ("release \(mod)", "switch")]
        return HStack(spacing: 16) {
            ForEach(items, id: \.0) { key, what in
                HStack(spacing: 5) {
                    Text(key)
                        .font(.system(size: 12 * prefs.scale, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.25)))
                    Text(what).font(.system(size: 13 * prefs.scale, weight: .medium))
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.bottom, 2)
    }

    // MARK: Styles

    private var thumbnailGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(Layout.thumbCellWidth(prefs.scale)), spacing: Layout.spacing), count: controller.columns)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: cols, spacing: Layout.spacing) {
                    ForEach(Array(controller.windows.enumerated()), id: \.element.id) { i, w in
                        ThumbnailCell(window: w, selected: i == controller.selectedIndex, scale: prefs.scale, badges: prefs.showBadges)
                            .id(w.id)
                            .cell(controller: controller, index: i)
                    }
                }
                .padding(4)
            }
            .fixedSize()
            .onChange(of: controller.selectedIndex) { _, _ in
                if let w = controller.selected { proxy.scrollTo(w.id) }
            }
        }
    }

    private var iconRow: some View {
        let cols = Array(repeating: GridItem(.fixed(Layout.iconCellWidth(prefs.scale)), spacing: Layout.spacing), count: controller.columns)
        return VStack(spacing: 8) {
            LazyVGrid(columns: cols, spacing: Layout.spacing) {
                ForEach(Array(controller.windows.enumerated()), id: \.element.id) { i, w in
                    IconCell(window: w, selected: i == controller.selectedIndex, scale: prefs.scale, badges: prefs.showBadges)
                        .cell(controller: controller, index: i)
                }
            }
            Text(controller.selected?.displayTitle ?? "")
                .font(.system(size: 14 * prefs.scale, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: CGFloat(controller.columns) * (Layout.iconCellWidth(prefs.scale) + Layout.spacing))
        }
    }

    private var titleList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(controller.windows.enumerated()), id: \.element.id) { i, w in
                        TitleRow(window: w, selected: i == controller.selectedIndex, scale: prefs.scale, badges: prefs.showBadges)
                            .id(w.id)
                            .cell(controller: controller, index: i)
                    }
                }
            }
            .frame(width: 480 * prefs.scale)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: controller.selectedIndex) { _, _ in
                if let w = controller.selected { proxy.scrollTo(w.id) }
            }
        }
    }
}

private extension View {
    /// Hover selects, click commits.
    func cell(controller: SwitcherController, index: Int) -> some View {
        self.contentShape(Rectangle())
            .onHover { if $0 { controller.select(index: index) } }
            .onTapGesture { controller.select(index: index); controller.commit() }
    }
}

// MARK: Cells

struct Badges: View {
    let window: WindowInfo
    let scale: Double
    var body: some View {
        HStack(spacing: 3) {
            if window.isMinimized { badge("arrow.down.right.and.arrow.up.left") }
            if window.isHidden { badge("eye.slash") }
            if !window.isOnActiveSpace && !window.isMinimized && !window.isAppPlaceholder { badge("square.on.square") }
            if window.isFullscreen { badge("arrow.up.left.and.arrow.down.right") }
            if window.isTab { badge("rectangle.stack") }
        }
    }
    private func badge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9 * scale, weight: .bold))
            .padding(4 * scale)
            .background(.black.opacity(0.55), in: Circle())
            .foregroundStyle(.white)
    }
}

struct ThumbnailCell: View {
    let window: WindowInfo
    let selected: Bool
    let scale: Double
    let badges: Bool

    private var boxW: CGFloat { Layout.thumbCellWidth(scale) - 16 }
    private var boxH: CGFloat { Layout.thumbCellHeight(scale) - 16 }

    /// The window's real shape, fitted into the cell. Without Screen Recording
    /// this is the "preview": shape + icon + title.
    private var fittedSize: CGSize {
        let w = max(window.frame.width, 1), h = max(window.frame.height, 1)
        let f = min(boxW / w, boxH / h)
        return window.isAppPlaceholder ? CGSize(width: boxW, height: boxH) : CGSize(width: w * f, height: h * f)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = window.thumbnail {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(colors: [.primary.opacity(0.10), .primary.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                            Image(nsImage: window.appIcon)
                                .resizable()
                                .frame(width: min(64 * scale, fittedSize.height * 0.6),
                                       height: min(64 * scale, fittedSize.height * 0.6))
                        }
                        .frame(width: fittedSize.width, height: fittedSize.height)
                    }
                }
                .frame(width: boxW, height: boxH)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if window.thumbnail != nil {
                    Image(nsImage: window.appIcon)
                        .resizable()
                        .frame(width: 28 * scale, height: 28 * scale)
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: .topLeading) { if badges { Badges(window: window, scale: scale).padding(4) } }
            Text(window.displayTitle)
                .font(.system(size: 12 * scale))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Layout.thumbCellWidth(scale) - 16)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct IconCell: View {
    let window: WindowInfo
    let selected: Bool
    let scale: Double
    let badges: Bool

    var body: some View {
        Image(nsImage: window.appIcon)
            .resizable()
            .frame(width: Layout.iconSize(scale), height: Layout.iconSize(scale))
            .overlay(alignment: .topLeading) { if badges { Badges(window: window, scale: scale) } }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TitleRow: View {
    let window: WindowInfo
    let selected: Bool
    let scale: Double
    let badges: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: window.appIcon)
                .resizable()
                .frame(width: 24 * scale, height: 24 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.displayTitle).font(.system(size: 13 * scale)).lineLimit(1)
                if !window.title.isEmpty {
                    Text(window.appName).font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if badges { Badges(window: window, scale: scale) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
