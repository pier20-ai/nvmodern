import AppKit
import SwiftUI

/// A format-neutral location represented by an item in the document outline.
///
/// Text documents use source offsets for the existing editor navigation
/// protocol. EPUB and PDF destinations deliberately carry stable, native
/// locations rather than pretending they have text offsets.
enum DocumentOutlineDestination: Equatable {
    case text(from: Int, to: Int, line: Int)
    case epub(href: String, cfi: String?)
    case pdf(pageIndex: Int)
}

struct DocumentOutlineItem: Identifiable, Equatable {
    let id: String
    let level: Int
    let title: String
    let destination: DocumentOutlineDestination

    static func textItems(from payload: [String: Any]) -> [DocumentOutlineItem] {
        (payload["outline"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["text"] as? String,
                  let level = item["level"] as? Int,
                  let from = item["from"] as? Int,
                  let to = item["to"] as? Int,
                  let line = item["line"] as? Int else { return nil }
            return DocumentOutlineItem(
                id: id, level: level, title: title,
                destination: .text(from: from, to: to, line: line)
            )
        }
    }
}

/// Keep the old name source-compatible while callers migrate to the generic
/// document outline model.
typealias DocumentNavigatorOutlineItem = DocumentOutlineItem

struct DocumentNavigatorSearchMatch: Identifiable, Equatable {
    let id: String
    let text: String
    let preview: String
    let line: Int
    let from: Int
    let to: Int
}

enum DocumentNavigatorMode: String, CaseIterable, Identifiable {
    case outline
    case line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: return "Outline"
        case .line: return "Line"
        }
    }
}

extension Notification.Name {
    static let documentNavigatorOpenRequested = Notification.Name("nvmodern.documentNavigatorOpenRequested")
}

enum DocumentNavigatorNotification {
    static let modeKey = "mode"
    static let windowNumberKey = "windowNumber"
}

extension Notification.Name {
    static let documentFindOpenRequested = Notification.Name("nvmodern.documentFindOpenRequested")
}

struct DocumentNavigatorPopoverView: View {
    let outlineItems: [DocumentOutlineItem]
    var activeOutlineItemID: String? = nil
    let lineCount: Int
    var initialMode: DocumentNavigatorMode = .outline
    /// Column mode strips the popover chrome (fixed size, window-background
    /// fill) so the view can live inside a full-height inspector column.
    var embedsInColumn: Bool = false
    /// The native inspector promotes Outline and Line to peer panes, while the
    /// compact popover still owns its local mode switcher.
    var showsModeBar: Bool = true
    let onPreviewOutline: (DocumentOutlineItem) -> Void
    let onPreviewLine: (Int) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var mode: DocumentNavigatorMode = .outline
    @State private var inputText = ""
    @State private var selectedIndex = 0
    /// Headings whose descendants are hidden. Collapse is view-local and is
    /// ignored while a filter query is active, where the list is flat.
    @State private var collapsedIDs: Set<String> = []
    @FocusState private var isFieldFocused: Bool

    private var isFilteringOutline: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredOutlineItems: [DocumentOutlineItem] {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return outlineItems }

        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return outlineItems.filter { item in
            tokens.allSatisfy { token in
                item.title.localizedStandardContains(token)
            }
        }
    }

    /// The rows the list actually shows: the filtered flat list while typing,
    /// otherwise the tree minus every descendant of a collapsed heading.
    /// Selection and keyboard navigation run over this list only.
    private var visibleOutlineItems: [DocumentOutlineItem] {
        guard !isFilteringOutline else { return filteredOutlineItems }
        guard !collapsedIDs.isEmpty else { return outlineItems }

        var visible: [DocumentOutlineItem] = []
        var hiddenBelowLevel: Int?
        for item in outlineItems {
            if let level = hiddenBelowLevel {
                if item.level > level { continue }
                hiddenBelowLevel = nil
            }
            visible.append(item)
            if collapsedIDs.contains(item.id) {
                hiddenBelowLevel = item.level
            }
        }
        return visible
    }

    /// An item has children when the next item in document order sits deeper.
    private var outlineParentIDs: Set<String> {
        var ids: Set<String> = []
        for (index, item) in outlineItems.enumerated() {
            let nextIndex = index + 1
            guard outlineItems.indices.contains(nextIndex) else { break }
            if outlineItems[nextIndex].level > item.level {
                ids.insert(item.id)
            }
        }
        return ids
    }

    private var activeCount: Int {
        switch mode {
        case .outline: return visibleOutlineItems.count
        case .line: return lineCount > 0 ? 1 : 0
        }
    }

    private var inputPlaceholder: String {
        switch mode {
        case .outline: return outlineItems.isEmpty ? "No outline available" : "Filter outline"
        case .line: return lineCount > 0 ? "Go to line 1–\(lineCount)" : "No lines available"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsModeBar {
                modeBar
            } else {
                Spacer().frame(height: 12)
            }
            inputRow
            Divider().opacity(0.5)
            resultArea
        }
        .frame(width: embedsInColumn ? nil : 380, height: embedsInColumn ? nil : 360)
        .background(embedsInColumn ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            mode = initialMode
            inputText = ""
            revealActiveOutlineItem()
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
        .onChange(of: mode) { _, _ in
            inputText = ""
            DispatchQueue.main.async {
                if mode == .outline {
                    revealActiveOutlineItem()
                } else {
                    selectedIndex = 0
                }
                isFieldFocused = true
            }
        }
        .onChange(of: outlineItems) { _, newItems in
            // Drop collapse state for headings the document no longer has, so
            // a reused id cannot hide a fresh subtree.
            let liveIDs = Set(newItems.map(\.id))
            collapsedIDs.formIntersection(liveIDs)
            revealActiveOutlineItem()
        }
        .onChange(of: activeOutlineItemID) { _, _ in
            revealActiveOutlineItem()
        }
        .onChange(of: inputText) { _, newValue in
            selectedIndex = 0
            switch mode {
            case .outline:
                clampSelection()
            case .line:
                let digits = newValue.filter(\.isNumber)
                if digits != newValue {
                    inputText = digits
                }
            }
        }
        .background(
            DocumentNavigatorKeyMonitor(
                // The popover owns the keyboard for as long as it is up. The
                // inspector column does not: it stays open after a jump, and a
                // monitor that kept swallowing Return and the arrow keys would
                // take them from the editor the jump just focused.
                isActive: !embedsInColumn || isFieldFocused,
                onMove: moveSelection,
                onCommit: commitSelection,
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Mode bar

    private var modeBar: some View {
        HStack(spacing: 0) {
            ForEach(DocumentNavigatorMode.allCases) { item in
                modeSegment(item)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(DesignTokens.Surface.overlay)
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignTokens.TextStyle.tertiary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func modeSegment(_ item: DocumentNavigatorMode) -> some View {
        Button {
            mode = item
        } label: {
            Text(item.title)
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(mode == item ? Color.white : DesignTokens.TextStyle.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(
                    Capsule().fill(mode == item ? DesignTokens.Accent.nav : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .line ? "number" : "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.TextStyle.tertiary)

            TextField(inputPlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.TextStyle.primary)
                .focused($isFieldFocused)
                .disabled(mode == .outline && outlineItems.isEmpty)
                .onSubmit { commitSelection() }

            if !inputText.isEmpty {
                Button {
                    inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(DesignTokens.Surface.overlay)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Results

    private var resultArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .outline:
                        outlineRows
                    case .line:
                        lineRows
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, index in
                guard let id = currentRowID(for: index) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: activeOutlineItemID) { _, id in
                guard mode == .outline, let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear {
                guard mode == .outline, let activeOutlineItemID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(activeOutlineItemID, anchor: .center)
                }
            }
        }
    }

    private func currentRowID(for index: Int) -> AnyHashable? {
        switch mode {
        case .outline:
            let items = visibleOutlineItems
            guard items.indices.contains(index) else { return nil }
            return items[index].id
        case .line:
            return "line-row" as AnyHashable
        }
    }

    @ViewBuilder
    private var outlineRows: some View {
        let items = visibleOutlineItems
        if items.isEmpty {
            emptyState(
                outlineItems.isEmpty
                    ? "No headings in this document"
                    : "No headings match"
            )
        } else {
            let parentIDs: Set<String> = isFilteringOutline ? [] : outlineParentIDs
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DocumentNavigatorOutlineRow(
                    item: item,
                    isSelected: selectedIndex == index,
                    hasChildren: parentIDs.contains(item.id),
                    isCollapsed: collapsedIDs.contains(item.id),
                    onToggleCollapse: { toggleOutlineCollapse(item) }
                )
                .id(item.id)
                .onTapGesture {
                    selectedIndex = index
                    onPreviewOutline(item)
                    onCommit()
                }
            }
        }
    }

    private func toggleOutlineCollapse(_ item: DocumentOutlineItem) {
        let previousItems = visibleOutlineItems
        let previouslySelectedID = previousItems.indices.contains(selectedIndex)
            ? previousItems[selectedIndex].id
            : nil

        if collapsedIDs.contains(item.id) {
            collapsedIDs.remove(item.id)
        } else {
            collapsedIDs.insert(item.id)
        }

        // Keep the selection on the same heading; if it just went out of view,
        // fall back to the heading that was collapsed.
        let updatedItems = visibleOutlineItems
        if let previouslySelectedID,
           let index = updatedItems.firstIndex(where: { $0.id == previouslySelectedID }) {
            selectedIndex = index
        } else if let index = updatedItems.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        if lineCount <= 0 {
            emptyState("No line information available")
        } else {
            let parsed = parsedLineNumber()
            let target = parsed ?? 1
            DocumentNavigatorLineRow(
                target: target,
                total: lineCount,
                isSelected: true
            )
            .id("line-row" as AnyHashable)
            .onTapGesture {
                inputText = String(target)
                onPreviewLine(target)
                onCommit()
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(DesignTokens.Typography.secondary)
            .foregroundStyle(DesignTokens.TextStyle.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
    }

    // MARK: - Selection plumbing

    private func moveSelection(delta: Int) {
        switch mode {
        case .outline:
            let items = visibleOutlineItems
            guard !items.isEmpty else { return }
            selectedIndex = clampedIndex(selectedIndex + delta, count: items.count)
            onPreviewOutline(items[selectedIndex])
        case .line:
            guard lineCount > 0 else { return }
            let current = parsedLineNumber() ?? 1
            let next = max(1, min(lineCount, current + delta))
            inputText = String(next)
            onPreviewLine(next)
        }
    }

    private func commitSelection() {
        switch mode {
        case .outline:
            let items = visibleOutlineItems
            if items.indices.contains(selectedIndex) {
                onPreviewOutline(items[selectedIndex])
            }
            onCommit()
        case .line:
            if lineCount > 0 {
                onPreviewLine(parsedLineNumber() ?? 1)
            }
            onCommit()
        }
    }

    private func parsedLineNumber() -> Int? {
        guard let value = Int(inputText.trimmingCharacters(in: .whitespacesAndNewlines)),
              lineCount > 0 else {
            return nil
        }
        return max(1, min(lineCount, value))
    }

    private func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }

    private func clampSelection() {
        selectedIndex = max(0, min(selectedIndex, max(0, activeCount - 1)))
    }

    /// Reveal and select the section reported by the active document runtime.
    /// Expanding only its collapsed ancestors preserves unrelated user collapse
    /// choices while ensuring that the current chapter/heading is visible.
    private func revealActiveOutlineItem() {
        guard mode == .outline,
              let activeOutlineItemID,
              let activeIndex = outlineItems.firstIndex(where: { $0.id == activeOutlineItemID }) else {
            clampSelection()
            return
        }

        if !isFilteringOutline {
            let activeLevel = outlineItems[activeIndex].level
            var nearestAncestorLevel = activeLevel
            if activeIndex > 0 {
                for index in stride(from: activeIndex - 1, through: 0, by: -1) {
                    let candidate = outlineItems[index]
                    guard candidate.level < nearestAncestorLevel else { continue }
                    collapsedIDs.remove(candidate.id)
                    nearestAncestorLevel = candidate.level
                    if nearestAncestorLevel <= 1 { break }
                }
            }
        }

        if let visibleIndex = visibleOutlineItems.firstIndex(where: { $0.id == activeOutlineItemID }) {
            selectedIndex = visibleIndex
        } else {
            clampSelection()
        }
    }
}

// MARK: - Rows

/// A plain outline row: one font, one color, depth carried by indentation and
/// a disclosure chevron. Per-level type scales and accent colors read as
/// document styling rather than as a navigator, so they are deliberately gone.
private struct DocumentNavigatorOutlineRow: View {
    let item: DocumentOutlineItem
    let isSelected: Bool
    let hasChildren: Bool
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    private static let indentPerLevel: CGFloat = 14
    private static let disclosureWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            disclosure
            Text(item.title)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(isSelected ? Color.white : DesignTokens.TextStyle.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var disclosure: some View {
        if hasChildren {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : DesignTokens.TextStyle.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
        } else {
            Color.clear.frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
        }
    }

    private var leadingInset: CGFloat {
        12 + CGFloat(max(0, item.level - 1)) * Self.indentPerLevel
    }
}

private struct DocumentNavigatorLineRow: View {
    let target: Int
    let total: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Accent.nav)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Go to line \(target)")
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundStyle(DesignTokens.TextStyle.primary)
                    .lineLimit(1)
                Text("of \(total) \(total == 1 ? "line" : "lines")")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DesignTokens.Surface.selected : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? DesignTokens.Accent.nav : Color.clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Keyboard monitor

private struct DocumentNavigatorKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    var onMove: (Int) -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onMove: onMove, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.hostWindow = view.window
            context.coordinator.installMonitorIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostWindow = nsView.window
        context.coordinator.isActive = isActive
        context.coordinator.onMove = onMove
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostWindow: NSWindow?
        var isActive: Bool
        var onMove: (Int) -> Void
        var onCommit: () -> Void
        var onCancel: () -> Void
        private var monitor: Any?

        init(
            isActive: Bool,
            onMove: @escaping (Int) -> Void,
            onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.isActive = isActive
            self.onMove = onMove
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard isActive else { return event }
                guard NSApp.keyWindow != nil else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let meaningfulFlags = flags.subtracting([.function, .numericPad])
                guard meaningfulFlags.isEmpty else { return event }

                switch event.keyCode {
                case 36:
                    onCommit()
                    return nil
                case 53:
                    onCancel()
                    return nil
                case 126:
                    onMove(-1)
                    return nil
                case 125:
                    onMove(1)
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
