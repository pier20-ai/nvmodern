import AppKit
import SwiftUI

/// The one palette surface. Renders whichever frame is on top of the stack.
///
/// The header is the sentence so far, and no more of it than there is: root is
/// bare input; a verbs frame shows one accent noun pill; an object frame shows
/// that pill, the verb as plain text, and the picker's own placeholder.
@MainActor
struct PaletteFrameView: View {
    @ObservedObject var session: PaletteSession
    @ObservedObject var stack: PaletteStack

    @State private var isSurfacePresented = false
    @State private var isContentPresented = false
    /// Nothing is drawn before the first resolve lands (or the cap below
    /// expires), so the palette appears once, already at the height its rows
    /// need.
    @State private var isRevealed = false
    @State private var revealCapTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceCommandOverlayDismissCoordinator) private var dismissCoordinator

    init(session: PaletteSession) {
        self.session = session
        self.stack = session.stack
    }

    private var frame: PaletteFrameSpec {
        stack.top.spec
    }

    private var accentColor: Color {
        switch frame.accent {
        case .nav: return DesignTokens.Accent.nav
        case .intent: return DesignTokens.Accent.intent
        case .search: return DesignTokens.Accent.search
        }
    }

    private var animatesPresentation: Bool {
        // Tahoe has regressions in animated SwiftUI content embedded in AppKit hosts.
        // Render the first frame at full opacity so the palette cannot remain invisible.
        if #available(macOS 26.0, *) {
            return false
        }
        return true
    }

    private var isSurfaceVisible: Bool {
        isRevealed && (!animatesPresentation || isSurfacePresented)
    }

    private var isContentVisible: Bool {
        isRevealed && (!animatesPresentation || isContentPresented)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { session.stack.query },
            set: { session.setQuery($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sentenceRow
                .frame(height: PaletteFrameView.headerHeight)
                .opacity(isSurfaceVisible ? 1 : 0)
                .offset(y: isSurfaceVisible ? 0 : -5)

            divider

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(isContentVisible ? 1 : 0)
                .offset(y: isContentVisible ? 0 : -5)

            divider

            footer
                .opacity(isContentVisible ? 1 : 0)
        }
        .frame(height: desiredHeight)
        .background(commandSurface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.palette, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.palette, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .scaleEffect(isSurfaceVisible ? 1 : 0.985, anchor: .top)
        .opacity(isSurfaceVisible ? 1 : 0)
        .onAppear {
            // The first resolve is kicked before the host presents this view,
            // but it lands a beat later: revealing now would show the empty
            // frame at its minimum height and jump when the rows arrive.
            if session.resolveGeneration > 0 {
                reveal()
            } else {
                revealCapTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.revealCapNanoseconds)
                    guard !Task.isCancelled else { return }
                    reveal()
                }
            }
        }
        .onChange(of: session.resolveGeneration) { _, _ in
            reveal()
        }
        .onDisappear {
            revealCapTask?.cancel()
            revealCapTask = nil
        }
        .background(dismissObserver)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(frame.title)
    }

    /// Shows the surface, once, at whatever height the current sections ask
    /// for. Called by the first resolve, or by the cap if that resolve is slow.
    private func reveal() {
        guard !isRevealed else { return }
        revealCapTask?.cancel()
        revealCapTask = nil
        isRevealed = true
        guard animatesPresentation else {
            isSurfacePresented = true
            isContentPresented = true
            return
        }
        withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.15)) {
            isSurfacePresented = true
        }
        withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.14).delay(0.035)) {
            isContentPresented = true
        }
    }

    // MARK: The sentence

    private var sentenceRow: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            if let noun = nounLabel {
                nounPill(noun)
                chevron
            }

            if let verb = verbLabel {
                verbPill(verb)
                chevron
            }

            OmniboxTextField(
                text: queryBinding,
                placeholder: placeholder,
                onSubmit: { session.activateSelection(openInNewTab: false) },
                onCommandSubmit: { session.activateSelection(openInNewTab: true) },
                onShiftSubmit: { session.activateSelectionInSideStack() },
                onEscape: { session.handleEscape() },
                onMoveUp: { session.moveSelection(by: -1) },
                onMoveDown: { session.moveSelection(by: 1) },
                onStepInto: { session.stepIntoSelection() },
                onBackspaceWhenEmpty: { session.pop() },
                onSpace: { session.toggleMarkOnSelection() },
                onToggleMode: { session.toggleMode($0) },
                onPresetShortcut: { session.applyPresetShortcut($0) }
            )
            // A focused NSTextField keeps its field editor across an immediate
            // palette replacement. Give each frame its own native field so the
            // placeholder and command callbacks cannot leak from the old frame.
            .id(frame.id)
            .frame(height: 24)

            Text(session.preset.shortcutLabel)
                .font(DesignTokens.Typography.captionMono)
                .foregroundStyle(DesignTokens.TextStyle.tertiary)
        }
        // Same left edge as the section headers and row titles below, so the
        // input reads as part of the list rather than hugging the pane edge.
        .padding(.horizontal, DesignTokens.Spacing.space4 + DesignTokens.Spacing.space3)
    }

    /// The one noun the header names: the deepest bound subject on the stack,
    /// or the subject an object frame was pushed with. Root has none — the
    /// first row is the current document, so naming it twice said nothing.
    private var nounLabel: String? {
        if let bound = stack.frames.compactMap({ $0.spec.boundTarget }).last {
            return bound.breadcrumbLabel
        }
        if let subject = frame.subjectTarget {
            return subject.breadcrumbLabel
        }
        // An object frame reached from a preset (`⌘R`) still has a subject:
        // the tab's document. The sentence reads wrong without it.
        return frame.isArgumentFrame ? session.currentDocumentTitle : nil
    }

    /// The committed verb, shown only once its object frame is open.
    private var verbLabel: String? {
        guard frame.isArgumentFrame else { return nil }
        return frame.title
            .replacingOccurrences(of: "\u{2026}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var placeholder: String {
        if session.isMultiSelectModeActive, !session.marked.isEmpty {
            return "\(session.marked.count) marked \u{00B7} Tab to bind"
        }
        return frame.placeholder
    }

    private var chevron: some View {
        Text("\u{25B8}")
            .font(DesignTokens.Typography.captionMono)
            .foregroundStyle(DesignTokens.TextStyle.tertiary)
    }

    /// The bound noun: a solid capsule in the selection blue with white text,
    /// the one loud element in the header so the subject is never in doubt.
    private func nounPill(_ label: String) -> some View {
        Text(label)
            .font(DesignTokens.Typography.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(DesignTokens.Surface.activeSelection))
            .fixedSize()
    }

    /// The committed verb: same capsule as the noun, tinted rather than
    /// solid, so the sentence reads subject then verb at a glance.
    private func verbPill(_ label: String) -> some View {
        Text(label)
            .font(DesignTokens.Typography.caption.weight(.medium))
            .foregroundStyle(DesignTokens.Surface.activeSelection)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(DesignTokens.Surface.activeSelection.opacity(0.14)))
            .fixedSize()
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let sections = stack.top.sections
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        PaletteEmptyStateRow(message: session.emptyMessage)
                    } else {
                        ForEach(sections) { section in
                            if !section.title.isEmpty {
                                PaletteSectionHeader(title: section.title)
                            }
                            ForEach(section.items) { item in
                                PaletteItemRow(
                                    item: item,
                                    sectionTitle: section.title,
                                    query: stack.top.query,
                                    isSelected: item.id == stack.top.selectedItemID,
                                    markState: markState(for: item),
                                    showsNounChevron: frame.isRoot,
                                    showsActionIcon: frame.sources == [.actions(category: PaletteFrameSpec.captureCategory)],
                                    onHoverSelect: { session.selectFromHover(itemID: item.id) },
                                    onSelect: { session.select(itemID: item.id) },
                                    onActivate: { session.activate(item, openInNewTab: false) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                }
                .padding(.top, PaletteFrameView.rowsTopPadding)
                .padding(.bottom, PaletteFrameView.rowsBottomPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: stack.top.selectedItemID) { _, selectedID in
                guard let selectedID else { return }
                proxy.scrollTo(selectedID)
            }
        }
        .clipped()
    }

    /// Nil outside multi-select, or on a row that cannot be marked.
    private func markState(for item: PaletteItem) -> Bool? {
        guard session.isMultiSelectModeActive,
              item.target?.noteRelativePath != nil else {
            return nil
        }
        return session.marked[item.id] != nil
    }

    // MARK: Footer

    /// Four hints at most, chosen for the selected row, and a quiet mode
    /// indicator on the right. Everything else the palette can do is either
    /// obvious (arrows) or already known to whoever uses it (`⌘⏎`).
    private var footer: some View {
        let selected = stack.top.selectedItem
        return HStack(spacing: DesignTokens.Spacing.space4) {
            commandHint("⏎", primaryHintLabel(for: selected))
            if isSteppableNounSelected(selected) {
                commandHint("⇥", "actions")
            } else if selected?.hasSubmenu == true {
                commandHint("⇥", "choose")
            }
            if stack.canPop {
                commandHint("⌫", "back")
            }
            commandHint("esc", "close")
            Spacer()
            modeIndicator
        }
        .padding(.horizontal, DesignTokens.Spacing.space5)
        .frame(height: 40)
    }

    @ViewBuilder
    private var modeIndicator: some View {
        let active = PaletteMode.allCases.filter { session.modes.contains($0) }
        if !active.isEmpty {
            HStack(spacing: DesignTokens.Spacing.space2) {
                Circle()
                    .fill(DesignTokens.Accent.intent)
                    .frame(width: 6, height: 6)
                Text(active.map(\.label).joined(separator: " \u{00B7} "))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
            }
        }
    }

    /// A noun Tab can bind as the subject. Only root offers this: an object
    /// frame is already collecting something, and its rows are objects even
    /// when they happen to denote a noun.
    private func isSteppableNounSelected(_ item: PaletteItem?) -> Bool {
        frame.isRoot && item?.target?.nounKind != nil
    }

    /// What Enter does: open, run, or collect the verb's object.
    private func primaryHintLabel(for item: PaletteItem?) -> String {
        if session.isMultiSelectModeActive, !session.marked.isEmpty {
            return "actions for \(session.marked.count)"
        }
        guard let item else { return frame.primaryActionLabel }
        switch item.activation {
        case .push, .pluginPick:
            return "choose"
        case .runAction:
            return "run"
        case .jumpToOutlineItem:
            return "jump"
        case .openNote, .openFolder, .focusTab:
            return "open"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignTokens.TextStyle.tertiary.opacity(0.10))
            .frame(height: 1)
    }

    /// Frost with a faint diagonal wash: cool at the top-left corner, warm at
    /// the bottom-right, fading through nothing in the middle. The colour is
    /// what keeps the pane from reading as a white web card; the low opacity
    /// is what keeps it from reading as a gradient.
    private var commandSurface: some View {
        let isDark = colorScheme == .dark
        return CommandOverlayVisualEffectView(material: isDark ? .hudWindow : .popover)
            .overlay(DesignTokens.Surface.raised.opacity(isDark ? 0.06 : 0.10))
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: DesignTokens.Accent.paletteCool.opacity(isDark ? 0.14 : 0.16), location: 0),
                        .init(color: DesignTokens.Accent.paletteCool.opacity(0), location: 0.45),
                        .init(color: DesignTokens.Accent.paletteWarm.opacity(0), location: 0.6),
                        .init(color: DesignTokens.Accent.paletteWarm.opacity(isDark ? 0.12 : 0.14), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    /// Header, footer, and the rows the frame holds, capped at the host's
    /// preferred height. A menu should be as tall as its items, not a fixed
    /// box with dead space under a short list.
    private var desiredHeight: CGFloat {
        let sections = stack.top.sections
        var rows: CGFloat = 0
        for section in sections {
            if !section.title.isEmpty { rows += Self.sectionHeaderHeight }
            for item in section.items {
                rows += item.snippet?.isEmpty == false ? Self.snippetRowHeight : Self.rowHeight
            }
        }
        if sections.isEmpty { rows = Self.emptyStateHeight }
        let content = Self.headerHeight + 2 + Self.rowsTopPadding + Self.rowsBottomPadding + rows + Self.footerHeight
        return min(max(content, Self.minimumHeight), Self.maximumHeight)
    }

    static let rowHeight: CGFloat = 30
    static let snippetRowHeight: CGFloat = 42
    static let headerHeight: CGFloat = 50
    static let footerHeight: CGFloat = 40
    static let sectionHeaderHeight: CGFloat = 28
    static let rowsTopPadding: CGFloat = 10
    static let rowsBottomPadding: CGFloat = 6
    static let emptyStateHeight: CGFloat = 44
    static let minimumHeight: CGFloat = 44 + 40 + 2 + 44
    static let maximumHeight: CGFloat = 480
    /// How long the reveal waits on the first resolve before showing the
    /// palette anyway. Long enough for the providers in practice, short enough
    /// that a slow one cannot make `⌘K` feel unresponsive.
    static let revealCapNanoseconds: UInt64 = 120_000_000

    @ViewBuilder
    private var dismissObserver: some View {
        if let dismissCoordinator {
            PaletteDismissObserver(coordinator: dismissCoordinator) { isDismissing in
                guard isDismissing, animatesPresentation else { return }
                withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.07)) {
                    isContentPresented = false
                }
                withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.10)) {
                    isSurfacePresented = false
                }
            }
        }
    }

    private func commandHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            Text(key)
                .font(DesignTokens.Typography.captionMono)
                .foregroundStyle(DesignTokens.TextStyle.secondary)
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.TextStyle.tertiary)
        }
    }
}

// MARK: - Row

/// One palette row: title, optional snippet, then the verb's current value or
/// the row's meta, shortcut glyphs, and a chevron when the row pushes a frame.
/// Nouns get no chevron — the footer explains Tab. Nouns and the Capture
/// menu show icons; other verbs stay text-only.
struct PaletteItemRow: View {
    let item: PaletteItem
    /// Title of the section the row sits in. A subtitle that merely repeats
    /// it (an action's category under its own category header) is dropped.
    var sectionTitle: String = ""
    let query: String
    let isSelected: Bool
    /// Nil outside multi-select; true when this row is marked.
    var markState: Bool?
    /// Root nouns step into their verbs on Tab and say so with a caret; a
    /// folder in a picker is an answer, not a subject, and gets none.
    var showsNounChevron: Bool = false
    var showsActionIcon: Bool = false
    var onHoverSelect: () -> Void = {}
    var onSelect: () -> Void = {}
    var onActivate: () -> Void = {}

    private var hasSnippet: Bool {
        item.snippet?.isEmpty == false
    }

    private var isOutlineItem: Bool {
        if case .jumpToOutlineItem = item.activation { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.space3) {
            if item.target != nil || showsActionIcon, let icon = item.iconSystemName {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : DesignTokens.TextStyle.tertiary)
                    .frame(width: 14, height: 14)
            }

            if let markState {
                Text(markState ? "\u{25CF}" : "\u{25CB}")
                    .font(DesignTokens.Typography.captionMono)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : DesignTokens.Accent.intent)
                    .frame(width: 10)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.space1) {
                Text(item.title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

                if let snippet = item.snippet, !snippet.isEmpty {
                    Text(boldHighlighted(snippet, match: query))
                        .font(DesignTokens.Typography.secondary)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(min(item.indentation, 12)) * 12)

            Spacer(minLength: DesignTokens.Spacing.space3)

            if let value = item.value, !value.isEmpty {
                Text(value)
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            } else if let subtitle = item.subtitle,
                      !subtitle.isEmpty,
                      subtitle.caseInsensitiveCompare(sectionTitle) != .orderedSame {
                Text(subtitle)
                    .font(isOutlineItem ? DesignTokens.Typography.secondary.monospaced() : DesignTokens.Typography.secondary)
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }

            if let shortcutLabel = item.shortcutLabel, !shortcutLabel.isEmpty {
                Text(shortcutLabel)
                    .font(DesignTokens.Typography.captionMono)
                    .foregroundStyle(secondaryTextColor)
            }

            // Verbs with an object push a frame; nouns step into their verbs
            // on Tab. Both are "there is more here", so both get the caret.
            if item.hasSubmenu || (showsNounChevron && item.target?.nounKind != nil) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.hasSubmenu ? secondaryTextColor : tertiaryTextColor)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.space3)
        .padding(.vertical, hasSnippet ? 5 : 2)
        .frame(height: hasSnippet ? PaletteFrameView.snippetRowHeight : PaletteFrameView.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Concentric with the palette corner: its 22 pt radius minus the
            // 12 pt inset the row sits at.
            RoundedRectangle(cornerRadius: DesignTokens.Radius.palette - DesignTokens.Spacing.space4, style: .continuous)
                .fill(isSelected ? DesignTokens.Surface.activeSelection : Color.clear)
        )
        .padding(.horizontal, DesignTokens.Spacing.space4)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase {
                onHoverSelect()
            }
        }
        .onTapGesture {
            onSelect()
            onActivate()
        }
    }

    // Selected rows force white text. This is deliberate and load-bearing: the
    // selection fill is the system accent, where semantic primary text has no
    // guaranteed contrast.
    private var primaryTextColor: Color {
        isSelected ? .white : DesignTokens.TextStyle.primary
    }

    private var secondaryTextColor: Color {
        isSelected ? .white.opacity(0.82) : DesignTokens.TextStyle.secondary
    }

    private var tertiaryTextColor: Color {
        isSelected ? .white.opacity(0.7) : DesignTokens.TextStyle.tertiary
    }

    private func boldHighlighted(_ text: String, match: String) -> AttributedString {
        var attr = AttributedString(text)
        let trimmedMatch = PaletteQueryScope.parse(match).text
        guard !trimmedMatch.isEmpty else { return attr }

        // Highlight every case-insensitive occurrence, not just the first, so
        // multi-word sentences stay readable when the query appears more than
        // once in the snippet.
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let stringRange = text.range(
                of: trimmedMatch,
                options: .caseInsensitive,
                range: cursor..<text.endIndex
              ) {
            if let lower = AttributedString.Index(stringRange.lowerBound, within: attr),
               let upper = AttributedString.Index(stringRange.upperBound, within: attr) {
                let attrRange = lower..<upper
                attr[attrRange].font = .system(size: 12, weight: .semibold)
                attr[attrRange].foregroundColor = primaryTextColor
            }
            cursor = stringRange.upperBound
        }
        return attr
    }
}

// MARK: - Shared chrome pieces

/// Section header: one uppercase label, whether it names a category or the
/// subject a group of verbs acts on.
struct PaletteSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DesignTokens.Typography.caption.weight(.medium))
            .foregroundStyle(DesignTokens.TextStyle.tertiary)
            .kerning(0.2)
            .lineLimit(1)
            // Row inset plus the row's own leading padding, so the header
            // sits on the same left edge as the titles under it.
            .padding(.horizontal, DesignTokens.Spacing.space4 + DesignTokens.Spacing.space3)
            .padding(.top, DesignTokens.Spacing.space3)
            .padding(.bottom, DesignTokens.Spacing.space2)
    }
}

/// Muted row shown when a frame has nothing to offer. Kept visually lighter
/// than a real result so it does not read as clickable.
struct PaletteEmptyStateRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(DesignTokens.Typography.secondary)
            .foregroundStyle(DesignTokens.TextStyle.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.space4)
            .padding(.vertical, DesignTokens.Spacing.space3)
    }
}

private struct PaletteDismissObserver: View {
    @ObservedObject var coordinator: WorkspaceCommandOverlayDismissCoordinator
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: coordinator.isDismissing) { _, isDismissing in
                onChange(isDismissing)
            }
    }
}

/// The palette's glass. `.popover` rather than `.hudWindow` because hud is a
/// fixed dark plate: it ignores the window's appearance, so a light workspace
/// got a slab of night in the middle of it.
struct CommandOverlayVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
    }
}
