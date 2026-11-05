import Foundation
import UniformTypeIdentifiers

enum MillerItemKind: Hashable {
    case folder
    case note
}

struct MillerItem: Identifiable, Hashable {
    let relativePath: String
    let name: String
    let kind: MillerItemKind
    let modifiedDate: Date?

    var id: String { relativePath }
}

struct NoteSearchResult: Identifiable, Hashable {
    let title: String
    let relativePath: String
    let snippet: String
    let modifiedDate: Date?
    let score: Int

    var id: String { relativePath }

    var displayPath: String {
        relativePath.replacingOccurrences(of: "/", with: " › ")
    }
}

struct EditorDiffFileContext: Equatable {
    let path: String
    let title: String
    let body: String
}

struct EditorDiffContext: Equatable {
    let left: EditorDiffFileContext
    let right: EditorDiffFileContext
}

struct EditorSelectionContext {
    enum Kind: String {
        case folder
        case text
        case pdf
        case csv
        case canvas
        case image
        case html
        case epub
        case diff
        case unsupported

        var isEditable: Bool {
            self == .text || self == .canvas
        }
    }

    let kind: Kind
    let title: String
    let relativePath: String
    let body: String
    let modifiedDate: Date?
    let mimeType: String?
    let fileSize: Int64?
    let diff: EditorDiffContext?

    init(
        kind: Kind,
        title: String,
        relativePath: String,
        body: String,
        modifiedDate: Date?,
        mimeType: String?,
        fileSize: Int64?,
        diff: EditorDiffContext? = nil
    ) {
        self.kind = kind
        self.title = title
        self.relativePath = relativePath
        self.body = body
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.diff = diff
    }
}

struct TextContextLoadDescriptor {
    let title: String
    let relativePath: String
    let fileURL: URL
    let modifiedDate: Date?
    let mimeType: String?
    let fileSize: Int64?
}

struct WikilinkAutocompleteSuggestion {
    let label: String
    let insertText: String
    let detail: String
}

enum MarkdownReferenceKind: String {
    case heading
    case block
}

struct MarkdownReferenceTarget {
    let kind: MarkdownReferenceKind
    let query: String
}

struct ParsedWikilinkTarget {
    let raw: String
    let core: String
    let noteTarget: String
    let alias: String
    let reference: MarkdownReferenceTarget?
}

struct MarkdownHeadingReference {
    let text: String
    let line: Int
    let level: Int
}

struct MarkdownBlockReference {
    let id: String
    let line: Int
}

struct MarkdownReferenceIndex {
    let headings: [MarkdownHeadingReference]
    let blocks: [MarkdownBlockReference]
}

@MainActor
final class NotesWorkspaceModel: ObservableObject {
    @Published private(set) var runtimeConfig: NVModernRuntimeConfig
    @Published private(set) var childrenByFolder: [String: [MillerItem]] = [:]
    @Published private(set) var lastReloadDate = Date()
    @Published private(set) var liveTreeRevision: Int = 0
    @Published private(set) var liveConflictedPaths: Set<String> = []
    @Published private(set) var liveUpdateRevision: Int = 0
    @Published private(set) var lastLiveSyncUpdate: WorkspaceLiveSyncUpdate?

    private var searchEngine: NoteSearchEngine
    private let projectRootPath: String?
    private var filesByPath: [String: ScannedFile] = [:]
    // Successful local creations can open before the background scan discovers
    // them. Keep their written text until a scan supplies authoritative metadata.
    private var pendingCreatedTextBodies: [String: String] = [:]
    private var markdownReferenceIndexCache: [String: CachedMarkdownReferenceIndex] = [:]
    private let liveSyncApplyQueue = DispatchQueue(label: "nvmodern.notes-live-sync-apply", qos: .utility)
    private var liveSyncApplyGeneration: Int = 0
    private var pendingLiveSyncApplyTask: Task<Void, Never>?
    private let liveSyncController: WorkspaceLiveSyncController

    init(projectRootPath: String? = nil) {
        self.projectRootPath = projectRootPath
        let initialRuntimeConfig = NVModernConfigLoader.load(projectRootPath: projectRootPath)
        runtimeConfig = initialRuntimeConfig
        searchEngine = NoteSearchEngineRegistry.shared.engine(for: initialRuntimeConfig.activeProject)
        liveSyncController = WorkspaceLiveSyncController(rootURL: initialRuntimeConfig.rootURL)
        liveSyncController.onUpdate = { [weak self] update in
            self?.scheduleLiveSyncApply(update: update)
        }
        // The first configuration refresh schedules the initial tree scan.
        // Calling reload() here scheduled the same scan a second time.
        reloadConfiguration()
    }

    deinit {
        pendingLiveSyncApplyTask?.cancel()
        liveSyncController.stop()
    }

    /// Full reload: config plus a fresh tree scan. The scan runs on the
    /// background scan queue and the snapshot applies when it lands, so
    /// callers get control back immediately instead of blocking the main
    /// thread on a full iCloud Drive walk.
    func reload() {
        reloadConfiguration()
        scheduleScan(update: nil, reason: "reload")
    }

    /// Re-reads config.toml and refreshes config-dependent state without
    /// rescanning the tree — config edits (themes, users, substitutions) have
    /// nothing to do with the file tree, and rescanning here used to put a
    /// full synchronous iCloud walk on the main thread. A changed project
    /// root, or a first load with no snapshot yet, still schedules a scan.
    func reloadConfiguration() {
        let previousRootURL = runtimeConfig.rootURL

        runtimeConfig = NVModernConfigLoader.load(projectRootPath: projectRootPath)
        if runtimeConfig.rootURL != previousRootURL {
            pendingCreatedTextBodies.removeAll()
        }
        searchEngine = NoteSearchEngineRegistry.shared.engine(for: runtimeConfig.activeProject)
        liveSyncController.updateRootURL(runtimeConfig.rootURL, reason: "NotesWorkspaceModel.reload()")
        lastReloadDate = Date()

        print("[NVModern][Config] \(runtimeConfig.debugLabel)")
        print("[NVModern][Index] folders=\(childrenByFolder.count) files=\(filesByPath.count)")

        if runtimeConfig.rootURL != previousRootURL || filesByPath.isEmpty {
            scheduleScan(update: nil, reason: runtimeConfig.rootURL != previousRootURL ? "rootChanged" : "initialScan")
        }
    }

    /// Schedules a full-tree scan on the background scan queue and applies
    /// the snapshot on the main actor when it lands. A newer request cancels
    /// an older pending one (last write wins); the generation guard discards
    /// snapshots whose scan was already in flight.
    func scheduleScan(update: WorkspaceLiveSyncUpdate?, reason: String) {
        liveSyncApplyGeneration += 1
        let applyGeneration = liveSyncApplyGeneration
        let rootURL = runtimeConfig.rootURL

        pendingLiveSyncApplyTask?.cancel()
        pendingLiveSyncApplyTask = Task { [weak self] in
            guard let self else { return }

            await withCheckedContinuation { continuation in
                self.liveSyncApplyQueue.async {
                    let scanStartedAt = ProcessInfo.processInfo.systemUptime
                    PerformanceDiagnostics.background(
                        kind: "workspace-scan",
                        event: "scan.begin",
                        metadata: ["reason": reason, "root": rootURL.path]
                    )
                    let snapshot = NotesScanner.scan(rootURL: rootURL)
                    PerformanceDiagnostics.background(
                        kind: "workspace-scan",
                        event: "scan.end",
                        startedAt: scanStartedAt,
                        metadata: [
                            "fileCount": String(snapshot.filesByPath.count),
                            "folderCount": String(snapshot.childrenByFolder.count),
                            "reason": reason,
                            "root": rootURL.path
                        ]
                    )
                    Task { @MainActor [weak self] in
                        guard let self else {
                            continuation.resume()
                            return
                        }

                        defer {
                            continuation.resume()
                        }

                        guard applyGeneration == self.liveSyncApplyGeneration,
                              self.runtimeConfig.rootURL == rootURL else {
                            return
                        }

                        // Apply against the current config — a config-only
                        // reload may have landed while the scan ran.
                        self.applySnapshot(snapshot, runtimeConfig: self.runtimeConfig, liveUpdate: update)
                        self.liveTreeRevision += 1

                        if let update {
                            self.liveConflictedPaths = update.conflictedPaths
                            self.lastLiveSyncUpdate = update
                            self.liveUpdateRevision += 1

                            let selfWriteLabel = update.selfWriteConfirmedPaths.sorted().joined(separator: ", ")
                            let modifiedLabel = update.externalModifiedPaths.sorted().joined(separator: ", ")
                            let deletedLabel = update.externalDeletedPaths.sorted().joined(separator: ", ")
                            let renamedLabel = update.renamedPaths.keys.sorted().compactMap { oldPath in
                                update.renamedPaths[oldPath].map { "\(oldPath)->\($0)" }
                            }.joined(separator: ", ")
                            let conflictLabel = update.conflictedPaths.sorted().joined(separator: ", ")
                            print(
                                "[NVModern][LiveSync] applied reason=\(update.reason) changedPaths=\(update.changedPaths.count) selfWrites=[\(selfWriteLabel)] modified=[\(modifiedLabel)] deleted=[\(deletedLabel)] renamed=[\(renamedLabel)] conflicts=[\(conflictLabel)]"
                            )
                        } else {
                            print("[NVModern][Index] scanned reason=\(reason) folders=\(self.childrenByFolder.count) files=\(self.filesByPath.count) searchable=\(snapshot.searchDocuments.count)")
                        }
                    }
                }
            }
        }
    }

    var supportedSearchFacetKeys: [String] {
        runtimeConfig.supportedSearchFacetKeys
    }

    func search(query: String, cursorLocationUTF16: Int? = nil) async -> NoteSearchResponse {
        await searchEngine.search(
            query: query,
            rootURL: runtimeConfig.rootURL,
            cursorLocationUTF16: cursorLocationUTF16,
            supportedFacetKeys: runtimeConfig.supportedSearchFacetKeys
        )
    }

    func isLiveConflictedPath(_ relativePath: String) -> Bool {
        liveConflictedPaths.contains(relativePath)
    }

    /// Builds the launchpad browser's columns.
    ///
    /// Column 0 is the synthetic root list (Workspace / Recent).
    /// Chain element 0 names which of those is selected, and every later chain
    /// element is a real folder path, so chain index `i` still produces column
    /// `i + 1` exactly as it did before the root column existed.
    func columns(for selectedFolderChain: [String], recentItems: [MillerItem] = []) -> [[MillerItem]] {
        var columns: [[MillerItem]] = [LaunchpadRootColumn.items()]

        let chain = LaunchpadRootColumn.normalized(selectedFolderChain)
        let source = LaunchpadRootColumn.source(for: chain.first)

        if case .recent = source {
            columns.append(recentItems)
            return columns
        }

        guard var parentPath = LaunchpadRootColumn.rootFolderPath(for: source) else {
            return columns
        }

        columns.append(childrenByFolder[parentPath, default: []])

        for selectedFolderPath in chain.dropFirst() {
            let siblings = childrenByFolder[parentPath, default: []]
            let isValidFolder = siblings.contains(where: { item in
                item.kind == .folder && item.relativePath == selectedFolderPath
            })

            guard isValidFolder else { break }

            parentPath = selectedFolderPath
            columns.append(childrenByFolder[parentPath, default: []])
        }

        return columns
    }

    private func scheduleLiveSyncApply(update: WorkspaceLiveSyncUpdate) {
        scheduleScan(update: update, reason: update.reason)
    }

    private func applySnapshot(
        _ snapshot: NotesScanSnapshot,
        runtimeConfig: NVModernRuntimeConfig,
        liveUpdate: WorkspaceLiveSyncUpdate?
    ) {
        self.runtimeConfig = runtimeConfig
        searchEngine = NoteSearchEngineRegistry.shared.engine(for: runtimeConfig.activeProject)
        childrenByFolder = snapshot.childrenByFolder
        filesByPath = snapshot.filesByPath
        pendingCreatedTextBodies = pendingCreatedTextBodies.filter { path, _ in
            filesByPath[path] == nil && noteURL(for: path).map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        markdownReferenceIndexCache.removeAll(keepingCapacity: true)

        let isSelfWriteOnly = liveUpdate.map(Self.isSelfWriteOnly) ?? false
        Task {
            await searchEngine.updateIndex(
                rootURL: runtimeConfig.rootURL,
                facetMap: runtimeConfig.searchFacetMap,
                documents: snapshot.searchDocuments,
                liveUpdate: liveUpdate,
                isSelfWriteOnly: isSelfWriteOnly
            )
        }
    }

    /// Whether every path in a live-sync batch is one the app itself just
    /// wrote. Those batches arrive on every save and must never restart
    /// indexing — at most they upsert exactly the paths that were written.
    static func isSelfWriteOnly(_ update: WorkspaceLiveSyncUpdate) -> Bool {
        guard !update.selfWriteConfirmedPaths.isEmpty,
              update.externalModifiedPaths.isEmpty,
              update.externalAddedPaths.isEmpty,
              update.externalDeletedPaths.isEmpty,
              update.renamedPaths.isEmpty,
              update.addedFolders.isEmpty,
              update.removedFolders.isEmpty else {
            return false
        }
        return update.changedPaths.isSubset(of: update.selfWriteConfirmedPaths)
    }

    /// Waits until the initial background tree scan has been applied. The
    /// first scan is asynchronous — `init` returns before any file metadata
    /// exists — so callers that need the tree populated should await this.
    /// Returns false when the snapshot did not arrive within `timeout`.
    func waitForInitialSnapshot(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while liveTreeRevision == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return liveTreeRevision > 0
    }

    func contextForNote(relativePath: String) -> EditorSelectionContext? {
        WorkspaceActivationTraceCenter.shared.mark(path: relativePath, event: "notes.contextForNote.start")
        let contextStart = ProcessInfo.processInfo.systemUptime
        if let body = pendingCreatedTextBodies[relativePath],
           let url = noteURL(for: relativePath),
           FileManager.default.fileExists(atPath: url.path) {
            let preparation = ArborDocumentSource.prepareForOpen(path: relativePath, source: body)
            if preparation.insertedLanguageDirective {
                try? saveTextNote(relativePath: relativePath, body: preparation.source)
            }
            return EditorSelectionContext(
                kind: .text,
                title: url.deletingPathExtension().lastPathComponent,
                relativePath: relativePath,
                body: preparation.source,
                modifiedDate: nil,
                mimeType: "text/plain",
                fileSize: Int64(preparation.source.lengthOfBytes(using: .utf8))
            )
        }
        guard let file = filesByPath[relativePath] else {
            WorkspaceActivationTraceCenter.shared.mark(path: relativePath, event: "notes.contextForNote.missing")
            return nil
        }

        if file.isTextFile {
            let loadStart = ProcessInfo.processInfo.systemUptime
            let loadedContent = loadFullText(from: file.fileURL) ?? ""
            let preparation = ArborDocumentSource.prepareForOpen(
                path: file.relativePath,
                source: loadedContent
            )
            let content = preparation.source
            if preparation.insertedLanguageDirective {
                try? saveTextNote(relativePath: file.relativePath, body: content)
            }
            let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            WorkspaceActivationTraceCenter.shared.mark(
                path: relativePath,
                event: "notes.contextForNote.textLoad",
                details: [
                    "bytes": String(content.lengthOfBytes(using: .utf8)),
                    "durationMs": String(format: "%.2f", loadDurationMs)
                ]
            )
            let context = EditorSelectionContext(
                kind: .text,
                title: file.title,
                relativePath: file.relativePath,
                body: content,
                modifiedDate: preparation.insertedLanguageDirective ? Date() : file.modifiedDate,
                mimeType: "text/plain",
                fileSize: preparation.insertedLanguageDirective
                    ? Int64(content.lengthOfBytes(using: .utf8))
                    : file.fileSize
            )
            let totalDurationMs = (ProcessInfo.processInfo.systemUptime - contextStart) * 1000
            WorkspaceActivationTraceCenter.shared.mark(
                path: relativePath,
                event: "notes.contextForNote.end",
                details: [
                    "kind": context.kind.rawValue,
                    "durationMs": String(format: "%.2f", totalDurationMs)
                ]
            )
            return context
        }

        let context = lightweightContextForScannedFile(file)
        let totalDurationMs = (ProcessInfo.processInfo.systemUptime - contextStart) * 1000
        WorkspaceActivationTraceCenter.shared.mark(
            path: relativePath,
            event: "notes.contextForNote.end",
            details: [
                "kind": context.kind.rawValue,
                "durationMs": String(format: "%.2f", totalDurationMs)
            ]
        )
        return context
    }

    func lightweightContextForNote(relativePath: String) -> EditorSelectionContext? {
        if pendingCreatedTextBodies[relativePath] != nil {
            return contextForNote(relativePath: relativePath)
        }
        guard let file = filesByPath[relativePath] else {
            return nil
        }

        if file.isTextFile {
            return EditorSelectionContext(
                kind: .text,
                title: file.title,
                relativePath: file.relativePath,
                body: "",
                modifiedDate: file.modifiedDate,
                mimeType: "text/plain",
                fileSize: file.fileSize
            )
        }

        return lightweightContextForScannedFile(file)
    }

    func textContextLoadDescriptorForNote(relativePath: String) -> TextContextLoadDescriptor? {
        // The caller already has the bytes written by this app; a disk read
        // and an index wait add no information while creation is pending.
        guard pendingCreatedTextBodies[relativePath] == nil else { return nil }
        guard let file = filesByPath[relativePath],
              file.isTextFile else {
            return nil
        }

        return TextContextLoadDescriptor(
            title: file.title,
            relativePath: file.relativePath,
            fileURL: file.fileURL,
            modifiedDate: file.modifiedDate,
            mimeType: "text/plain",
            fileSize: file.fileSize
        )
    }

    func textContextForNote(relativePath: String) async -> EditorSelectionContext? {
        guard let file = filesByPath[relativePath],
              file.isTextFile else {
            return nil
        }

        WorkspaceActivationTraceCenter.shared.mark(path: relativePath, event: "notes.textContextForNote.async.start")
        let loadStart = ProcessInfo.processInfo.systemUptime
        let loadedContent = (try? await WorkspaceFileIO.shared.readText(from: file.fileURL)) ?? ""
        let preparation = ArborDocumentSource.prepareForOpen(
            path: file.relativePath,
            source: loadedContent
        )
        let content = preparation.source
        if preparation.insertedLanguageDirective {
            do {
                try await saveTextNoteAsync(relativePath: file.relativePath, body: content)
            } catch {
                print("[NVModern][Arbor] Failed to add language directive to \(file.relativePath): \(error)")
            }
        }
        let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        WorkspaceActivationTraceCenter.shared.mark(
            path: relativePath,
            event: "notes.textContextForNote.async.end",
            details: [
                "bytes": String(content.lengthOfBytes(using: .utf8)),
                "durationMs": String(format: "%.2f", loadDurationMs)
            ]
        )

        return EditorSelectionContext(
            kind: .text,
            title: file.title,
            relativePath: file.relativePath,
            body: content,
            modifiedDate: preparation.insertedLanguageDirective ? Date() : file.modifiedDate,
            mimeType: "text/plain",
            fileSize: preparation.insertedLanguageDirective
                ? Int64(content.lengthOfBytes(using: .utf8))
                : file.fileSize
        )
    }

    func contextForFolder(relativePath: String?) -> EditorSelectionContext {
        let folderPath = relativePath ?? ""
        let children = childrenByFolder[folderPath, default: []]
        let folderName: String

        if folderPath.isEmpty {
            folderName = runtimeConfig.rootURL.lastPathComponent
        } else {
            folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        }

        let listing = children
            .map { item in
                let marker = item.kind == .folder ? "📁" : "📝"
                return "\(marker) \(item.name)"
            }
            .joined(separator: "\n")

        let body = listing.isEmpty
            ? "Folder is empty."
            : "Children:\n\n\(listing)"

        return EditorSelectionContext(
            kind: .folder,
            title: folderName,
            relativePath: folderPath,
            body: body,
            modifiedDate: nil,
            mimeType: nil,
            fileSize: nil
        )
    }

    func createNote(inFolderRelativePath folderRelativePath: String?, fileName: String) throws -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Please enter a filename"])
        }

        var sanitized = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        if sanitized.hasSuffix(".") {
            sanitized.removeLast()
        }

        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid filename"])
        }

        if (sanitized as NSString).pathExtension.isEmpty {
            sanitized += ".md"
        }

        let parentPath = normalizeRelativePath(folderRelativePath ?? "")
        let relativePath = parentPath.isEmpty ? sanitized : "\(parentPath)/\(sanitized)"

        guard let fileURL = noteURL(for: relativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw NSError(domain: "NVModern", code: 409, userInfo: [NSLocalizedDescriptionKey: "A file with this name already exists"])
        }

        let parentURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let data = Self.initialFileData(forPath: relativePath)
        let token = liveSyncController.beginLocalWrite(
            relativePath: relativePath,
            expectedData: data,
            reason: "createNote"
        )

        do {
            try data.write(to: fileURL, options: .atomic)
            if NotesScanner.isTextFile(fileURL) {
                pendingCreatedTextBodies[relativePath] = String(decoding: data, as: UTF8.self)
            }
            liveSyncController.completeLocalWrite(token, fileURL: fileURL)
        } catch {
            liveSyncController.failLocalWrite(token, error: error)
            throw error
        }

        return relativePath
    }

    /// Contents of a freshly created note: an empty Excalidraw scene for
    /// canvases, otherwise whatever the format seeds an empty document with.
    /// Shared with notes created outside the workspace.
    static func initialFileData(forPath path: String) -> Data {
        if path.lowercased().hasSuffix(".excalidraw") {
            return Data("{\"type\":\"excalidraw\",\"version\":2,\"source\":\"https://excalidraw.com\",\"elements\":[],\"appState\":{},\"files\":{}}".utf8)
        }
        return Data(ArborDocumentSource.prepareForOpen(path: path, source: "").source.utf8)
    }

    func createFolder(inFolderRelativePath folderRelativePath: String?, name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Please enter a folder name"])
        }

        var sanitized = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while sanitized.hasSuffix(".") {
            sanitized.removeLast()
        }

        guard !sanitized.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid folder name"])
        }

        let parentPath = normalizeRelativePath(folderRelativePath ?? "")
        let relativePath = parentPath.isEmpty ? sanitized : "\(parentPath)/\(sanitized)"

        guard let folderURL = workspaceURL(for: relativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid folder path"])
        }

        if FileManager.default.fileExists(atPath: folderURL.path) {
            throw NSError(domain: "NVModern", code: 409, userInfo: [NSLocalizedDescriptionKey: "An item with this name already exists"])
        }

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        return relativePath
    }

    func renameWorkspaceItem(relativePath: String, to proposedName: String) throws -> String {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard let sourceURL = workspaceURL(for: normalizedPath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid item path"])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item no longer exists"])
        }

        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Please enter a name"])
        }

        var sanitizedLeafName = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while sanitizedLeafName.hasSuffix(".") {
            sanitizedLeafName.removeLast()
        }

        guard !sanitizedLeafName.isEmpty else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid name"])
        }

        if !isDirectory.boolValue {
            let currentLeafName = sourceURL.lastPathComponent
            let currentExtension = sourceURL.pathExtension
            let proposedExtension = (sanitizedLeafName as NSString).pathExtension

            if !proposedExtension.isEmpty,
               proposedExtension.caseInsensitiveCompare(currentExtension) != .orderedSame {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Changing the file extension is not supported here"]
                )
            }

            if proposedExtension.isEmpty, !currentExtension.isEmpty {
                let baseName = URL(fileURLWithPath: sanitizedLeafName).deletingPathExtension().lastPathComponent
                sanitizedLeafName = baseName.isEmpty ? currentLeafName : "\(baseName).\(currentExtension)"
            }
        }

        let parentRelativePath = directoryPath(for: normalizedPath)
        let destinationRelativePath = parentRelativePath.isEmpty
            ? sanitizedLeafName
            : "\(parentRelativePath)/\(sanitizedLeafName)"

        if destinationRelativePath == normalizedPath {
            return normalizedPath
        }

        guard let destinationURL = workspaceURL(for: destinationRelativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid destination path"])
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw NSError(domain: "NVModern", code: 409, userInfo: [NSLocalizedDescriptionKey: "An item with this name already exists"])
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return destinationRelativePath
    }

    func moveWorkspaceNote(relativePath: String, toFolderRelativePath folderRelativePath: String?) throws -> String {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard let sourceURL = workspaceURL(for: normalizedPath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        var isSourceDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isSourceDirectory),
              !isSourceDirectory.boolValue else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Note no longer exists"])
        }

        let destinationFolderPath = normalizeRelativePath(folderRelativePath ?? "")
        guard let destinationFolderURL = workspaceItemURL(allowingRootRelativePath: destinationFolderPath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid destination folder"])
        }

        var isDestinationDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationFolderURL.path, isDirectory: &isDestinationDirectory),
              isDestinationDirectory.boolValue else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Destination folder no longer exists"])
        }

        let destinationRelativePath = destinationFolderPath.isEmpty
            ? sourceURL.lastPathComponent
            : "\(destinationFolderPath)/\(sourceURL.lastPathComponent)"
        if destinationRelativePath == normalizedPath {
            return normalizedPath
        }

        guard let destinationURL = workspaceURL(for: destinationRelativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid destination path"])
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSError(domain: "NVModern", code: 409, userInfo: [NSLocalizedDescriptionKey: "A note with this name already exists in the destination"])
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return destinationRelativePath
    }

    /// Moves a browser selection as one operation after validating every source and
    /// destination. If a filesystem error occurs midway through the move, completed
    /// items are moved back before the original error is surfaced.
    func moveWorkspaceItems(
        relativePaths: [String],
        toFolderRelativePath folderRelativePath: String?
    ) throws -> [String: String] {
        let normalizedPaths = Array(Set(relativePaths.map(normalizeRelativePath)))
            .filter { !$0.isEmpty }
            .sorted()
        guard !normalizedPaths.isEmpty else {
            throw NSError(
                domain: "NVModern",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Select at least one item to move"]
            )
        }

        for path in normalizedPaths {
            if normalizedPaths.contains(where: { ancestor in
                ancestor != path && path.hasPrefix(ancestor + "/")
            }) {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "The selection contains an item inside a selected folder"]
                )
            }
        }

        let destinationFolderPath = normalizeRelativePath(folderRelativePath ?? "")
        guard let destinationFolderURL = workspaceItemURL(allowingRootRelativePath: destinationFolderPath) else {
            throw NSError(
                domain: "NVModern",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid destination folder"]
            )
        }

        var isDestinationDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: destinationFolderURL.path,
            isDirectory: &isDestinationDirectory
        ), isDestinationDirectory.boolValue else {
            throw NSError(
                domain: "NVModern",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Destination folder no longer exists"]
            )
        }

        struct PlannedMove {
            let sourcePath: String
            let destinationPath: String
            let sourceURL: URL
            let destinationURL: URL
        }

        var plannedMoves: [PlannedMove] = []
        var plannedDestinations = Set<String>()
        for sourcePath in normalizedPaths {
            guard let sourceURL = workspaceURL(for: sourcePath) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid item path: \(sourcePath)"]
                )
            }

            var isSourceDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isSourceDirectory) else {
                throw NSError(
                    domain: "NVModern",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Item no longer exists: \(sourcePath)"]
                )
            }

            if isSourceDirectory.boolValue,
               (destinationFolderPath == sourcePath || destinationFolderPath.hasPrefix(sourcePath + "/")) {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "A folder cannot be moved into itself"]
                )
            }

            let destinationPath = destinationFolderPath.isEmpty
                ? sourceURL.lastPathComponent
                : "\(destinationFolderPath)/\(sourceURL.lastPathComponent)"
            if destinationPath == sourcePath {
                continue
            }

            guard plannedDestinations.insert(destinationPath).inserted else {
                throw NSError(
                    domain: "NVModern",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "The selection contains items with the same name"]
                )
            }
            guard let destinationURL = workspaceURL(for: destinationPath) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid destination path"]
                )
            }
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw NSError(
                    domain: "NVModern",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "An item named \(sourceURL.lastPathComponent) already exists in the destination"]
                )
            }

            plannedMoves.append(
                PlannedMove(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
            )
        }

        var completedMoves: [PlannedMove] = []
        do {
            for move in plannedMoves {
                try FileManager.default.moveItem(at: move.sourceURL, to: move.destinationURL)
                completedMoves.append(move)
            }
        } catch {
            for move in completedMoves.reversed() {
                try? FileManager.default.moveItem(at: move.destinationURL, to: move.sourceURL)
            }
            throw error
        }

        return Dictionary(uniqueKeysWithValues: plannedMoves.map { ($0.sourcePath, $0.destinationPath) })
    }

    func duplicateWorkspaceNote(relativePath: String) throws -> String {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard let sourceURL = workspaceURL(for: normalizedPath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Only files can be duplicated"])
        }

        let parentRelativePath = directoryPath(for: normalizedPath)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension

        let candidateLeafNames = sequence(first: 1, next: { $0 + 1 }).lazy.map { copyIndex -> String in
            let suffix = copyIndex == 1 ? " copy" : " copy \(copyIndex)"
            let candidateBase = "\(baseName)\(suffix)"
            return pathExtension.isEmpty ? candidateBase : "\(candidateBase).\(pathExtension)"
        }

        guard let destinationRelativePath = candidateLeafNames
            .map({ candidateLeafName in
                parentRelativePath.isEmpty ? candidateLeafName : "\(parentRelativePath)/\(candidateLeafName)"
            })
            .first(where: { candidateRelativePath in
                guard let candidateURL = workspaceURL(for: candidateRelativePath) else { return false }
                return !FileManager.default.fileExists(atPath: candidateURL.path)
            }),
              let destinationURL = workspaceURL(for: destinationRelativePath) else {
            throw NSError(domain: "NVModern", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create duplicate name"])
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationRelativePath
    }

    func trashWorkspaceItem(relativePath: String) throws {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard let sourceURL = workspaceURL(for: normalizedPath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid item path"])
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item no longer exists"])
        }

        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
    }

    func finderTags(forWorkspaceItem relativePath: String?) throws -> [String] {
        guard let url = workspaceItemURL(allowingRootRelativePath: relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item no longer exists"])
        }

        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    func setFinderTags(_ tags: [String], forWorkspaceItem relativePath: String?) throws {
        guard let url = workspaceItemURL(allowingRootRelativePath: relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item no longer exists"])
        }

        let cleanedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sortedTags = Array(Set(cleanedTags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        try (url as NSURL).setResourceValue(sortedTags, forKey: URLResourceKey.tagNamesKey)
    }

    func saveTextNote(relativePath: String, body: String) throws {
        guard let url = noteURL(for: relativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        let data = Data(body.utf8)
        let token = liveSyncController.beginLocalWrite(
            relativePath: relativePath,
            expectedData: data,
            reason: "saveTextNote"
        )

        do {
            try body.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            if pendingCreatedTextBodies[relativePath] != nil {
                pendingCreatedTextBodies[relativePath] = body
            }
            liveSyncController.completeLocalWrite(token, fileURL: url)
        } catch {
            liveSyncController.failLocalWrite(token, error: error)
            throw error
        }
    }

    func saveTextNoteAsync(relativePath: String, body: String) async throws {
        guard let url = noteURL(for: relativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        let data = Data(body.utf8)
        let token = liveSyncController.beginLocalWrite(
            relativePath: relativePath,
            expectedData: data,
            reason: "saveTextNote"
        )

        do {
            try await WorkspaceFileIO.shared.writeText(body, to: url)
            if pendingCreatedTextBodies[relativePath] != nil {
                pendingCreatedTextBodies[relativePath] = body
            }
            liveSyncController.completeLocalWrite(token, fileURL: url)
        } catch {
            liveSyncController.failLocalWrite(token, error: error)
            throw error
        }
    }

    func saveDataNote(relativePath: String, data: Data) throws {
        guard let url = noteURL(for: relativePath) else {
            throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid note path"])
        }

        let token = liveSyncController.beginLocalWrite(
            relativePath: relativePath,
            expectedData: data,
            reason: "saveDataNote"
        )

        do {
            try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
            liveSyncController.completeLocalWrite(token, fileURL: url)
        } catch {
            liveSyncController.failLocalWrite(token, error: error)
            throw error
        }
    }

    func updateLiveSyncVisibleWorkspaceDocument(
        observerID: String,
        relativePath: String?,
        kind: EditorSelectionContext.Kind?,
        isEditable: Bool
    ) {
        liveSyncController.registerVisibleDocument(
            observerID: observerID,
            relativePath: relativePath,
            kind: kind?.rawValue,
            isEditable: isEditable
        )
    }

    func unregisterLiveSyncObserver(observerID: String) {
        liveSyncController.unregisterObserver(observerID: observerID)
    }

    func resolveTransclusion(target: String, sourceRelativePath: String?) -> (relativePath: String, content: String, kind: String?)? {
        let parsed = parseObsidianWikilinkTarget(target)
        guard let resolvedPath = resolveWikilinkTarget(target, from: sourceRelativePath),
              let url = noteURL(for: resolvedPath),
              let fullContent = loadFullText(from: url)
        else {
            return nil
        }

        let content: String
        if let reference = parsed.reference,
           reference.kind == .heading {
            guard let range = markdownHeadingSectionRange(in: fullContent, query: reference.query) else {
                return nil
            }
            content = String(fullContent[range])
        } else {
            content = fullContent
        }

        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return (resolvedPath, content, ext.isEmpty ? nil : ext)
    }

    func saveTransclusion(target: String, sourceRelativePath: String?, content: String) throws -> String {
        let parsed = parseObsidianWikilinkTarget(target)
        guard let resolvedPath = resolveWikilinkTarget(target, from: sourceRelativePath) else {
            throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not resolve transclusion target"])
        }

        if let reference = parsed.reference,
           reference.kind == .heading {
            guard let url = noteURL(for: resolvedPath),
                  var fullContent = loadFullText(from: url),
                  let range = markdownHeadingSectionRange(in: fullContent, query: reference.query)
            else {
                throw NSError(domain: "NVModern", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not resolve transclusion heading"])
            }

            fullContent.replaceSubrange(range, with: content)
            try saveTextNote(relativePath: resolvedPath, body: fullContent)
        } else {
            try saveTextNote(relativePath: resolvedPath, body: content)
        }

        return resolvedPath
    }

    func resolveWikilinkTarget(_ rawTarget: String, from sourceRelativePath: String?) -> String? {
        let parsed = parseObsidianWikilinkTarget(rawTarget)
        let target = parsed.noteTarget
        guard !target.isEmpty else {
            return nil
        }

        let allFiles = allIndexedFilePaths()
        let currentDir = directoryPath(for: sourceRelativePath)
        var candidates: [String] = []
        var seen = Set<String>()

        func pushCandidate(_ value: String) {
            let normalized = normalizeRelativePath(value)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return }
            seen.insert(normalized)
            candidates.append(normalized)
        }

        pushCandidate(target)

        if !currentDir.isEmpty {
            pushCandidate("\(currentDir)/\(target)")
        }

        let targetHasExtension = target.range(of: #"\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
        if !targetHasExtension {
            for ext in NotesScanner.existingWikilinkExtensions {
                pushCandidate("\(target).\(ext)")
                if !currentDir.isEmpty {
                    pushCandidate("\(currentDir)/\(target).\(ext)")
                }
            }
            pushCandidate("\(target).outline")
            if !currentDir.isEmpty {
                pushCandidate("\(currentDir)/\(target).outline")
            }
        }

        for candidate in candidates where allFiles.contains(candidate) {
            return candidate
        }

        let exactBasenameMatches = allFiles.filter {
            URL(fileURLWithPath: $0).lastPathComponent == target
        }
        if exactBasenameMatches.count == 1 {
            return exactBasenameMatches[0]
        }

        let basenameWithoutExtensionMatches = allFiles.filter {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == target
        }
        if basenameWithoutExtensionMatches.count == 1 {
            return basenameWithoutExtensionMatches[0]
        }

        return nil
    }

    func autocompleteWikilinks(query: String, sourceRelativePath: String?, limit: Int = 50) -> [WikilinkAutocompleteSuggestion] {
        let parsed = parseObsidianWikilinkTarget(query)

        if let reference = parsed.reference {
            return autocompleteWikilinkReferences(
                parsed: parsed,
                reference: reference,
                sourceRelativePath: sourceRelativePath,
                limit: limit
            )
        }

        return autocompleteWikilinkFiles(query: parsed.core, sourceRelativePath: sourceRelativePath, limit: limit)
    }

    private func autocompleteWikilinkFiles(query: String, sourceRelativePath: String?, limit: Int) -> [WikilinkAutocompleteSuggestion] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentDir = directoryPath(for: sourceRelativePath)

        let files = allIndexedFilePaths()
            .filter { path in
                guard let file = filesByPath[path] else { return false }
                return file.isTextFile
            }

        let suggestions = files
            .filter { path in
                guard !normalizedQuery.isEmpty else { return true }

                let visible = relativeToCurrentDirectory(path: path, currentDirectory: currentDir).lowercased()
                let full = path.lowercased()
                let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()

                return visible.contains(normalizedQuery)
                    || full.contains(normalizedQuery)
                    || name.contains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                let leftVisible = relativeToCurrentDirectory(path: lhs, currentDirectory: currentDir)
                let rightVisible = relativeToCurrentDirectory(path: rhs, currentDirectory: currentDir)

                let leftVisibleLower = leftVisible.lowercased()
                let rightVisibleLower = rightVisible.lowercased()

                let leftStarts = leftVisibleLower.hasPrefix(normalizedQuery)
                let rightStarts = rightVisibleLower.hasPrefix(normalizedQuery)
                if leftStarts != rightStarts { return leftStarts }

                let leftName = URL(fileURLWithPath: leftVisible).lastPathComponent.lowercased()
                let rightName = URL(fileURLWithPath: rightVisible).lastPathComponent.lowercased()

                let leftNameStarts = leftName.hasPrefix(normalizedQuery)
                let rightNameStarts = rightName.hasPrefix(normalizedQuery)
                if leftNameStarts != rightNameStarts { return leftNameStarts }

                if leftVisible.count != rightVisible.count {
                    return leftVisible.count < rightVisible.count
                }

                return leftVisible.localizedCaseInsensitiveCompare(rightVisible) == .orderedAscending
            }
            .prefix(limit)
            .map { path in
                let visible = relativeToCurrentDirectory(path: path, currentDirectory: currentDir)
                return WikilinkAutocompleteSuggestion(
                    label: visible,
                    insertText: path,
                    detail: path
                )
            }

        return Array(suggestions)
    }

    private func autocompleteWikilinkReferences(
        parsed: ParsedWikilinkTarget,
        reference: MarkdownReferenceTarget,
        sourceRelativePath: String?,
        limit: Int
    ) -> [WikilinkAutocompleteSuggestion] {
        let resolvedPath: String?
        if parsed.noteTarget.isEmpty {
            resolvedPath = sourceRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedPath = resolveWikilinkTarget(parsed.noteTarget, from: sourceRelativePath)
        }

        guard let resolvedPath,
              let index = markdownReferenceIndex(for: resolvedPath)
        else {
            return []
        }

        let headingPrefix = parsed.noteTarget.isEmpty ? "#" : "\(resolvedPath)#"
        let blockPrefix = parsed.noteTarget.isEmpty ? "#^" : "\(resolvedPath)#^"
        let normalizedQuery = reference.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch reference.kind {
        case .heading:
            return index.headings
                .filter { heading in
                    guard !normalizedQuery.isEmpty else { return true }
                    return heading.text.lowercased().contains(normalizedQuery)
                }
                .prefix(limit)
                .map { heading in
                    WikilinkAutocompleteSuggestion(
                        label: heading.text,
                        insertText: "\(headingPrefix)\(heading.text)",
                        detail: resolvedPath
                    )
                }
        case .block:
            return index.blocks
                .filter { block in
                    guard !normalizedQuery.isEmpty else { return true }
                    return block.id.lowercased().contains(normalizedQuery)
                }
                .prefix(limit)
                .map { block in
                    WikilinkAutocompleteSuggestion(
                        label: "^\(block.id)",
                        insertText: "\(blockPrefix)\(block.id)",
                        detail: resolvedPath
                    )
                }
        }
    }

    private func markdownReferenceIndex(for relativePath: String) -> MarkdownReferenceIndex? {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard let file = filesByPath[normalizedPath],
              file.isTextFile,
              let content = loadFullText(from: file.fileURL)
        else {
            return nil
        }

        let cacheKey = normalizedPath
        if let cached = markdownReferenceIndexCache[cacheKey],
           cached.modifiedDate == file.modifiedDate {
            return cached.index
        }

        let index = scanMarkdownReferenceIndex(content)
        markdownReferenceIndexCache[cacheKey] = CachedMarkdownReferenceIndex(
            modifiedDate: file.modifiedDate,
            index: index
        )
        return index
    }

    private func lightweightContextForScannedFile(_ file: ScannedFile) -> EditorSelectionContext {
        let preview = previewDescriptor(for: file)
        let body = preview.kind == .unsupported
            ? "Preview unavailable for this file type yet."
            : ""

        return EditorSelectionContext(
            kind: preview.kind,
            title: file.title,
            relativePath: file.relativePath,
            body: body,
            modifiedDate: file.modifiedDate,
            mimeType: preview.mimeType,
            fileSize: file.fileSize
        )
    }

    private func previewDescriptor(for file: ScannedFile) -> (kind: EditorSelectionContext.Kind, mimeType: String?) {
        let ext = file.fileURL.pathExtension.lowercased()

        if ext == "csv" {
            return (.csv, "text/csv")
        }

        if ext == "excalidraw" {
            return (.canvas, "application/vnd.excalidraw+json")
        }

        if ext == "pdf" {
            return (.pdf, "application/pdf")
        }

        if ext == "html" {
            return (.html, "text/html")
        }

        if ext == "epub" {
            return (.epub, "application/epub+zip")
        }

        if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "svg"].contains(ext) {
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType
            return (.image, mime ?? fallbackMimeType(forExtension: ext))
        }

        if let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .pdf) {
                return (.pdf, utType.preferredMIMEType ?? "application/pdf")
            }

            if utType.conforms(to: .image) {
                return (.image, utType.preferredMIMEType ?? fallbackMimeType(forExtension: ext))
            }
        }

        return (.unsupported, fallbackMimeType(forExtension: ext))
    }

    private func fallbackMimeType(forExtension ext: String) -> String {
        switch ext {
        case "csv":
            return "text/csv"
        case "excalidraw":
            return "application/vnd.excalidraw+json"
        case "pdf":
            return "application/pdf"
        case "html":
            return "text/html"
        case "epub":
            return "application/epub+zip"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        case "svg":
            return "image/svg+xml"
        default:
            return "application/octet-stream"
        }
    }

    private func allIndexedFilePaths() -> [String] {
        filesByPath.keys.sorted()
    }

    private func directoryPath(for sourceRelativePath: String?) -> String {
        guard let sourceRelativePath,
              !sourceRelativePath.isEmpty
        else {
            return ""
        }

        let url = URL(fileURLWithPath: sourceRelativePath)
        let directory = url.deletingLastPathComponent().path
        if directory == "/" || directory == "." {
            return ""
        }
        return directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func relativeToCurrentDirectory(path: String, currentDirectory: String) -> String {
        guard !currentDirectory.isEmpty else {
            return path
        }

        let prefix = currentDirectory + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    func workspaceURL(for relativePath: String) -> URL? {
        let normalized = normalizeRelativePath(relativePath)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("../"),
              !normalized.contains("/../")
        else {
            return nil
        }

        let pathComponents = normalized.split(separator: "/")
        if pathComponents.contains("..") {
            return nil
        }

        return runtimeConfig.rootURL.appendingPathComponent(normalized)
    }

    func workspaceItemURL(allowingRootRelativePath relativePath: String?) -> URL? {
        let normalized = normalizeRelativePath(relativePath ?? "")
        guard !normalized.hasPrefix("../"),
              !normalized.contains("/../")
        else {
            return nil
        }

        let pathComponents = normalized.split(separator: "/")
        if pathComponents.contains("..") {
            return nil
        }

        guard !normalized.isEmpty else {
            return runtimeConfig.rootURL
        }

        return runtimeConfig.rootURL.appendingPathComponent(normalized)
    }

    private func noteURL(for relativePath: String) -> URL? {
        workspaceURL(for: relativePath)
    }

    private func normalizeRelativePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        return normalized
    }

    private func loadFullText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard !data.isEmpty else { return "" }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }

        return String(data: data, encoding: .ascii)
    }
}

/// Project-scoped workspace models are shared by native tab windows. AppKit
/// represents every tab as an NSWindow, but each tab must not create another
/// filesystem watcher, search index, and full workspace scan for the same root.
@MainActor
final class NotesWorkspaceModelRegistry {
    static let shared = NotesWorkspaceModelRegistry()

    private var modelsByProjectRoot: [String: NotesWorkspaceModel] = [:]

    func model(projectRootPath: String?) -> NotesWorkspaceModel {
        let key = projectRootPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? "<default-project>"

        if let model = modelsByProjectRoot[key] {
            return model
        }

        let model = NotesWorkspaceModel(projectRootPath: projectRootPath)
        modelsByProjectRoot[key] = model
        return model
    }
}

private struct MarkdownHeadingLine {
    let text: String
    let level: Int
    let range: Range<String.Index>
}

private struct CachedMarkdownReferenceIndex {
    let modifiedDate: Date?
    let index: MarkdownReferenceIndex
}

func parseObsidianWikilinkTarget(_ rawTarget: String) -> ParsedWikilinkTarget {
    let aliasSeparator = rawTarget.firstIndex(of: "|")
    let core = aliasSeparator.map { String(rawTarget[..<$0]) } ?? rawTarget
    let alias = aliasSeparator.map { String(rawTarget[rawTarget.index(after: $0)...]) } ?? ""

    if let blockRange = core.range(of: "#^") {
        return ParsedWikilinkTarget(
            raw: rawTarget,
            core: core.trimmingCharacters(in: .whitespacesAndNewlines),
            noteTarget: String(core[..<blockRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: MarkdownReferenceTarget(
                kind: .block,
                query: String(core[blockRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    if let headingRange = core.range(of: "#") {
        return ParsedWikilinkTarget(
            raw: rawTarget,
            core: core.trimmingCharacters(in: .whitespacesAndNewlines),
            noteTarget: String(core[..<headingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: MarkdownReferenceTarget(
                kind: .heading,
                query: cleanMarkdownHeadingReferenceQuery(String(core[headingRange.upperBound...]))
            )
        )
    }

    let trimmedCore = core.trimmingCharacters(in: .whitespacesAndNewlines)
    return ParsedWikilinkTarget(
        raw: rawTarget,
        core: trimmedCore,
        noteTarget: trimmedCore,
        alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
        reference: nil
    )
}

private func scanMarkdownReferenceIndex(_ content: String) -> MarkdownReferenceIndex {
    let headingPattern = try? NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$"#)
    let trailingHeadingTagsPattern = try? NSRegularExpression(pattern: #"\s+(:[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?(?::[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?)*:)\s*$"#)
    let fencePattern = try? NSRegularExpression(pattern: #"^\s*```"#)
    let blockPattern = try? NSRegularExpression(pattern: #"(?:^|[\t ]+)\^([A-Za-z0-9_-]+)[\t ]*$"#)

    var headings: [MarkdownHeadingReference] = []
    var blocks: [MarkdownBlockReference] = []

    let lines = content.components(separatedBy: .newlines)
    let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var inFrontmatter = firstLine == "---"
    var inFence = false

    for (index, line) in lines.enumerated() {
        let lineNo = index + 1
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        if inFrontmatter {
            if lineNo > 1 && trimmed == "---" {
                inFrontmatter = false
            }
            continue
        }

        if inFence {
            if fencePattern?.firstMatch(in: line, options: [], range: fullRange) != nil {
                inFence = false
            }
            continue
        }

        if fencePattern?.firstMatch(in: line, options: [], range: fullRange) != nil {
            inFence = true
            continue
        }

        if let headingMatch = headingPattern?.firstMatch(in: line, options: [], range: fullRange),
           headingMatch.numberOfRanges >= 3,
           let textRange = Range(headingMatch.range(at: 2), in: line) {
            var headingText = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let headingRange = NSRange(location: 0, length: (headingText as NSString).length)
            if let trailingMatch = trailingHeadingTagsPattern?.firstMatch(in: headingText, options: [], range: headingRange),
               let matchRange = Range(trailingMatch.range(at: 0), in: headingText) {
                headingText.removeSubrange(matchRange)
                headingText = headingText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !headingText.isEmpty {
                let level = headingMatch.range(at: 1).length
                headings.append(MarkdownHeadingReference(text: headingText, line: lineNo, level: level))
            }
        }

        if let blockMatch = blockPattern?.firstMatch(in: line, options: [], range: fullRange),
           blockMatch.numberOfRanges >= 2,
           let blockRange = Range(blockMatch.range(at: 1), in: line) {
            let blockID = String(line[blockRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !blockID.isEmpty {
                blocks.append(MarkdownBlockReference(id: blockID, line: lineNo))
            }
        }
    }

    return MarkdownReferenceIndex(headings: headings, blocks: blocks)
}

private func markdownHeadingSectionRange(in content: String, query: String) -> Range<String.Index>? {
    let lines = markdownLineRanges(in: content)
    guard !lines.isEmpty else { return nil }

    var inFrontmatter = lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    var inFence = false
    var matchedHeading: MarkdownHeadingLine?

    for (index, line) in lines.enumerated() {
        let lineNo = index + 1
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inFrontmatter {
            if lineNo > 1 && trimmed == "---" {
                inFrontmatter = false
            }
            continue
        }

        if inFence {
            if isMarkdownFenceLine(line.text) {
                inFence = false
            }
            continue
        }

        if isMarkdownFenceLine(line.text) {
            inFence = true
            continue
        }

        guard let heading = parseMarkdownHeadingLine(line.text, range: line.range) else {
            continue
        }

        if let current = matchedHeading {
            if heading.level <= current.level {
                return current.range.lowerBound..<heading.range.lowerBound
            }
            continue
        }

        if markdownHeadingReferenceMatches(query, heading.text) {
            matchedHeading = heading
        }
    }

    guard let matchedHeading else { return nil }
    return matchedHeading.range.lowerBound..<content.endIndex
}

private func markdownLineRanges(in content: String) -> [(text: String, range: Range<String.Index>)] {
    guard !content.isEmpty else { return [] }

    var result: [(text: String, range: Range<String.Index>)] = []
    var start = content.startIndex

    while start < content.endIndex {
        let lineEnd = content[start...].firstIndex(of: "\n") ?? content.endIndex
        let rangeEnd = lineEnd < content.endIndex ? content.index(after: lineEnd) : lineEnd
        var text = String(content[start..<lineEnd])
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        result.append((text: text, range: start..<rangeEnd))
        start = rangeEnd
    }

    return result
}

private func isMarkdownFenceLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
}

private func parseMarkdownHeadingLine(_ line: String, range: Range<String.Index>) -> MarkdownHeadingLine? {
    var index = line.startIndex
    var leadingSpaces = 0

    while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
        leadingSpaces += 1
        index = line.index(after: index)
    }

    guard leadingSpaces <= 3 else { return nil }

    var level = 0
    while index < line.endIndex, line[index] == "#", level < 7 {
        level += 1
        index = line.index(after: index)
    }

    guard (1...6).contains(level),
          index < line.endIndex,
          (line[index] == " " || line[index] == "\t")
    else {
        return nil
    }

    let rawText = String(line[index...])
    let text = cleanMarkdownHeadingText(rawText)
    guard !text.isEmpty else { return nil }

    return MarkdownHeadingLine(text: text, level: level, range: range)
}

private func cleanMarkdownHeadingText(_ rawText: String) -> String {
    var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let closingHashPattern = try? NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    let closingHashRange = NSRange(location: 0, length: (text as NSString).length)
    if let match = closingHashPattern?.firstMatch(in: text, options: [], range: closingHashRange),
       let matchRange = Range(match.range(at: 0), in: text) {
        text.removeSubrange(matchRange)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let trailingTagPattern = try? NSRegularExpression(pattern: #"\s+(:[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?(?::[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?)*:)\s*$"#)
    let range = NSRange(location: 0, length: (text as NSString).length)
    if let match = trailingTagPattern?.firstMatch(in: text, options: [], range: range),
       let matchRange = Range(match.range(at: 0), in: text) {
        text.removeSubrange(matchRange)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return text
}

private func normalizeMarkdownHeadingReference(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .lowercased()
}

private func markdownHeadingReferenceMatches(_ query: String, _ candidate: String) -> Bool {
    let normalizedQuery = normalizeMarkdownHeadingReference(query)
    let normalizedCandidate = normalizeMarkdownHeadingReference(candidate)
    guard !normalizedQuery.isEmpty, !normalizedCandidate.isEmpty else { return false }
    return normalizedQuery == normalizedCandidate
}

private func cleanMarkdownHeadingReferenceQuery(_ rawQuery: String) -> String {
    var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    while query.hasPrefix("#") {
        query.removeFirst()
    }
    return query.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct ScannedFile {
    let fileURL: URL
    let relativePath: String
    let title: String
    let modifiedDate: Date?
    let fileSize: Int64?
    let isTextFile: Bool
}

private struct NotesScanSnapshot {
    let childrenByFolder: [String: [MillerItem]]
    let filesByPath: [String: ScannedFile]
    let searchDocuments: [NoteSearchDocument]
}

private enum NotesScanner {
    static let existingWikilinkExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "mdown", "mkd", "org"
    ]
    static let textExtensions = existingWikilinkExtensions.union(["outline"])

    static func scan(rootURL: URL, fileManager: FileManager = .default) -> NotesScanSnapshot {
        var childrenByFolder: [String: [MillerItem]] = [:]
        var filesByPath: [String: ScannedFile] = [:]
        var searchDocuments: [NoteSearchDocument] = []

        walkDirectory(
            at: rootURL,
            relativePath: "",
            workspaceRootURL: rootURL.resolvingSymlinksInPath().standardizedFileURL,
            ancestorDirectoryPaths: [],
            fileManager: fileManager,
            childrenByFolder: &childrenByFolder,
            filesByPath: &filesByPath,
            searchDocuments: &searchDocuments
        )

        return NotesScanSnapshot(
            childrenByFolder: childrenByFolder,
            filesByPath: filesByPath,
            searchDocuments: searchDocuments
        )
    }

    private static func walkDirectory(
        at directoryURL: URL,
        relativePath: String,
        workspaceRootURL: URL,
        ancestorDirectoryPaths: Set<String>,
        fileManager: FileManager,
        childrenByFolder: inout [String: [MillerItem]],
        filesByPath: inout [String: ScannedFile],
        searchDocuments: inout [NoteSearchDocument]
    ) {
        // Foundation enumerates the target directory only when given its resolved URL.
        let resolvedDirectoryURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let ancestorDirectoryPaths = ancestorDirectoryPaths.union([resolvedDirectoryURL.path])
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isHiddenKey
        ]

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: resolvedDirectoryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
            )
        } catch {
            // A silent failure here would drop the whole subtree from the
            // index — on iCloud this happens while the volume catalog is
            // still settling, which used to strand restored tabs on the
            // "waiting for the workspace index" placeholder forever.
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "notes.scan",
                event: "directoryEnumerationFailed",
                metadata: [
                    "path": directoryURL.path,
                    "error": error.localizedDescription
                ]
            )
            urls = []
        }

        var items: [MillerItem] = []

        for url in urls {
            guard let values = WorkspaceScanEntry.resourceValues(
                at: url, within: workspaceRootURL, forKeys: Set(keys)
            ) else { continue }

            let name = url.lastPathComponent
            let itemRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

            if values.isDirectory == true {
                let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !ancestorDirectoryPaths.contains(resolvedPath) else { continue }
                items.append(
                    MillerItem(
                        relativePath: itemRelativePath,
                        name: name,
                        kind: .folder,
                        modifiedDate: values.contentModificationDate
                    )
                )

                walkDirectory(
                    at: url,
                    relativePath: itemRelativePath,
                    workspaceRootURL: workspaceRootURL,
                    ancestorDirectoryPaths: ancestorDirectoryPaths,
                    fileManager: fileManager,
                    childrenByFolder: &childrenByFolder,
                    filesByPath: &filesByPath,
                    searchDocuments: &searchDocuments
                )
                continue
            }

            guard values.isRegularFile == true else { continue }

            let isText = isTextFile(url)
            let scannedFile = ScannedFile(
                fileURL: workspaceRootURL.appendingPathComponent(itemRelativePath),
                relativePath: itemRelativePath,
                title: url.deletingPathExtension().lastPathComponent,
                modifiedDate: values.contentModificationDate,
                fileSize: values.fileSize.map(Int64.init),
                isTextFile: isText
            )

            filesByPath[itemRelativePath] = scannedFile
            searchDocuments.append(
                NoteSearchDocument(
                    fileURL: scannedFile.fileURL,
                    relativePath: itemRelativePath,
                    title: scannedFile.title,
                    modifiedDate: scannedFile.modifiedDate,
                    fileSize: scannedFile.fileSize,
                    isTextFile: isText
                )
            )

            items.append(
                MillerItem(
                    relativePath: itemRelativePath,
                    name: name,
                    kind: .note,
                    modifiedDate: scannedFile.modifiedDate
                )
            )
        }

        childrenByFolder[relativePath] = items.sorted(by: itemSort)
    }

    private static func itemSort(lhs: MillerItem, rhs: MillerItem) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .folder
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return true
        }
        return textExtensions.contains(ext)
    }
}
