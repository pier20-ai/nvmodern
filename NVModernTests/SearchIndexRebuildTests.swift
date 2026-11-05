import XCTest
@testable import nvModern

/// Covers the rebuild livelock fixes: batched commits with a resume cursor,
/// searches that read while a rebuild holds the write lock, and coalescing of
/// index updates that arrive while a rebuild is in flight.
final class SearchIndexRebuildTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-search-rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: SearchIndexStore.indexDirectoryURL(for: rootURL))
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private func makeWorkspace(fileCount: Int) throws -> [NoteSearchDocument] {
        var documents: [NoteSearchDocument] = []
        documents.reserveCapacity(fileCount)
        for index in 0..<fileCount {
            let name = String(format: "note-%04d.md", index)
            let fileURL = rootURL.appendingPathComponent(name, isDirectory: false)
            let body = "# Note \(index)\n\nhaystack marker\(index) body text for note \(index).\n"
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            documents.append(
                NoteSearchDocument(
                    fileURL: fileURL,
                    relativePath: name,
                    title: "Note \(index)",
                    modifiedDate: attributes[.modificationDate] as? Date,
                    fileSize: (attributes[.size] as? NSNumber)?.int64Value,
                    isTextFile: true
                )
            )
        }
        return documents
    }

    private func parsedQuery(_ text: String) -> NoteSearchParsedQuery {
        SearchQueryParser.parse(query: text, supportedFacetKeys: NVModernSearchFacetMap.supportedFacetKeys)
    }

    private func waitUntil(
        timeout: TimeInterval = 20,
        description: String,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: Resumable rebuilds

    func testInterruptedRebuildResumesWithoutReExtractingCommittedDocuments() throws {
        let documents = try makeWorkspace(fileCount: 300)
        let sortedPaths = documents.map(\.relativePath).sorted()

        let firstRecorder = ExtractionRecorder()
        let firstStore = SearchIndexStore()
        firstStore.rebuildBatchSize = 50
        firstStore.didExtractDocumentForTesting = { [firstRecorder] path in firstRecorder.record(path) }

        XCTAssertThrowsError(
            try firstStore.rebuildIndex(
                documents: documents,
                facetMap: .empty,
                rootURL: rootURL,
                interruptionCheck: { [firstRecorder] in
                    if firstRecorder.count >= 120 {
                        throw SearchIndexStore.IndexingInterruption.cancelled
                    }
                }
            )
        )
        firstStore.close()

        XCTAssertEqual(firstRecorder.count, 120, "the interruption should stop extraction at the 120th document")
        XCTAssertFalse(
            SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty),
            "an interrupted rebuild must not report a usable index"
        )

        let secondRecorder = ExtractionRecorder()
        let secondStore = SearchIndexStore()
        secondStore.rebuildBatchSize = 50
        secondStore.didExtractDocumentForTesting = { [secondRecorder] path in secondRecorder.record(path) }
        try secondStore.rebuildIndex(documents: documents, facetMap: .empty, rootURL: rootURL)

        // Two batches of 50 committed before the interruption, so the resumed
        // rebuild re-extracts only the remaining 200 documents.
        XCTAssertEqual(secondRecorder.count, 200)
        let reExtracted = Set(secondRecorder.paths).intersection(sortedPaths.prefix(100))
        XCTAssertTrue(reExtracted.isEmpty, "committed documents were re-extracted: \(reExtracted.sorted())")
        XCTAssertTrue(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty))

        let results = try secondStore.search(parsedQuery: parsedQuery("haystack"), limit: 500)
        XCTAssertFalse(results.isEmpty, "the completed index should answer a content search")
        secondStore.close()
    }

    func testFacetMapChangeRestartsInsteadOfResuming() throws {
        let documents = try makeWorkspace(fileCount: 120)
        let recorder = ExtractionRecorder()
        let store = SearchIndexStore()
        store.rebuildBatchSize = 50
        store.didExtractDocumentForTesting = { [recorder] path in recorder.record(path) }

        XCTAssertThrowsError(
            try store.rebuildIndex(
                documents: documents,
                facetMap: .empty,
                rootURL: rootURL,
                interruptionCheck: { [recorder] in
                    if recorder.count >= 60 {
                        throw SearchIndexStore.IndexingInterruption.superseded
                    }
                }
            )
        )
        store.close()

        let changedFacetMap = NVModernSearchFacetMap(mappingsByFacetKey: ["class": ["": "note"]])
        let resumedRecorder = ExtractionRecorder()
        let resumedStore = SearchIndexStore()
        resumedStore.rebuildBatchSize = 50
        resumedStore.didExtractDocumentForTesting = { [resumedRecorder] path in resumedRecorder.record(path) }
        try resumedStore.rebuildIndex(documents: documents, facetMap: changedFacetMap, rootURL: rootURL)
        resumedStore.close()

        XCTAssertEqual(resumedRecorder.count, 120, "a facet-map change invalidates the cursor and restarts the rebuild")
        XCTAssertTrue(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: changedFacetMap))
        XCTAssertFalse(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty))
    }

    // MARK: Reading during a rebuild

    func testSearchDuringRebuildReadsCommittedBatches() async throws {
        let documents = try makeWorkspace(fileCount: 200)
        let gate = RebuildGate(holdAt: 100)
        let store = SearchIndexStore()
        store.rebuildBatchSize = 50
        store.willCommitRebuildBatchForTesting = { [gate] indexed, _ in gate.holdIfNeeded(indexed: indexed) }

        let rebuildFinished = Flag()
        DispatchQueue.global(qos: .userInitiated).async { [rootURL] in
            try? store.rebuildIndex(documents: documents, facetMap: .empty, rootURL: rootURL!)
            store.close()
            rebuildFinished.set()
        }

        // The rebuild is now parked inside the second batch's transaction, so
        // the first batch is committed and the write lock is held.
        try await waitUntil(description: "rebuild to hold the write lock") { gate.isHeld }
        XCTAssertFalse(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty))

        let reader = SearchIndexStore()
        try reader.openForSearchingIfNeeded(rootURL: rootURL)
        let results = try reader.search(parsedQuery: parsedQuery("haystack"), limit: 500)
        reader.close()
        XCTAssertFalse(results.isEmpty, "a search during a rebuild must see the batches already committed")

        gate.release()
        try await waitUntil(description: "rebuild to finish") { rebuildFinished.isSet }
        XCTAssertTrue(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty))
    }

    // MARK: Coalescing

    func testUpdateIndexDuringRebuildCoalescesInsteadOfCancelling() async throws {
        let documents = try makeWorkspace(fileCount: 150)
        let gate = RebuildGate(holdAt: 50)
        let engine = NoteSearchEngine(makeIndexingStore: { [gate] in
            let store = SearchIndexStore()
            store.rebuildBatchSize = 50
            store.willCommitRebuildBatchForTesting = { indexed, _ in gate.holdIfNeeded(indexed: indexed) }
            return store
        })

        await engine.updateIndex(rootURL: rootURL, facetMap: .empty, documents: documents)
        try await waitUntil(description: "rebuild to start") { gate.isHeld }

        let before = await engine.indexingSnapshotForTesting()
        XCTAssertTrue(before.isIndexing)

        await engine.updateIndex(rootURL: rootURL, facetMap: .empty, documents: documents)
        let after = await engine.indexingSnapshotForTesting()

        XCTAssertEqual(after.active, before.active, "the same facet map must not bump the indexing generation")
        XCTAssertTrue(after.isIndexing, "the in-flight rebuild must keep running")
        XCTAssertTrue(after.hasPendingFollowUp, "the coalesced request must be queued as a follow-up")

        gate.release()
        try await waitUntil(description: "indexing to settle") {
            let snapshot = await engine.indexingSnapshotForTesting()
            return !snapshot.isIndexing && snapshot.completed == snapshot.active && !snapshot.hasPendingFollowUp
        }
        XCTAssertTrue(SearchIndexStore.hasUsableIndex(rootURL: rootURL, facetMap: .empty))
    }

    @MainActor
    func testSelfWriteOnlyUpdateIsRecognized() {
        let selfWriteOnly = WorkspaceLiveSyncUpdate(
            reason: "save",
            changedPaths: ["note-0001.md"],
            selfWriteConfirmedPaths: ["note-0001.md"],
            externalModifiedPaths: [],
            externalDeletedPaths: [],
            externalAddedPaths: [],
            renamedPaths: [:],
            conflictedPaths: [],
            addedFolders: [],
            removedFolders: []
        )
        XCTAssertTrue(NotesWorkspaceModel.isSelfWriteOnly(selfWriteOnly))

        let mixed = WorkspaceLiveSyncUpdate(
            reason: "save",
            changedPaths: ["note-0001.md", "note-0002.md"],
            selfWriteConfirmedPaths: ["note-0001.md"],
            externalModifiedPaths: ["note-0002.md"],
            externalDeletedPaths: [],
            externalAddedPaths: [],
            renamedPaths: [:],
            conflictedPaths: [],
            addedFolders: [],
            removedFolders: []
        )
        XCTAssertFalse(NotesWorkspaceModel.isSelfWriteOnly(mixed))
    }
}

// MARK: - Helpers

private final class ExtractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Parks a rebuild inside one batch's transaction so a test can observe the
/// index while the write lock is held.
private final class RebuildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var released = false
    private let holdAt: Int

    init(holdAt: Int) {
        self.holdAt = holdAt
    }

    func holdIfNeeded(indexed: Int) {
        guard indexed == holdAt else { return }
        lock.lock()
        held = true
        lock.unlock()
        while !isReleased {
            usleep(2_000)
        }
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
