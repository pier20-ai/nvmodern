import Foundation

enum WorkspaceActionOpenDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case currentTab
    case newTab
    case backgroundTab
}

enum WorkspaceActionDocumentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceNote
    case externalMarkdown
    case clipboardMarkdown
    case diff
}

enum WorkspaceEditorCommandSurfaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case folder
    case pdf
    case csv
    case canvas
    case image
    case html
    case epub
    case diff
    case unsupported
}

struct WorkspaceActionDocumentSnapshot: Codable, Hashable, Sendable {
    let kind: WorkspaceActionDocumentKind
    let title: String
    let relativePath: String?
    let absolutePath: String?
    let projectRootPath: String
    let windowID: String
    let workspaceID: String
    let tabID: String?
    let isEditable: Bool
}

struct WorkspaceActionNoteCreateResult: Codable, Hashable, Sendable {
    let relativePath: String
    let absolutePath: String
    let projectRootPath: String
    let wasOpened: Bool
    let windowID: String?
    let workspaceID: String?
    let tabID: String?
}

struct WorkspaceActionNoteMoveResult: Codable, Hashable, Sendable {
    let oldRelativePath: String
    let relativePath: String
    let absolutePath: String
    let projectRootPath: String
    let windowID: String
    let workspaceID: String
    let tabID: String?
}

struct WorkspaceEditorCommandTargetSnapshot: Codable, Hashable, Sendable {
    let surfaceKind: WorkspaceEditorCommandSurfaceKind
    let title: String
    let path: String?
    let isEditable: Bool
    let supportsSelectionReplacement: Bool
}

struct WorkspaceActionProjectSnapshot: Codable, Hashable, Sendable {
    var name: String
    var rootPath: String
}

struct WorkspaceActionTabSnapshot: Codable, Hashable, Sendable {
    var tabID: String
    var kind: String
    var title: String
    var selected: Bool
    var relativePath: String?
}

struct WorkspaceActionSearchHit: Codable, Hashable, Sendable {
    var title: String
    var relativePath: String
    var snippet: String
    var score: Int
}

struct WorkspaceEditorTextSlice: Codable, Hashable, Sendable {
    var startLine: Int
    var endLine: Int
    var text: String
    var truncated: Bool
}

struct WorkspaceEditorSelectionSnapshot: Codable, Hashable, Sendable {
    var text: String
    var startLine: Int?
    var endLine: Int?
    var empty: Bool
    /// 1-based pages, for a selection in a PDF.
    var startPage: Int? = nil
    var endPage: Int? = nil
}

struct WorkspaceEditorCursorSnapshot: Codable, Hashable, Sendable {
    var line: Int
    var column: Int
    var startLine: Int
    var endLine: Int
    var text: String
    var truncated: Bool
}

struct WorkspaceEditorContextSnapshot: Codable, Hashable, Sendable {
    var path: String?
    var title: String?
    var surface: String
    var selection: WorkspaceEditorSelectionSnapshot?
    var viewport: WorkspaceEditorTextSlice?
    var cursor: WorkspaceEditorCursorSnapshot?
}

struct WorkspaceActionContextSnapshot: Codable, Hashable, Sendable {
    var project: WorkspaceActionProjectSnapshot
    var document: WorkspaceActionDocumentSnapshot?
    var surface: String
    var tabs: [WorkspaceActionTabSnapshot]
    var viewport: WorkspaceEditorTextSlice?
    var selection: WorkspaceEditorSelectionSnapshot?
    var cursor: WorkspaceEditorCursorPosition?
}

struct WorkspaceEditorCursorPosition: Codable, Hashable, Sendable {
    var line: Int
    var column: Int
}

struct WorkspaceEditorContextQuery: Hashable, Sendable {
    var includeSelection: Bool
    var includeViewport: Bool
    var includeCursor: Bool
    var radiusLines: Int
    var maxChars: Int

    static let selection = WorkspaceEditorContextQuery(
        includeSelection: true,
        includeViewport: false,
        includeCursor: false,
        radiusLines: 12,
        maxChars: 4000
    )

    static let cursorNeighborhood = WorkspaceEditorContextQuery(
        includeSelection: true,
        includeViewport: false,
        includeCursor: true,
        radiusLines: 12,
        maxChars: 2000
    )

    static let currentContext = WorkspaceEditorContextQuery(
        includeSelection: true,
        includeViewport: true,
        includeCursor: true,
        radiusLines: 12,
        maxChars: 8000
    )
}

@MainActor
protocol WorkspaceActionRuntime: AnyObject {
    var windowNumber: Int { get }
    var windowID: String { get }
    var workspaceID: String { get }
    var projectRootPath: String { get }
    var orderedTabIDs: [String] { get }
    var selectedTabID: String? { get }
    var isSidebarVisible: Bool { get }

    func containsTab(publicID: String) -> Bool
    func closeCurrentTab()
    func newTab()
    func splitHorizontally()
    func splitVertically()
    func focusPreviousSplit()
    func focusNextSplit()
    func selectTab(publicID: String) -> Bool
    func selectPreviousTab()
    func selectNextTab()
    func setSidebarVisible(_ isVisible: Bool)
    func cycleTabSwitcher(reverse: Bool) -> Bool
    func commitTabSwitcher() -> Bool
    func cancelTabSwitcher() -> Bool
    func duplicateCurrentTab()
    func showAllTabs()
    func presentNewNotePanel(inFolderRelativePath folderRelativePath: String?)
    func focusDocument(_ document: WorkspaceOpenedDocument) -> Bool
    func openDocument(_ document: WorkspaceOpenedDocument, disposition: WorkspaceActionOpenDisposition)
    func showInParentFolder(relativePath: String, selectDocument: Bool) -> Bool
    func revealCurrentDocumentInFinder() -> Bool
    func copyCurrentDocumentLink() -> Bool
    func duplicateCurrentWorkspaceNote() throws -> WorkspaceActionNoteCreateResult?
    func refileCurrentWorkspaceNote(toFolderRelativePath folderRelativePath: String?) throws -> WorkspaceActionNoteMoveResult?
    /// Moves a named workspace note, with the same post-move bookkeeping as
    /// the current-note path. The palette uses it to refile a noun that is not
    /// the open document, once per member of a multi-select batch.
    func refileWorkspaceNote(
        relativePath: String,
        toFolderRelativePath folderRelativePath: String?
    ) throws -> WorkspaceActionNoteMoveResult?
    /// Renames a workspace note or folder and applies the window-level
    /// follow-up: open tabs, history, Miller selection, and any diff selection
    /// follow the item. Returns the new workspace-relative path.
    func renameWorkspaceItem(relativePath: String, to newName: String) throws -> String
    func reloadCurrentDocumentFromDisk() -> Bool
    func currentDocumentInspectorSettings() -> DocumentInspectorSettings?
    func setCurrentDocumentInspectorSettings(_ settings: DocumentInspectorSettings) -> Bool
    func currentDocumentSnapshot() -> WorkspaceActionDocumentSnapshot?
    func currentEditorCommandTargetSnapshot() -> WorkspaceEditorCommandTargetSnapshot?
    func currentProjectSnapshot() -> WorkspaceActionProjectSnapshot
    func listTabs() -> [WorkspaceActionTabSnapshot]
    func queryEditorContext(_ query: WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot?
    func currentDiffOriginalSource() -> WorkspaceDiffSource?
    func setCurrentDiffOriginalSource(_ source: WorkspaceDiffSource?)
    @discardableResult func replaceCurrentEditorSelection(with text: String) -> Bool
    @discardableResult func toggleCurrentEditorSelectionHighlight() -> Bool
    @discardableResult func performCurrentEditorBridgeCommand(
        _ command: String,
        payload: [String: ActionValue]
    ) -> Bool
    func createNote(
        inFolderRelativePath folderRelativePath: String?,
        fileName: String,
        body: String?,
        open: Bool,
        disposition: WorkspaceActionOpenDisposition
    ) throws -> WorkspaceActionNoteCreateResult
    func jumpInCurrentDocument(heading: String?, line: Int?)
    /// Sends an annotation request to the selected tab's text editor. Nil
    /// means no text editor is showing the selected tab's document yet.
    func performEditorAnnotationRequest(_ request: [String: ActionValue]) async -> ActionValue?
    /// The selected tab's side stack (ticket 0031), when the runtime has one.
    func sideStackController() -> SideStackController?
}

extension WorkspaceActionRuntime {
    func sideStackController() -> SideStackController? { nil }
    func currentDocumentInspectorSettings() -> DocumentInspectorSettings? { nil }
    func setCurrentDocumentInspectorSettings(_ settings: DocumentInspectorSettings) -> Bool { false }

    @discardableResult
    func performCurrentEditorBridgeCommand(_ command: String) -> Bool {
        performCurrentEditorBridgeCommand(command, payload: [:])
    }
}

@MainActor
final class ClosureWorkspaceActionRuntime: WorkspaceActionRuntime {
    let windowNumber: Int
    let windowID: String
    let workspaceID: String

    private let projectRootPathProvider: () -> String
    private let orderedTabIDsProvider: () -> [String]
    private let selectedTabIDProvider: () -> String?
    private let sidebarVisibleProvider: () -> Bool
    private let closeCurrentTabHandler: () -> Void
    private let newTabHandler: () -> Void
    private let splitHorizontallyHandler: () -> Void
    private let splitVerticallyHandler: () -> Void
    private let focusPreviousSplitHandler: () -> Void
    private let focusNextSplitHandler: () -> Void
    private let selectTabHandler: (String) -> Bool
    private let selectPreviousTabHandler: () -> Void
    private let selectNextTabHandler: () -> Void
    private let setSidebarVisibleHandler: (Bool) -> Void
    private let cycleTabSwitcherHandler: (Bool) -> Bool
    private let commitTabSwitcherHandler: () -> Bool
    private let cancelTabSwitcherHandler: () -> Bool
    private let duplicateCurrentTabHandler: () -> Void
    private let showAllTabsHandler: () -> Void
    private let presentNewNotePanelHandler: (String?) -> Void
    private let focusDocumentHandler: (WorkspaceOpenedDocument) -> Bool
    private let openDocumentHandler: (WorkspaceOpenedDocument, WorkspaceActionOpenDisposition) -> Void
    private let showInParentFolderHandler: (String, Bool) -> Bool
    private let revealCurrentDocumentInFinderHandler: () -> Bool
    private let copyCurrentDocumentLinkHandler: () -> Bool
    private let duplicateCurrentWorkspaceNoteHandler: () throws -> WorkspaceActionNoteCreateResult?
    private let refileCurrentWorkspaceNoteHandler: (String?) throws -> WorkspaceActionNoteMoveResult?
    private let refileWorkspaceNoteHandler: (String, String?) throws -> WorkspaceActionNoteMoveResult?
    private let renameWorkspaceItemHandler: (String, String) throws -> String
    private let reloadCurrentDocumentFromDiskHandler: () -> Bool
    private let documentInspectorSettingsProvider: () -> DocumentInspectorSettings?
    private let documentInspectorSettingsHandler: (DocumentInspectorSettings) -> Bool
    private let currentDocumentSnapshotProvider: () -> WorkspaceActionDocumentSnapshot?
    private let currentEditorCommandTargetSnapshotProvider: () -> WorkspaceEditorCommandTargetSnapshot?
    private let currentProjectSnapshotProvider: () -> WorkspaceActionProjectSnapshot
    private let listTabsProvider: () -> [WorkspaceActionTabSnapshot]
    private let queryEditorContextHandler: (WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot?
    private let currentDiffOriginalSourceProvider: () -> WorkspaceDiffSource?
    private let setCurrentDiffOriginalSourceHandler: (WorkspaceDiffSource?) -> Void
    private let replaceCurrentEditorSelectionHandler: (String) -> Bool
    private let toggleCurrentEditorSelectionHighlightHandler: () -> Bool
    private let performCurrentEditorBridgeCommandHandler: (String, [String: ActionValue]) -> Bool
    private let createNoteHandler: (String?, String, String?, Bool, WorkspaceActionOpenDisposition) throws -> WorkspaceActionNoteCreateResult
    private let jumpInCurrentDocumentHandler: (String?, Int?) -> Void
    private let editorAnnotationRequestHandler: ([String: ActionValue]) async -> ActionValue?
    private let sideStackProvider: () -> SideStackController?

    init(
        windowNumber: Int,
        windowID: String,
        workspaceID: String,
        projectRootPathProvider: @escaping () -> String,
        orderedTabIDsProvider: @escaping () -> [String],
        selectedTabIDProvider: @escaping () -> String?,
        closeCurrentTab: @escaping () -> Void,
        newTab: @escaping () -> Void,
        splitHorizontally: @escaping () -> Void,
        splitVertically: @escaping () -> Void,
        focusPreviousSplit: @escaping () -> Void,
        focusNextSplit: @escaping () -> Void,
        selectTab: @escaping (String) -> Bool,
        selectPreviousTab: @escaping () -> Void,
        selectNextTab: @escaping () -> Void,
        sidebarVisibleProvider: @escaping () -> Bool,
        setSidebarVisible: @escaping (Bool) -> Void,
        cycleTabSwitcher: @escaping (Bool) -> Bool,
        commitTabSwitcher: @escaping () -> Bool,
        cancelTabSwitcher: @escaping () -> Bool,
        duplicateCurrentTab: @escaping () -> Void,
        showAllTabs: @escaping () -> Void,
        presentNewNotePanel: @escaping (String?) -> Void,
        focusDocument: @escaping (WorkspaceOpenedDocument) -> Bool,
        openDocument: @escaping (WorkspaceOpenedDocument, WorkspaceActionOpenDisposition) -> Void,
        showInParentFolder: @escaping (String, Bool) -> Bool,
        revealCurrentDocumentInFinder: @escaping () -> Bool,
        copyCurrentDocumentLink: @escaping () -> Bool,
        duplicateCurrentWorkspaceNote: @escaping () throws -> WorkspaceActionNoteCreateResult?,
        refileCurrentWorkspaceNote: @escaping (String?) throws -> WorkspaceActionNoteMoveResult?,
        refileWorkspaceNote: @escaping (String, String?) throws -> WorkspaceActionNoteMoveResult?,
        renameWorkspaceItem: @escaping (String, String) throws -> String,
        reloadCurrentDocumentFromDisk: @escaping () -> Bool,
        currentDocumentSnapshot: @escaping () -> WorkspaceActionDocumentSnapshot?,
        currentEditorCommandTargetSnapshot: @escaping () -> WorkspaceEditorCommandTargetSnapshot?,
        currentProjectSnapshot: @escaping () -> WorkspaceActionProjectSnapshot,
        listTabs: @escaping () -> [WorkspaceActionTabSnapshot],
        queryEditorContext: @escaping (WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot?,
        currentDiffOriginalSource: @escaping () -> WorkspaceDiffSource?,
        setCurrentDiffOriginalSource: @escaping (WorkspaceDiffSource?) -> Void,
        replaceCurrentEditorSelection: @escaping (String) -> Bool,
        toggleCurrentEditorSelectionHighlight: @escaping () -> Bool,
        performCurrentEditorBridgeCommand: @escaping (String, [String: ActionValue]) -> Bool,
        createNote: @escaping (String?, String, String?, Bool, WorkspaceActionOpenDisposition) throws -> WorkspaceActionNoteCreateResult,
        jumpInCurrentDocument: @escaping (String?, Int?) -> Void,
        currentDocumentInspectorSettings: @escaping () -> DocumentInspectorSettings? = { nil },
        setCurrentDocumentInspectorSettings: @escaping (DocumentInspectorSettings) -> Bool = { _ in false },
        performEditorAnnotationRequest: @escaping ([String: ActionValue]) async -> ActionValue? = { _ in nil },
        sideStack: @escaping () -> SideStackController? = { nil }
    ) {
        self.editorAnnotationRequestHandler = performEditorAnnotationRequest
        self.sideStackProvider = sideStack
        self.documentInspectorSettingsProvider = currentDocumentInspectorSettings
        self.documentInspectorSettingsHandler = setCurrentDocumentInspectorSettings
        self.windowNumber = windowNumber
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.projectRootPathProvider = projectRootPathProvider
        self.orderedTabIDsProvider = orderedTabIDsProvider
        self.selectedTabIDProvider = selectedTabIDProvider
        self.sidebarVisibleProvider = sidebarVisibleProvider
        self.closeCurrentTabHandler = closeCurrentTab
        self.newTabHandler = newTab
        self.splitHorizontallyHandler = splitHorizontally
        self.splitVerticallyHandler = splitVertically
        self.focusPreviousSplitHandler = focusPreviousSplit
        self.focusNextSplitHandler = focusNextSplit
        self.selectTabHandler = selectTab
        self.selectPreviousTabHandler = selectPreviousTab
        self.selectNextTabHandler = selectNextTab
        self.setSidebarVisibleHandler = setSidebarVisible
        self.cycleTabSwitcherHandler = cycleTabSwitcher
        self.commitTabSwitcherHandler = commitTabSwitcher
        self.cancelTabSwitcherHandler = cancelTabSwitcher
        self.duplicateCurrentTabHandler = duplicateCurrentTab
        self.showAllTabsHandler = showAllTabs
        self.presentNewNotePanelHandler = presentNewNotePanel
        self.focusDocumentHandler = focusDocument
        self.openDocumentHandler = openDocument
        self.showInParentFolderHandler = showInParentFolder
        self.revealCurrentDocumentInFinderHandler = revealCurrentDocumentInFinder
        self.copyCurrentDocumentLinkHandler = copyCurrentDocumentLink
        self.duplicateCurrentWorkspaceNoteHandler = duplicateCurrentWorkspaceNote
        self.refileCurrentWorkspaceNoteHandler = refileCurrentWorkspaceNote
        self.refileWorkspaceNoteHandler = refileWorkspaceNote
        self.renameWorkspaceItemHandler = renameWorkspaceItem
        self.reloadCurrentDocumentFromDiskHandler = reloadCurrentDocumentFromDisk
        self.currentDocumentSnapshotProvider = currentDocumentSnapshot
        self.currentEditorCommandTargetSnapshotProvider = currentEditorCommandTargetSnapshot
        self.currentProjectSnapshotProvider = currentProjectSnapshot
        self.listTabsProvider = listTabs
        self.queryEditorContextHandler = queryEditorContext
        self.currentDiffOriginalSourceProvider = currentDiffOriginalSource
        self.setCurrentDiffOriginalSourceHandler = setCurrentDiffOriginalSource
        self.replaceCurrentEditorSelectionHandler = replaceCurrentEditorSelection
        self.toggleCurrentEditorSelectionHighlightHandler = toggleCurrentEditorSelectionHighlight
        self.performCurrentEditorBridgeCommandHandler = performCurrentEditorBridgeCommand
        self.createNoteHandler = createNote
        self.jumpInCurrentDocumentHandler = jumpInCurrentDocument
    }

    var projectRootPath: String {
        projectRootPathProvider()
    }

    var orderedTabIDs: [String] {
        orderedTabIDsProvider()
    }

    var selectedTabID: String? {
        selectedTabIDProvider()
    }

    var isSidebarVisible: Bool {
        sidebarVisibleProvider()
    }

    func containsTab(publicID: String) -> Bool {
        orderedTabIDs.contains(publicID)
    }

    func closeCurrentTab() {
        closeCurrentTabHandler()
    }

    func newTab() {
        newTabHandler()
    }

    func splitHorizontally() {
        splitHorizontallyHandler()
    }

    func splitVertically() {
        splitVerticallyHandler()
    }

    func focusPreviousSplit() {
        focusPreviousSplitHandler()
    }

    func focusNextSplit() {
        focusNextSplitHandler()
    }

    func selectTab(publicID: String) -> Bool {
        selectTabHandler(publicID)
    }

    func selectPreviousTab() {
        selectPreviousTabHandler()
    }

    func selectNextTab() {
        selectNextTabHandler()
    }

    func setSidebarVisible(_ isVisible: Bool) {
        setSidebarVisibleHandler(isVisible)
    }

    func cycleTabSwitcher(reverse: Bool) -> Bool {
        cycleTabSwitcherHandler(reverse)
    }

    func commitTabSwitcher() -> Bool {
        commitTabSwitcherHandler()
    }

    func cancelTabSwitcher() -> Bool {
        cancelTabSwitcherHandler()
    }

    func duplicateCurrentTab() {
        duplicateCurrentTabHandler()
    }

    func showAllTabs() {
        showAllTabsHandler()
    }

    func presentNewNotePanel(inFolderRelativePath folderRelativePath: String?) {
        presentNewNotePanelHandler(folderRelativePath)
    }

    func focusDocument(_ document: WorkspaceOpenedDocument) -> Bool {
        focusDocumentHandler(document)
    }

    func openDocument(_ document: WorkspaceOpenedDocument, disposition: WorkspaceActionOpenDisposition) {
        openDocumentHandler(document, disposition)
    }

    func showInParentFolder(relativePath: String, selectDocument: Bool) -> Bool {
        showInParentFolderHandler(relativePath, selectDocument)
    }

    func revealCurrentDocumentInFinder() -> Bool {
        revealCurrentDocumentInFinderHandler()
    }

    func copyCurrentDocumentLink() -> Bool {
        copyCurrentDocumentLinkHandler()
    }

    func duplicateCurrentWorkspaceNote() throws -> WorkspaceActionNoteCreateResult? {
        try duplicateCurrentWorkspaceNoteHandler()
    }

    func refileCurrentWorkspaceNote(toFolderRelativePath folderRelativePath: String?) throws -> WorkspaceActionNoteMoveResult? {
        try refileCurrentWorkspaceNoteHandler(folderRelativePath)
    }

    func refileWorkspaceNote(
        relativePath: String,
        toFolderRelativePath folderRelativePath: String?
    ) throws -> WorkspaceActionNoteMoveResult? {
        try refileWorkspaceNoteHandler(relativePath, folderRelativePath)
    }

    func renameWorkspaceItem(relativePath: String, to newName: String) throws -> String {
        try renameWorkspaceItemHandler(relativePath, newName)
    }

    func reloadCurrentDocumentFromDisk() -> Bool {
        reloadCurrentDocumentFromDiskHandler()
    }

    func currentDocumentInspectorSettings() -> DocumentInspectorSettings? {
        documentInspectorSettingsProvider()
    }

    func setCurrentDocumentInspectorSettings(_ settings: DocumentInspectorSettings) -> Bool {
        documentInspectorSettingsHandler(settings)
    }

    func currentDocumentSnapshot() -> WorkspaceActionDocumentSnapshot? {
        currentDocumentSnapshotProvider()
    }

    func currentEditorCommandTargetSnapshot() -> WorkspaceEditorCommandTargetSnapshot? {
        currentEditorCommandTargetSnapshotProvider()
    }

    func currentProjectSnapshot() -> WorkspaceActionProjectSnapshot {
        currentProjectSnapshotProvider()
    }

    func listTabs() -> [WorkspaceActionTabSnapshot] {
        listTabsProvider()
    }

    func queryEditorContext(_ query: WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot? {
        await queryEditorContextHandler(query)
    }

    func currentDiffOriginalSource() -> WorkspaceDiffSource? {
        currentDiffOriginalSourceProvider()
    }

    func setCurrentDiffOriginalSource(_ source: WorkspaceDiffSource?) {
        setCurrentDiffOriginalSourceHandler(source)
    }

    @discardableResult
    func replaceCurrentEditorSelection(with text: String) -> Bool {
        replaceCurrentEditorSelectionHandler(text)
    }

    @discardableResult
    func toggleCurrentEditorSelectionHighlight() -> Bool {
        toggleCurrentEditorSelectionHighlightHandler()
    }

    @discardableResult
    func performCurrentEditorBridgeCommand(
        _ command: String,
        payload: [String: ActionValue] = [:]
    ) -> Bool {
        performCurrentEditorBridgeCommandHandler(command, payload)
    }

    func createNote(
        inFolderRelativePath folderRelativePath: String?,
        fileName: String,
        body: String?,
        open: Bool,
        disposition: WorkspaceActionOpenDisposition
    ) throws -> WorkspaceActionNoteCreateResult {
        try createNoteHandler(folderRelativePath, fileName, body, open, disposition)
    }

    func jumpInCurrentDocument(heading: String?, line: Int?) {
        jumpInCurrentDocumentHandler(heading, line)
    }

    func performEditorAnnotationRequest(_ request: [String: ActionValue]) async -> ActionValue? {
        await editorAnnotationRequestHandler(request)
    }

    func sideStackController() -> SideStackController? {
        sideStackProvider()
    }
}
