import AppKit
import QuickLookUI
import WebKit
import SwiftUI

// MARK: — MillerColumnsView

struct MillerPreviewColumnContent: Equatable {
    let title: String
    let relativePath: String
    let iconName: String
    let fileURL: URL
}

enum MillerSelectionGesture {
    case replace
    case toggle
    case range
}

enum MillerHorizontalScrollEdge: Equatable {
    case left
    case right
    case revealActive
}

struct MillerHorizontalScrollRequest: Equatable {
    let id: Int
    let edge: MillerHorizontalScrollEdge
}

private let millerDropTargetColor = Color(nsColor: .systemBlue)

func millerDebugLog(_ category: String, _ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["NVMODERN_MILLER_DIAGNOSTICS"] == "1" else { return }
    let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    let line = "[NVModern][Miller][\(uptime)][\(category)] \(message())\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

struct MillerColumnsView: View {
    let columns: [[MillerItem]]
    let lineageFolderChain: [String]
    let lineagePaths: Set<String>
    let activeDepth: Int
    let activeItemPath: String?
    let showActiveSelection: Bool
    let onSelectFolder: (_ depth: Int, _ row: Int, _ relativePath: String) -> Void
    let onSelectNote: (_ depth: Int, _ row: Int, _ relativePath: String) -> Void
    let onOpenNote: (_ relativePath: String) -> Void
    let onOpenNoteInNewTab: (_ relativePath: String) -> Void
    let onShowInFinder: (_ relativePath: String) -> Void
    let onCopyPath: (_ relativePath: String) -> Void
    let onCopyAbsolutePath: (_ relativePath: String) -> Void
    let onRenameItem: (_ relativePath: String, _ kind: MillerItemKind, _ currentName: String) -> Void
    let onDuplicateNote: (_ relativePath: String) -> Void
    let onMoveItemToTrash: (_ relativePath: String, _ kind: MillerItemKind, _ currentName: String) -> Void
    let onCreateNote: () -> Void
    let onCreateNoteInFolder: (_ relativePath: String) -> Void
    let onCreateFolderInFolder: (_ relativePath: String?) -> Void
    let onCreateNoteFromClipboardInFolder: (_ relativePath: String?) -> Void
    let onSearchFolder: (_ relativePath: String?) -> Void
    let onOpenFolderInFinder: (_ relativePath: String?) -> Void
    let onCopyFolderPath: (_ relativePath: String?) -> Void
    let onCopyFolderAbsolutePath: (_ relativePath: String?) -> Void
    let onEditFinderTags: (_ relativePath: String?, _ displayName: String) -> Void
    let onKeyboardFocus: () -> Void
    let onKeyboardTab: () -> Void
    let onMoveCommand: (_ direction: MoveCommandDirection) -> Void
    let isKeyboardFocused: Bool
    /// Whether the browser currently owns the keyboard in its window. Decided by
    /// the host from tab/pane focus rather than SwiftUI focus, which is what
    /// makes arrow keys work without a prior click. See `MillerKeyboardMonitor`.
    let ownsKeyboard: Bool
    let focusRequestID: Int
    let preview: MillerPreviewColumnContent?
    let horizontalScrollRequest: MillerHorizontalScrollRequest
    @ObservedObject var dropRouter: MillerNativeDropRouter
    let selectedPaths: Set<String>
    let workspaceRootURL: URL?
    let shelfItems: [MillerItem]
    let onSelectionGesture: ((_ depth: Int, _ row: Int, _ item: MillerItem, _ gesture: MillerSelectionGesture) -> Void)?
    let onStageItems: (_ relativePaths: [String]) -> Void
    let onRemoveShelfItem: (_ relativePath: String) -> Void
    let onClearShelf: () -> Void
    let onMoveItems: (_ relativePaths: [String], _ destinationFolderPath: String) -> Void
    let onOpenItemsInNewTabs: (_ relativePaths: [String]) -> Void
    let onRevealItems: (_ relativePaths: [String]) -> Void
    let onCopyItemPaths: (_ relativePaths: [String], _ absolute: Bool) -> Void
    let onMoveItemsToTrash: (_ relativePaths: [String]) -> Void

    @FocusState private var hasKeyboardFocus: Bool
    @Binding private var horizontalScrollOrigin: CGFloat
    @State private var handledFocusRequestID: Int
    @State private var maximumObservedColumnCount: Int
    @StateObject private var horizontalScrollCoordinator = MillerHorizontalScrollCoordinator()
    @ObservedObject private var sortPreferences = MillerSortPreferences.shared

    /// One width for every column in both modes. Details mode changes what a
    /// row shows, never how wide the column is, so arrow navigation does not
    /// reflow the browser.
    private let columnWidth: CGFloat = 240

    private var reservedColumnCount: Int {
        max(maximumObservedColumnCount, columns.count)
    }

    /// Details mode is a view preference, not per-document state, so it lives in
    /// UserDefaults rather than the persisted session. The View menu toggles the
    /// same key.
    @AppStorage(MillerDetailsPreference.key) private var isDetailsModeEnabled = false

    /// Every real folder column shows details. Column 0 is the synthetic root
    /// list (Workspace / Recent / capture roots) and stays a plain list.
    private func isDetailsColumn(depth: Int) -> Bool {
        isDetailsModeEnabled && depth > 0
    }

    private var sortPreferencesRoot: String {
        workspaceRootURL?.standardizedFileURL.path ?? ""
    }

    private func effectiveSort(forDepth depth: Int) -> MillerDetailsSort {
        MillerDetailsSortResolver.effectiveSort(chain: lineageFolderChain, depth: depth) { folderKey in
            sortPreferences.override(root: sortPreferencesRoot, folderKey: folderKey)
        }
    }

    /// Clicking a header adjusts the sort the column is currently showing,
    /// inherited or not, and records the result as this folder's override.
    private func selectSortField(_ field: MillerDetailsSortField, depth: Int) {
        guard let folderKey = MillerDetailsSortResolver.folderKey(chain: lineageFolderChain, depth: depth) else {
            return
        }
        var sort = effectiveSort(forDepth: depth)
        sort.select(field)
        sortPreferences.setOverride(sort, root: sortPreferencesRoot, folderKey: folderKey)
    }

    init(
        columns: [[MillerItem]],
        lineageFolderChain: [String],
        lineagePaths: Set<String>,
        activeDepth: Int,
        activeItemPath: String?,
        showActiveSelection: Bool,
        onSelectFolder: @escaping (_ depth: Int, _ row: Int, _ relativePath: String) -> Void,
        onSelectNote: @escaping (_ depth: Int, _ row: Int, _ relativePath: String) -> Void,
        onOpenNote: @escaping (_ relativePath: String) -> Void = { _ in },
        onOpenNoteInNewTab: @escaping (_ relativePath: String) -> Void,
        onShowInFinder: @escaping (_ relativePath: String) -> Void,
        onCopyPath: @escaping (_ relativePath: String) -> Void,
        onCopyAbsolutePath: @escaping (_ relativePath: String) -> Void,
        onRenameItem: @escaping (_ relativePath: String, _ kind: MillerItemKind, _ currentName: String) -> Void,
        onDuplicateNote: @escaping (_ relativePath: String) -> Void,
        onMoveItemToTrash: @escaping (_ relativePath: String, _ kind: MillerItemKind, _ currentName: String) -> Void,
        onCreateNote: @escaping () -> Void,
        onCreateNoteInFolder: @escaping (_ relativePath: String) -> Void,
        onCreateFolderInFolder: @escaping (_ relativePath: String?) -> Void,
        onCreateNoteFromClipboardInFolder: @escaping (_ relativePath: String?) -> Void,
        onSearchFolder: @escaping (_ relativePath: String?) -> Void,
        onOpenFolderInFinder: @escaping (_ relativePath: String?) -> Void,
        onCopyFolderPath: @escaping (_ relativePath: String?) -> Void,
        onCopyFolderAbsolutePath: @escaping (_ relativePath: String?) -> Void,
        onEditFinderTags: @escaping (_ relativePath: String?, _ displayName: String) -> Void,
        onKeyboardFocus: @escaping () -> Void,
        onKeyboardTab: @escaping () -> Void = {},
        onMoveCommand: @escaping (_ direction: MoveCommandDirection) -> Void,
        isKeyboardFocused: Bool,
        ownsKeyboard: Bool = true,
        focusRequestID: Int = 0,
        preview: MillerPreviewColumnContent? = nil,
        horizontalScrollRequest: MillerHorizontalScrollRequest = .init(id: 0, edge: .left),
        horizontalScrollOrigin: Binding<CGFloat> = .constant(0),
        dropRouter: MillerNativeDropRouter,
        selectedPaths: Set<String> = [],
        workspaceRootURL: URL? = nil,
        shelfItems: [MillerItem] = [],
        onSelectionGesture: ((_ depth: Int, _ row: Int, _ item: MillerItem, _ gesture: MillerSelectionGesture) -> Void)? = nil,
        onStageItems: @escaping (_ relativePaths: [String]) -> Void = { _ in },
        onRemoveShelfItem: @escaping (_ relativePath: String) -> Void = { _ in },
        onClearShelf: @escaping () -> Void = {},
        onMoveItems: @escaping (_ relativePaths: [String], _ destinationFolderPath: String) -> Void = { _, _ in },
        onOpenItemsInNewTabs: @escaping (_ relativePaths: [String]) -> Void = { _ in },
        onRevealItems: @escaping (_ relativePaths: [String]) -> Void = { _ in },
        onCopyItemPaths: @escaping (_ relativePaths: [String], _ absolute: Bool) -> Void = { _, _ in },
        onMoveItemsToTrash: @escaping (_ relativePaths: [String]) -> Void = { _ in }
    ) {
        self.columns = columns
        self.lineageFolderChain = lineageFolderChain
        self.lineagePaths = lineagePaths
        self.activeDepth = activeDepth
        self.activeItemPath = activeItemPath
        self.showActiveSelection = showActiveSelection
        self.onSelectFolder = onSelectFolder
        self.onSelectNote = onSelectNote
        self.onOpenNote = onOpenNote
        self.onOpenNoteInNewTab = onOpenNoteInNewTab
        self.onShowInFinder = onShowInFinder
        self.onCopyPath = onCopyPath
        self.onCopyAbsolutePath = onCopyAbsolutePath
        self.onRenameItem = onRenameItem
        self.onDuplicateNote = onDuplicateNote
        self.onMoveItemToTrash = onMoveItemToTrash
        self.onCreateNote = onCreateNote
        self.onCreateNoteInFolder = onCreateNoteInFolder
        self.onCreateFolderInFolder = onCreateFolderInFolder
        self.onCreateNoteFromClipboardInFolder = onCreateNoteFromClipboardInFolder
        self.onSearchFolder = onSearchFolder
        self.onOpenFolderInFinder = onOpenFolderInFinder
        self.onCopyFolderPath = onCopyFolderPath
        self.onCopyFolderAbsolutePath = onCopyFolderAbsolutePath
        self.onEditFinderTags = onEditFinderTags
        self.onKeyboardFocus = onKeyboardFocus
        self.onKeyboardTab = onKeyboardTab
        self.onMoveCommand = onMoveCommand
        self.isKeyboardFocused = isKeyboardFocused
        self.ownsKeyboard = ownsKeyboard
        self.focusRequestID = focusRequestID
        self.preview = preview
        self.horizontalScrollRequest = horizontalScrollRequest
        self._horizontalScrollOrigin = horizontalScrollOrigin
        self.dropRouter = dropRouter
        self.selectedPaths = selectedPaths
        self.workspaceRootURL = workspaceRootURL
        self.shelfItems = shelfItems
        self.onSelectionGesture = onSelectionGesture
        self.onStageItems = onStageItems
        self.onRemoveShelfItem = onRemoveShelfItem
        self.onClearShelf = onClearShelf
        self.onMoveItems = onMoveItems
        self.onOpenItemsInNewTabs = onOpenItemsInNewTabs
        self.onRevealItems = onRevealItems
        self.onCopyItemPaths = onCopyItemPaths
        self.onMoveItemsToTrash = onMoveItemsToTrash
        self._handledFocusRequestID = State(initialValue: focusRequestID)
        self._maximumObservedColumnCount = State(initialValue: columns.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            browserAndAccessory

            if let workspaceRootURL {
                MillerDropShelf(
                    items: shelfItems,
                    workspaceRootURL: workspaceRootURL,
                    dropRouter: dropRouter,
                    onStage: onStageItems,
                    onRemove: onRemoveShelfItem,
                    onClear: onClearShelf
                )
            }
        }
        .background(DesignTokens.Surface.base)
        .background(keyboardMonitor)
    }

    @ViewBuilder
    private var browserAndAccessory: some View {
        GeometryReader { geometry in
            let minimumBrowserWidth = min(columnWidth, geometry.size.width * 0.4)
            let idealAccessoryWidth = min(720, max(320, geometry.size.width * 0.58))
            let accessoryWidth = min(
                idealAccessoryWidth,
                max(0, geometry.size.width - minimumBrowserWidth - 1)
            )

            millerBrowser(accessoryWidth: accessoryWidth)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func millerBrowser(accessoryWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { depth, items in
                    column(items: items, depth: depth)
                        .frame(width: columnWidth)

                    if depth < columns.count - 1 {
                        columnDivider
                    }
                }

                Color.clear
                    .frame(
                        width: CGFloat(max(0, reservedColumnCount - columns.count))
                            * (columnWidth + 1)
                    )
                    .accessibilityHidden(true)

                // The accessory is a real sibling of the columns. Its slot
                // remains in the horizontal document when no preview is
                // active, keeping the document width and clip origin stable.
                Group {
                    if selectedItems.count > 1 || preview != nil {
                        HStack(spacing: 0) {
                            columnDivider

                            accessoryColumn
                                .frame(width: accessoryWidth)
                        }
                    } else {
                        Color.clear
                            .frame(width: accessoryWidth + 1)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: accessoryWidth + 1)
            }
            .background {
                MillerHorizontalScrollResolver(
                    coordinator: horizontalScrollCoordinator,
                    activeColumn: max(0, min(activeDepth, max(0, columns.count - 1))),
                    previewPath: preview?.relativePath,
                    columnWidth: columnWidth,
                    accessoryWidth: accessoryWidth + 1,
                    contentWidth: CGFloat(reservedColumnCount) * columnWidth
                        + CGFloat(max(0, reservedColumnCount - 1))
                        + accessoryWidth + 1,
                    scrollRequest: horizontalScrollRequest,
                    horizontalOrigin: $horizontalScrollOrigin
                )
            }
        }
        .background(DesignTokens.Surface.base)
        .onAppear {
            applyKeyboardFocusRequest()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .simultaneousGesture(TapGesture().onEnded {
            hasKeyboardFocus = true
        })
        .onChange(of: hasKeyboardFocus) { _, isFocused in
            guard isFocused else { return }
            onKeyboardFocus()
        }
        .onChange(of: focusRequestID) { _, _ in
            applyKeyboardFocusRequest()
        }
        .onChange(of: columns.count) { _, newCount in
            maximumObservedColumnCount = max(maximumObservedColumnCount, newCount)
        }
    }

    /// Keyboard handling lives outside `millerBrowser` on purpose. The browser
    /// is re-parented under a `GeometryReader` whenever the preview or
    /// multi-selection accessory appears, and that identity change tore down
    /// the old key monitor mid-navigation. Anchoring it to the outer container
    /// keeps one monitor alive across those layout switches.
    private var keyboardMonitor: some View {
        MillerKeyboardMonitor(
            isActive: ownsKeyboard,
            onTab: onKeyboardTab,
            onOpen: {
                preserveHorizontalScrollPosition()
                openActiveSelection()
            },
            onOpenInBackgroundTab: {
                preserveHorizontalScrollPosition()
                openActiveSelectionInBackgroundTab()
            },
            onMove: { direction in
                preserveHorizontalScrollPosition()
                onMoveCommand(direction)
            }
        )
        .frame(width: 0, height: 0)
    }

    @ViewBuilder
    private var accessoryColumn: some View {
        if selectedItems.count > 1 {
            MillerSelectionActionsColumn(
                items: selectedItems,
                onStage: { onStageItems(selectedItems.map(\.relativePath)) },
                onOpenInNewTabs: { onOpenItemsInNewTabs(selectedFilePaths) },
                onRevealInFinder: { onRevealItems(selectedItems.map(\.relativePath)) },
                onCopyRelativePaths: { onCopyItemPaths(selectedItems.map(\.relativePath), false) },
                onCopyAbsolutePaths: { onCopyItemPaths(selectedItems.map(\.relativePath), true) },
                onMoveToTrash: { onMoveItemsToTrash(selectedItems.map(\.relativePath)) }
            )
        } else if let preview {
            MillerPreviewColumn(content: preview)
        }
    }

    private var selectedItems: [MillerItem] {
        columns.flatMap { $0 }.filter { selectedPaths.contains($0.relativePath) }
    }

    private var selectedFilePaths: [String] {
        selectedItems.filter { $0.kind == .note }.map(\.relativePath)
    }

    private func applyKeyboardFocusRequest() {
        guard focusRequestID != handledFocusRequestID else { return }
        handledFocusRequestID = focusRequestID
        adoptKeyboardFocus()
    }

    private func adoptKeyboardFocus() {
        hasKeyboardFocus = true
        onKeyboardFocus()
    }

    private func preserveHorizontalScrollPosition() {
        horizontalScrollCoordinator.captureOrigin(into: $horizontalScrollOrigin)
    }

    // MARK: — single column

    @ViewBuilder
    private func column(items: [MillerItem], depth: Int) -> some View {
        let target = folderActionTarget(forDepth: depth)
        let targetID = "column:\(depth)"
        let isDropTargeted = dropRouter.activeTargetID == targetID

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let showsDetails = isDetailsColumn(depth: depth)
                    let sort = effectiveSort(forDepth: depth)

                    if showsDetails {
                        MillerDetailsHeader(sort: sort) { field in
                            selectSortField(field, depth: depth)
                        }
                    }

                    ForEach(Array(items.enumerated()), id: \.element.id) { row, item in
                        rowView(item: item, depth: depth, row: row, showsDetails: showsDetails)
                    }

                    // The synthetic root column lists sources, not folder
                    // contents, so there is nowhere for "New note" to create one.
                    if !(items.first.map({ LaunchpadRootColumn.isSynthetic($0.relativePath) }) ?? false) {
                        folderActionFooter(forDepth: depth)
                            .padding(.horizontal, DesignTokens.Spacing.space3)
                            .padding(.top, DesignTokens.Spacing.space3)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.space2)
            }
            .onAppear {
                scrollRelevantItemIfNeeded(proxy: proxy, depth: depth, items: items)
            }
            .onChange(of: activeItemPath) { _, _ in
                scrollRelevantItemIfNeeded(proxy: proxy, depth: depth, items: items)
            }
            .onChange(of: lineagePaths) { _, _ in
                scrollRelevantItemIfNeeded(proxy: proxy, depth: depth, items: items)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(millerDropTargetColor, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .background {
            MillerNativeDropTarget(
                router: dropRouter,
                targetID: targetID,
                priority: 10,
                isEnabled: true
            ) { payload in
                guard payload.workspaceRootPath == workspaceRootURL?.standardizedFileURL.path else { return }
                onMoveItems(payload.relativePaths, target.relativePath ?? "")
            }
        }
    }

    // MARK: — row

    @ViewBuilder
    private func rowView(item: MillerItem, depth: Int, row: Int, showsDetails: Bool = false) -> some View {
        let isActive: Bool = showActiveSelection
            && depth == activeDepth
            && item.relativePath == activeItemPath
        let isSelected = selectedPaths.contains(item.relativePath)
        let isLineage: Bool = !isActive && lineagePaths.contains(item.relativePath)
        let targetID = "folder:\(item.relativePath)"
        let isDropTargeted = dropRouter.activeTargetID == targetID

        MillerColumnRow(
            item: item,
            isActive: isActive,
            isSelected: isSelected,
            isLineage: isLineage,
            isKeyboardFocused: isKeyboardFocused,
            iconName: iconName(for: item),
            details: showsDetails ? MillerRowDetails(item: item) : nil,
            onSelect: { gesture in
                millerDebugLog(
                    "Selection",
                    "dispatch depth=\(depth) row=\(row) kind=\(item.kind) gesture=\(gesture) path=\(item.relativePath)"
                )
                preserveHorizontalScrollPosition()
                adoptKeyboardFocus()
                if let onSelectionGesture {
                    onSelectionGesture(depth, row, item, gesture)
                } else if item.kind == .folder {
                    onSelectFolder(depth, row, item.relativePath)
                } else {
                    onSelectNote(depth, row, item.relativePath)
                }
            },
            onOpen: {
                preserveHorizontalScrollPosition()
                adoptKeyboardFocus()
                if item.kind == .folder {
                    onSelectFolder(depth, row, item.relativePath)
                } else {
                    onOpenNote(item.relativePath)
                }
            },
            dragItemProvider: {
                dragItemProvider(for: item)
            },
            isDropTargeted: isDropTargeted
        )
        .background {
            if item.kind == .folder {
                MillerNativeDropTarget(
                    router: dropRouter,
                    targetID: targetID,
                    priority: 20,
                    isEnabled: true
                ) { payload in
                    guard payload.workspaceRootPath == workspaceRootURL?.standardizedFileURL.path else { return }
                    onMoveItems(payload.relativePaths, item.relativePath)
                }
            }
        }
        .help(
            item.kind == .folder
                ? "Open \(item.name). Drop workspace items here to move them."
                : item.name
        )
        // Rows in the synthetic root column have no file behind them, so every
        // item on this menu — rename, move to trash, reveal, copy path — would
        // act on a path that does not exist.
        .contextMenu {
            if LaunchpadRootColumn.isSynthetic(item.relativePath) {
                EmptyView()
            } else {
                WorkspaceItemContextMenu(
                kind: item.kind,
                relativePath: item.relativePath,
                displayName: item.name,
                onOpen: {
                    if item.kind == .folder {
                        onSelectFolder(depth, row, item.relativePath)
                    } else {
                        onOpenNote(item.relativePath)
                    }
                },
                onOpenInNewTab: item.kind == .note ? {
                    onOpenNoteInNewTab(item.relativePath)
                } : nil,
                onShowInFinder: {
                    onShowInFinder(item.relativePath)
                },
                onOpenFolderInFinder: item.kind == .folder ? {
                    onOpenFolderInFinder(item.relativePath)
                } : nil,
                onCopyPath: {
                    onCopyPath(item.relativePath)
                },
                onCopyAbsolutePath: {
                    onCopyAbsolutePath(item.relativePath)
                },
                onRename: {
                    onRenameItem(item.relativePath, item.kind, item.name)
                },
                onDuplicate: item.kind == .note ? {
                    onDuplicateNote(item.relativePath)
                } : nil,
                onTrash: {
                    onMoveItemToTrash(item.relativePath, item.kind, item.name)
                },
                onCreateNoteInFolder: item.kind == .folder ? {
                    onCreateNoteInFolder(item.relativePath)
                } : nil,
                onCreateFolderInFolder: item.kind == .folder ? {
                    onCreateFolderInFolder(item.relativePath)
                } : nil,
                onCreateNoteFromClipboardInFolder: item.kind == .folder ? {
                    onCreateNoteFromClipboardInFolder(item.relativePath)
                } : nil,
                onSearchInFolder: item.kind == .folder ? {
                    onSearchFolder(item.relativePath)
                } : nil,
                onEditFinderTags: {
                    onEditFinderTags(item.relativePath, item.name)
                }
                )
            }
        }
        .id(item.relativePath)
    }

    private func dragItemProvider(for item: MillerItem) -> NSItemProvider {
        guard let workspaceRootURL else { return NSItemProvider() }
        let dragItems = selectedPaths.contains(item.relativePath) && !selectedItems.isEmpty
            ? selectedItems
            : [item]
        let paths = dragItems.map(\.relativePath)
        let payload = MillerDragPayload(
            workspaceRootPath: workspaceRootURL.standardizedFileURL.path,
            relativePaths: paths
        )
        guard let payloadData = try? JSONEncoder().encode(payload) else {
            return NSItemProvider()
        }

        dropRouter.beginDrag(payload)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: MillerDragPayload.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(payloadData, nil)
            return nil
        }
        provider.suggestedName = dragItems.count == 1
            ? dragItems[0].name
            : "\(dragItems.count) workspace items"
        millerDebugLog(
            "Drag",
            "provider created source=row item=\(item.relativePath) paths=\(paths) types=\(provider.registeredTypeIdentifiers)"
        )
        return provider
    }

    private func activeSelection() -> (item: MillerItem, row: Int)? {
        guard columns.indices.contains(activeDepth),
              let activeItemPath else { return nil }
        guard let row = columns[activeDepth].firstIndex(where: { $0.relativePath == activeItemPath }) else {
            return nil
        }
        return (columns[activeDepth][row], row)
    }

    private func openActiveSelection() {
        guard let selection = activeSelection() else { return }
        if selection.item.kind == .folder {
            onSelectFolder(activeDepth, selection.row, selection.item.relativePath)
        } else {
            onOpenNote(selection.item.relativePath)
        }
    }

    private func openActiveSelectionInBackgroundTab() {
        guard let selection = activeSelection() else { return }
        if selection.item.kind == .folder {
            onSelectFolder(activeDepth, selection.row, selection.item.relativePath)
        } else {
            onOpenNoteInNewTab(selection.item.relativePath)
        }
    }

    // MARK: — footer folder actions

    private func folderActionFooter(forDepth depth: Int) -> some View {
        // Column at depth N shows children of lineageFolderChain[N-1]
        // (root for N == 0). Folder actions should target that parent.
        let target = folderActionTarget(forDepth: depth)

        return MillerColumnActionFooter(
            target: target,
            onCreateNote: {
                adoptKeyboardFocus()
                if let parentFolder = target.relativePath {
                    onCreateNoteInFolder(parentFolder)
                } else {
                    onCreateNote()
                }
            },
            onCreateFolder: {
                adoptKeyboardFocus()
                onCreateFolderInFolder(target.relativePath)
            },
            onCreateNoteFromClipboard: {
                adoptKeyboardFocus()
                onCreateNoteFromClipboardInFolder(target.relativePath)
            },
            onSearchInFolder: {
                adoptKeyboardFocus()
                onSearchFolder(target.relativePath)
            },
            onOpenFolderInFinder: {
                adoptKeyboardFocus()
                onOpenFolderInFinder(target.relativePath)
            },
            onCopyRelativePath: {
                adoptKeyboardFocus()
                onCopyFolderPath(target.relativePath)
            },
            onCopyAbsolutePath: {
                adoptKeyboardFocus()
                onCopyFolderAbsolutePath(target.relativePath)
            },
            onEditFinderTags: {
                adoptKeyboardFocus()
                onEditFinderTags(target.relativePath, target.displayName)
            }
        )
    }

    private func folderActionTarget(forDepth depth: Int) -> WorkspaceFolderActionTarget {
        guard depth > 0 else {
            return WorkspaceFolderActionTarget(relativePath: nil, displayName: "Workspace Root")
        }

        let parentIndex = depth - 1
        guard parentIndex < lineageFolderChain.count else {
            return WorkspaceFolderActionTarget(relativePath: nil, displayName: "Workspace Root")
        }

        let relativePath = lineageFolderChain[parentIndex]
        let displayName = (relativePath as NSString).lastPathComponent
        return WorkspaceFolderActionTarget(
            relativePath: relativePath,
            displayName: displayName.isEmpty ? "Workspace Root" : displayName
        )
    }

    // MARK: — divider between columns

    private var columnDivider: some View {
        Rectangle()
            .fill(DesignTokens.TextStyle.tertiary.opacity(0.25))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    // MARK: — icon selection

    private func iconName(for item: MillerItem) -> String {
        guard item.kind == .note else {
            return "folder"
        }

        let ext = (item.relativePath as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf":
            return "doc.richtext"
        case "csv":
            return "tablecells"
        case "excalidraw":
            return "scribble.variable"
        case "html":
            return "globe"
        case "epub":
            return "book.closed"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "svg":
            return "photo"
        case "md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline":
            return "doc.text"
        default:
            return "doc"
        }
    }

    // MARK: — scroll sync

    private func scrollRelevantItemIfNeeded(proxy: ScrollViewProxy, depth: Int, items: [MillerItem]) {
        let targetPath: String?

        if depth == activeDepth {
            targetPath = activeItemPath
        } else if depth < lineageFolderChain.count {
            targetPath = lineageFolderChain[depth]
        } else {
            targetPath = nil
        }

        guard let targetPath,
              items.contains(where: { $0.relativePath == targetPath }) else {
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(targetPath)
        }
    }
}

// MARK: — horizontal scroll preservation

enum MillerHorizontalScrollGeometry {
    static func revealedOrigin(
        currentOrigin: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        targetMinX: CGFloat,
        targetMaxX: CGFloat
    ) -> CGFloat {
        let maximumOrigin = max(0, contentWidth - viewportWidth)
        let clampedCurrentOrigin = min(max(0, currentOrigin), maximumOrigin)
        guard viewportWidth > 0 else { return clampedCurrentOrigin }

        let targetWidth = max(0, targetMaxX - targetMinX)
        let proposedOrigin: CGFloat
        if targetWidth >= viewportWidth {
            proposedOrigin = targetMinX
        } else if targetMinX < clampedCurrentOrigin {
            proposedOrigin = targetMinX
        } else if targetMaxX > clampedCurrentOrigin + viewportWidth {
            proposedOrigin = targetMaxX - viewportWidth
        } else {
            return clampedCurrentOrigin
        }

        return min(max(0, proposedOrigin), maximumOrigin)
    }
}

private final class MillerHorizontalScrollCoordinator: ObservableObject {
    private struct RevealTarget: Equatable {
        let activeColumn: Int
        let previewPath: String?
    }

    private weak var scrollView: NSScrollView?
    private weak var observedClipView: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private var horizontalOrigin: Binding<CGFloat>?
    private var isRestoringOrigin = false
    private var pendingOrigin: CGFloat?
    private var preservationGeneration = 0
    private var handledScrollRequestID = 0
    private var lastRevealTarget: RevealTarget?

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func captureOrigin(into horizontalOrigin: Binding<CGFloat>) {
        guard let scrollView else { return }
        self.horizontalOrigin = horizontalOrigin
        let origin = scrollView.contentView.bounds.origin.x
        pendingOrigin = origin
        preservationGeneration += 1
        isRestoringOrigin = true
        horizontalOrigin.wrappedValue = origin
    }

    func attach(
        scrollView: NSScrollView,
        activeColumn: Int,
        previewPath: String?,
        columnWidth: CGFloat,
        accessoryWidth: CGFloat,
        contentWidth: CGFloat,
        scrollRequest: MillerHorizontalScrollRequest,
        horizontalOrigin: Binding<CGFloat>
    ) {
        let isReplacement = self.scrollView !== scrollView
        let shouldRestore = isReplacement || pendingOrigin != nil
        let preservedOriginX = pendingOrigin ?? horizontalOrigin.wrappedValue
        let revealTarget = RevealTarget(activeColumn: activeColumn, previewPath: previewPath)
        let targetChanged = lastRevealTarget != revealTarget
        let requestsActiveReveal = scrollRequest.edge == .revealActive
            && scrollRequest.id != handledScrollRequestID
        if targetChanged, !isReplacement, pendingOrigin == nil {
            // A semantic navigation that arrives while an older attachment is
            // still settling owns the next position. Cancel that stale restore
            // before it can pull the document back on the following run loop.
            preservationGeneration += 1
            isRestoringOrigin = false
        }
        let generation = preservationGeneration
        let shouldRevealAfterRestore = (targetChanged && !isReplacement) || requestsActiveReveal
        self.scrollView = scrollView
        self.horizontalOrigin = horizontalOrigin
        if isReplacement {
            isRestoringOrigin = true
            observeBounds(of: scrollView.contentView)
            lastRevealTarget = revealTarget
            if !requestsActiveReveal {
                handledScrollRequestID = scrollRequest.id
            }
        }
        if targetChanged {
            lastRevealTarget = revealTarget
        }
        if shouldRestore {
            restoreOrigin(preservedOriginX, in: scrollView, contentWidth: contentWidth)
        }

        if !shouldRestore {
            apply(scrollRequest, in: scrollView, contentWidth: contentWidth)
            if targetChanged {
                reveal(
                    activeColumn: activeColumn,
                    previewPath: previewPath,
                    columnWidth: columnWidth,
                    accessoryWidth: accessoryWidth,
                    contentWidth: contentWidth
                )
            }
        }

        if shouldRestore {
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                guard self.preservationGeneration == generation else { return }
                self.restoreOrigin(preservedOriginX, in: scrollView, contentWidth: contentWidth)
                self.apply(scrollRequest, in: scrollView, contentWidth: contentWidth)
                if shouldRevealAfterRestore {
                    self.reveal(
                        activeColumn: activeColumn,
                        previewPath: previewPath,
                        columnWidth: columnWidth,
                        accessoryWidth: accessoryWidth,
                        contentWidth: contentWidth
                    )
                }
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    guard self.preservationGeneration == generation else { return }
                    self.pendingOrigin = nil
                    self.isRestoringOrigin = false
                    self.horizontalOrigin?.wrappedValue = scrollView.contentView.bounds.origin.x
                }
            }
        }
    }

    private func apply(
        _ request: MillerHorizontalScrollRequest,
        in scrollView: NSScrollView,
        contentWidth: CGFloat
    ) {
        guard request.id != handledScrollRequestID else { return }
        handledScrollRequestID = request.id
        let clipView = scrollView.contentView
        let destination: CGFloat
        switch request.edge {
        case .left:
            destination = 0
        case .right:
            destination = max(0, contentWidth - clipView.bounds.width)
        case .revealActive:
            return
        }
        horizontalOrigin?.wrappedValue = destination
        clipView.scroll(to: NSPoint(x: destination, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func observeBounds(of clipView: NSClipView) {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self, weak clipView] _ in
            guard let self,
                  let clipView,
                  self.observedClipView === clipView,
                  !self.isRestoringOrigin else {
                return
            }
            self.horizontalOrigin?.wrappedValue = clipView.bounds.origin.x
        }
    }

    private func restoreOrigin(
        _ preservedOriginX: CGFloat,
        in scrollView: NSScrollView,
        contentWidth: CGFloat
    ) {
        let clipView = scrollView.contentView
        let maximumOrigin = max(0, contentWidth - clipView.bounds.width)
        let restoredOrigin = min(max(0, preservedOriginX), maximumOrigin)
        clipView.scroll(to: NSPoint(x: restoredOrigin, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func reveal(
        activeColumn: Int,
        previewPath: String?,
        columnWidth: CGFloat,
        accessoryWidth: CGFloat,
        contentWidth: CGFloat
    ) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin.x
        let columnMinX = CGFloat(activeColumn) * (columnWidth + 1)
        let targetMinX: CGFloat
        let targetMaxX: CGFloat
        if previewPath != nil {
            targetMinX = max(columnMinX, contentWidth - accessoryWidth)
            targetMaxX = contentWidth
        } else {
            targetMinX = columnMinX
            targetMaxX = columnMinX + columnWidth
        }
        let destination = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: currentOrigin,
            viewportWidth: clipView.bounds.width,
            contentWidth: contentWidth,
            targetMinX: targetMinX,
            targetMaxX: targetMaxX
        )
        guard abs(destination - currentOrigin) > 0.5 else { return }
        horizontalOrigin?.wrappedValue = destination

        clipView.scroll(to: NSPoint(x: destination, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private struct MillerHorizontalScrollResolver: NSViewRepresentable {
    let coordinator: MillerHorizontalScrollCoordinator
    let activeColumn: Int
    let previewPath: String?
    let columnWidth: CGFloat
    let accessoryWidth: CGFloat
    let contentWidth: CGFloat
    let scrollRequest: MillerHorizontalScrollRequest
    @Binding var horizontalOrigin: CGFloat

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ResolverView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ResolverView) {
        view.coordinator = coordinator
        view.activeColumn = activeColumn
        view.previewPath = previewPath
        view.columnWidth = columnWidth
        view.accessoryWidth = accessoryWidth
        view.contentWidth = contentWidth
        view.scrollRequest = scrollRequest
        view.horizontalOrigin = $horizontalOrigin
        view.resolveScrollView()
    }

    final class ResolverView: NSView {
        weak var coordinator: MillerHorizontalScrollCoordinator?
        var activeColumn = 0
        var previewPath: String?
        var columnWidth: CGFloat = 0
        var accessoryWidth: CGFloat = 0
        var contentWidth: CGFloat = 0
        var scrollRequest = MillerHorizontalScrollRequest(id: 0, edge: .left)
        var horizontalOrigin: Binding<CGFloat> = .constant(0)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScrollView()
        }

        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? NSScrollView {
                        self.coordinator?.attach(
                            scrollView: scrollView,
                            activeColumn: self.activeColumn,
                            previewPath: self.previewPath,
                            columnWidth: self.columnWidth,
                            accessoryWidth: self.accessoryWidth,
                            contentWidth: self.contentWidth,
                            scrollRequest: self.scrollRequest,
                            horizontalOrigin: self.horizontalOrigin
                        )
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

/// Native key routing for the browser.
///
/// The arrow keys used to go through SwiftUI's `.focusable()` + `.onMoveCommand`
/// on the horizontal `ScrollView`. That only fires while SwiftUI focus sits on
/// the scroll view, and nothing reliably put it there: a fresh tab never focused
/// the browser, the preview column's `QLPreviewView`/`WKWebView` grabbed first
/// responder as soon as it loaded, and the old `GeometryReader` re-parenting
/// destroyed the focused hosting view when the preview appeared while
/// `@FocusState` still read `true`, so re-asserting focus was a no-op. The
/// result was arrow keys that worked only after a lucky click.
///
/// A local event monitor sidesteps SwiftUI focus entirely. The host decides
/// whether the browser owns the keyboard (`isActive`), and the monitor only
/// stands down for the responders that genuinely need the keys: text entry
/// (rename sheets, the omnibox field) and web views outside the browser.
private struct MillerKeyboardMonitor: NSViewRepresentable {
    let isActive: Bool
    let onTab: () -> Void
    let onOpen: () -> Void
    let onOpenInBackgroundTab: () -> Void
    let onMove: (_ direction: MoveCommandDirection) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: MonitorView) {
        view.isActive = isActive
        view.onTab = onTab
        view.onOpen = onOpen
        view.onOpenInBackgroundTab = onOpenInBackgroundTab
        view.onMove = onMove
    }

    final class MonitorView: NSView {
        var isActive = false
        var onTab: (() -> Void)?
        var onOpen: (() -> Void)?
        var onOpenInBackgroundTab: (() -> Void)?
        var onMove: ((MoveCommandDirection) -> Void)?
        private var keyMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        private func removeMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        /// Returns `true` when the event was consumed.
        private func handle(_ event: NSEvent) -> Bool {
            guard isActive,
                  WindowEventRouting.shouldHandleLocalEvent(event, in: window),
                  !MillerKeyboardRouting.responderNeedsKeys(window?.firstResponder),
                  let action = MillerKeyboardRouting.action(for: event) else {
                return false
            }

            switch action {
            case .move(let direction):
                onMove?(direction)
            case .tab:
                onTab?()
            case .open:
                onOpen?()
            case .openInBackgroundTab:
                onOpenInBackgroundTab?()
            }
            return true
        }
    }
}

/// The pure key-routing decisions behind `MillerKeyboardMonitor`, split out so
/// they can be unit tested without a window.
enum MillerKeyboardRouting {
    enum Action: Equatable {
        case move(MoveCommandDirection)
        case tab
        case open
        case openInBackgroundTab
    }

    static func action(for event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return action(keyCode: event.keyCode, flags: flags)
    }

    static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
        let meaningfulFlags = flags.subtracting([.function, .numericPad])

        if let direction = moveDirection(forKeyCode: keyCode) {
            // Shift-arrows are passed through as plain moves, matching what
            // `.onMoveCommand` delivered. Option/Command/Control arrows are
            // text-editing and window shortcuts; leave them alone.
            guard meaningfulFlags.isSubset(of: [.shift]) else { return nil }
            return .move(direction)
        }

        if keyCode == 48 {
            return meaningfulFlags.isEmpty ? .tab : nil
        }

        guard keyCode == 36 || keyCode == 76 else { return nil }

        if flags.contains(.command) {
            return .openInBackgroundTab
        }
        return meaningfulFlags.isEmpty ? .open : nil
    }

    private static func moveDirection(forKeyCode keyCode: UInt16) -> MoveCommandDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// Responders that must keep the arrow/Return/Tab keys even while the
    /// browser is the focused surface.
    static func responderNeedsKeys(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }

        // Text entry: rename/new-note sheets, the omnibox field, and any
        // field editor. `NSTextView` covers the field editor that AppKit
        // installs when an `NSTextField` is being edited.
        if view is NSTextView || view is NSTextField {
            return true
        }

        // Web views own their keys — except the browser's own Markdown
        // preview, which only ever grabs first responder as a side effect
        // of loading and should not silence the columns beside it.
        var current: NSView? = view
        while let candidate = current {
            if candidate is WKWebView {
                return !(candidate is MillerPreviewWebView)
            }
            current = candidate.superview
        }

        return false
    }
}

private struct MillerPreviewColumn: View {
    let content: MillerPreviewColumnContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(DesignTokens.TextStyle.tertiary.opacity(0.25))
                .frame(height: 1)
            bodyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Surface.base)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.space3) {
            Image(systemName: content.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.TextStyle.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(DesignTokens.Typography.bodySemibold)
                    .foregroundStyle(DesignTokens.TextStyle.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(content.relativePath)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.TextStyle.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.space4)
        .frame(height: 52, alignment: .center)
    }

    @ViewBuilder
    private var bodyContent: some View {
        Group {
            if Self.htmlTextPreviewExtensions.contains(content.fileURL.pathExtension.lowercased()) {
                MillerMarkdownPreview(fileURL: content.fileURL)
                    .accessibilityLabel("Document preview of \(content.title)")
            } else {
                MillerQuickLookPreview(fileURL: content.fileURL)
                    .accessibilityLabel("Quick Look preview of \(content.title)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .layoutPriority(1)
    }

    private static let htmlTextPreviewExtensions: Set<String> = [
        "markdown", "md", "mdown", "mkd", "mkdn", "org"
    ]
}

private struct MillerQuickLookPreview: NSViewControllerRepresentable {
    let fileURL: URL

    func makeNSViewController(context: Context) -> PreviewController {
        let controller = PreviewController()
        controller.setPreviewItem(fileURL)
        millerDebugLog(
            "QuickLook",
            "make controller=\(ObjectIdentifier(controller)) file=\(fileURL.path)"
        )
        return controller
    }

    func updateNSViewController(_ controller: PreviewController, context: Context) {
        let currentURL = controller.previewURL
        guard currentURL != fileURL else { return }
        millerDebugLog(
            "QuickLook",
            "update controller=\(ObjectIdentifier(controller)) old=\(currentURL?.path ?? "<nil>") new=\(fileURL.path)"
        )
        controller.setPreviewItem(fileURL)
    }

    static func dismantleNSViewController(_ controller: PreviewController, coordinator: ()) {
        controller.close()
    }

    final class PreviewController: NSViewController {
        private let previewView: QLPreviewView
        private var preparedPreviewItem: MillerQuickLookItem?
        private var appliedPreviewURL: URL?

        private(set) var previewURL: URL?

        init() {
            let initialFrame = NSRect(x: 0, y: 0, width: 720, height: 552)
            previewView = QLPreviewView(frame: initialFrame, style: .normal)
                ?? QLPreviewView(frame: initialFrame, style: .compact)!
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            previewView.shouldCloseWithWindow = false
            view = previewView
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            schedulePreviewApplication()
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            applyPreviewIfReady()
        }

        func setPreviewItem(_ fileURL: URL) {
            previewURL = fileURL
            appliedPreviewURL = nil
            preparedPreviewItem = MillerQuickLookItem(fileURL: fileURL)
            millerDebugLog("QuickLook", "prepared source=\(fileURL.path)")
            schedulePreviewApplication()
        }

        func close() {
            previewView.close()
        }

        private func schedulePreviewApplication() {
            DispatchQueue.main.async { [weak self] in
                self?.applyPreviewIfReady()
            }
        }

        private func applyPreviewIfReady() {
            guard let previewURL,
                  let preparedPreviewItem,
                  appliedPreviewURL != previewURL,
                  isViewLoaded,
                  view.window != nil,
                  previewView.bounds.width > 1,
                  previewView.bounds.height > 1 else {
                return
            }

            appliedPreviewURL = previewURL
            previewView.previewItem = preparedPreviewItem
            millerDebugLog(
                "QuickLook",
                "apply controller=\(ObjectIdentifier(self)) file=\(previewURL.path) previewBounds=\(previewView.bounds) appeared=\(view.window != nil)"
            )
        }
    }
}

private final class MillerQuickLookItem: NSObject, QLPreviewItem {
    private let fileURL: URL

    var previewItemURL: URL? { fileURL }
    var previewItemTitle: String? { fileURL.lastPathComponent }

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }
}

private struct MillerSelectionActionsColumn: View {
    let items: [MillerItem]
    let onStage: () -> Void
    let onOpenInNewTabs: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyRelativePaths: () -> Void
    let onCopyAbsolutePaths: () -> Void
    let onMoveToTrash: () -> Void

    private var fileCount: Int { items.filter { $0.kind == .note }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.space5) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.space2) {
                Text("\(items.count) items selected")
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(DesignTokens.TextStyle.primary)
                Text("Drag the selection to a folder, or stage it on the drop shelf while you navigate.")
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: DesignTokens.Spacing.space3
            ) {
                actionButton("Stage on Drop Shelf", icon: "tray.and.arrow.down", action: onStage)
                actionButton(
                    fileCount == 1 ? "Open File in New Tab" : "Open Files in New Tabs",
                    icon: "plus.rectangle.on.rectangle",
                    isDisabled: fileCount == 0,
                    action: onOpenInNewTabs
                )
                actionButton("Reveal in Finder", icon: "finder", action: onRevealInFinder)
                actionButton("Copy Relative Paths", icon: "doc.on.doc", action: onCopyRelativePaths)
                actionButton("Copy Absolute Paths", icon: "link", action: onCopyAbsolutePaths)
                actionButton("Move to Trash", icon: "trash", role: .destructive, action: onMoveToTrash)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.space2) {
                ForEach(items.prefix(10)) { item in
                    HStack(spacing: DesignTokens.Spacing.space3) {
                        Image(systemName: item.kind == .folder ? "folder" : "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.TextStyle.secondary)
                            .frame(width: 16)
                        Text(item.name)
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.TextStyle.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: 28)
                }

                if items.count > 10 {
                    Text("and \(items.count - 10) more")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Surface.base)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: DesignTokens.Spacing.space3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(DesignTokens.Typography.bodySemibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.space4)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .foregroundStyle(role == .destructive ? Color.red : DesignTokens.TextStyle.primary)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                    .fill(DesignTokens.Surface.overlay)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MillerActionButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

private struct MillerActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MillerDropShelf: View {
    let items: [MillerItem]
    let workspaceRootURL: URL
    @ObservedObject var dropRouter: MillerNativeDropRouter
    let onStage: ([String]) -> Void
    let onRemove: (String) -> Void
    let onClear: () -> Void

    private var isDropTargeted: Bool {
        dropRouter.activeTargetID == "shelf"
    }

    private var backgroundFill: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.10) }
        return isEmpty ? Color.clear : DesignTokens.Surface.raised
    }

    private var borderColor: Color {
        if isDropTargeted { return millerDropTargetColor.opacity(0.90) }
        return DesignTokens.TextStyle.tertiary.opacity(isEmpty ? 0.12 : 0.20)
    }

    @ViewBuilder
    private var shelfContent: some View {
        if isEmpty {
            HStack(spacing: DesignTokens.Spacing.space2) {
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .regular))
                Text("Drop Shelf")
                    .font(DesignTokens.Typography.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDropTargeted ? Color.accentColor : DesignTokens.TextStyle.tertiary)
        } else {
            HStack(spacing: DesignTokens.Spacing.space3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(isDropTargeted ? 0.20 : 0.11))
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignTokens.Spacing.space2) {
                        Text("Drop Shelf")
                            .font(DesignTokens.Typography.bodySemibold)
                            .foregroundStyle(DesignTokens.TextStyle.primary)

                        Text("\(items.count) IN TRANSIT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.11))
                            )
                    }
                    Text("Drag this shelf onto a folder to move everything together.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                        .lineLimit(1)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Spacing.space2) {
                        ForEach(items) { item in
                            MillerShelfChip(item: item) {
                                onRemove(item.relativePath)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.space2)
                }
                .frame(height: 48)

                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
                    .frame(minWidth: 40, minHeight: 40)
            }
        }
    }

    private var isEmpty: Bool { items.isEmpty }

    /// Empty, the shelf is a quiet hairline strip. It used to sit at the bottom
    /// of every new tab as a 68pt card with an accent tile, a bold title, a
    /// shadow, and a sentence of instructions — permanent furniture explaining a
    /// feature that was not in use. It only earns that weight once it holds
    /// something.
    var body: some View {
        shelfContent
            .padding(.horizontal, isEmpty ? DesignTokens.Spacing.space3 : DesignTokens.Spacing.space4)
            .frame(
                maxWidth: .infinity,
                minHeight: isEmpty ? 24 : 68,
                maxHeight: isEmpty ? 24 : 68
            )
            .background(
                RoundedRectangle(cornerRadius: isEmpty ? 6 : 14, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isEmpty ? 6 : 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isDropTargeted ? 2 : 1)
            )
            .shadow(
                color: Color.black.opacity(isEmpty ? 0 : 0.10),
                radius: isEmpty ? 0 : 6,
                x: 0,
                y: isEmpty ? 0 : 2
            )
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.Spacing.space4)
            .padding(.vertical, isEmpty ? DesignTokens.Spacing.space2 : DesignTokens.Spacing.space3)
            .background(DesignTokens.Surface.base)
            .help("Drag files or folders here to move them together")
            .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .background {
            MillerNativeDropTarget(
                router: dropRouter,
                targetID: "shelf",
                priority: 30,
                isEnabled: true
            ) { payload in
                guard payload.workspaceRootPath == workspaceRootURL.standardizedFileURL.path else { return }
                onStage(payload.relativePaths)
            }
        }
        .onDrag {
            shelfItemProvider()
        }
    }

    private func shelfItemProvider() -> NSItemProvider {
        guard !items.isEmpty else { return NSItemProvider() }
        let payload = MillerDragPayload(
            workspaceRootPath: workspaceRootURL.standardizedFileURL.path,
            relativePaths: items.map(\.relativePath)
        )
        guard let payloadData = try? JSONEncoder().encode(payload) else {
            return NSItemProvider()
        }
        dropRouter.beginDrag(payload)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: MillerDragPayload.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(payloadData, nil)
            return nil
        }
        provider.suggestedName = items.count == 1 ? items[0].name : "\(items.count) workspace items"
        millerDebugLog(
            "Drag",
            "provider created source=shelf paths=\(items.map(\.relativePath)) types=\(provider.registeredTypeIdentifiers)"
        )
        return provider
    }
}

private struct MillerShelfChip: View {
    let item: MillerItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            Image(systemName: item.kind == .folder ? "folder" : "doc")
                .font(.system(size: 10, weight: .medium))
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from drop shelf")
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.TextStyle.secondary)
        .padding(.leading, DesignTokens.Spacing.space3)
        .padding(.trailing, DesignTokens.Spacing.space2)
        .frame(height: 40)
    }
}

// MARK: — row view

private struct MillerColumnRow: View {
    let item: MillerItem
    let isActive: Bool
    let isSelected: Bool
    let isLineage: Bool
    let isKeyboardFocused: Bool
    let iconName: String
    var details: MillerRowDetails? = nil
    let onSelect: (MillerSelectionGesture) -> Void
    let onOpen: () -> Void
    let dragItemProvider: () -> NSItemProvider
    let isDropTargeted: Bool

    @State private var isHovering = false

    private var rowBackground: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.18)
        }
        if isSelected || isActive {
            return isKeyboardFocused
                ? DesignTokens.Surface.activeSelection
                : DesignTokens.Surface.inactiveSelection
        }
        if isLineage {
            return DesignTokens.Surface.inactiveSelection
        }
        if isHovering {
            return DesignTokens.Surface.overlay
        }
        return Color.clear
    }

    private var titleColor: Color {
        (isSelected || isActive) && isKeyboardFocused ? .white : DesignTokens.TextStyle.primary
    }

    private var iconColor: Color {
        (isSelected || isActive) && isKeyboardFocused ? .white : DesignTokens.TextStyle.secondary
    }

    private var chevronColor: Color {
        (isSelected || isActive) && isKeyboardFocused ? .white.opacity(0.78) : DesignTokens.TextStyle.tertiary
    }

    private var detailColor: Color {
        (isSelected || isActive) && isKeyboardFocused ? .white.opacity(0.85) : DesignTokens.TextStyle.tertiary
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.space3) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: MillerDetailsMetrics.iconWidth, alignment: .center)

            Text(item.name)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if let details {
                Text(details.modified)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .frame(width: MillerDetailsMetrics.modifiedWidth, alignment: .trailing)
                    .help(details.modifiedTooltip ?? "")
            }

            if item.kind == .folder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chevronColor)
                    .frame(width: details == nil ? nil : MillerDetailsMetrics.chevronWidth)
            } else if details != nil {
                // Keep the date column aligned with folder rows.
                Color.clear
                    .frame(width: MillerDetailsMetrics.chevronWidth, height: 1)
            }
        }
        .padding(.leading, DesignTokens.Spacing.space3)
        .padding(.trailing, DesignTokens.Spacing.space3)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.ControlSize.millerCellHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .fill(rowBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .strokeBorder(millerDropTargetColor, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, DesignTokens.Spacing.space2)
        .contentShape(Rectangle())
        .background(
            MillerRowPointerProbe(
                relativePath: item.relativePath,
                onSelect: onSelect,
                onOpen: onOpen
            )
        )
        .onDrag(dragItemProvider)
        .onHover { hovering in
            withAnimation(.linear(duration: DesignTokens.Motion.rowSelectDuration)) {
                isHovering = hovering
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }
}

private struct MillerRowPointerProbe: NSViewRepresentable {
    let relativePath: String
    let onSelect: (MillerSelectionGesture) -> Void
    let onOpen: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ProbeView) {
        view.relativePath = relativePath
        view.onSelect = onSelect
        view.onOpen = onOpen
    }

    final class ProbeView: NSView {
        var relativePath = ""
        var onSelect: ((MillerSelectionGesture) -> Void)?
        var onOpen: (() -> Void)?

        private var mouseMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let hostWindow = self.window,
                      event.window === hostWindow,
                      self.superview != nil else {
                    return event
                }

                let localPoint = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(localPoint) else { return event }

                if event.clickCount == 2 {
                    millerDebugLog("Selection", "mouseDown double path=\(self.relativePath)")
                    self.onOpen?()
                } else if event.clickCount == 1 {
                    let gesture = Self.selectionGesture(for: event.modifierFlags)
                    let ageMilliseconds = max(
                        0,
                        (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000
                    )
                    millerDebugLog(
                        "Selection",
                        "mouseDown select path=\(self.relativePath) gesture=\(gesture) eventAgeMs=\(String(format: "%.3f", ageMilliseconds))"
                    )
                    self.onSelect?(gesture)
                }
                return event
            }
        }

        private func removeMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        private static func selectionGesture(for modifierFlags: NSEvent.ModifierFlags) -> MillerSelectionGesture {
            let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                return .range
            }
            if flags.contains(.command) {
                return .toggle
            }
            return .replace
        }
    }
}

// MARK: — folder action footer row

private struct MillerColumnActionFooter: View {
    let target: WorkspaceFolderActionTarget
    let onCreateNote: () -> Void
    let onCreateFolder: () -> Void
    let onCreateNoteFromClipboard: () -> Void
    let onSearchInFolder: () -> Void
    let onOpenFolderInFinder: () -> Void
    let onCopyRelativePath: () -> Void
    let onCopyAbsolutePath: () -> Void
    let onEditFinderTags: () -> Void

    @State private var isHoveringCreate = false
    @State private var isHoveringMenu = false

    /// Two separate controls rather than one box split by a hairline rule.
    ///
    /// The combined form read as a single button with a seam through it, and the
    /// menu half had no label of its own — only the divider and the arrow that
    /// `.borderlessButton` draws, which is why it looked unfinished.
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            Button(action: onCreateNote) {
                HStack(spacing: DesignTokens.Spacing.space3) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(DesignTokens.TextStyle.secondary)
                        .frame(width: 14, alignment: .center)

                    Text("New file")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.TextStyle.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, DesignTokens.Spacing.space3)
                .padding(.trailing, DesignTokens.Spacing.space2)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.ControlSize.millerCellHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Create a new file in \(target.displayName)")
            .background(footerControlBackground(isHovering: isHoveringCreate))
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.linear(duration: DesignTokens.Motion.rowSelectDuration)) {
                    isHoveringCreate = hovering
                }
            }

            Menu {
                WorkspaceFolderActionMenu(
                    target: target,
                    onCreateNote: onCreateNote,
                    onCreateFolder: onCreateFolder,
                    onCreateNoteFromClipboard: onCreateNoteFromClipboard,
                    onSearchInFolder: onSearchInFolder,
                    onOpenFolderInFinder: onOpenFolderInFinder,
                    onCopyRelativePath: onCopyRelativePath,
                    onCopyAbsolutePath: onCopyAbsolutePath,
                    onEditFinderTags: onEditFinderTags,
                    onRenameFolder: nil,
                    onMoveFolderToTrash: nil
                )
            } label: {
                // Deliberately unlabelled. `.borderlessButton` draws its own
                // arrow at the label's trailing edge, so a wide label pushed the
                // caret right of centre; a zero-width label centred in the box
                // puts the caret in the middle, and adding a chevron here would
                // yield two of them.
                Color.clear
                    .frame(width: 0, height: DesignTokens.ControlSize.millerCellHeight)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .fixedSize()
            .frame(width: 30, height: DesignTokens.ControlSize.millerCellHeight)
            .help("More folder actions")
            .background(footerControlBackground(isHovering: isHoveringMenu))
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.linear(duration: DesignTokens.Motion.rowSelectDuration)) {
                    isHoveringMenu = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: DesignTokens.ControlSize.millerCellHeight, alignment: .leading)
    }

    /// A soft fill rather than a dashed outline. The dashes read as a
    /// placeholder or a drop zone, and two dashed boxes side by side were the
    /// heaviest thing in an otherwise quiet column.
    private func footerControlBackground(isHovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
            .fill(
                isHovering
                    ? DesignTokens.Surface.overlay
                    : DesignTokens.TextStyle.tertiary.opacity(0.07)
            )
    }
}

// MARK: — previews

#if DEBUG

private enum MillerPreviewData {
    static let columns: [[MillerItem]] = [
        [
            MillerItem(relativePath: "10-Workspaces", name: "10-Workspaces", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "20-Records", name: "20-Records", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "00-Capture", name: "00-Capture", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "readme.md", name: "readme.md", kind: .note, modifiedDate: nil),
        ],
        [
            MillerItem(relativePath: "10-Workspaces/23-Market-Research", name: "23-Market-Research", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/11-Claude-Code", name: "11-Claude-Code", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/overview.md", name: "overview.md", kind: .note, modifiedDate: nil),
        ],
        [
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book", name: "12-Claude-Book", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/weekly.md", name: "weekly.md", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/vol-notes.md", name: "vol-notes.md", kind: .note, modifiedDate: nil),
        ],
        [
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/01_foundations.md", name: "01_foundations.md", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/02_black_scholes.md", name: "02_black_scholes.md", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/03_greeks.md", name: "03_greeks.md", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/04_why_bs_breaks.md", name: "04_why_bs_breaks.md", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/image.png", name: "image.png", kind: .note, modifiedDate: nil),
            MillerItem(relativePath: "10-Workspaces/23-Market-Research/12-Claude-Book/datasheet.csv", name: "datasheet.csv", kind: .note, modifiedDate: nil),
        ],
    ]

    static let lineageChain: [String] = [
        "10-Workspaces",
        "10-Workspaces/23-Market-Research",
        "10-Workspaces/23-Market-Research/12-Claude-Book",
    ]

    static let lineageSet: Set<String> = Set(lineageChain)
    @MainActor static let dropRouter = MillerNativeDropRouter()

    @MainActor
    static func makeView(isKeyboardFocused: Bool) -> MillerColumnsView {
        MillerColumnsView(
            columns: columns,
            lineageFolderChain: lineageChain,
            lineagePaths: lineageSet,
            activeDepth: 3,
            activeItemPath: "10-Workspaces/23-Market-Research/12-Claude-Book/03_greeks.md",
            showActiveSelection: true,
            onSelectFolder: { _, _, _ in },
            onSelectNote: { _, _, _ in },
            onOpenNoteInNewTab: { _ in },
            onShowInFinder: { _ in },
            onCopyPath: { _ in },
            onCopyAbsolutePath: { _ in },
            onRenameItem: { _, _, _ in },
            onDuplicateNote: { _ in },
            onMoveItemToTrash: { _, _, _ in },
            onCreateNote: {},
            onCreateNoteInFolder: { _ in },
            onCreateFolderInFolder: { _ in },
            onCreateNoteFromClipboardInFolder: { _ in },
            onSearchFolder: { _ in },
            onOpenFolderInFinder: { _ in },
            onCopyFolderPath: { _ in },
            onCopyFolderAbsolutePath: { _ in },
            onEditFinderTags: { _, _ in },
            onKeyboardFocus: {},
            onMoveCommand: { _ in },
            isKeyboardFocused: isKeyboardFocused,
            dropRouter: dropRouter
        )
    }
}

#Preview("Miller Columns — keyboard-focused") {
    MillerPreviewData.makeView(isKeyboardFocused: true)
        .frame(width: 980, height: 520)
        .background(DesignTokens.Surface.base)
}

#Preview("Miller Columns — inactive focus") {
    MillerPreviewData.makeView(isKeyboardFocused: false)
        .frame(width: 980, height: 520)
        .background(DesignTokens.Surface.base)
}

#Preview("Miller Columns — single column") {
    MillerColumnsView(
        columns: [MillerPreviewData.columns[0]],
        lineageFolderChain: [],
        lineagePaths: [],
        activeDepth: 0,
        activeItemPath: "20-Records",
        showActiveSelection: true,
        onSelectFolder: { _, _, _ in },
        onSelectNote: { _, _, _ in },
        onOpenNoteInNewTab: { _ in },
        onShowInFinder: { _ in },
        onCopyPath: { _ in },
        onCopyAbsolutePath: { _ in },
        onRenameItem: { _, _, _ in },
        onDuplicateNote: { _ in },
        onMoveItemToTrash: { _, _, _ in },
        onCreateNote: {},
        onCreateNoteInFolder: { _ in },
        onCreateFolderInFolder: { _ in },
        onCreateNoteFromClipboardInFolder: { _ in },
        onSearchFolder: { _ in },
        onOpenFolderInFinder: { _ in },
        onCopyFolderPath: { _ in },
        onCopyFolderAbsolutePath: { _ in },
        onEditFinderTags: { _, _ in },
        onKeyboardFocus: {},
        onMoveCommand: { _ in },
        isKeyboardFocused: true,
        dropRouter: MillerPreviewData.dropRouter
    )
    .frame(width: 280, height: 420)
    .background(DesignTokens.Surface.base)
}

#endif
