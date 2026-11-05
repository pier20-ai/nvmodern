import AppKit
import SwiftUI

struct OmniboxBreadcrumb: Equatable {
    enum Segment: Equatable {
        case folder(name: String, path: String)
        case ellipsis
        case note(String)
    }

    var segments: [Segment]

    static let empty = OmniboxBreadcrumb(segments: [])
}

struct OmniboxSiblingFile: Identifiable, Equatable {
    let relativePath: String
    let name: String
    let iconSystemName: String

    var id: String { relativePath }
}

enum OmniboxPresentation: Equatable {
    case standard
    case focusHeader
}

struct OmniboxView: View {
    var breadcrumb: OmniboxBreadcrumb
    var emptyPlaceholder: String = "New Tab"
    var presentation: OmniboxPresentation = .standard
    var reservesTrafficLightSpace: Bool = false
    var isFocusedPane: Bool = true
    var isContextRibbonOpen: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var canOpenDocumentNavigator: Bool = false
    var canOpenDocumentInspector: Bool = false
    var isDocumentNavigatorPresented: Binding<Bool> = .constant(false)
    var isDocumentInspectorPresented: Binding<Bool> = .constant(false)
    var documentNavigatorPopoverContent: AnyView = AnyView(EmptyView())
    var documentInspectorPopoverContent: AnyView = AnyView(EmptyView())
    var siblingFiles: [OmniboxSiblingFile] = []
    var onAnchorResolved: (NSView) -> Void = { _ in }
    var onMagnifierTap: () -> Void = {}
    /// Nil hides the control. The sidebar toggle lives here and nowhere else —
    /// the sidebar used to carry its own copy, which meant two buttons for one
    /// piece of state sitting a few points apart.
    var onToggleSidebar: (() -> Void)?
    var onSegmentTap: (String) -> Void = { _ in }
    var onSiblingFileTap: (String) -> Void = { _ in }
    var onEllipsisTap: () -> Void = {}
    var onPrevTap: () -> Void = {}
    var onNextTap: () -> Void = {}
    var onReloadTap: () -> Void = {}
    var onRevealTap: () -> Void = {}
    var onFindInDocument: () -> Void = {}
    var onExpandTap: () -> Void = {}

    @State private var isBreadcrumbExpanded = false

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardContent
            case .focusHeader:
                focusHeaderContent
            }
        }
        .background(
            OmniboxAnchorBridge(onResolve: onAnchorResolved)
        )
        .onChange(of: breadcrumb) { oldValue, newValue in
            if lastNoteSegment(in: oldValue) != lastNoteSegment(in: newValue) {
                isBreadcrumbExpanded = false
            }
        }
    }

    private var standardContent: some View {
        HStack(spacing: DesignTokens.Spacing.space3) {
            if let onToggleSidebar {
                ContextButton(
                    systemName: "sidebar.left",
                    tooltip: "Toggle Sidebar (⌃⌘S)",
                    isEnabled: true,
                    action: onToggleSidebar
                )
            }

            magnifierButton
            historyButtons
            breadcrumbRow
            Spacer(minLength: DesignTokens.Spacing.space3)
            contextButtons
        }
        .padding(.horizontal, DesignTokens.Spacing.space3)
        .frame(height: DesignTokens.ControlSize.searchboxHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onMagnifierTap()
        }
    }

    private var focusHeaderContent: some View {
        ZStack {
            FocusHeaderDragRegion()

            HStack(spacing: DesignTokens.Spacing.space2) {
                if reservesTrafficLightSpace {
                    Color.clear
                        .frame(width: 94, height: 40)
                        .allowsHitTesting(false)
                }

                breadcrumbRow
                    .layoutPriority(1)
                    .padding(.leading, DesignTokens.Spacing.space4)

                Spacer(minLength: DesignTokens.Spacing.space3)

                HStack(spacing: 0) {
                    ContextButton(
                        systemName: "info.circle",
                        tooltip: "Document appearance (⌥⌘I)",
                        isEnabled: canOpenDocumentInspector,
                        hitAreaSize: 40,
                        emphasis: .subtle,
                        iconHorizontalOffset: 4
                    ) {
                        isDocumentInspectorPresented.wrappedValue.toggle()
                    }
                    .overlay(alignment: .leading) {
                        if isFocusedPane {
                            Circle()
                                .fill(DesignTokens.Accent.nav.opacity(0.72))
                                .frame(width: 4, height: 4)
                                .offset(x: 4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .popover(isPresented: isDocumentInspectorPresented, arrowEdge: .bottom) {
                        documentInspectorPopoverContent
                    }

                    ContextButton(
                        systemName: "magnifyingglass",
                        tooltip: "Find in document (⌘F)",
                        isEnabled: canOpenDocumentNavigator,
                        hitAreaSize: 40,
                        emphasis: .subtle
                    ) {
                        onFindInDocument()
                    }

                    ContextButton(
                        systemName: "list.bullet.indent",
                        tooltip: "Outline and Go to Line",
                        isEnabled: canOpenDocumentNavigator,
                        hitAreaSize: 40,
                        emphasis: .subtle,
                        iconHorizontalOffset: -4
                    ) {
                        isDocumentNavigatorPresented.wrappedValue.toggle()
                    }
                    .popover(isPresented: isDocumentNavigatorPresented, arrowEdge: .bottom) {
                        documentNavigatorPopoverContent
                    }
                }
                .padding(.trailing, DesignTokens.Spacing.space1)
            }
            .opacity(isFocusedPane ? 1 : 0.68)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .background(.bar)
    }

    private var historyButtons: some View {
        HStack(spacing: DesignTokens.Spacing.space1) {
            ContextButton(
                systemName: "chevron.left",
                tooltip: "Back",
                isEnabled: canGoBack,
                action: onPrevTap
            )
            ContextButton(
                systemName: "chevron.right",
                tooltip: "Forward",
                isEnabled: canGoForward,
                action: onNextTap
            )
        }
    }

    private var magnifierButton: some View {
        Button(action: onMagnifierTap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignTokens.ControlSize.contextButtonIconSize, weight: .medium))
                .foregroundStyle(DesignTokens.TextStyle.secondary)
                .frame(width: DesignTokens.ControlSize.contextButtonSize, height: DesignTokens.ControlSize.contextButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Focus palette (⌘K)")
    }

    private var breadcrumbRow: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            if breadcrumb.segments.isEmpty {
                Text(emptyPlaceholder)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.TextStyle.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                let displayedSegments = visibleSegments()
                ForEach(Array(displayedSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        separator
                    }
                    segmentView(segment: segment)
                }
            }
        }
    }

    /// Returns the segments that should actually be displayed, applying
    /// truncation when collapsed and more than 3 folder crumbs exist.
    private func visibleSegments() -> [OmniboxBreadcrumb.Segment] {
        let raw = breadcrumb.segments
        if isBreadcrumbExpanded { return raw }

        // Only ever truncate folder segments. If the caller already inserted
        // an ellipsis placeholder, just honor what they gave us.
        if raw.contains(.ellipsis) { return raw }

        let folders = raw.compactMap { segment -> OmniboxBreadcrumb.Segment? in
            if case .folder = segment { return segment } else { return nil }
        }
        guard folders.count > 3 else { return raw }

        // Keep first + ellipsis + last folder, then any trailing note.
        var truncated: [OmniboxBreadcrumb.Segment] = []
        truncated.append(folders.first!)
        truncated.append(.ellipsis)
        truncated.append(folders.last!)
        for segment in raw {
            if case .note = segment { truncated.append(segment) }
        }
        return truncated
    }

    private var separator: some View {
        Text("›")
            .font(DesignTokens.Typography.body)
            .foregroundStyle(
                presentation == .focusHeader
                    ? DesignTokens.TextStyle.tertiary.opacity(0.68)
                    : DesignTokens.TextStyle.tertiary
            )
    }

    @ViewBuilder
    private func segmentView(segment: OmniboxBreadcrumb.Segment) -> some View {
        switch segment {
        case .folder(let name, let path):
            BreadcrumbButton(
                label: name,
                kind: .folder,
                emphasis: presentation == .focusHeader ? .subtle : .standard
            ) {
                onSegmentTap(path)
            }
        case .ellipsis:
            BreadcrumbButton(
                label: "…",
                kind: .ellipsis,
                emphasis: presentation == .focusHeader ? .subtle : .standard
            ) {
                isBreadcrumbExpanded.toggle()
                onEllipsisTap()
            }
        case .note(let name):
            HStack(spacing: 0) {
                Text(name)
                    .font(
                        presentation == .focusHeader
                            ? DesignTokens.Typography.bodyMedium
                            : DesignTokens.Typography.bodySemibold
                    )
                    .foregroundStyle(
                        presentation == .focusHeader
                            ? DesignTokens.TextStyle.secondary
                            : DesignTokens.TextStyle.primary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !siblingFiles.isEmpty {
                    BreadcrumbSiblingMenu(
                        files: siblingFiles,
                        emphasis: presentation == .focusHeader ? .subtle : .standard,
                        onSelect: onSiblingFileTap
                    )
                }
            }
        }
    }

    private var contextButtons: some View {
        HStack(spacing: DesignTokens.Spacing.space1) {
            ContextButton(systemName: "arrow.clockwise", tooltip: "Reload", action: onReloadTap)
            ContextButton(systemName: "arrow.up.forward.square", tooltip: "Reveal in Finder", action: onRevealTap)
            ContextButton(
                systemName: "info.circle",
                tooltip: "Document inspector",
                isEnabled: canOpenDocumentInspector
            ) {
                isDocumentInspectorPresented.wrappedValue.toggle()
            }
            .popover(isPresented: isDocumentInspectorPresented, arrowEdge: .bottom) {
                documentInspectorPopoverContent
            }
            ContextButton(
                systemName: "magnifyingglass",
                tooltip: "Find in document (⌘F)",
                isEnabled: canOpenDocumentNavigator,
                action: onFindInDocument
            )
            ContextButton(
                systemName: "list.bullet.indent",
                tooltip: "Outline and Go to Line",
                isEnabled: canOpenDocumentNavigator
            ) {
                isDocumentNavigatorPresented.wrappedValue.toggle()
            }
            .popover(isPresented: isDocumentNavigatorPresented, arrowEdge: .bottom) {
                documentNavigatorPopoverContent
            }
            ContextButton(
                systemName: isContextRibbonOpen ? "chevron.up.circle" : "chevron.down.circle",
                tooltip: contextRibbonTooltip,
                action: onExpandTap
            )
        }
    }

    private var contextRibbonTooltip: String {
        return isContextRibbonOpen ? "Hide folder shortcuts" : "Show folder shortcuts"
    }

    private func lastNoteSegment(in breadcrumb: OmniboxBreadcrumb) -> String? {
        for segment in breadcrumb.segments.reversed() {
            if case .note(let name) = segment {
                return name
            }
        }
        return nil
    }
}

private struct BreadcrumbSiblingMenu: View {
    enum Emphasis: Equatable {
        case standard
        case subtle
    }

    let files: [OmniboxSiblingFile]
    let emphasis: Emphasis
    let onSelect: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(files) { file in
                Button {
                    onSelect(file.relativePath)
                } label: {
                    Label(file.name, systemImage: file.iconSystemName)
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.input)
                    .fill(isHovering ? hoverFill : Color.clear)

                Image(systemName: "chevron.down")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DesignTokens.TextStyle.tertiary)
                    .frame(width: 7, height: 4)
                    .opacity(caretOpacity)
            }
            .frame(width: 20, height: 20)
            .frame(width: 40, height: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        // `.borderlessButton` draws its own arrow in full label color and
        // ignores `.menuIndicator(.hidden)`, which is what made this caret read
        // as solid black next to the much lighter breadcrumb separators. A
        // plain-styled button menu renders only the label above, so the caret
        // is the tertiary 7×4 chevron at `caretOpacity` it was meant to be.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help("Open sibling file")
        .accessibilityLabel("Open sibling file")
    }

    private var caretOpacity: Double {
        if isHovering {
            return emphasis == .subtle ? 0.68 : 0.78
        }
        return emphasis == .subtle ? 0.42 : 0.50
    }

    private var hoverFill: Color {
        emphasis == .subtle
            ? DesignTokens.Surface.overlay.opacity(0.55)
            : DesignTokens.Surface.overlay
    }
}

private struct BreadcrumbButton: View {
    enum Kind { case folder, ellipsis }
    enum Emphasis: Equatable { case standard, subtle }

    let label: String
    let kind: Kind
    var emphasis: Emphasis = .standard
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.space2)
                .padding(.vertical, DesignTokens.Spacing.space1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var textColor: Color {
        if emphasis == .subtle {
            switch kind {
            case .folder:
                return isHovering
                    ? DesignTokens.TextStyle.primary.opacity(0.90)
                    : DesignTokens.TextStyle.secondary.opacity(0.78)
            case .ellipsis:
                return isHovering
                    ? DesignTokens.TextStyle.secondary
                    : DesignTokens.TextStyle.tertiary.opacity(0.76)
            }
        }

        switch kind {
        case .folder:
            return isHovering ? DesignTokens.Accent.nav : DesignTokens.TextStyle.primary
        case .ellipsis:
            return isHovering ? DesignTokens.Accent.nav : DesignTokens.TextStyle.tertiary
        }
    }
}

private struct OmniboxAnchorBridge: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = OmniboxAnchorNSView(frame: .zero)
        view.onResolve = onResolve
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let anchorView = nsView as? OmniboxAnchorNSView {
            anchorView.onResolve = onResolve
        }
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

private final class OmniboxAnchorNSView: NSView {
    var onResolve: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onResolve?(self)
        }
    }
}

private struct ContextButton: View {
    enum Emphasis: Equatable {
        case standard
        case subtle
    }

    let systemName: String
    let tooltip: String
    var isEnabled: Bool = true
    var hitAreaSize: CGFloat = DesignTokens.ControlSize.contextButtonSize
    var emphasis: Emphasis = .standard
    var iconHorizontalOffset: CGFloat = 0
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            Image(systemName: systemName)
                .font(.system(size: iconPointSize, weight: iconWeight))
                .foregroundStyle(iconColor)
                .frame(width: DesignTokens.ControlSize.contextButtonSize, height: DesignTokens.ControlSize.contextButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.input)
                        .fill(backgroundFill)
                )
                .offset(x: iconHorizontalOffset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitAreaSize, height: hitAreaSize)
        .contentShape(Rectangle())
        .onHover { isHovering = isEnabled ? $0 : false }
        .help(tooltip)
        .allowsHitTesting(isEnabled)
    }

    private var iconColor: Color {
        if !isEnabled {
            return DesignTokens.TextStyle.tertiary.opacity(emphasis == .subtle ? 0.30 : 0.50)
        }
        if emphasis == .subtle {
            return isHovering
                ? DesignTokens.TextStyle.secondary
                : DesignTokens.TextStyle.tertiary.opacity(0.82)
        }
        return isHovering ? DesignTokens.TextStyle.primary : DesignTokens.TextStyle.secondary
    }

    private var backgroundFill: Color {
        guard isEnabled else { return Color.clear }
        if isPressed { return DesignTokens.Surface.selected }
        if isHovering {
            return emphasis == .subtle
                ? DesignTokens.Surface.overlay.opacity(0.55)
                : DesignTokens.Surface.overlay
        }
        return Color.clear
    }

    private var iconPointSize: CGFloat {
        emphasis == .subtle ? 12.5 : DesignTokens.ControlSize.contextButtonIconSize
    }

    private var iconWeight: Font.Weight {
        emphasis == .subtle ? .regular : .medium
    }
}

private struct FocusHeaderDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragRegionView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragRegionView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

#Preview("Omnibox — idle (deep path)") {
    OmniboxView(
        breadcrumb: OmniboxBreadcrumb(segments: [
            .folder(name: "10-Workspaces", path: "10-Workspaces"),
            .folder(name: "23-Market-Research", path: "10-Workspaces/23-Market-Research"),
            .folder(name: "Research", path: "10-Workspaces/23-Market-Research/Research"),
            .folder(name: "12-Claude-Book", path: "10-Workspaces/23-Market-Research/Research/12-Claude-Book"),
            .note("01_foundations.md"),
        ])
    )
    .padding(DesignTokens.Spacing.space5)
    .frame(width: 900)
    .background(DesignTokens.Surface.base)
}

#Preview("Omnibox — idle (shallow)") {
    OmniboxView(
        breadcrumb: OmniboxBreadcrumb(segments: [
            .folder(name: "20-Records", path: "20-Records"),
            .note("weekly.md"),
        ]),
        siblingFiles: [
            OmniboxSiblingFile(relativePath: "20-Records/brief.pdf", name: "brief.pdf", iconSystemName: "doc.richtext"),
            OmniboxSiblingFile(relativePath: "20-Records/weekly.md", name: "weekly.md", iconSystemName: "doc.text"),
            OmniboxSiblingFile(relativePath: "20-Records/year.html", name: "year.html", iconSystemName: "globe"),
        ]
    )
    .padding(DesignTokens.Spacing.space5)
    .frame(width: 900)
    .background(DesignTokens.Surface.base)
}

#Preview("Omnibox — idle (empty)") {
    OmniboxView(breadcrumb: .empty)
        .padding(DesignTokens.Spacing.space5)
        .frame(width: 900)
        .background(DesignTokens.Surface.base)
}

#Preview("Omnibox — focus header") {
    OmniboxView(
        breadcrumb: OmniboxBreadcrumb(segments: [
            .folder(name: "10-Workspaces", path: "10-Workspaces"),
            .folder(name: "Drafts", path: "10-Workspaces/Drafts"),
            .note("Focus mode"),
        ]),
        presentation: .focusHeader,
        reservesTrafficLightSpace: true
    )
    .frame(width: 900)
}
