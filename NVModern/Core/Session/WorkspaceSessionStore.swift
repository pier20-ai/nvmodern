import AppKit
import Combine
import Foundation

/// Session persistence lives outside SwiftUI scene restoration on purpose.
///
/// This app has an app-owned tab model plus mixed native/web previews,
/// so we persist a compact app-owned snapshot instead of relying on macOS window
/// restoration APIs. Phase 1 stores:
/// - all open windows
/// - each window's tab layout (the split tree of the old shell is still decoded)
/// - per-pane tabs + selected tabs
/// - focused pane per window
/// - per-window project root
/// - per-document scroll state for Markdown and PDF
///
/// The snapshot is written to:
/// ~/Library/Application Support/nvModern/session-v6.json
///
/// Window snapshots are keyed in-memory by `windowNumber` while the app is running,
/// then serialized as an ordered array on disk for replay at next launch.
/// Scroll persistence is intentionally limited to formats with a meaningful notion
/// of vertical reading position in Phase 1.
enum PersistedDocumentScrollKind: String, Codable {
    case markdown
    case pdf
}

struct PersistedTextDocumentSnapshot: Codable, Equatable {
    static let maxBodyBytes = 1_000_000

    var path: String
    var title: String
    var body: String
    var modifiedDate: Date?
    var mimeType: String?
    var fileSize: Int64?
    var capturedAt: Date

    var isWithinSizeLimit: Bool {
        body.lengthOfBytes(using: .utf8) <= Self.maxBodyBytes
    }
}

struct PersistedWorkspaceTabState: Codable, Equatable {
    var kind: WorkspaceTabKind
    var selectedFolderChain: [String]
    var selectedNotePath: String?
    var openedDocument: WorkspaceOpenedDocument?
    var documentInspectorSettings: DocumentInspectorSettings
    var millerActiveDepth: Int
    var activeMillerItemPath: String?
    var millerHorizontalOrigin: Double
    var backHistory: [WorkspaceHistoryItem]
    var forwardHistory: [WorkspaceHistoryItem]
    var historyCurrentItem: WorkspaceHistoryItem?
    var textSnapshot: PersistedTextDocumentSnapshot?
    /// The tab's side stack (ticket 0031). Optional and additive: sessions
    /// written before it decode with no stack.
    var sideStack: SideStackState?

    init(
        kind: WorkspaceTabKind = .note,
        selectedFolderChain: [String],
        selectedNotePath: String?,
        openedDocument: WorkspaceOpenedDocument?,
        documentInspectorSettings: DocumentInspectorSettings = .default,
        millerActiveDepth: Int,
        activeMillerItemPath: String?,
        millerHorizontalOrigin: Double = 0,
        backHistory: [WorkspaceHistoryItem] = [],
        forwardHistory: [WorkspaceHistoryItem] = [],
        historyCurrentItem: WorkspaceHistoryItem? = nil,
        textSnapshot: PersistedTextDocumentSnapshot? = nil,
        sideStack: SideStackState? = nil
    ) {
        self.kind = kind
        self.selectedFolderChain = selectedFolderChain
        self.selectedNotePath = selectedNotePath
        self.openedDocument = openedDocument ?? selectedNotePath.map { .workspaceNote(relativePath: $0) }
        self.documentInspectorSettings = documentInspectorSettings
        self.millerActiveDepth = millerActiveDepth
        self.activeMillerItemPath = activeMillerItemPath
        self.millerHorizontalOrigin = millerHorizontalOrigin
        self.backHistory = backHistory
        self.forwardHistory = forwardHistory
        self.historyCurrentItem = historyCurrentItem
            ?? self.openedDocument?.historyItem
        self.textSnapshot = textSnapshot?.isWithinSizeLimit == true ? textSnapshot : nil
        self.sideStack = sideStack?.isDefault == false ? sideStack : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedFolderChain = try container.decodeIfPresent([String].self, forKey: .selectedFolderChain) ?? []
        selectedNotePath = try container.decodeIfPresent(String.self, forKey: .selectedNotePath)
        openedDocument = try container.decodeIfPresent(WorkspaceOpenedDocument.self, forKey: .openedDocument)
            ?? selectedNotePath.map { .workspaceNote(relativePath: $0) }
        documentInspectorSettings = try container.decodeIfPresent(DocumentInspectorSettings.self, forKey: .documentInspectorSettings) ?? .default
        millerActiveDepth = try container.decodeIfPresent(Int.self, forKey: .millerActiveDepth) ?? 0
        activeMillerItemPath = try container.decodeIfPresent(String.self, forKey: .activeMillerItemPath)
        millerHorizontalOrigin = try container.decodeIfPresent(Double.self, forKey: .millerHorizontalOrigin) ?? 0
        backHistory = Self.decodeHistory(from: container, forKey: .backHistory)
        forwardHistory = Self.decodeHistory(from: container, forKey: .forwardHistory)
        // A retired history kind (a chat tab) decodes as nil rather than
        // failing the tab.
        historyCurrentItem = try (try? container.decodeIfPresent(WorkspaceHistoryItem.self, forKey: .historyCurrentItem))
            ?? (container.decodeIfPresent(String.self, forKey: .historyCurrentNotePath)).map { .workspaceNote(relativePath: $0) }
            ?? openedDocument?.historyItem
        textSnapshot = try container.decodeIfPresent(PersistedTextDocumentSnapshot.self, forKey: .textSnapshot)
        if textSnapshot?.isWithinSizeLimit != true {
            textSnapshot = nil
        }
        // A malformed stack is dropped rather than failing the tab.
        sideStack = (try? container.decodeIfPresent(SideStackState.self, forKey: .sideStack)) ?? nil

        // Unknown kinds, including the retired `chat`, restore as launchpad.
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) {
            kind = WorkspaceTabKind(rawValue: rawKind) ?? .launchpad
        } else {
            kind = openedDocument == nil ? .launchpad : .note
        }

        // Sessions written before companions and chat documents were retired
        // may still carry `companionPanes`, `childPane`, or `chatSession`;
        // they are not CodingKeys any more, so the decoder ignores them.
    }

    /// Decodes a history list item by item, dropping entries of retired kinds
    /// (chat) instead of losing the whole list. Pre-v5 sessions stored plain
    /// note paths.
    private static func decodeHistory(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [WorkspaceHistoryItem] {
        if let paths = try? container.decodeIfPresent([String].self, forKey: key) {
            return paths.map { .workspaceNote(relativePath: $0) }
        }
        let items = (try? container.decodeIfPresent([LossyHistoryItem].self, forKey: key)) ?? []
        return items.compactMap(\.item)
    }

    private struct LossyHistoryItem: Decodable {
        let item: WorkspaceHistoryItem?

        init(from decoder: Decoder) throws {
            item = try? WorkspaceHistoryItem(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(selectedFolderChain, forKey: .selectedFolderChain)
        try container.encodeIfPresent(selectedNotePath, forKey: .selectedNotePath)
        try container.encodeIfPresent(openedDocument, forKey: .openedDocument)
        try container.encode(documentInspectorSettings, forKey: .documentInspectorSettings)
        try container.encode(millerActiveDepth, forKey: .millerActiveDepth)
        try container.encodeIfPresent(activeMillerItemPath, forKey: .activeMillerItemPath)
        try container.encode(millerHorizontalOrigin, forKey: .millerHorizontalOrigin)
        try container.encode(backHistory, forKey: .backHistory)
        try container.encode(forwardHistory, forKey: .forwardHistory)
        try container.encodeIfPresent(historyCurrentItem, forKey: .historyCurrentItem)
        try container.encodeIfPresent(textSnapshot?.isWithinSizeLimit == true ? textSnapshot : nil, forKey: .textSnapshot)
        try container.encodeIfPresent(sideStack?.isDefault == false ? sideStack : nil, forKey: .sideStack)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case query
        case selectedFolderChain
        case selectedNotePath
        case openedDocument
        case documentInspectorSettings
        case isDetailsSpaceVisible
        case millerActiveDepth
        case activeMillerItemPath
        case millerHorizontalOrigin
        case backHistory
        case forwardHistory
        case historyCurrentItem
        case historyCurrentNotePath
        case textSnapshot
        case sideStack
    }
}

struct PersistedWorkspaceWindowTab: Codable, Equatable {
    var title: String
    var icon: String?
    var iconTint: String?
    var state: PersistedWorkspaceTabState
}

enum PersistedWorkspaceLayoutBranch: String, Codable, Equatable {
    case first
    case second
}

struct PersistedWorkspacePaneState: Codable, Equatable {
    var tabs: [PersistedWorkspaceWindowTab]
    var selectedTabIndex: Int
}

struct PersistedWorkspaceSplitState: Codable, Equatable {
    var orientation: String
    var dividerPosition: Double
    var first: PersistedWorkspaceLayoutNode
    var second: PersistedWorkspaceLayoutNode
}

/// Serialized layout tree used for window restore.
///
/// The split-pane shell that produced nested layouts is gone; the node stays so
/// sessions written by it still decode.
indirect enum PersistedWorkspaceLayoutNode: Codable, Equatable {
    case pane(PersistedWorkspacePaneState)
    case split(PersistedWorkspaceSplitState)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pane":
            self = .pane(try container.decode(PersistedWorkspacePaneState.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(PersistedWorkspaceSplitState.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneState):
            try container.encode("pane", forKey: .type)
            try container.encode(paneState, forKey: .pane)
        case .split(let splitState):
            try container.encode("split", forKey: .type)
            try container.encode(splitState, forKey: .split)
        }
    }
}

/// Full persisted state for one app window.
///
/// `rootNode` is the current canonical representation. `tabs` and `selectedTabIndex`
/// are retained as a backward-compatible fallback for older session files produced by
/// the initial Phase 1 implementation before split-tree persistence was added.
struct PersistedWorkspaceWindowState: Codable, Equatable {
    struct Frame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    var frame: Frame?
    var rootPath: String?
    var rootNode: PersistedWorkspaceLayoutNode?
    var focusedPanePath: [PersistedWorkspaceLayoutBranch]?
    var isSidebarVisible: Bool
    var sidebarWidth: Double
    var sidebarExpandedFolderPaths: [String]
    var sidebarFocusedRootPath: String?
    var tabs: [PersistedWorkspaceWindowTab]
    var selectedTabIndex: Int

    init(
        frame: Frame?,
        rootPath: String? = nil,
        rootNode: PersistedWorkspaceLayoutNode? = nil,
        focusedPanePath: [PersistedWorkspaceLayoutBranch]? = nil,
        isSidebarVisible: Bool = false,
        sidebarWidth: Double = 288,
        sidebarExpandedFolderPaths: [String] = [],
        sidebarFocusedRootPath: String? = nil,
        tabs: [PersistedWorkspaceWindowTab] = [],
        selectedTabIndex: Int = 0
    ) {
        self.frame = frame
        self.rootPath = rootPath
        self.rootNode = rootNode
        self.focusedPanePath = focusedPanePath
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = sidebarWidth
        self.sidebarExpandedFolderPaths = sidebarExpandedFolderPaths
        self.sidebarFocusedRootPath = sidebarFocusedRootPath
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        rootNode = try container.decodeIfPresent(PersistedWorkspaceLayoutNode.self, forKey: .rootNode)
        focusedPanePath = try container.decodeIfPresent([PersistedWorkspaceLayoutBranch].self, forKey: .focusedPanePath)
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? false
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 288
        sidebarExpandedFolderPaths = try container.decodeIfPresent([String].self, forKey: .sidebarExpandedFolderPaths) ?? []
        sidebarFocusedRootPath = try container.decodeIfPresent(String.self, forKey: .sidebarFocusedRootPath)
        tabs = try container.decodeIfPresent([PersistedWorkspaceWindowTab].self, forKey: .tabs) ?? []
        selectedTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTabIndex) ?? 0
    }

    /// `isFocusMode` was persisted here before focus mode was removed. It is
    /// deliberately absent: the decoder only reads the keys below, so older
    /// session files that still carry it decode unchanged.
    private enum CodingKeys: String, CodingKey {
        case frame
        case rootPath
        case rootNode
        case focusedPanePath
        case isSidebarVisible
        case sidebarWidth
        case sidebarExpandedFolderPaths
        case sidebarFocusedRootPath
        case tabs
        case selectedTabIndex
    }
}

struct PersistedDocumentScrollState: Codable, Equatable {
    var rootPath: String
    var relativePath: String
    var kind: PersistedDocumentScrollKind
    var verticalRatio: Double
    var updatedAt: Date
}

/// Stable reading position for a reflowable EPUB. A CFI survives pagination,
/// viewport, and theme changes more reliably than a raw scroll ratio; `href`
/// and `progression` are retained as graceful fallbacks for imperfect books.
struct PersistedEPUBLocation: Codable, Equatable {
    var rootPath: String
    var relativePath: String
    var href: String
    var cfi: String?
    var progression: Double?
    var updatedAt: Date
}

private struct PersistedWorkspaceSession: Codable {
    var version: Int
    var windows: [PersistedWorkspaceWindowState]
    var documentScroll: [PersistedDocumentScrollState]
    var recentDocuments: [PersistedRecentDocument]
    /// Additive and optional on decode so older snapshots still load.
    var pinnedDocuments: [PersistedPinnedDocument]
    /// Additive and optional on decode so older snapshots still load.
    var epubLocations: [PersistedEPUBLocation]

    init(
        version: Int,
        windows: [PersistedWorkspaceWindowState],
        documentScroll: [PersistedDocumentScrollState],
        recentDocuments: [PersistedRecentDocument] = [],
        pinnedDocuments: [PersistedPinnedDocument] = [],
        epubLocations: [PersistedEPUBLocation] = []
    ) {
        self.version = version
        self.windows = windows
        self.documentScroll = documentScroll
        self.recentDocuments = recentDocuments
        self.pinnedDocuments = pinnedDocuments
        self.epubLocations = epubLocations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 5
        windows = try container.decodeIfPresent([PersistedWorkspaceWindowState].self, forKey: .windows) ?? []
        documentScroll = try container.decodeIfPresent([PersistedDocumentScrollState].self, forKey: .documentScroll) ?? []
        recentDocuments = try container.decodeIfPresent([PersistedRecentDocument].self, forKey: .recentDocuments) ?? []
        pinnedDocuments = try container.decodeIfPresent([PersistedPinnedDocument].self, forKey: .pinnedDocuments) ?? []
        epubLocations = try container.decodeIfPresent([PersistedEPUBLocation].self, forKey: .epubLocations) ?? []
    }

    static let empty = PersistedWorkspaceSession(version: 6, windows: [], documentScroll: [], recentDocuments: [])

    private enum CodingKeys: String, CodingKey {
        case version
        case windows
        case documentScroll
        case recentDocuments
        case pinnedDocuments
        case epubLocations
    }
}

/// A note the user pinned to the sidebar. Pins are per workspace root and
/// ordered by when they were pinned, so the list stays stable while recents
/// churn underneath it.
struct PersistedPinnedDocument: Codable, Equatable, Identifiable {
    var rootPath: String
    var document: WorkspaceOpenedDocument
    var title: String
    var pinnedAt: Date

    var id: String {
        "\(rootPath)|\(document.editorPath)"
    }
}

struct PersistedRecentDocument: Codable, Equatable, Identifiable {
    var rootPath: String
    var document: WorkspaceOpenedDocument
    var title: String
    var openedAt: Date

    var id: String {
        "\(rootPath)|\(document.editorPath)"
    }

    init(rootPath: String, document: WorkspaceOpenedDocument, title: String, openedAt: Date) {
        self.rootPath = rootPath
        self.document = document
        self.title = title
        self.openedAt = openedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        document = try container.decode(WorkspaceOpenedDocument.self, forKey: .document)
        title = try container.decode(String.self, forKey: .title)
        openedAt = try container.decode(Date.self, forKey: .openedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(document, forKey: .document)
        try container.encode(title, forKey: .title)
        try container.encode(openedAt, forKey: .openedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case rootPath
        case document
        case title
        case openedAt
    }
}

private struct DocumentScrollKey: Hashable {
    var rootPath: String
    var relativePath: String
    var kind: PersistedDocumentScrollKind
}

private struct EPUBLocationKey: Hashable {
    var rootPath: String
    var relativePath: String
}

/// Central session coordinator.
///
/// Responsibilities:
/// - load the previous launch snapshot once
/// - hand out saved window states to newly created `WorkspaceView`s during launch
/// - debounce live writes while the user is working
/// - force a final synchronous flush on app termination
/// - keep document scroll state independent from window/tab lifetime so reopening a
///   Markdown or PDF file can restore its reading position even after the tab closed
@MainActor
final class WorkspaceSessionStore: ObservableObject {
    static let shared = WorkspaceSessionStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let sessionURL: URL
    private let legacyV5SessionURL: URL
    private let legacyV4SessionURL: URL
    private let legacyV3SessionURL: URL
    private let legacyV2SessionURL: URL
    private let legacyV1SessionURL: URL
    private var didLoad = false
    private var persistedSession = PersistedWorkspaceSession.empty
    private var liveWindows: [Int: PersistedWorkspaceWindowState] = [:]
    private var launchWindowQueue: [PersistedWorkspaceWindowState] = []
    private var documentScrollByKey: [DocumentScrollKey: PersistedDocumentScrollState] = [:]
    private var epubLocationByKey: [EPUBLocationKey: PersistedEPUBLocation] = [:]
    private var recentDocuments: [PersistedRecentDocument] = []
    private var pinnedDocuments: [PersistedPinnedDocument] = []
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var didConsumeAdditionalLaunchWindows = false

    @Published private(set) var recentDocumentsRevision = 0
    @Published private(set) var pinnedDocumentsRevision = 0

    private(set) var isTerminating = false

    private init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        let directoryURL = applicationSupportURL.appendingPathComponent("nvModern", isDirectory: true)
        sessionURL = directoryURL.appendingPathComponent("session-v6.json", isDirectory: false)
        legacyV5SessionURL = directoryURL.appendingPathComponent("session-v5.json", isDirectory: false)
        legacyV4SessionURL = directoryURL.appendingPathComponent("session-v4.json", isDirectory: false)
        legacyV3SessionURL = directoryURL.appendingPathComponent("session-v3.json", isDirectory: false)
        legacyV2SessionURL = directoryURL.appendingPathComponent("session-v2.json", isDirectory: false)
        legacyV1SessionURL = directoryURL.appendingPathComponent("session-v1.json", isDirectory: false)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Called once per launched window scene.
    ///
    /// The first created window gets the first saved snapshot, the next gets the next,
    /// and so on. `NVModernApp` opens extra windows eagerly based on the remaining count.
    func claimNextLaunchWindowState() -> PersistedWorkspaceWindowState? {
        loadIfNeeded()
        guard !launchWindowQueue.isEmpty else { return nil }
        return launchWindowQueue.removeFirst()
    }

    func hasPersistedLaunchWindowStates() -> Bool {
        loadIfNeeded()
        return !persistedSession.windows.isEmpty
    }

    func consumeAdditionalLaunchWindowCount() -> Int {
        loadIfNeeded()
        guard !didConsumeAdditionalLaunchWindows else { return 0 }
        didConsumeAdditionalLaunchWindows = true
        return launchWindowQueue.count
    }

    func upsertWindowState(windowNumber: Int, state: PersistedWorkspaceWindowState) {
        loadIfNeeded()
        liveWindows[windowNumber] = state
        scheduleSave()
    }

    func removeWindowState(windowNumber: Int) {
        loadIfNeeded()
        guard !isTerminating else { return }
        liveWindows.removeValue(forKey: windowNumber)
        flushNow()
    }

    /// Persist per-document scroll independent of any particular window/tab.
    ///
    /// This is what allows:
    /// - quit/relaunch restore
    /// - close-tab/reopen restore for Markdown and PDF
    func recordDocumentScroll(rootURL: URL, relativePath: String, kind: PersistedDocumentScrollKind, verticalRatio: Double) {
        loadIfNeeded()

        let normalizedPath = normalize(relativePath: relativePath)
        guard !normalizedPath.isEmpty else { return }

        let key = DocumentScrollKey(
            rootPath: rootURL.standardizedFileURL.path,
            relativePath: normalizedPath,
            kind: kind
        )

        let clampedRatio = max(0, min(1, verticalRatio))
        let existing = documentScrollByKey[key]
        if existing?.verticalRatio == clampedRatio {
            return
        }

        documentScrollByKey[key] = PersistedDocumentScrollState(
            rootPath: key.rootPath,
            relativePath: key.relativePath,
            kind: kind,
            verticalRatio: clampedRatio,
            updatedAt: Date()
        )
        scheduleSave()
    }

    func documentScrollRatio(rootURL: URL, relativePath: String, kind: PersistedDocumentScrollKind) -> Double? {
        loadIfNeeded()

        let key = DocumentScrollKey(
            rootPath: rootURL.standardizedFileURL.path,
            relativePath: normalize(relativePath: relativePath),
            kind: kind
        )
        return documentScrollByKey[key]?.verticalRatio
    }

    func recordEPUBLocation(
        rootURL: URL,
        relativePath: String,
        href: String,
        cfi: String?,
        progression: Double?
    ) {
        loadIfNeeded()
        let normalizedPath = normalize(relativePath: relativePath)
        let normalizedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty, !normalizedHref.isEmpty else { return }

        let key = EPUBLocationKey(
            rootPath: rootURL.standardizedFileURL.path,
            relativePath: normalizedPath
        )
        let normalizedCFI = cfi?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedProgression = progression.map { max(0, min(1, $0)) }
        let next = PersistedEPUBLocation(
            rootPath: key.rootPath,
            relativePath: key.relativePath,
            href: normalizedHref,
            cfi: normalizedCFI?.isEmpty == false ? normalizedCFI : nil,
            progression: clampedProgression,
            updatedAt: Date()
        )
        if let existing = epubLocationByKey[key],
           existing.href == next.href,
           existing.cfi == next.cfi,
           existing.progression == next.progression {
            return
        }
        epubLocationByKey[key] = next
        scheduleSave()
    }

    func epubLocation(rootURL: URL, relativePath: String) -> PersistedEPUBLocation? {
        loadIfNeeded()
        return epubLocationByKey[
            EPUBLocationKey(
                rootPath: rootURL.standardizedFileURL.path,
                relativePath: normalize(relativePath: relativePath)
            )
        ]
    }

    func recordRecentDocument(rootURL: URL, document: WorkspaceOpenedDocument) {
        loadIfNeeded()

        switch document {
        case .workspaceNote, .externalMarkdown:
            break
        case .clipboardMarkdown, .diff:
            return
        }

        let rootPath = rootURL.standardizedFileURL.path
        let title = document.tabPresentation.title
        let id = "\(rootPath)|\(document.editorPath)"
        recentDocuments.removeAll { $0.id == id }
        recentDocuments.insert(
            PersistedRecentDocument(
                rootPath: rootPath,
                document: document,
                title: title,
                openedAt: Date()
            ),
            at: 0
        )
        if recentDocuments.count > 50 {
            recentDocuments = Array(recentDocuments.prefix(50))
        }
        recentDocumentsRevision += 1
        scheduleSave()
    }

    func recentDocuments(rootURL: URL? = nil, limit: Int = 12) -> [PersistedRecentDocument] {
        loadIfNeeded()

        let rootPath = rootURL?.standardizedFileURL.path
        let filtered = recentDocuments.filter { recent in
            guard let rootPath else { return true }
            return recent.rootPath == rootPath
        }
        return Array(filtered.prefix(max(0, limit)))
    }

    // MARK: - Pinned documents

    func pinnedDocuments(rootURL: URL? = nil, limit: Int = 50) -> [PersistedPinnedDocument] {
        loadIfNeeded()

        let rootPath = rootURL?.standardizedFileURL.path
        let filtered = pinnedDocuments.filter { pinned in
            guard let rootPath else { return true }
            return pinned.rootPath == rootPath
        }
        return Array(filtered.prefix(max(0, limit)))
    }

    func isPinned(rootURL: URL, document: WorkspaceOpenedDocument) -> Bool {
        loadIfNeeded()

        let id = "\(rootURL.standardizedFileURL.path)|\(document.editorPath)"
        return pinnedDocuments.contains { $0.id == id }
    }

    /// Pins are only meaningful for documents that can be reopened from a path.
    /// Clipboard notes and diffs have no durable identity, so they
    /// are silently ignored rather than pinned into a dead entry.
    func setPinned(
        _ isPinned: Bool,
        rootURL: URL,
        document: WorkspaceOpenedDocument,
        title: String? = nil
    ) {
        loadIfNeeded()

        switch document {
        case .workspaceNote, .externalMarkdown:
            break
        case .clipboardMarkdown, .diff:
            return
        }

        let rootPath = rootURL.standardizedFileURL.path
        let id = "\(rootPath)|\(document.editorPath)"
        let wasPinned = pinnedDocuments.contains { $0.id == id }
        guard wasPinned != isPinned else { return }

        if isPinned {
            pinnedDocuments.append(
                PersistedPinnedDocument(
                    rootPath: rootPath,
                    document: document,
                    title: title ?? document.tabPresentation.title,
                    pinnedAt: Date()
                )
            )
        } else {
            pinnedDocuments.removeAll { $0.id == id }
        }

        pinnedDocumentsRevision += 1
        scheduleSave()
    }

    func beginTermination() {
        loadIfNeeded()
        isTerminating = true
        flushNow()
    }

    func flushNow() {
        loadIfNeeded()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        persistToDisk()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let decoded = loadPersistedSession() else {
            persistedSession = .empty
            launchWindowQueue = []
            documentScrollByKey = [:]
            epubLocationByKey = [:]
            recentDocuments = []
            pinnedDocuments = []
            return
        }

        persistedSession = decoded
        launchWindowQueue = decoded.windows
        documentScrollByKey = Dictionary(
            uniqueKeysWithValues: decoded.documentScroll.map {
                (
                    DocumentScrollKey(rootPath: $0.rootPath, relativePath: $0.relativePath, kind: $0.kind),
                    $0
                )
            }
        )
        epubLocationByKey = Dictionary(
            uniqueKeysWithValues: decoded.epubLocations.map {
                (
                    EPUBLocationKey(rootPath: $0.rootPath, relativePath: $0.relativePath),
                    $0
                )
            }
        )
        recentDocuments = decoded.recentDocuments.sorted { $0.openedAt > $1.openedAt }
        pinnedDocuments = decoded.pinnedDocuments.sorted { $0.pinnedAt < $1.pinnedAt }
    }

    private func loadPersistedSession() -> PersistedWorkspaceSession? {
        if let data = try? Data(contentsOf: sessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        if let data = try? Data(contentsOf: legacyV5SessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        if let data = try? Data(contentsOf: legacyV4SessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        if let data = try? Data(contentsOf: legacyV3SessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        if let data = try? Data(contentsOf: legacyV2SessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        if let data = try? Data(contentsOf: legacyV1SessionURL),
           let decoded = try? decoder.decode(PersistedWorkspaceSession.self, from: data)
        {
            return decoded
        }

        return nil
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistToDisk()
            }
        }

        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func persistToDisk() {
        let session = PersistedWorkspaceSession(
            version: 6,
            windows: liveWindows
                .sorted(by: { $0.key < $1.key })
                .map(\.value),
            documentScroll: documentScrollByKey.values
                .sorted { lhs, rhs in
                    if lhs.rootPath != rhs.rootPath {
                        return lhs.rootPath < rhs.rootPath
                    }
                    if lhs.relativePath != rhs.relativePath {
                        return lhs.relativePath < rhs.relativePath
                    }
                    return lhs.kind.rawValue < rhs.kind.rawValue
                },
            recentDocuments: recentDocuments,
            pinnedDocuments: pinnedDocuments,
            epubLocations: epubLocationByKey.values.sorted { lhs, rhs in
                if lhs.rootPath != rhs.rootPath { return lhs.rootPath < rhs.rootPath }
                return lhs.relativePath < rhs.relativePath
            }
        )

        do {
            let directoryURL = sessionURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(session)
            try data.write(to: sessionURL, options: .atomic)
            persistedSession = session
        } catch {
            print("[NVModern][Session] Failed to persist session: \(error)")
        }
    }

    private func normalize(relativePath: String) -> String {
        var normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        return normalized
    }
}
