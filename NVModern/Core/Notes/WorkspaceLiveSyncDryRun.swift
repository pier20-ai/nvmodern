/// Workspace live-sync finite state machine.
///
/// This controller watches the active workspace root, classifies file-system changes, and
/// emits concrete refresh decisions back into the app.
///
/// Per workspace-relative path, the FSM is:
///
/// 1. `idle`
///    - No pending local write is waiting to be confirmed.
///    - No unresolved external change is pending.
///
/// 2. `awaitingSelfWriteConfirmation(pendingWrite)`
///    - nvModern has just written this path and expects the watcher/rescan layer to observe
///      the resulting on-disk state.
///    - The pending write stores a generation, timestamps, and an expected content-aware
///      fingerprint.
///    - If the next observed disk fingerprint matches the expected one, this is classified
///      as a confirmed self-write and the path transitions back to `idle`.
///    - If the next observed disk fingerprint differs, the change is treated as external and
///      the path transitions to either `externalChangePending` or `conflicted` depending on
///      whether an active editable surface is observing the path.
///    - If confirmation never arrives before expiry, the path returns to `idle` and the
///      pending self-write is discarded.
///
/// 3. `externalChangePending(change)`
///    - A disk change was classified as external, but no active editable surface is observing
///      the path.
///    - The controller emits this path in `WorkspaceLiveSyncUpdate.autoRefreshPaths`, so the
///      app can refresh inactive or non-editable content surfaces automatically.
///    - After the update is emitted, the path returns to `idle`.
///
/// 4. `conflicted(conflict)`
///    - A disk change was classified as external while an active editable surface is observing
///      the path.
///    - The controller emits the current set of conflicted paths in
///      `WorkspaceLiveSyncUpdate.conflictedPaths`.
///    - The app must not force-reload that active editable surface. A subsequent local save for
///      the same path transitions back to `awaitingSelfWriteConfirmation` with a newer generation.
///
/// Signals used by the classifier:
/// - FSEvents recursive watch of the workspace root
/// - debounced full tree rescans
/// - path + expected fingerprint matching for local saves
/// - active visible workspace document registrations from `WorkspaceView`
///
/// Important: timing is only supporting evidence. A write is only classified as a self-write
/// when the observed disk fingerprint matches the fingerprint nvModern expected to write.
///
/// Phase-2 / future work intentionally left pending:
/// - **Incremental rescans / indexing**: we currently rescan the full tree and rebuild the
///   searchable snapshot after each coalesced filesystem batch. This keeps correctness simple,
///   but larger workspaces may eventually want path-local diffs and incremental search updates.
/// - **Shared watcher/controller per root**: each `NotesWorkspaceModel` currently owns its own
///   watcher. Multiple windows on the same project could share a single root-scoped live-sync
///   controller and fan out updates to all models.
/// - **Additional event deduping**: iCloud Drive and other sync providers emit metadata/xattr
///   churn. We already suppress many metadata-only changes via content fingerprints, but a future
///   pass could further reduce rescans by prefiltering raw event batches.
/// - **Richer rename / move heuristics**: rename detection currently relies on stable file
///   resource identifiers. This works well for common atomic-save and rename paths, but cross-volume
///   moves or provider-specific behaviors may need stronger heuristics.
/// - **Conflict UX polish**: current banner-based conflict handling is intentionally conservative.
///   Future versions may optionally auto-refresh unfocused open tabs, add compare affordances, or
///   expose more detailed per-path conflict metadata.
/// - **Window/process lifecycle cleanup**: retained editor/web sessions are intentionally kept alive
///   across some SwiftUI subtree transitions to avoid blank panes. A future pass could centralize
///   lifecycle ownership further and trim steady-state log noise.
import CoreServices
import CryptoKit
import Foundation

struct WorkspaceLiveSyncUpdate {
    let reason: String
    let changedPaths: Set<String>
    let selfWriteConfirmedPaths: Set<String>
    let externalModifiedPaths: Set<String>
    let externalDeletedPaths: Set<String>
    let externalAddedPaths: Set<String>
    let renamedPaths: [String: String]
    let conflictedPaths: Set<String>
    let addedFolders: [String]
    let removedFolders: [String]

    var hasMaterialChange: Bool {
        !changedPaths.isEmpty
            || !addedFolders.isEmpty
            || !removedFolders.isEmpty
            || !renamedPaths.isEmpty
    }
}

final class WorkspaceLiveSyncController {
    struct LocalWriteToken {
        let relativePath: String
        let generation: Int
    }

    private struct PendingSelfWrite: Equatable {
        let generation: Int
        let reason: String
        let startedAt: Date
        let expiresAt: Date
        let expectedFingerprint: FileFingerprint
        var observedPostWriteFingerprint: FileFingerprint?

        var shortLabel: String {
            "gen=\(generation) reason=\(reason) expected=\(expectedFingerprint.shortLabel)"
        }
    }

    private struct ExternalChange: Equatable {
        let reason: String
        let changeKind: ChangeKind
        let observedAt: Date
        let diskFingerprint: FileFingerprint?
        let activeObserverSummary: String

        var shortLabel: String {
            let fingerprint = diskFingerprint?.shortLabel ?? "missing"
            return "kind=\(changeKind.rawValue) reason=\(reason) disk=\(fingerprint) observers=\(activeObserverSummary)"
        }
    }

    private struct ConflictState: Equatable {
        let reason: String
        let changeKind: ChangeKind
        let observedAt: Date
        let diskFingerprint: FileFingerprint?
        let activeObserverSummary: String

        var shortLabel: String {
            let fingerprint = diskFingerprint?.shortLabel ?? "missing"
            return "kind=\(changeKind.rawValue) reason=\(reason) disk=\(fingerprint) observers=\(activeObserverSummary)"
        }
    }

    private enum PathState: Equatable {
        case idle
        case awaitingSelfWriteConfirmation(PendingSelfWrite)
        case externalChangePending(ExternalChange)
        case conflicted(ConflictState)

        var shortLabel: String {
            switch self {
            case .idle:
                return "idle"
            case .awaitingSelfWriteConfirmation(let pending):
                return "awaitingSelfWriteConfirmation(\(pending.shortLabel))"
            case .externalChangePending(let change):
                return "externalChangePending(\(change.shortLabel))"
            case .conflicted(let conflict):
                return "conflicted(\(conflict.shortLabel))"
            }
        }

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    private enum ChangeKind: String {
        case added
        case modified
        case removed
    }

    private struct ObserverRecord: Equatable {
        let observerID: String
        let relativePath: String
        let kind: String?
        let isEditable: Bool
        let updatedAt: Date

        var summary: String {
            let kindLabel = kind ?? "unknown"
            return "\(observerID):kind=\(kindLabel),editable=\(isEditable)"
        }

        func isSameConfiguration(as other: ObserverRecord) -> Bool {
            relativePath == other.relativePath && kind == other.kind && isEditable == other.isEditable
        }
    }

    private struct FileSnapshot: Equatable {
        let relativePath: String
        let modifiedDate: Date?
        let fileSize: Int64?
        let fileResourceIdentifier: String?
    }

    private struct TreeSnapshot {
        let folders: Set<String>
        let filesByRelativePath: [String: FileSnapshot]

        static func scan(rootURL: URL, fileManager: FileManager = .default) -> TreeSnapshot {
            var folders: Set<String> = [""]
            var files: [String: FileSnapshot] = [:]
            walk(
                directoryURL: rootURL,
                relativePath: "",
                workspaceRootURL: rootURL.resolvingSymlinksInPath().standardizedFileURL,
                ancestorDirectoryPaths: [],
                fileManager: fileManager,
                folders: &folders,
                files: &files
            )
            return TreeSnapshot(folders: folders, filesByRelativePath: files)
        }

        private static func walk(
            directoryURL: URL,
            relativePath: String,
            workspaceRootURL: URL,
            ancestorDirectoryPaths: Set<String>,
            fileManager: FileManager,
            folders: inout Set<String>,
            files: inout [String: FileSnapshot]
        ) {
            let resolvedDirectoryURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
            let ancestorDirectoryPaths = ancestorDirectoryPaths.union([resolvedDirectoryURL.path])
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isHiddenKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .fileResourceIdentifierKey
            ]

            let urls = (try? fileManager.contentsOfDirectory(
                at: resolvedDirectoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            )) ?? []

            for url in urls {
                guard let values = WorkspaceScanEntry.resourceValues(
                    at: url, within: workspaceRootURL, forKeys: keys
                ) else { continue }

                let name = url.lastPathComponent
                let itemRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

                if values.isDirectory == true {
                    let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                    guard !ancestorDirectoryPaths.contains(resolvedPath) else { continue }
                    folders.insert(itemRelativePath)
                    if values.isPackage != true {
                        walk(
                            directoryURL: url,
                            relativePath: itemRelativePath,
                            workspaceRootURL: workspaceRootURL,
                            ancestorDirectoryPaths: ancestorDirectoryPaths,
                            fileManager: fileManager,
                            folders: &folders,
                            files: &files
                        )
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }
                files[itemRelativePath] = FileSnapshot(
                    relativePath: itemRelativePath,
                    modifiedDate: values.contentModificationDate,
                    fileSize: values.fileSize.map(Int64.init),
                    fileResourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
                )
            }
        }
    }

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let fileSize: Int64?
        let modifiedTimeIntervalSinceReferenceDate: TimeInterval?
        let contentHash: String?

        var shortLabel: String {
            let existsLabel = exists ? "exists" : "missing"
            let sizeLabel = fileSize.map(String.init) ?? "nil"
            let mtimeLabel = modifiedTimeIntervalSinceReferenceDate.map { String(format: "%.3f", $0) } ?? "nil"
            let hashLabel = contentHash ?? "nil"
            return "\(existsLabel),size=\(sizeLabel),mtime=\(mtimeLabel),hash=\(hashLabel)"
        }

        static func expected(from data: Data) -> FileFingerprint {
            FileFingerprint(
                exists: true,
                fileSize: Int64(data.count),
                modifiedTimeIntervalSinceReferenceDate: nil,
                contentHash: Self.sha256Hex(for: data)
            )
        }

        static func snapshot(at url: URL, includeContentHash: Bool, fileManager: FileManager = .default) -> FileFingerprint {
            guard fileManager.fileExists(atPath: url.path) else {
                return FileFingerprint(
                    exists: false,
                    fileSize: nil,
                    modifiedTimeIntervalSinceReferenceDate: nil,
                    contentHash: nil
                )
            }

            let attributes = try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            let modifiedDate = attributes?[.modificationDate] as? Date
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            let contentHash: String?
            if includeContentHash, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                contentHash = Self.sha256Hex(for: data)
            } else {
                contentHash = nil
            }

            return FileFingerprint(
                exists: true,
                fileSize: fileSize,
                modifiedTimeIntervalSinceReferenceDate: modifiedDate?.timeIntervalSinceReferenceDate,
                contentHash: contentHash
            )
        }

        func matchesExpected(_ expected: FileFingerprint) -> Bool {
            guard exists == expected.exists else { return false }
            guard fileSize == expected.fileSize else { return false }
            if let expectedHash = expected.contentHash {
                return contentHash == expectedHash
            }
            return true
        }

        private static func sha256Hex(for data: Data) -> String {
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct RawEvent {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId

        var shortLabel: String {
            "id=\(id) path=\(path) flags=\(flagSummary(flags))"
        }
    }

    var onUpdate: ((WorkspaceLiveSyncUpdate) -> Void)?

    private static let rescanDebounceSeconds: TimeInterval = 0.28
    private static let pendingSelfWriteTTLSeconds: TimeInterval = 4.0
    private static let logPrefix = "[NVModern][LiveSync]"

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "nvmodern.live-sync", qos: .utility)

    private var rootURL: URL
    private var latestSnapshot: TreeSnapshot
    private var stream: FSEventStreamRef?
    private var pathStates: [String: PathState] = [:]
    private var nextGenerationByPath: [String: Int] = [:]
    private var observersByID: [String: ObserverRecord] = [:]
    private var pendingRawEvents: [RawEvent] = []
    private var pendingRescanWorkItem: DispatchWorkItem?
    private var lastKnownDiskFingerprintByPath: [String: FileFingerprint] = [:]

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL.standardizedFileURL
        self.latestSnapshot = TreeSnapshot.scan(rootURL: self.rootURL, fileManager: fileManager)

        queue.sync {
            logLocked("bootstrap root=\(self.rootURL.path) files=\(latestSnapshot.filesByRelativePath.count) folders=\(latestSnapshot.folders.count)")
            startWatcherLocked()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        queue.sync {
            stopWatcherLocked(reason: "stop()")
        }
    }

    func updateRootURL(_ newRootURL: URL, reason: String) {
        let standardized = newRootURL.standardizedFileURL
        queue.async {
            guard standardized.path != self.rootURL.path else {
                self.logLocked("root unchanged reason=\(reason) root=\(standardized.path)")
                return
            }

            self.stopWatcherLocked(reason: "root update")
            self.rootURL = standardized
            self.latestSnapshot = TreeSnapshot.scan(rootURL: standardized, fileManager: self.fileManager)
            self.pathStates.removeAll()
            self.nextGenerationByPath.removeAll()
            self.observersByID.removeAll()
            self.pendingRawEvents.removeAll()
            self.lastKnownDiskFingerprintByPath.removeAll()
            self.logLocked("root updated reason=\(reason) root=\(standardized.path) files=\(self.latestSnapshot.filesByRelativePath.count) folders=\(self.latestSnapshot.folders.count)")
            self.startWatcherLocked()
        }
    }

    func registerVisibleDocument(observerID: String, relativePath: String?, kind: String?, isEditable: Bool) {
        queue.async {
            guard let relativePath, !relativePath.isEmpty else {
                let removed = self.observersByID.removeValue(forKey: observerID)
                if removed != nil {
                    self.logLocked("observer cleared id=\(observerID) previous=\(removed?.summary ?? "none")")
                }
                return
            }

            let record = ObserverRecord(
                observerID: observerID,
                relativePath: relativePath,
                kind: kind,
                isEditable: isEditable,
                updatedAt: Date()
            )

            if let existing = self.observersByID[observerID], existing.isSameConfiguration(as: record) {
                self.observersByID[observerID] = record
                return
            }

            self.observersByID[observerID] = record
            self.logLocked("observer upserted path=\(relativePath) record=\(record.summary)")
        }
    }

    func unregisterObserver(observerID: String) {
        queue.async {
            let removed = self.observersByID.removeValue(forKey: observerID)
            if removed != nil {
                self.logLocked("observer unregistered id=\(observerID) previous=\(removed?.summary ?? "none")")
            }
        }
    }

    @discardableResult
    func beginLocalWrite(relativePath: String, expectedData: Data, reason: String) -> LocalWriteToken {
        queue.sync {
            cleanupExpiredSelfWritesLocked(now: Date())

            let nextGeneration = (nextGenerationByPath[relativePath] ?? 0) + 1
            nextGenerationByPath[relativePath] = nextGeneration

            let pending = PendingSelfWrite(
                generation: nextGeneration,
                reason: reason,
                startedAt: Date(),
                expiresAt: Date().addingTimeInterval(Self.pendingSelfWriteTTLSeconds),
                expectedFingerprint: FileFingerprint.expected(from: expectedData),
                observedPostWriteFingerprint: nil
            )

            transitionLocked(
                path: relativePath,
                to: .awaitingSelfWriteConfirmation(pending),
                reason: "localSaveStarted reason=\(reason)"
            )

            return LocalWriteToken(relativePath: relativePath, generation: nextGeneration)
        }
    }

    func completeLocalWrite(_ token: LocalWriteToken, fileURL: URL?) {
        queue.async {
            guard case .awaitingSelfWriteConfirmation(let pending) = self.stateLocked(for: token.relativePath) else {
                self.logLocked("localSaveSucceeded ignored path=\(token.relativePath) generation=\(token.generation) state=\(self.stateLocked(for: token.relativePath).shortLabel)")
                return
            }

            guard pending.generation == token.generation else {
                self.logLocked("localSaveSucceeded stale path=\(token.relativePath) generation=\(token.generation) current=\(pending.generation)")
                return
            }

            let observed = fileURL.map { FileFingerprint.snapshot(at: $0, includeContentHash: true, fileManager: self.fileManager) }
            var updatedPending = pending
            updatedPending.observedPostWriteFingerprint = observed
            self.pathStates[token.relativePath] = .awaitingSelfWriteConfirmation(updatedPending)
            self.logLocked("localSaveSucceeded path=\(token.relativePath) generation=\(token.generation) observed=\(observed?.shortLabel ?? "missing")")
        }
    }

    func failLocalWrite(_ token: LocalWriteToken, error: Error) {
        queue.async {
            guard case .awaitingSelfWriteConfirmation(let pending) = self.stateLocked(for: token.relativePath) else {
                self.logLocked("localSaveFailed ignored path=\(token.relativePath) generation=\(token.generation) error=\(error)")
                return
            }

            guard pending.generation == token.generation else {
                self.logLocked("localSaveFailed stale path=\(token.relativePath) generation=\(token.generation) current=\(pending.generation) error=\(error)")
                return
            }

            self.transitionLocked(path: token.relativePath, to: .idle, reason: "localSaveFailed error=\(error.localizedDescription)")
        }
    }

    private func startWatcherLocked() {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            logLocked("watcher not started because root is missing: \(rootURL.path)")
            return
        }

        guard stream == nil else {
            logLocked("watcher already running root=\(rootURL.path)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        let pathsToWatch = [rootURL.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.fseventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            logLocked("watcher create failed root=\(rootURL.path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        let started = FSEventStreamStart(stream)
        if started {
            self.stream = stream
            logLocked("watcher started root=\(rootURL.path)")
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            logLocked("watcher start failed root=\(rootURL.path)")
        }
    }

    private func stopWatcherLocked(reason: String) {
        pendingRescanWorkItem?.cancel()
        pendingRescanWorkItem = nil
        pendingRawEvents.removeAll()

        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logLocked("watcher stopped reason=\(reason) root=\(rootURL.path)")
    }

    private func handleRawEventsLocked(_ rawEvents: [RawEvent]) {
        guard !rawEvents.isEmpty else { return }

        cleanupExpiredSelfWritesLocked(now: Date())
        for rawEvent in rawEvents {
            logLocked("fs event \(rawEvent.shortLabel)")
        }

        pendingRawEvents.append(contentsOf: rawEvents)
        pendingRescanWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performRescanLocked(reason: "fsevents batch count=\(self.pendingRawEvents.count)")
        }

        pendingRescanWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.rescanDebounceSeconds, execute: workItem)
    }

    private func performRescanLocked(reason: String) {
        let events = pendingRawEvents
        pendingRawEvents.removeAll()
        pendingRescanWorkItem = nil

        cleanupExpiredSelfWritesLocked(now: Date())

        let previousSnapshot = latestSnapshot
        let nextSnapshot = TreeSnapshot.scan(rootURL: rootURL, fileManager: fileManager)
        latestSnapshot = nextSnapshot

        let previousFiles = previousSnapshot.filesByRelativePath
        let nextFiles = nextSnapshot.filesByRelativePath

        let removedFolders = previousSnapshot.folders.subtracting(nextSnapshot.folders).sorted()
        let addedFolders = nextSnapshot.folders.subtracting(previousSnapshot.folders).sorted()

        logLocked("rescan trigger reason=\(reason) rawEventCount=\(events.count)")

        if !addedFolders.isEmpty {
            logLocked("folder additions: \(addedFolders.joined(separator: ", "))")
        }
        if !removedFolders.isEmpty {
            logLocked("folder removals: \(removedFolders.joined(separator: ", "))")
        }

        let removedPaths = Set(previousFiles.keys).subtracting(nextFiles.keys)
        let addedPaths = Set(nextFiles.keys).subtracting(previousFiles.keys)
        let modifiedPaths = Set(previousFiles.keys).intersection(nextFiles.keys).filter { previousFiles[$0] != nextFiles[$0] }

        let renamedPaths = detectRenamedPaths(removedPaths: removedPaths, addedPaths: addedPaths, previousFiles: previousFiles, nextFiles: nextFiles)
        let renamedOldPaths = Set(renamedPaths.keys)
        let renamedNewPaths = Set(renamedPaths.values)

        var changedPaths = Set<String>()
        var selfWriteConfirmedPaths = Set<String>()
        var externalModifiedPaths = Set<String>()
        var externalDeletedPaths = Set<String>()
        var externalAddedPaths = Set<String>()

        for path in modifiedPaths.sorted() {
            changedPaths.insert(path)
            classifyPathChangeLocked(
                relativePath: path,
                changeKind: .modified,
                reason: reason,
                selfWriteConfirmedPaths: &selfWriteConfirmedPaths,
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )
        }

        for path in removedPaths.subtracting(renamedOldPaths).sorted() {
            changedPaths.insert(path)
            classifyPathChangeLocked(
                relativePath: path,
                changeKind: .removed,
                reason: reason,
                selfWriteConfirmedPaths: &selfWriteConfirmedPaths,
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )
        }

        for path in addedPaths.subtracting(renamedNewPaths).sorted() {
            changedPaths.insert(path)
            classifyPathChangeLocked(
                relativePath: path,
                changeKind: .added,
                reason: reason,
                selfWriteConfirmedPaths: &selfWriteConfirmedPaths,
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )
        }

        for (oldPath, newPath) in renamedPaths.sorted(by: { $0.key < $1.key }) {
            changedPaths.insert(oldPath)
            changedPaths.insert(newPath)
            if let fingerprint = lastKnownDiskFingerprintByPath.removeValue(forKey: oldPath) {
                lastKnownDiskFingerprintByPath[newPath] = fingerprint
            }
            transitionLocked(path: oldPath, to: .idle, reason: "path renamed to \(newPath)")
            transitionLocked(path: newPath, to: .idle, reason: "path renamed from \(oldPath)")
            logLocked("detected rename old=\(oldPath) new=\(newPath)")
        }

        let conflictedPaths = Set(pathStates.compactMap { entry -> String? in
            if case .conflicted = entry.value {
                return entry.key
            }
            return nil
        })

        let update = WorkspaceLiveSyncUpdate(
            reason: reason,
            changedPaths: changedPaths,
            selfWriteConfirmedPaths: selfWriteConfirmedPaths,
            externalModifiedPaths: externalModifiedPaths,
            externalDeletedPaths: externalDeletedPaths,
            externalAddedPaths: externalAddedPaths,
            renamedPaths: renamedPaths,
            conflictedPaths: conflictedPaths,
            addedFolders: addedFolders,
            removedFolders: removedFolders
        )

        if !update.hasMaterialChange {
            logLocked("rescan produced no material diff")
            return
        }

        logLocked(
            "rescan diff summary files=\(changedPaths.count) foldersAdded=\(addedFolders.count) foldersRemoved=\(removedFolders.count) selfWrites=\(selfWriteConfirmedPaths.count) externalModified=\(externalModifiedPaths.count) externalDeleted=\(externalDeletedPaths.count) renamed=\(renamedPaths.count) conflicts=\(conflictedPaths.count)"
        )
        emitUpdateLocked(update)
    }

    private func classifyPathChangeLocked(
        relativePath: String,
        changeKind: ChangeKind,
        reason: String,
        selfWriteConfirmedPaths: inout Set<String>,
        externalModifiedPaths: inout Set<String>,
        externalDeletedPaths: inout Set<String>,
        externalAddedPaths: inout Set<String>
    ) {
        let activeObservers = observersLocked(for: relativePath)
        let activeObserverSummary = activeObservers.isEmpty
            ? "none"
            : activeObservers.map(\.summary).sorted().joined(separator: ";")
        let hasActiveEditableObserver = activeObservers.contains(where: { $0.isEditable })

        let url = rootURL.appendingPathComponent(relativePath)
        let currentState = stateLocked(for: relativePath)
        let includeHash = shouldIncludeContentHash(relativePath: relativePath, state: currentState)
        let diskFingerprint = FileFingerprint.snapshot(at: url, includeContentHash: includeHash, fileManager: fileManager)

        logLocked(
            "classify path=\(relativePath) change=\(changeKind.rawValue) state=\(currentState.shortLabel) disk=\(diskFingerprint.shortLabel) observers=\(activeObserverSummary)"
        )

        if changeKind == .modified,
           let lastKnown = lastKnownDiskFingerprintByPath[relativePath],
           diskFingerprint.contentHash != nil,
           diskFingerprint.matchesExpected(lastKnown) {
            lastKnownDiskFingerprintByPath[relativePath] = diskFingerprint
            logLocked("ignoring metadata-only change path=\(relativePath)")
            return
        }

        switch currentState {
        case .awaitingSelfWriteConfirmation(let pending):
            if diskFingerprint.matchesExpected(pending.expectedFingerprint) {
                selfWriteConfirmedPaths.insert(relativePath)
                lastKnownDiskFingerprintByPath[relativePath] = diskFingerprint
                transitionLocked(
                    path: relativePath,
                    to: .idle,
                    reason: "self-write confirmed change=\(changeKind.rawValue) generation=\(pending.generation)"
                )
                return
            }

            recordExternalChangeLocked(
                relativePath: relativePath,
                changeKind: changeKind,
                diskFingerprint: diskFingerprint,
                activeObserverSummary: activeObserverSummary,
                hasActiveEditableObserver: hasActiveEditableObserver,
                reason: "external mismatch vs pending generation=\(pending.generation)",
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )

        case .conflicted:
            recordExternalChangeLocked(
                relativePath: relativePath,
                changeKind: changeKind,
                diskFingerprint: diskFingerprint,
                activeObserverSummary: activeObserverSummary,
                hasActiveEditableObserver: hasActiveEditableObserver,
                reason: "conflict updated",
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )

        case .idle, .externalChangePending:
            recordExternalChangeLocked(
                relativePath: relativePath,
                changeKind: changeKind,
                diskFingerprint: diskFingerprint,
                activeObserverSummary: activeObserverSummary,
                hasActiveEditableObserver: hasActiveEditableObserver,
                reason: hasActiveEditableObserver ? "active editable observer present" : "external change observed",
                externalModifiedPaths: &externalModifiedPaths,
                externalDeletedPaths: &externalDeletedPaths,
                externalAddedPaths: &externalAddedPaths
            )
        }
    }

    private func recordExternalChangeLocked(
        relativePath: String,
        changeKind: ChangeKind,
        diskFingerprint: FileFingerprint,
        activeObserverSummary: String,
        hasActiveEditableObserver: Bool,
        reason: String,
        externalModifiedPaths: inout Set<String>,
        externalDeletedPaths: inout Set<String>,
        externalAddedPaths: inout Set<String>
    ) {
        switch changeKind {
        case .modified:
            externalModifiedPaths.insert(relativePath)
            lastKnownDiskFingerprintByPath[relativePath] = diskFingerprint
        case .removed:
            externalDeletedPaths.insert(relativePath)
            lastKnownDiskFingerprintByPath.removeValue(forKey: relativePath)
        case .added:
            externalAddedPaths.insert(relativePath)
            lastKnownDiskFingerprintByPath[relativePath] = diskFingerprint
        }

        if hasActiveEditableObserver {
            let conflict = ConflictState(
                reason: "external change observed",
                changeKind: changeKind,
                observedAt: Date(),
                diskFingerprint: diskFingerprint,
                activeObserverSummary: activeObserverSummary
            )
            transitionLocked(path: relativePath, to: .conflicted(conflict), reason: reason)
            logLocked("action: keep active editable surface in conflict path=\(relativePath)")
        } else {
            let change = ExternalChange(
                reason: "external change observed",
                changeKind: changeKind,
                observedAt: Date(),
                diskFingerprint: diskFingerprint,
                activeObserverSummary: activeObserverSummary
            )
            transitionLocked(path: relativePath, to: .externalChangePending(change), reason: reason)
            transitionLocked(path: relativePath, to: .idle, reason: "external change recorded")
        }
    }

    private func detectRenamedPaths(
        removedPaths: Set<String>,
        addedPaths: Set<String>,
        previousFiles: [String: FileSnapshot],
        nextFiles: [String: FileSnapshot]
    ) -> [String: String] {
        var removedByIdentifier: [String: [String]] = [:]
        var addedByIdentifier: [String: [String]] = [:]

        for path in removedPaths {
            guard let identifier = previousFiles[path]?.fileResourceIdentifier else { continue }
            removedByIdentifier[identifier, default: []].append(path)
        }

        for path in addedPaths {
            guard let identifier = nextFiles[path]?.fileResourceIdentifier else { continue }
            addedByIdentifier[identifier, default: []].append(path)
        }

        var renamed: [String: String] = [:]
        for (identifier, oldPaths) in removedByIdentifier {
            guard let newPaths = addedByIdentifier[identifier],
                  oldPaths.count == 1,
                  newPaths.count == 1,
                  let oldPath = oldPaths.first,
                  let newPath = newPaths.first,
                  oldPath != newPath else {
                continue
            }
            renamed[oldPath] = newPath
        }

        return renamed
    }

    private func emitUpdateLocked(_ update: WorkspaceLiveSyncUpdate) {
        let handler = onUpdate
        Task { @MainActor in
            handler?(update)
        }
    }

    private func cleanupExpiredSelfWritesLocked(now: Date) {
        let paths = pathStates.keys.sorted()
        for path in paths {
            guard case .awaitingSelfWriteConfirmation(let pending) = stateLocked(for: path) else {
                continue
            }

            guard pending.expiresAt <= now else { continue }
            transitionLocked(path: path, to: .idle, reason: "pending self-write expired generation=\(pending.generation)")
        }
    }

    private func shouldIncludeContentHash(relativePath: String, state: PathState) -> Bool {
        if case .awaitingSelfWriteConfirmation = state {
            return true
        }

        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        return ["md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline", "csv"].contains(ext)
    }

    private func observersLocked(for relativePath: String) -> [ObserverRecord] {
        observersByID.values
            .filter { $0.relativePath == relativePath }
            .sorted { lhs, rhs in
                lhs.observerID.localizedCaseInsensitiveCompare(rhs.observerID) == .orderedAscending
            }
    }

    private func stateLocked(for path: String) -> PathState {
        pathStates[path] ?? .idle
    }

    private func transitionLocked(path: String, to newState: PathState, reason: String) {
        let oldState = stateLocked(for: path)
        if oldState == newState {
            return
        }

        if newState.isIdle {
            pathStates.removeValue(forKey: path)
        } else {
            pathStates[path] = newState
        }

        logLocked("state transition path=\(path) old=\(oldState.shortLabel) new=\(newState.shortLabel) reason=\(reason)")
    }

    private func logLocked(_ message: String) {
        print("\(Self.logPrefix) \(message)")
    }

    private static let fseventCallback: FSEventStreamCallback = { _, info, numEvents, eventPathsPointer, eventFlagsPointer, eventIDsPointer in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceLiveSyncController>.fromOpaque(info).takeUnretainedValue()

        let paths = unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String] ?? []
        let flags = UnsafeBufferPointer(start: eventFlagsPointer, count: Int(numEvents))
        let ids = UnsafeBufferPointer(start: eventIDsPointer, count: Int(numEvents))

        let events: [RawEvent] = (0..<Int(numEvents)).map { index in
            RawEvent(
                path: paths.indices.contains(index) ? paths[index] : "<unknown>",
                flags: flags[index],
                id: ids[index]
            )
        }

        watcher.handleRawEventsLocked(events)
    }
}

private func flagSummary(_ flags: FSEventStreamEventFlags) -> String {
    var labels: [String] = []

    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
        labels.append("mustScanSubDirs")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
        labels.append("rootChanged")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
        labels.append("created")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
        labels.append("removed")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
        labels.append("inodeMetaMod")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
        labels.append("renamed")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
        labels.append("modified")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemFinderInfoMod) != 0 {
        labels.append("finderInfoMod")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner) != 0 {
        labels.append("changeOwner")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod) != 0 {
        labels.append("xattrMod")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 {
        labels.append("file")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
        labels.append("dir")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink) != 0 {
        labels.append("symlink")
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent) != 0 {
        labels.append("ownEvent")
    }

    return labels.isEmpty ? "none" : labels.joined(separator: "|")
}
