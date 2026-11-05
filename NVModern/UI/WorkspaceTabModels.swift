import AppKit
import SwiftUI

enum WorkspaceTabBannerStyle: String, Equatable {
    case info
    case warning
    case danger

    var tintColor: Color {
        switch self {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }
    var backgroundColor: Color {
        let color = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .info:
                return isDark
                    ? NSColor(srgbRed: 0.15, green: 0.20, blue: 0.28, alpha: 1)
                    : NSColor(srgbRed: 0.90, green: 0.95, blue: 1.00, alpha: 1)
            case .warning:
                return isDark
                    ? NSColor(srgbRed: 0.28, green: 0.21, blue: 0.13, alpha: 1)
                    : NSColor(srgbRed: 1.00, green: 0.95, blue: 0.87, alpha: 1)
            case .danger:
                return isDark
                    ? NSColor(srgbRed: 0.28, green: 0.15, blue: 0.15, alpha: 1)
                    : NSColor(srgbRed: 1.00, green: 0.91, blue: 0.91, alpha: 1)
            }
        }
        return Color(nsColor: color)
    }
    var borderColor: Color {
        switch self {
        case .info:
            return Color.blue.opacity(0.28)
        case .warning:
            return Color.orange.opacity(0.30)
        case .danger:
            return Color.red.opacity(0.30)
        }
    }
}

enum WorkspaceTabBannerActionID: String, Equatable {
    case reloadFromDisk
    case keepLocal
    case restoreDeleted
    case closeTab
}

struct WorkspaceTabBannerAction: Equatable, Identifiable {
    enum Style: String, Equatable {
        case normal
        case prominent
        case destructive
    }

    let id: WorkspaceTabBannerActionID
    let title: String
    let style: Style
}

enum WorkspaceTabBannerKind: Equatable {
    case modified(path: String, date: Date)
    case deleted(path: String, date: Date)
    case renamed(oldPath: String, newPath: String, date: Date)
}

struct WorkspaceTabBannerState: Equatable, Identifiable {
    let id: UUID
    let kind: WorkspaceTabBannerKind
    let style: WorkspaceTabBannerStyle
    let symbolName: String
    let title: String
    let message: String
    let date: Date
    let actions: [WorkspaceTabBannerAction]

    init(
        kind: WorkspaceTabBannerKind,
        style: WorkspaceTabBannerStyle,
        symbolName: String,
        title: String,
        message: String,
        date: Date,
        actions: [WorkspaceTabBannerAction]
    ) {
        self.id = UUID()
        self.kind = kind
        self.style = style
        self.symbolName = symbolName
        self.title = title
        self.message = message
        self.date = date
        self.actions = actions
    }
}

struct WorkspaceDeletedDocumentSnapshot: Equatable {
    let title: String
    let kind: EditorSelectionContext.Kind
    let relativePath: String
    let textBody: String?
    let data: Data?
    let mimeType: String?
}

struct WorkspaceStatusBanner: View {
    let banner: WorkspaceTabBannerState
    var onAction: (WorkspaceTabBannerActionID) -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var relativeTimestamp: String {
        Self.relativeFormatter.localizedString(for: banner.date, relativeTo: Date())
    }

    @ViewBuilder
    private func bannerActionButton(_ action: WorkspaceTabBannerAction) -> some View {
        switch action.style {
        case .prominent:
            Button(action.title) {
                onAction(action.id)
            }
            .buttonStyle(.borderedProminent)
            .tint(banner.style.tintColor)
            .controlSize(.small)
        case .destructive:
            Button(action.title) {
                onAction(action.id)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        case .normal:
            Button(action.title) {
                onAction(action.id)
            }
            .buttonStyle(.bordered)
            .tint(banner.style.tintColor)
            .controlSize(.small)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: banner.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(banner.style.tintColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(banner.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(relativeTimestamp)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(banner.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                ForEach(banner.actions) { action in
                    bannerActionButton(action)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(banner.style.backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(banner.style.borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}

/// Kind of surface a tab currently renders. New tabs start as `.launchpad`;
/// opening a note transforms the tab to `.note` and it doesn't regress back
/// even if the note is later closed/deleted.
enum WorkspaceTabKind: String, Equatable, Codable {
    case note
    case launchpad
}

struct WorkspaceTabState: Equatable {
    var kind: WorkspaceTabKind
    var selectedFolderChain: [String]
    var selectedNotePath: String?
    var openedDocument: WorkspaceOpenedDocument?
    var documentInspectorSettings: DocumentInspectorSettings
    var millerActiveDepth: Int
    var activeMillerItemPath: String?
    var millerHorizontalOrigin: CGFloat
    var backHistory: [WorkspaceHistoryItem]
    var forwardHistory: [WorkspaceHistoryItem]
    var historyCurrentItem: WorkspaceHistoryItem?
    var liveBanner: WorkspaceTabBannerState?
    var liveLocalRefreshRevision: Int
    var liveDiskReloadRevision: Int
    var liveCachedTextBody: String?
    var liveCachedData: Data?
    var liveCachedKind: EditorSelectionContext.Kind?
    var liveCachedTitle: String?
    var liveDeletedSnapshot: WorkspaceDeletedDocumentSnapshot?
    var persistedTextSnapshot: PersistedTextDocumentSnapshot?
    var pendingMarkdownJump: PendingMarkdownJump?
    /// Reference cards beside the tab's content (ticket 0031). Owned by the
    /// tab, so navigating the main view leaves it alone.
    var sideStack: SideStackState

    static let initial = WorkspaceTabState(
        kind: .launchpad,
        selectedFolderChain: [],
        selectedNotePath: nil,
        openedDocument: nil,
        documentInspectorSettings: .default,
        millerActiveDepth: 0,
        activeMillerItemPath: nil,
        millerHorizontalOrigin: 0,
        backHistory: [],
        forwardHistory: [],
        historyCurrentItem: nil,
        liveBanner: nil,
        liveLocalRefreshRevision: 0,
        liveDiskReloadRevision: 0,
        liveCachedTextBody: nil,
        liveCachedData: nil,
        liveCachedKind: nil,
        liveCachedTitle: nil,
        liveDeletedSnapshot: nil,
        persistedTextSnapshot: nil,
        pendingMarkdownJump: nil,
        sideStack: .empty
    )

    init(
        kind: WorkspaceTabKind = .note,
        selectedFolderChain: [String],
        selectedNotePath: String?,
        openedDocument: WorkspaceOpenedDocument?,
        documentInspectorSettings: DocumentInspectorSettings = .default,
        millerActiveDepth: Int,
        activeMillerItemPath: String?,
        millerHorizontalOrigin: CGFloat = 0,
        backHistory: [WorkspaceHistoryItem],
        forwardHistory: [WorkspaceHistoryItem],
        historyCurrentItem: WorkspaceHistoryItem?,
        liveBanner: WorkspaceTabBannerState? = nil,
        liveLocalRefreshRevision: Int = 0,
        liveDiskReloadRevision: Int = 0,
        liveCachedTextBody: String? = nil,
        liveCachedData: Data? = nil,
        liveCachedKind: EditorSelectionContext.Kind? = nil,
        liveCachedTitle: String? = nil,
        liveDeletedSnapshot: WorkspaceDeletedDocumentSnapshot? = nil,
        persistedTextSnapshot: PersistedTextDocumentSnapshot? = nil,
        pendingMarkdownJump: PendingMarkdownJump? = nil,
        sideStack: SideStackState = .empty
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
        self.liveBanner = liveBanner
        self.liveLocalRefreshRevision = liveLocalRefreshRevision
        self.liveDiskReloadRevision = liveDiskReloadRevision
        self.liveCachedTextBody = liveCachedTextBody
        self.liveCachedData = liveCachedData
        self.liveCachedKind = liveCachedKind
        self.liveCachedTitle = liveCachedTitle
        self.liveDeletedSnapshot = liveDeletedSnapshot
        self.persistedTextSnapshot = persistedTextSnapshot
        self.pendingMarkdownJump = pendingMarkdownJump
        self.sideStack = sideStack
    }

    init(
        document: WorkspaceOpenedDocument,
        documentInspectorSettings: DocumentInspectorSettings = .default
    ) {
        switch document {
        case .workspaceNote(let relativePath):
            let selectedFolderChain = Self.folderChain(for: relativePath)
            self.init(
                selectedFolderChain: selectedFolderChain,
                selectedNotePath: relativePath,
                openedDocument: document,
                documentInspectorSettings: documentInspectorSettings,
                millerActiveDepth: selectedFolderChain.count,
                activeMillerItemPath: relativePath,
                backHistory: [],
                forwardHistory: [],
                historyCurrentItem: document.historyItem
            )
        case .externalMarkdown, .clipboardMarkdown, .diff:
            self.init(
                selectedFolderChain: [],
                selectedNotePath: nil,
                openedDocument: document,
                documentInspectorSettings: documentInspectorSettings,
                millerActiveDepth: 0,
                activeMillerItemPath: nil,
                backHistory: [],
                forwardHistory: [],
                historyCurrentItem: document.historyItem
            )
        }
    }

    init(persisted: PersistedWorkspaceTabState) {
        self.init(
            kind: persisted.kind,
            selectedFolderChain: persisted.selectedFolderChain,
            selectedNotePath: persisted.selectedNotePath,
            openedDocument: persisted.openedDocument,
            documentInspectorSettings: persisted.documentInspectorSettings,
            millerActiveDepth: persisted.millerActiveDepth,
            activeMillerItemPath: persisted.activeMillerItemPath,
            millerHorizontalOrigin: CGFloat(persisted.millerHorizontalOrigin),
            backHistory: persisted.backHistory,
            forwardHistory: persisted.forwardHistory,
            historyCurrentItem: persisted.historyCurrentItem,
            persistedTextSnapshot: persisted.textSnapshot,
            sideStack: persisted.sideStack ?? .empty
        )
    }

    var persisted: PersistedWorkspaceTabState {
        let persistedOpenedDocument = openedDocument

        return PersistedWorkspaceTabState(
            kind: kind,
            selectedFolderChain: selectedFolderChain,
            selectedNotePath: selectedNotePath,
            openedDocument: persistedOpenedDocument,
            documentInspectorSettings: documentInspectorSettings,
            millerActiveDepth: millerActiveDepth,
            activeMillerItemPath: activeMillerItemPath,
            millerHorizontalOrigin: Double(millerHorizontalOrigin),
            backHistory: backHistory,
            forwardHistory: forwardHistory,
            historyCurrentItem: historyCurrentItem ?? openedDocument?.historyItem,
            textSnapshot: persistedOpenedDocument == nil ? nil : persistedTextSnapshot,
            sideStack: sideStack
        )
    }

    mutating func navigate(
        to document: WorkspaceOpenedDocument,
        millerDepth: Int? = nil,
        recordHistory: Bool = true
    ) {
        if recordHistory,
           let currentHistoryItem = historyCurrentItem,
           currentHistoryItem != document.historyItem
        {
            backHistory.append(currentHistoryItem)
            forwardHistory.removeAll()
        }

        kind = .note
        historyCurrentItem = document.historyItem
        openedDocument = document

        switch document {
        case .workspaceNote(let relativePath):
            selectedNotePath = relativePath
            selectedFolderChain = Self.folderChain(for: relativePath)
            millerActiveDepth = millerDepth ?? selectedFolderChain.count
            activeMillerItemPath = relativePath

        case .externalMarkdown, .clipboardMarkdown, .diff:
            selectedNotePath = nil
            selectedFolderChain = []
            millerActiveDepth = 0
            activeMillerItemPath = nil
        }
    }

    static func folderChain(for notePath: String) -> [String] {
        var chain: [String] = []
        let components = notePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }

        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? component : "\(current)/\(component)"
            chain.append(current)
        }

        return chain
    }
}
