import Foundation

/// Everything a provider is allowed to know about the workspace it is filling
/// a frame for. Built by `WorkspaceTabView` at resolve time — never inside a
/// SwiftUI `body` evaluation, because the action variables reach workspace
/// state (see `ActionAutomationContextBuilder`).
@MainActor
struct PaletteContext {
    let notesModel: NotesWorkspaceModel
    let openTabEntries: [WorkspaceOpenDocumentPathEntry]
    /// The workspace note open in this tab, if any.
    let currentDocumentRelativePath: String?
    /// Title of whatever document the tab shows, workspace note or not. Nil on
    /// a launchpad tab, which is what drops the "on <file>" subject group.
    let currentDocumentTitle: String?
    /// The folder the Miller browser is sitting in, if any.
    let currentFolderRelativePath: String?
    let projectRootPath: String
    let windowNumber: Int?
    /// Values shown on verb rows before the chevron. See
    /// `ActionsPaletteProvider.valueProviders`.
    let currentDocumentThemeID: String
    let currentDocumentWidth: DocumentInspectorWidth
    let currentThemeTitle: String
    let isCompactToolbarEnabled: Bool
    let isSidebarVisible: Bool
    let outlineItems: [DocumentOutlineItem]
    let activeOutlineItemID: String?

    /// The folder holding the current note, for the Refile row's value.
    var currentNoteFolderRelativePath: String? {
        currentDocumentRelativePath.map { ($0 as NSString).deletingLastPathComponent }
    }

    init(
        notesModel: NotesWorkspaceModel,
        openTabEntries: [WorkspaceOpenDocumentPathEntry] = [],
        currentDocumentRelativePath: String? = nil,
        currentDocumentTitle: String? = nil,
        currentFolderRelativePath: String? = nil,
        projectRootPath: String,
        windowNumber: Int? = nil,
        currentDocumentThemeID: String = "system",
        currentDocumentWidth: DocumentInspectorWidth = .comfortable,
        currentThemeTitle: String = "System",
        isCompactToolbarEnabled: Bool = false,
        isSidebarVisible: Bool = true,
        outlineItems: [DocumentOutlineItem] = [],
        activeOutlineItemID: String? = nil
    ) {
        self.notesModel = notesModel
        self.openTabEntries = openTabEntries
        self.currentDocumentRelativePath = currentDocumentRelativePath
        self.currentDocumentTitle = currentDocumentTitle
            ?? currentDocumentRelativePath.map { ($0 as NSString).lastPathComponent }
        self.currentFolderRelativePath = currentFolderRelativePath
        self.projectRootPath = projectRootPath
        self.windowNumber = windowNumber
        self.currentDocumentThemeID = currentDocumentThemeID
        self.currentDocumentWidth = currentDocumentWidth
        self.currentThemeTitle = currentThemeTitle
        self.isCompactToolbarEnabled = isCompactToolbarEnabled
        self.isSidebarVisible = isSidebarVisible
        self.outlineItems = outlineItems
        self.activeOutlineItemID = activeOutlineItemID
    }
}

/// One provider per `PaletteSourceKind`. Providers own their own caching and
/// return ordered, already-limited sections; the resolver only decides which
/// sources are active for a frame and in what order their sections appear.
@MainActor
protocol PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection]
}
