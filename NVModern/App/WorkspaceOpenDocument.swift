import Foundation

struct WorkspaceTabPresentation: Equatable {
    let title: String
    let icon: String
}

func workspaceFileIconName(forPath path: String) -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

    switch ext {
    case "pdf":
        return "doc.richtext"
    case "csv", "tsv":
        return "tablecells"
    case "excalidraw":
        return "scribble.variable"
    case "html", "htm":
        return "globe"
    case "epub":
        return "book.closed"
    case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif":
        return "photo"
    case "svg":
        return "square.on.circle"
    case "org":
        return "list.bullet.rectangle"
    case "outline":
        return "list.bullet.indent"
    case "txt", "text":
        return "doc.plaintext"
    case "md", "markdown", "mdown", "mkd":
        return "doc.text"
    case "json":
        return "curlybraces"
    case "yaml", "yml", "toml":
        return "slider.horizontal.3"
    case "zip", "tar", "gz", "bz2", "xz", "7z":
        return "archivebox"
    case "dmg", "pkg":
        return "shippingbox"
    case "mp3", "m4a", "wav", "aiff", "flac":
        return "waveform"
    case "mp4", "mov", "m4v", "avi", "mkv":
        return "film"
    case "swift":
        return "swift"
    case "sh", "zsh", "bash", "fish":
        return "terminal"
    case "js", "jsx", "ts", "tsx", "css", "py", "rb", "rs", "go", "c", "h", "m", "mm":
        return "chevron.left.forwardslash.chevron.right"
    default:
        return "doc"
    }
}

enum WorkspaceDiffSource: Codable, Equatable, Hashable, Sendable {
    case workspace(relativePath: String)
    case external(filePath: String)

    var path: String {
        switch self {
        case .workspace(let relativePath):
            return relativePath
        case .external(let filePath):
            return filePath
        }
    }

    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Untitled.md" : name
    }

    func fileURL(rootURL: URL) -> URL {
        switch self {
        case .workspace(let relativePath):
            return rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        case .external(let filePath):
            return URL(fileURLWithPath: filePath, isDirectory: false).standardizedFileURL
        }
    }
}

enum WorkspaceOpenedDocument: Codable, Equatable {
    case workspaceNote(relativePath: String)
    case externalMarkdown(filePath: String)
    case clipboardMarkdown(title: String, body: String)
    case diff(left: WorkspaceDiffSource, right: WorkspaceDiffSource)

    var tabPresentation: WorkspaceTabPresentation {
        switch self {
        case .workspaceNote(let relativePath):
            let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
            return WorkspaceTabPresentation(
                title: fileName.isEmpty ? "Untitled" : fileName,
                icon: workspaceFileIconName(forPath: relativePath)
            )
        case .externalMarkdown(let filePath):
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            return WorkspaceTabPresentation(
                title: fileName.isEmpty ? "External Markdown" : fileName,
                icon: "arrow.up.forward.square"
            )
        case .clipboardMarkdown(let title, _):
            return WorkspaceTabPresentation(
                title: title,
                icon: "clipboard"
            )
        case .diff(let left, let right):
            return WorkspaceTabPresentation(
                title: "\(left.displayName) ↔ \(right.displayName)",
                icon: "arrow.left.arrow.right"
            )
        }
    }

    var historyItem: WorkspaceHistoryItem? {
        switch self {
        case .workspaceNote(let relativePath):
            return .workspaceNote(relativePath: relativePath)
        case .externalMarkdown(let filePath):
            return .externalMarkdown(filePath: filePath)
        case .clipboardMarkdown, .diff:
            return nil
        }
    }

    var editorPath: String {
        switch self {
        case .workspaceNote(let relativePath):
            return relativePath
        case .externalMarkdown(let filePath):
            return filePath
        case .clipboardMarkdown(let title, _):
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty ? "Clipboard.md" : "\(trimmedTitle).md"
        case .diff(let left, let right):
            return "__diff__/\(left.path)↔\(right.path)"
        }
    }

    var diffSource: WorkspaceDiffSource? {
        switch self {
        case .workspaceNote(let relativePath):
            return .workspace(relativePath: relativePath)
        case .externalMarkdown(let filePath):
            return .external(filePath: filePath)
        case .clipboardMarkdown, .diff:
            return nil
        }
    }
}

enum WorkspaceHistoryItem: Codable, Equatable {
    case workspaceNote(relativePath: String)
    case externalMarkdown(filePath: String)

    var openedDocument: WorkspaceOpenedDocument? {
        switch self {
        case .workspaceNote(let relativePath):
            return .workspaceNote(relativePath: relativePath)
        case .externalMarkdown(let filePath):
            return .externalMarkdown(filePath: filePath)
        }
    }
}

@MainActor
final class WorkspaceWindowLaunchStore {
    struct WindowRequest {
        var projectRootPath: String?
        var documents: [WorkspaceOpenedDocument]
        var pendingJump: PendingMarkdownJump?
        var initialTabState: WorkspaceTabState?
    }

    static let shared = WorkspaceWindowLaunchStore()

    private var pendingWindowRequests: [WindowRequest] = []
    private var recentlyHandledInternalOpenFilePaths: [String: Date] = [:]
    private var openWorkspaceWindowAction: (() -> Void)?

    func registerOpenWorkspaceWindowAction(_ action: @escaping () -> Void) {
        openWorkspaceWindowAction = action
    }

    func enqueueWindowRequest(
        projectRootPath: String?,
        documents: [WorkspaceOpenedDocument] = [],
        pendingJump: PendingMarkdownJump? = nil,
        initialTabState: WorkspaceTabState? = nil
    ) {
        pendingWindowRequests.append(
            WindowRequest(
                projectRootPath: projectRootPath,
                documents: documents,
                pendingJump: pendingJump,
                initialTabState: initialTabState
            )
        )
    }

    func claimNextWindowRequest() -> WindowRequest? {
        guard !pendingWindowRequests.isEmpty else { return nil }
        return pendingWindowRequests.removeFirst()
    }

    /// Reads the head of the queue without consuming it, so a caller can decide
    /// whether it can serve the request before taking ownership of it.
    func peekNextWindowRequest() -> WindowRequest? {
        pendingWindowRequests.first
    }

    func markInternallyHandledOpenFile(path: String) {
        purgeExpiredInternalOpenFileMarks(now: Date())
        recentlyHandledInternalOpenFilePaths[path] = Date()
    }

    func consumeInternalOpenFileMarkIfPresent(path: String) -> Bool {
        let now = Date()
        purgeExpiredInternalOpenFileMarks(now: now)
        guard recentlyHandledInternalOpenFilePaths.removeValue(forKey: path) != nil else {
            return false
        }
        return true
    }

    func requestWorkspaceWindow() {
        openWorkspaceWindowAction?()
    }

    private func purgeExpiredInternalOpenFileMarks(now: Date) {
        let expirationInterval: TimeInterval = 5
        recentlyHandledInternalOpenFilePaths = recentlyHandledInternalOpenFilePaths.filter { _, timestamp in
            now.timeIntervalSince(timestamp) < expirationInterval
        }
    }
}
