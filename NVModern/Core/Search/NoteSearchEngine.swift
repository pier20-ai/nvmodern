import Foundation

struct NoteSearchDocument: Hashable {
    let fileURL: URL
    let relativePath: String
    let title: String
    let modifiedDate: Date?
    let fileSize: Int64?
    let isTextFile: Bool
}

actor NoteSearchEngine {
    private enum IndexingDisplayState {
        case idle
        case rebuild
        case catchingUp
        case liveUpdatePending
        case failed(String)

        var phase: NoteSearchIndexStatus.Phase {
            switch self {
            case .idle:
                return .ready
            case .rebuild:
                return .rebuilding
            case .catchingUp:
                return .catchingUp
            case .liveUpdatePending:
                return .liveUpdatePending
            case .failed:
                return .failed
            }
        }

        var message: String? {
            switch self {
            case .failed(let message):
                return message
            case .idle, .rebuild, .catchingUp, .liveUpdatePending:
                return nil
            }
        }
    }

    private final class IndexingGenerationGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var currentGeneration: Int = 0

        func setCurrentGeneration(_ generation: Int) {
            lock.lock()
            currentGeneration = generation
            lock.unlock()
        }

        func validate(generation: Int) throws {
            try Task.checkCancellation()

            lock.lock()
            let isCurrent = currentGeneration == generation
            lock.unlock()

            guard isCurrent else {
                throw SearchIndexStore.IndexingInterruption.superseded
            }
        }
    }

    private let indexStore = SearchIndexStore()
    private let indexingGuard = IndexingGenerationGuard()
    private let makeIndexingStore: @Sendable () -> SearchIndexStore
    private var rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true)
    private var facetMap: NVModernSearchFacetMap = .empty
    private var documentsByPath: [String: NoteSearchDocument] = [:]
    private var hasBootstrappedIndex = false
    private var indexingTask: Task<Void, Never>?
    private var indexingGeneration: Int = 0
    private var completedIndexingGeneration: Int = 0
    private var indexingDisplayState: IndexingDisplayState = .idle
    /// Root path and facet fingerprint of the pass currently in flight, so a
    /// newer request for the same work can be coalesced instead of cancelling.
    private var activeIndexingRootPath: String?
    private var activeIndexingFingerprint: String?
    /// Newest document set that arrived while a pass was in flight. It runs as
    /// a single reconcile once that pass finishes.
    private var pendingFollowUpDocuments: [NoteSearchDocument]?
    private var rebuildProgress: (indexed: Int, total: Int)?

    init(makeIndexingStore: @escaping @Sendable () -> SearchIndexStore = { SearchIndexStore() }) {
        self.makeIndexingStore = makeIndexingStore
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[NVModern][Search] \(message)")
        #endif
    }

    /// Brings the index up to date.
    ///
    /// A pass already running for the same root and facet map is never
    /// cancelled: the request is folded into one follow-up reconcile that runs
    /// when the pass finishes. Only a facet-map change, a different root, or
    /// `forceFullRebuild` cancels, because those invalidate the work in flight.
    func updateIndex(
        rootURL: URL,
        facetMap: NVModernSearchFacetMap,
        documents: [NoteSearchDocument],
        liveUpdate: WorkspaceLiveSyncUpdate? = nil,
        isSelfWriteOnly: Bool = false,
        forceFullRebuild: Bool = false
    ) async {
        let standardizedRootURL = rootURL.standardizedFileURL
        let documentsByPath = Dictionary(uniqueKeysWithValues: documents.map { ($0.relativePath, $0) })
        let facetFingerprint = SearchIndexStore.facetFingerprint(for: facetMap)
        let persistentIndexAvailable = SearchIndexStore.hasUsableIndex(rootURL: standardizedRootURL)
        let facetCompatibleIndexAvailable = SearchIndexStore.hasUsableIndex(rootURL: standardizedRootURL, facetMap: facetMap)
        let facetMapChanged = persistentIndexAvailable && !facetCompatibleIndexAvailable
        let shouldRebuild = !facetCompatibleIndexAvailable && !isSelfWriteOnly
        let shouldReconcile = liveUpdate == nil && facetCompatibleIndexAvailable

        if facetCompatibleIndexAvailable && !hasBootstrappedIndex {
            hasBootstrappedIndex = true
            debugLog("bootstrapped from persisted index root=\(standardizedRootURL.path)")
        }

        debugLog(
            "updateIndex root=\(standardizedRootURL.path) docs=\(documents.count) rebuild=\(shouldRebuild) reconcile=\(shouldReconcile) liveUpdate=\(liveUpdate != nil) selfWriteOnly=\(isSelfWriteOnly) persistedIndex=\(persistentIndexAvailable) facetCompatibleIndex=\(facetCompatibleIndexAvailable) facetMapChanged=\(facetMapChanged)"
        )

        self.rootURL = standardizedRootURL
        self.facetMap = facetMap
        self.documentsByPath = documentsByPath

        // A write the app itself just made must never restart indexing. With no
        // usable index yet, the rebuild that is running (or about to run) picks
        // the file up anyway; otherwise it costs one targeted upsert.
        if isSelfWriteOnly, !facetCompatibleIndexAvailable || liveUpdate == nil {
            debugLog("updateIndex skipped self-write-only update root=\(standardizedRootURL.path)")
            return
        }

        if let indexingTask, !indexingTask.isCancelled {
            let isSameWork = activeIndexingRootPath == standardizedRootURL.path
                && activeIndexingFingerprint == facetFingerprint
            if isSameWork && !forceFullRebuild {
                pendingFollowUpDocuments = documents
                debugLog(
                    "updateIndex coalesced into in-flight generation=\(indexingGeneration) docs=\(documents.count)"
                )
                return
            }
            indexingTask.cancel()
        }

        indexingGeneration += 1
        let generation = indexingGeneration
        indexingGuard.setCurrentGeneration(generation)
        indexingDisplayState = shouldRebuild ? .rebuild : (shouldReconcile ? .catchingUp : .liveUpdatePending)
        activeIndexingRootPath = standardizedRootURL.path
        activeIndexingFingerprint = facetFingerprint
        rebuildProgress = shouldRebuild ? (0, documents.count) : nil

        let interruptionCheck: SearchIndexStore.InterruptionCheck = { [indexingGuard] in
            try indexingGuard.validate(generation: generation)
        }
        let progress: SearchIndexStore.RebuildProgress = { [weak self] indexed, total in
            Task { await self?.reportRebuildProgress(generation: generation, indexed: indexed, total: total) }
        }
        let makeIndexingStore = self.makeIndexingStore

        indexingTask = Task.detached(priority: .utility) {
            let indexingStore = makeIndexingStore()
            do {
                if shouldRebuild {
                    try indexingStore.rebuildIndex(
                        documents: documents,
                        facetMap: facetMap,
                        rootURL: standardizedRootURL,
                        interruptionCheck: interruptionCheck,
                        progress: progress
                    )
                    await self.finishIndexingSuccess(
                        generation: generation,
                        message: "updateIndex rebuild completed root=\(standardizedRootURL.path)"
                    )
                    return
                }

                if shouldReconcile {
                    try indexingStore.reconcileIndex(
                        documents: documents,
                        facetMap: facetMap,
                        rootURL: standardizedRootURL,
                        interruptionCheck: interruptionCheck
                    )
                    await self.finishIndexingSuccess(
                        generation: generation,
                        message: "updateIndex reconcile completed root=\(standardizedRootURL.path)"
                    )
                    return
                }

                guard let liveUpdate else {
                    await self.finishIndexingSuccess(
                        generation: generation,
                        message: "updateIndex skipped incremental because liveUpdate=nil"
                    )
                    return
                }

                var deletedPaths = liveUpdate.externalDeletedPaths
                var changedPaths = liveUpdate.externalModifiedPaths
                    .union(liveUpdate.externalAddedPaths)
                    .union(liveUpdate.selfWriteConfirmedPaths)

                for (oldPath, newPath) in liveUpdate.renamedPaths {
                    deletedPaths.insert(oldPath)
                    changedPaths.insert(newPath)
                }

                try interruptionCheck()
                try indexingStore.applyChanges(
                    documentsByPath: documentsByPath,
                    changedPaths: changedPaths,
                    deletedPaths: deletedPaths,
                    facetMap: facetMap,
                    rootURL: standardizedRootURL,
                    skipUnchangedContentHash: isSelfWriteOnly,
                    interruptionCheck: interruptionCheck
                )
                await self.finishIndexingSuccess(
                    generation: generation,
                    message: "updateIndex incremental completed changed=\(changedPaths.count) deleted=\(deletedPaths.count)"
                )
            } catch let interruption as SearchIndexStore.IndexingInterruption {
                await self.finishIndexingInterrupted(generation: generation, interruption: interruption)
            } catch {
                await self.finishIndexingFailure(
                    generation: generation,
                    message: "index update failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func reportRebuildProgress(generation: Int, indexed: Int, total: Int) {
        guard generation == indexingGeneration else { return }
        rebuildProgress = (indexed, total)
    }

    private func finishIndexingSuccess(generation: Int, message: String) {
        guard generation == indexingGeneration else {
            debugLog("ignored stale indexing completion generation=\(generation) current=\(indexingGeneration)")
            return
        }

        completedIndexingGeneration = generation
        hasBootstrappedIndex = true
        clearActiveIndexingState()
        indexingDisplayState = .idle
        debugLog(message)
        drainPendingFollowUpIfNeeded()
    }

    private func finishIndexingInterrupted(generation: Int, interruption: SearchIndexStore.IndexingInterruption) {
        guard generation == indexingGeneration else {
            debugLog("ignored stale indexing interruption generation=\(generation) current=\(indexingGeneration) reason=\(interruption.localizedDescription)")
            return
        }

        clearActiveIndexingState()
        indexingDisplayState = .idle
        debugLog("index update interrupted generation=\(generation) reason=\(interruption.localizedDescription)")
        drainPendingFollowUpIfNeeded()
    }

    private func finishIndexingFailure(generation: Int, message: String) {
        guard generation == indexingGeneration else {
            debugLog("ignored stale indexing failure generation=\(generation) current=\(indexingGeneration) message=\(message)")
            return
        }

        clearActiveIndexingState()
        indexingDisplayState = .failed(message)
        pendingFollowUpDocuments = nil
        debugLog(message)
    }

    private func clearActiveIndexingState() {
        indexingTask = nil
        activeIndexingRootPath = nil
        activeIndexingFingerprint = nil
        rebuildProgress = nil
    }

    /// Runs the requests that were coalesced into the pass that just finished
    /// as a single reconcile, which skips documents whose size and mtime are
    /// unchanged.
    private func drainPendingFollowUpIfNeeded() {
        guard let documents = pendingFollowUpDocuments else { return }
        pendingFollowUpDocuments = nil
        let rootURL = self.rootURL
        let facetMap = self.facetMap
        debugLog("draining coalesced follow-up docs=\(documents.count)")
        Task { [weak self] in
            await self?.updateIndex(rootURL: rootURL, facetMap: facetMap, documents: documents)
        }
    }

    private func currentIndexStatus() -> NoteSearchIndexStatus {
        let phase = indexingDisplayState.phase
        let isStale = hasBootstrappedIndex && completedIndexingGeneration < indexingGeneration && phase != .ready
        return NoteSearchIndexStatus(
            phase: phase,
            isStale: isStale,
            activeGeneration: indexingGeneration,
            completedGeneration: completedIndexingGeneration,
            message: indexingDisplayState.message,
            indexedCount: phase == .rebuilding ? rebuildProgress?.indexed : nil,
            totalCount: phase == .rebuilding ? rebuildProgress?.total : nil
        )
    }

    /// Indexing state for tests: the generation counters plus whether a pass is
    /// still in flight and whether a coalesced follow-up is queued.
    func indexingSnapshotForTesting() -> (active: Int, completed: Int, isIndexing: Bool, hasPendingFollowUp: Bool) {
        (indexingGeneration, completedIndexingGeneration, indexingTask != nil, pendingFollowUpDocuments != nil)
    }

    func search(
        query: String,
        rootURL: URL,
        cursorLocationUTF16: Int? = nil,
        supportedFacetKeys: [String]
    ) async -> NoteSearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexStatus = currentIndexStatus()
        guard !trimmedQuery.isEmpty else {
            return NoteSearchResponse(results: [], suggestions: [], indexStatus: indexStatus)
        }

        let parsedQuery = SearchQueryParser.parse(
            query: query,
            cursorLocationUTF16: cursorLocationUTF16,
            supportedFacetKeys: supportedFacetKeys
        )

        if shouldSkipBroadPrefixSearch(parsedQuery) {
            debugLog(
                "search skipped broadPrefix query=\(query) status=\(indexStatus.phase.rawValue) stale=\(indexStatus.isStale) root=\(rootURL.standardizedFileURL.path)"
            )
            return NoteSearchResponse(results: [], suggestions: [], indexStatus: indexStatus)
        }

        do {
            // Reader open: no DDL and no metadata writes, so a rebuild holding
            // the write lock cannot turn a search into an error. Batches that
            // are already committed are visible.
            try indexStore.openForSearchingIfNeeded(rootURL: rootURL.standardizedFileURL)
            let results = try indexStore.search(parsedQuery: parsedQuery, limit: 80)
            let suggestions = try indexStore.suggestions(for: parsedQuery, supportedFacetKeys: supportedFacetKeys)
            debugLog(
                "search query=\(query) results=\(results.count) suggestions=\(suggestions.count) status=\(indexStatus.phase.rawValue) stale=\(indexStatus.isStale) generation=\(indexStatus.completedGeneration)/\(indexStatus.activeGeneration) root=\(rootURL.standardizedFileURL.path)"
            )
            return NoteSearchResponse(results: results, suggestions: suggestions, indexStatus: indexStatus)
        } catch {
            debugLog(
                "search failed query=\(query) status=\(indexStatus.phase.rawValue) stale=\(indexStatus.isStale) error=\(error.localizedDescription)"
            )
            return NoteSearchResponse(results: [], suggestions: [], indexStatus: indexStatus)
        }
    }

    private func shouldSkipBroadPrefixSearch(_ parsedQuery: NoteSearchParsedQuery) -> Bool {
        guard parsedQuery.facets.isEmpty,
              parsedQuery.searchTerms.count == 1,
              let term = parsedQuery.searchTerms.first,
              !term.isQuotedPhrase else {
            return false
        }

        let trimmed = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2 else { return false }
        guard trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil else { return false }
        return true
    }
}

final class NoteSearchEngineRegistry {
    static let shared = NoteSearchEngineRegistry()

    private let lock = NSLock()
    private var enginesByRootPath: [String: NoteSearchEngine] = [:]

    func engine(for project: NVModernProject) -> NoteSearchEngine {
        let rootPath = project.rootURL.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }

        if let existing = enginesByRootPath[rootPath] {
            return existing
        }

        let engine = NoteSearchEngine()
        enginesByRootPath[rootPath] = engine
        return engine
    }
}
