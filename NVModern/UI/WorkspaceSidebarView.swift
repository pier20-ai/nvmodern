import AppKit
import SwiftUI

struct WorkspaceSidebarTreeRow: Identifiable, Equatable {
    let relativePath: String
    let displayName: String
    let kind: MillerItemKind
    let depth: Int
    let hasChildren: Bool

    var id: String {
        "\(kind == .folder ? "folder" : "note"):\(relativePath)"
    }
}

enum WorkspaceSidebarTreeBuilder {
    static func rows(
        childrenByFolder: [String: [MillerItem]],
        rootPath: String?,
        expandedFolderPaths: Set<String>,
        filterQuery: String = ""
    ) -> [WorkspaceSidebarTreeRow] {
        var result: [WorkspaceSidebarTreeRow] = []
        let normalizedFilterQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedFilterQuery.isEmpty {
            appendRows(
                below: normalized(rootPath),
                depth: 0,
                childrenByFolder: childrenByFolder,
                expandedFolderPaths: expandedFolderPaths,
                into: &result
            )
        } else {
            _ = appendFilteredRows(
                below: normalized(rootPath),
                depth: 0,
                filterQuery: normalizedFilterQuery,
                childrenByFolder: childrenByFolder,
                into: &result
            )
        }
        return result
    }

    static func folderPaths(in childrenByFolder: [String: [MillerItem]]) -> Set<String> {
        var paths = Set(childrenByFolder.keys.filter { !$0.isEmpty })
        for children in childrenByFolder.values {
            for child in children where child.kind == .folder {
                paths.insert(child.relativePath)
            }
        }
        return paths
    }

    static func ancestorFolderPaths(forDocumentPath relativePath: String?) -> Set<String> {
        guard let relativePath else { return [] }
        let components = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
        guard components.count > 1 else { return [] }

        var paths = Set<String>()
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            paths.insert(current)
        }
        return paths
    }

    private static func appendRows(
        below parentPath: String,
        depth: Int,
        childrenByFolder: [String: [MillerItem]],
        expandedFolderPaths: Set<String>,
        into result: inout [WorkspaceSidebarTreeRow]
    ) {
        for item in childrenByFolder[parentPath, default: []] {
            switch item.kind {
            case .note:
                result.append(
                    WorkspaceSidebarTreeRow(
                        relativePath: item.relativePath,
                        displayName: item.name,
                        kind: .note,
                        depth: depth,
                        hasChildren: false
                    )
                )

            case .folder:
                let compacted = compactedFolder(
                    startingAt: item,
                    childrenByFolder: childrenByFolder
                )
                let children = childrenByFolder[compacted.relativePath, default: []]
                result.append(
                    WorkspaceSidebarTreeRow(
                        relativePath: compacted.relativePath,
                        displayName: compacted.displayNames.joined(separator: " / "),
                        kind: .folder,
                        depth: depth,
                        hasChildren: !children.isEmpty
                    )
                )

                if expandedFolderPaths.contains(compacted.relativePath) {
                    appendRows(
                        below: compacted.relativePath,
                        depth: depth + 1,
                        childrenByFolder: childrenByFolder,
                        expandedFolderPaths: expandedFolderPaths,
                        into: &result
                    )
                }
            }
        }
    }

    private static func compactedFolder(
        startingAt item: MillerItem,
        childrenByFolder: [String: [MillerItem]]
    ) -> (relativePath: String, displayNames: [String]) {
        var path = item.relativePath
        var names = [item.name]
        var visited = Set([path])

        while true {
            let children = childrenByFolder[path, default: []]
            guard children.count == 1,
                  let onlyChild = children.first,
                  onlyChild.kind == .folder,
                  visited.insert(onlyChild.relativePath).inserted else {
                break
            }

            path = onlyChild.relativePath
            names.append(onlyChild.name)
        }

        return (path, names)
    }

    @discardableResult
    private static func appendFilteredRows(
        below parentPath: String,
        depth: Int,
        filterQuery: String,
        childrenByFolder: [String: [MillerItem]],
        into result: inout [WorkspaceSidebarTreeRow]
    ) -> Bool {
        var matchedRows: [WorkspaceSidebarTreeRow] = []

        for item in childrenByFolder[parentPath, default: []] {
            switch item.kind {
            case .note:
                guard matchesFilter(
                    displayName: item.name,
                    relativePath: item.relativePath,
                    filterQuery: filterQuery
                ) else {
                    continue
                }
                matchedRows.append(
                    WorkspaceSidebarTreeRow(
                        relativePath: item.relativePath,
                        displayName: item.name,
                        kind: .note,
                        depth: depth,
                        hasChildren: false
                    )
                )

            case .folder:
                let compacted = compactedFolder(
                    startingAt: item,
                    childrenByFolder: childrenByFolder
                )
                let displayName = compacted.displayNames.joined(separator: " / ")
                var descendantRows: [WorkspaceSidebarTreeRow] = []
                let hasMatchingDescendants = appendFilteredRows(
                    below: compacted.relativePath,
                    depth: depth + 1,
                    filterQuery: filterQuery,
                    childrenByFolder: childrenByFolder,
                    into: &descendantRows
                )
                let folderMatches = matchesFilter(
                    displayName: displayName,
                    relativePath: compacted.relativePath,
                    filterQuery: filterQuery
                )

                guard folderMatches || hasMatchingDescendants else { continue }
                matchedRows.append(
                    WorkspaceSidebarTreeRow(
                        relativePath: compacted.relativePath,
                        displayName: displayName,
                        kind: .folder,
                        depth: depth,
                        hasChildren: hasMatchingDescendants
                    )
                )
                if hasMatchingDescendants {
                    matchedRows.append(contentsOf: descendantRows)
                }
            }
        }

        result.append(contentsOf: matchedRows)
        return !matchedRows.isEmpty
    }

    private static func matchesFilter(
        displayName: String,
        relativePath: String,
        filterQuery: String
    ) -> Bool {
        displayName.localizedCaseInsensitiveContains(filterQuery)
            || relativePath.localizedCaseInsensitiveContains(filterQuery)
    }

    private static func normalized(_ path: String?) -> String {
        guard let path else { return "" }
        return path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// One entry in the sidebar's Recent section. Recents come from the session
/// store, which also tracks external and clipboard documents; only workspace
/// notes appear here, so the row can reuse the tree's open callback instead of
/// growing a second, parallel opening path.
struct WorkspaceSidebarRecentRow: Identifiable, Equatable {
    let relativePath: String
    let title: String

    var id: String { relativePath }
}

private enum WorkspaceSidebarSelection: Hashable {
    case pinned(String)
    case recent(String)
    case file(String, MillerItemKind)
}

private enum WorkspaceSidebarIcon {
    case system(String)
    case markdown
}

/// A compact, monoline Markdown mark for sidebar-scale rendering. The usual
/// filled logo becomes visually dense beside SF Symbols at 11 points, so this
/// keeps the familiar M + down-arrow silhouette with native-style strokes.
private struct WorkspaceSidebarMarkdownGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        path.move(to: point(0.06, 0.82))
        path.addLine(to: point(0.06, 0.18))
        path.addLine(to: point(0.27, 0.54))
        path.addLine(to: point(0.48, 0.18))
        path.addLine(to: point(0.48, 0.82))

        path.move(to: point(0.73, 0.18))
        path.addLine(to: point(0.73, 0.82))
        path.move(to: point(0.59, 0.67))
        path.addLine(to: point(0.73, 0.82))
        path.addLine(to: point(0.87, 0.67))
        return path
    }
}

private final class WorkspaceSidebarCapsuleSearchField: NSSearchField {
    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 1, dy: 1)
    }

    override func drawFocusRingMask() {
        let maskBounds = focusRingMaskBounds
        NSBezierPath(
            roundedRect: maskBounds,
            xRadius: maskBounds.height / 2,
            yRadius: maskBounds.height / 2
        ).fill()
    }
}

private struct WorkspaceSidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = WorkspaceSidebarCapsuleSearchField(string: text)
        field.placeholderString = prompt
        field.bezelStyle = .roundedBezel
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        guard field.stringValue != text else { return }
        field.stringValue = text
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct WorkspaceSidebarView: View {
    private static let treeAnimation = Animation.easeInOut(duration: 0.22)
    /// `NavigationSplitView` adds one extra chrome band above its sidebar
    /// content when AppKit switches the window to `.unifiedCompact`. The
    /// detail column's native tab strip stays in that band, so lift the
    /// sidebar content by the same optical distance to keep search aligned.
    private static let compactToolbarTopCorrection: CGFloat = 36

    /// Row content starts at the row's own leading edge, which is where the
    /// section labels and the filter field sit. Without this the list's default
    /// row inset pushes every row right of the labels above it.
    private static let rowInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
    /// The chevron column every file row reserves, so folder chevrons and note
    /// icons line up whether or not a row can be expanded.
    private static let chevronColumnWidth: CGFloat = 12
    private static let indentPerLevel: CGFloat = 12
    private static let iconSize: CGFloat = 11
    private static let iconColumnWidth: CGFloat = 14

    @ObservedObject var notesModel: NotesWorkspaceModel
    @Binding var expandedFolderPaths: Set<String>
    let focusedRootPath: String?
    let selectedDocumentPath: String?
    let onSetFocusedRoot: (String?) -> Void
    let onOpenDocument: (_ relativePath: String, _ inNewTab: Bool) -> Void
    let onBrowseInColumns: (_ relativePath: String?) -> Void
    let onCreateNoteInFolder: (_ relativePath: String?) -> Void

    @ObservedObject private var sessionStore = WorkspaceSessionStore.shared

    @State private var filterQuery = ""
    /// macOS List applies row insertions/removals through its AppKit backing
    /// view, which does not honor SwiftUI transitions. Keep descendants alive
    /// just long enough to fade/slide them out, and insert them initially
    /// hidden before revealing them on the next update.
    @State private var transitioningFolderPaths: Set<String> = []

    /// App-level rather than per-window, and deliberately not part of the
    /// session snapshot — a collapsed section is a standing preference, not
    /// window state, and keeping it out of `PersistedWorkspaceWindowState`
    /// avoids a schema revision for one boolean.
    @AppStorage("sidebar.recentsExpanded") private var isRecentsExpanded = true
    @AppStorage("sidebar.pinnedExpanded") private var isPinnedExpanded = true
    @AppStorage("sidebar.filesExpanded") private var isFilesExpanded = true
    @AppStorage(CompactToolbarPreference.key) private var isCompactToolbarEnabled = false

    private var isFiltering: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rows: [WorkspaceSidebarTreeRow] {
        WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: notesModel.childrenByFolder,
            rootPath: focusedRootPath,
            expandedFolderPaths: expandedFolderPaths,
            filterQuery: filterQuery
        )
    }

    /// Pinned and recent lists are hidden while filtering: a filter is a
    /// question about the tree, and leaving unfiltered lists above the results
    /// makes the answer harder to read.
    private var pinnedRows: [WorkspaceSidebarRecentRow] {
        guard !isFiltering else { return [] }
        _ = sessionStore.pinnedDocumentsRevision
        return sessionStore
            .pinnedDocuments(rootURL: notesModel.runtimeConfig.rootURL)
            .compactMap { pinned in
                guard case .workspaceNote(let relativePath) = pinned.document else { return nil }
                return WorkspaceSidebarRecentRow(relativePath: relativePath, title: pinned.title)
            }
    }

    /// A pinned note is already listed above, so it is dropped from recents
    /// rather than appearing twice in one column. The window is widened past
    /// the display limit first, so pinning a note does not shorten the recents
    /// list underneath it.
    private var recentRows: [WorkspaceSidebarRecentRow] {
        guard !isFiltering else { return [] }
        _ = sessionStore.recentDocumentsRevision
        let pinnedPaths = Set(pinnedRows.map(\.relativePath))
        return sessionStore
            .recentDocuments(rootURL: notesModel.runtimeConfig.rootURL, limit: 12)
            .compactMap { recent in
                guard case .workspaceNote(let relativePath) = recent.document,
                      !pinnedPaths.contains(relativePath) else {
                    return nil
                }
                return WorkspaceSidebarRecentRow(relativePath: relativePath, title: recent.title)
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSidebarSearchField(text: $filterQuery, prompt: "Filter Files")
                .frame(height: 22)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 5)

            content
        }
        .padding(
            .top,
            isCompactToolbarEnabled ? -Self.compactToolbarTopCorrection : 0
        )
    }

    // MARK: - Content

    private var content: some View {
        List(selection: sidebarSelection) {
            if !pinnedRows.isEmpty {
                Section("Pinned", isExpanded: $isPinnedExpanded) {
                    ForEach(pinnedRows) { row in
                        shortcutRow(row, selection: .pinned(row.relativePath))
                    }
                }
            }

            if !recentRows.isEmpty {
                Section("Recent", isExpanded: $isRecentsExpanded) {
                    ForEach(recentRows) { row in
                        shortcutRow(row, selection: .recent(row.relativePath))
                    }
                }
            }

            Section("Files", isExpanded: $isFilesExpanded) {
                ForEach(rows) { row in
                    fileRow(row)
                        .tag(WorkspaceSidebarSelection.file(row.relativePath, row.kind))
                        .opacity(isTransitioningDescendant(row) ? 0 : 1)
                        .offset(y: isTransitioningDescendant(row) ? -5 : 0)
                    .contextMenu {
                        contextMenu(for: row)
                    }
                }

                if rows.isEmpty {
                    ContentUnavailableView(
                        isFiltering ? "No Matching Files" : "No Files",
                        systemImage: isFiltering ? "magnifyingglass" : "folder",
                        description: Text(
                            isFiltering
                                ? "No files in this workspace match your filter."
                                : "This folder is empty."
                        )
                    )
                    .selectionDisabled()
                }
            }

        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 16)
        .animation(Self.treeAnimation, value: isPinnedExpanded)
        .animation(Self.treeAnimation, value: isRecentsExpanded)
        .animation(Self.treeAnimation, value: isFilesExpanded)
    }

    private var sidebarSelection: Binding<WorkspaceSidebarSelection?> {
        Binding(
            get: {
                if let selectedDocumentPath {
                    return .file(selectedDocumentPath, .note)
                }
                return nil
            },
            set: { selection in
                guard let selection else { return }
                activate(selection)
            }
        )
    }

    private func shortcutRow(
        _ row: WorkspaceSidebarRecentRow,
        selection: WorkspaceSidebarSelection
    ) -> some View {
        HStack(spacing: 6) {
            sidebarIcon(fileIcon(forPath: row.relativePath))
            Text(row.title)
        }
            .lineLimit(1)
            .truncationMode(.middle)
            .listRowInsets(Self.rowInsets)
            .tag(selection)
            .help(row.relativePath)
        .contextMenu {
            Button {
                onOpenDocument(row.relativePath, true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
            }

            let isPinned = pinnedRows.contains { $0.relativePath == row.relativePath }
            Button {
                WorkspaceSessionStore.shared.setPinned(
                    !isPinned,
                    rootURL: notesModel.runtimeConfig.rootURL,
                    document: .workspaceNote(relativePath: row.relativePath),
                    title: row.title
                )
            } label: {
                Label(isPinned ? "Unpin Note" : "Pin Note", systemImage: isPinned ? "pin.slash" : "pin")
            }

            Divider()

            Button {
                revealInFinder(row.relativePath)
            } label: {
                Label("Show in Finder", systemImage: "finder")
            }
        }
    }

    /// Depth is leading padding rather than a spacer view: a zero-width spacer
    /// still takes the stack's spacing, which pushed even level-0 rows right of
    /// their section label.
    private func fileRow(_ row: WorkspaceSidebarTreeRow) -> some View {
        HStack(spacing: 6) {
            if row.kind == .folder && row.hasChildren {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(
                        .degrees(
                            isFiltering || expandedFolderPaths.contains(row.relativePath)
                                && !transitioningFolderPaths.contains(row.relativePath)
                                ? 90
                                : 0
                        )
                    )
                    .animation(
                        Self.treeAnimation,
                        value: expandedFolderPaths.contains(row.relativePath)
                            && !transitioningFolderPaths.contains(row.relativePath)
                    )
                    .frame(width: Self.chevronColumnWidth)
            } else {
                Color.clear.frame(width: Self.chevronColumnWidth, height: 1)
            }

            HStack(spacing: 6) {
                sidebarIcon(row.kind == .folder ? .system("folder") : fileIcon(forPath: row.relativePath))
                Text(row.displayName)
            }
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(row.depth) * Self.indentPerLevel)
        .listRowInsets(Self.rowInsets)
        .help(row.relativePath)
    }

    @ViewBuilder
    private func sidebarIcon(_ icon: WorkspaceSidebarIcon) -> some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: Self.iconSize, weight: .regular))
            case .markdown:
                WorkspaceSidebarMarkdownGlyph()
                    .stroke(
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                    )
                    .padding(1.5)
                    .offset(y: 0.5)
            }
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.secondary)
        .frame(width: Self.iconColumnWidth, height: Self.iconColumnWidth)
    }

    private func fileIcon(forPath path: String) -> WorkspaceSidebarIcon {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd":
            return .markdown
        default:
            return .system(workspaceFileIconName(forPath: path))
        }
    }

    private func activate(_ selection: WorkspaceSidebarSelection) {
        switch selection {
        case .pinned(let relativePath), .recent(let relativePath):
            onOpenDocument(relativePath, NSEvent.modifierFlags.contains(.command))
        case .file(let relativePath, let kind):
            let row = rows.first { $0.relativePath == relativePath && $0.kind == kind }
            if let row {
                activate(row)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for row: WorkspaceSidebarTreeRow) -> some View {
        if row.kind == .folder {
            Button {
                onCreateNoteInFolder(row.relativePath)
            } label: {
                Label("New Note Here…", systemImage: "square.and.pencil")
            }

            Divider()

            Button {
                onSetFocusedRoot(row.relativePath)
            } label: {
                Label("Focus Sidebar Here", systemImage: "scope")
            }
            .disabled(row.relativePath == focusedRootPath)

            Button {
                onBrowseInColumns(row.relativePath)
            } label: {
                Label("Browse in Columns", systemImage: "rectangle.split.3x1")
            }
        } else {
            Button {
                onOpenDocument(row.relativePath, true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
            }
        }

        Divider()

        Button {
            revealInFinder(row.relativePath)
        } label: {
            Label("Show in Finder", systemImage: "finder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.relativePath, forType: .string)
        } label: {
            Label("Copy Relative Path", systemImage: "doc.on.doc")
        }
    }

    private func activate(_ row: WorkspaceSidebarTreeRow) {
        switch row.kind {
        case .folder:
            if isFiltering {
                filterQuery = ""
                onSetFocusedRoot(row.relativePath)
                return
            }
            guard row.hasChildren else { return }
            let folderPath = row.relativePath
            guard !transitioningFolderPaths.contains(folderPath) else { return }

            if expandedFolderPaths.contains(folderPath) {
                withAnimation(Self.treeAnimation) {
                    _ = transitioningFolderPaths.insert(folderPath)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        _ = expandedFolderPaths.remove(folderPath)
                        _ = transitioningFolderPaths.remove(folderPath)
                    }
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    _ = transitioningFolderPaths.insert(folderPath)
                    _ = expandedFolderPaths.insert(folderPath)
                }
                DispatchQueue.main.async {
                    withAnimation(Self.treeAnimation) {
                        _ = transitioningFolderPaths.remove(folderPath)
                    }
                }
            }
        case .note:
            let opensNewTab = NSEvent.modifierFlags.contains(.command)
            onOpenDocument(row.relativePath, opensNewTab)
        }
    }

    private func revealInFinder(_ relativePath: String) {
        guard let url = notesModel.workspaceURL(for: relativePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func isTransitioningDescendant(_ row: WorkspaceSidebarTreeRow) -> Bool {
        transitioningFolderPaths.contains { folderPath in
            row.relativePath.hasPrefix(folderPath + "/")
        }
    }
}
