import CryptoKit
import Foundation
import PDFKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SearchIndexStore: @unchecked Sendable {
    private func debugLog(_ message: String) {
        #if DEBUG
        print("[NVModern][SearchIndex] \(message)")
        #endif
    }
    private static let schemaSQL = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    PRAGMA temp_store=MEMORY;

    CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY,
        rel_path TEXT NOT NULL UNIQUE,
        dir_path TEXT NOT NULL,
        name TEXT NOT NULL,
        stem TEXT NOT NULL,
        ext TEXT NOT NULL,
        top_root TEXT NOT NULL,
        class TEXT NOT NULL,
        workspace TEXT,
        entity TEXT,
        asset_bucket TEXT,
        library_bucket TEXT,
        size_bytes INTEGER NOT NULL,
        mtime_ns INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        is_archived INTEGER NOT NULL DEFAULT 0,
        is_text INTEGER NOT NULL DEFAULT 0,
        title TEXT,
        path_tokens TEXT NOT NULL,
        name_tokens TEXT NOT NULL,
        content_text TEXT NOT NULL,
        content_source TEXT NOT NULL DEFAULT 'none',
        indexed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE INDEX IF NOT EXISTS idx_files_class ON files(class);
    CREATE INDEX IF NOT EXISTS idx_files_ext ON files(ext);
    CREATE INDEX IF NOT EXISTS idx_files_workspace ON files(workspace);
    CREATE INDEX IF NOT EXISTS idx_files_entity ON files(entity);
    CREATE INDEX IF NOT EXISTS idx_files_top_root ON files(top_root);
    CREATE INDEX IF NOT EXISTS idx_files_archived ON files(is_archived);
    CREATE INDEX IF NOT EXISTS idx_files_mtime_ns ON files(mtime_ns DESC);

    CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(
        name,
        rel_path,
        path_tokens,
        name_tokens,
        content_text,
        tokenize = 'unicode61 remove_diacritics 2 tokenchars ''-_./'''
    );

    CREATE VIEW IF NOT EXISTS file_facets AS
    SELECT
        class,
        ext,
        COALESCE(workspace, '') AS workspace,
        COALESCE(entity, '') AS entity,
        COALESCE(asset_bucket, '') AS asset_bucket,
        COALESCE(library_bucket, '') AS library_bucket,
        COUNT(*) AS file_count
    FROM files
    GROUP BY class, ext, workspace, entity, asset_bucket, library_bucket;

    CREATE TABLE IF NOT EXISTS index_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline", "csv",
        "json", "jsonl", "py", "sql", "yaml", "yml", "toml", "ini", "cfg",
        "tsv", "xml", "html", "css", "js", "ts", "tsx", "jsx", "sh", "swift"
    ]
    private static let documentExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "odt"]
    private static let maxExtractedCharacters = 200_000
    private static let maxSuggestionCount = 8
    private static let schemaVersion = "search-v2"

    /// Resume cursor for an interrupted rebuild. Both keys live in
    /// `index_meta`, which every `search-v2` database already has, so no
    /// schema/version change is needed: an older binary simply ignores them.
    private static let rebuildCursorPathKey = "rebuild_cursor_path"
    private static let rebuildCursorFingerprintKey = "rebuild_cursor_fingerprint"

    typealias InterruptionCheck = @Sendable () throws -> Void

    /// Reports `(documents indexed so far, total documents)` after every
    /// committed rebuild batch.
    typealias RebuildProgress = @Sendable (Int, Int) -> Void

    /// Number of documents a rebuild extracts and commits per transaction.
    /// Each committed batch advances the persisted resume cursor, so an
    /// interruption costs at most one batch of work instead of everything.
    var rebuildBatchSize: Int = 200

    /// Test hook: fires with the relative path of every document whose text is
    /// actually extracted, so tests can prove a resumed rebuild skips work.
    var didExtractDocumentForTesting: (@Sendable (String) -> Void)?

    /// Test hook: fires after each rebuild batch commits.
    var didCommitRebuildBatchForTesting: (@Sendable (Int, Int) -> Void)?

    /// Test hook: fires inside each rebuild batch's transaction, just before it
    /// commits — that is, while this connection holds the write lock.
    var willCommitRebuildBatchForTesting: (@Sendable (Int, Int) -> Void)?

    enum IndexingInterruption: Error, LocalizedError {
        case cancelled
        case superseded

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Search indexing cancelled"
            case .superseded:
                return "Search indexing superseded by a newer generation"
            }
        }
    }

    private struct IndexedFileRecord {
        let relPath: String
        let dirPath: String
        let name: String
        let stem: String
        let ext: String
        let topRoot: String
        let fileClass: String
        let workspace: String?
        let entity: String?
        let assetBucket: String?
        let libraryBucket: String?
        let sizeBytes: Int64
        let mtimeNS: Int64
        let sha256: String
        let isArchived: Bool
        let isText: Bool
        let title: String?
        let pathTokens: String
        let nameTokens: String
        let contentText: String
        let contentSource: String
    }

    private struct IndexedFileMetadata {
        let sizeBytes: Int64
        let mtimeNS: Int64
    }

    private struct IndexMetadata {
        let schemaVersion: String?
        let rootPath: String?
        let facetMapFingerprint: String?
    }

    private var database: OpaquePointer?
    private var databaseURL: URL?
    /// Whether this connection has already run the schema DDL and metadata
    /// writes. A reader connection opens without them so a search never has to
    /// take the write lock a rebuild is holding.
    private var schemaEnsured = false

    deinit {
        close()
    }

    static func hasUsableIndex(rootURL: URL) -> Bool {
        guard let metadata = indexMetadata(rootURL: rootURL) else {
            return false
        }

        return metadata.schemaVersion == schemaVersion
            && metadata.rootPath == rootURL.standardizedFileURL.path
    }

    static func hasUsableIndex(rootURL: URL, facetMap: NVModernSearchFacetMap) -> Bool {
        guard let metadata = indexMetadata(rootURL: rootURL) else {
            return false
        }

        return metadata.schemaVersion == schemaVersion
            && metadata.rootPath == rootURL.standardizedFileURL.path
            && metadata.facetMapFingerprint == facetMapFingerprint(for: facetMap)
    }

    func openIfNeeded(rootURL: URL) throws {
        let targetURL = try Self.databaseURL(for: rootURL)
        if database != nil, databaseURL == targetURL {
            // An existing reader connection is upgraded in place rather than
            // reopened, so writers still get the schema they expect.
            if !schemaEnsured {
                try ensureSchema(rootURL: rootURL)
            }
            return
        }

        close()
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(targetURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            defer { if db != nil { sqlite3_close(db) } }
            throw databaseError(message: "Could not open search index", database: db)
        }

        database = db
        databaseURL = targetURL
        schemaEnsured = false
        // Before any statement, so a concurrent rebuild's write lock makes us
        // wait instead of failing with SQLITE_BUSY.
        try exec("PRAGMA busy_timeout=5000")
        try ensureSchema(rootURL: rootURL)
        debugLog("opened db=\(targetURL.path) root=\(rootURL.standardizedFileURL.path)")
    }

    /// Opens the index for reading only: no DDL, no metadata writes, so a
    /// search never contends for the write lock a rebuild holds. Falls back to
    /// the full read/write open when the database is missing or its schema is
    /// not at the expected version.
    func openForSearchingIfNeeded(rootURL: URL) throws {
        let targetURL = try Self.databaseURL(for: rootURL)
        if database != nil, databaseURL == targetURL { return }

        guard FileManager.default.fileExists(atPath: targetURL.path),
              let metadata = Self.indexMetadata(rootURL: rootURL),
              metadata.schemaVersion == Self.schemaVersion,
              metadata.rootPath == rootURL.standardizedFileURL.path else {
            try openIfNeeded(rootURL: rootURL)
            return
        }

        close()
        var db: OpaquePointer?
        // READWRITE without CREATE: WAL databases cannot reliably be opened
        // with SQLITE_OPEN_READONLY, and this connection never writes anyway.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(targetURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            defer { if db != nil { sqlite3_close(db) } }
            try openIfNeeded(rootURL: rootURL)
            return
        }

        database = db
        databaseURL = targetURL
        schemaEnsured = false
        try exec("PRAGMA busy_timeout=5000")
        debugLog("opened for reading db=\(targetURL.path) root=\(rootURL.standardizedFileURL.path)")
    }

    private func ensureSchema(rootURL: URL) throws {
        try exec(Self.schemaSQL)
        try setMeta(key: "schema_version", value: Self.schemaVersion)
        try setMeta(key: "root_path", value: rootURL.standardizedFileURL.path)
        schemaEnsured = true
    }

    func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        databaseURL = nil
        schemaEnsured = false
    }

    /// Rebuilds the whole index in committed batches.
    ///
    /// Documents are processed in `rel_path` order and each batch commits in
    /// its own transaction, recording the last committed path as a resume
    /// cursor in `index_meta`. An interrupted rebuild therefore resumes where
    /// it stopped instead of throwing away every extraction, and searches see
    /// the batches already committed. `facet_map_fingerprint` — the marker
    /// `hasUsableIndex(rootURL:facetMap:)` looks for — is written only when the
    /// final batch lands. A rebuild for a different facet map drops the cursor
    /// and starts over, because every extracted record's facets are stale.
    func rebuildIndex(
        documents: [NoteSearchDocument],
        facetMap: NVModernSearchFacetMap,
        rootURL: URL,
        interruptionCheck: InterruptionCheck? = nil,
        progress: RebuildProgress? = nil
    ) throws {
        try checkForInterruption(interruptionCheck)
        try openIfNeeded(rootURL: rootURL)

        let fingerprint = Self.facetMapFingerprint(for: facetMap)
        let sortedDocuments = documents.sorted { $0.relativePath < $1.relativePath }
        let totalCount = sortedDocuments.count
        let resumeCursor = try rebuildResumeCursor(fingerprint: fingerprint)
        let pendingDocuments = resumeCursor.map { cursor in
            sortedDocuments.filter { $0.relativePath > cursor }
        } ?? sortedDocuments
        var indexedCount = totalCount - pendingDocuments.count

        debugLog("rebuild prepare root=\(rootURL.path) docs=\(totalCount) resumeFrom=\(resumeCursor ?? "-") pending=\(pendingDocuments.count)")
        try pruneRecords(notIn: Set(sortedDocuments.map(\.relativePath)), interruptionCheck: interruptionCheck)
        progress?(indexedCount, totalCount)

        guard !pendingDocuments.isEmpty else {
            try beginTransaction()
            do {
                try setMeta(key: "facet_map_fingerprint", value: fingerprint)
                try clearRebuildCursor()
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
            debugLog("rebuild done rows=\(totalCount) (nothing pending)")
            return
        }

        var batchStart = 0
        let batchSize = max(1, rebuildBatchSize)
        while batchStart < pendingDocuments.count {
            let batchEnd = min(batchStart + batchSize, pendingDocuments.count)
            let isFinalBatch = batchEnd == pendingDocuments.count

            var records: [IndexedFileRecord] = []
            records.reserveCapacity(batchEnd - batchStart)
            for index in batchStart..<batchEnd {
                try checkForInterruption(interruptionCheck)
                records.append(try buildRecord(for: pendingDocuments[index], facetMap: facetMap))
            }

            try checkForInterruption(interruptionCheck)
            try beginTransaction()
            do {
                for record in records {
                    try upsert(record: record)
                }
                if isFinalBatch {
                    try setMeta(key: "facet_map_fingerprint", value: fingerprint)
                    try clearRebuildCursor()
                } else if let cursor = records.last?.relPath {
                    try setMeta(key: Self.rebuildCursorFingerprintKey, value: fingerprint)
                    try setMeta(key: Self.rebuildCursorPathKey, value: cursor)
                }
                willCommitRebuildBatchForTesting?(indexedCount + records.count, totalCount)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }

            indexedCount += records.count
            batchStart = batchEnd
            progress?(indexedCount, totalCount)
            didCommitRebuildBatchForTesting?(indexedCount, totalCount)
            debugLog("rebuild batch committed indexed=\(indexedCount)/\(totalCount)")
        }

        debugLog("rebuild done rows=\(indexedCount)")
    }

    /// Reads the resume cursor for `fingerprint`, dropping a cursor left by a
    /// rebuild for a different facet map.
    private func rebuildResumeCursor(fingerprint: String) throws -> String? {
        guard let storedFingerprint = try metaValue(Self.rebuildCursorFingerprintKey),
              storedFingerprint == fingerprint,
              let cursor = try metaValue(Self.rebuildCursorPathKey),
              !cursor.isEmpty else {
            try clearRebuildCursor()
            return nil
        }
        return cursor
    }

    private func clearRebuildCursor() throws {
        let sql = "DELETE FROM index_meta WHERE key IN (?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(Self.rebuildCursorPathKey), .text(Self.rebuildCursorFingerprintKey)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not clear rebuild cursor")
        }
    }

    /// Drops rows whose file no longer exists, in a transaction of its own so
    /// it never has to be redone by a resumed rebuild.
    private func pruneRecords(notIn desiredPaths: Set<String>, interruptionCheck: InterruptionCheck?) throws {
        let existingPaths = try fetchAllIndexedPaths()
        let deletedPaths = existingPaths.subtracting(desiredPaths)
        guard !deletedPaths.isEmpty else { return }

        try beginTransaction()
        do {
            for path in deletedPaths.sorted() {
                try checkForInterruption(interruptionCheck)
                try deleteRecord(relativePath: path)
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
        debugLog("rebuild pruned rows=\(deletedPaths.count)")
    }

    /// Applies a targeted set of changes.
    ///
    /// `skipUnchangedContentHash` is used for paths the app itself just wrote:
    /// a save that produced identical bytes costs one hash instead of a full
    /// re-extraction and re-index of the document.
    func applyChanges(
        documentsByPath: [String: NoteSearchDocument],
        changedPaths: Set<String>,
        deletedPaths: Set<String>,
        facetMap: NVModernSearchFacetMap,
        rootURL: URL,
        skipUnchangedContentHash: Bool = false,
        interruptionCheck: InterruptionCheck? = nil
    ) throws {
        try checkForInterruption(interruptionCheck)
        try openIfNeeded(rootURL: rootURL)
        guard !changedPaths.isEmpty || !deletedPaths.isEmpty else { return }

        debugLog("incremental update root=\(rootURL.path) changed=\(changedPaths.count) deleted=\(deletedPaths.count)")
        var skippedUnchanged = 0
        try beginTransaction()
        do {
            for path in deletedPaths.sorted() {
                try checkForInterruption(interruptionCheck)
                try deleteRecord(relativePath: path)
            }
            for path in changedPaths.sorted() {
                try checkForInterruption(interruptionCheck)
                guard let document = documentsByPath[path] else {
                    try deleteRecord(relativePath: path)
                    continue
                }
                if skipUnchangedContentHash,
                   let storedHash = try fetchStoredContentHash(relativePath: path),
                   !storedHash.isEmpty,
                   storedHash == sha256(for: document.fileURL) {
                    skippedUnchanged += 1
                    continue
                }
                let record = try buildRecord(for: document, facetMap: facetMap)
                try checkForInterruption(interruptionCheck)
                try upsert(record: record)
            }
            try checkForInterruption(interruptionCheck)
            try markFacetMapCompleteIfNoRebuildPending(facetMap: facetMap)
            try checkForInterruption(interruptionCheck)
            try commitTransaction()
            debugLog("incremental update done skippedUnchanged=\(skippedUnchanged)")
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func reconcileIndex(
        documents: [NoteSearchDocument],
        facetMap: NVModernSearchFacetMap,
        rootURL: URL,
        interruptionCheck: InterruptionCheck? = nil
    ) throws {
        try checkForInterruption(interruptionCheck)
        try openIfNeeded(rootURL: rootURL)

        let existingMetadataByPath = try fetchAllIndexedMetadataByPath()
        let desiredPaths = Set(documents.map(\.relativePath))
        let deletedPaths = Set(existingMetadataByPath.keys).subtracting(desiredPaths)

        var changedDocuments: [NoteSearchDocument] = []
        changedDocuments.reserveCapacity(documents.count)

        var skippedCount = 0
        for document in documents {
            try checkForInterruption(interruptionCheck)

            guard let existingMetadata = existingMetadataByPath[document.relativePath] else {
                changedDocuments.append(document)
                continue
            }

            guard let fileSize = document.fileSize,
                  let modifiedDate = document.modifiedDate else {
                changedDocuments.append(document)
                continue
            }

            let mtimeNS = Int64(modifiedDate.timeIntervalSince1970 * 1_000_000_000)
            if existingMetadata.sizeBytes == fileSize && existingMetadata.mtimeNS == mtimeNS {
                skippedCount += 1
            } else {
                changedDocuments.append(document)
            }
        }

        debugLog("reconcile start root=\(rootURL.path) docs=\(documents.count) changed=\(changedDocuments.count) delete=\(deletedPaths.count) skipped=\(skippedCount)")
        guard !changedDocuments.isEmpty || !deletedPaths.isEmpty else {
            debugLog("reconcile done no-op")
            return
        }

        try beginTransaction()
        do {
            for path in deletedPaths.sorted() {
                try checkForInterruption(interruptionCheck)
                try deleteRecord(relativePath: path)
            }
            for document in changedDocuments {
                try checkForInterruption(interruptionCheck)
                let record = try buildRecord(for: document, facetMap: facetMap)
                try checkForInterruption(interruptionCheck)
                try upsert(record: record)
            }
            try checkForInterruption(interruptionCheck)
            try markFacetMapCompleteIfNoRebuildPending(facetMap: facetMap)
            try checkForInterruption(interruptionCheck)
            try commitTransaction()
            debugLog("reconcile done changed=\(changedDocuments.count) delete=\(deletedPaths.count)")
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func search(parsedQuery: NoteSearchParsedQuery, limit: Int) throws -> [NoteSearchResult] {
        guard database != nil else {
            debugLog("search skipped because database is not open query=\(parsedQuery.rawQuery)")
            return []
        }

        let groupedFacets = Dictionary(grouping: parsedQuery.facets, by: \.key)
        let (whereClauses, bindValues) = buildWhereClauses(groupedFacets)

        if parsedQuery.terms.isEmpty {
            let sql = """
            SELECT
                f.rel_path,
                f.stem,
                f.ext,
                f.class,
                f.title,
                f.content_text,
                f.mtime_ns
            FROM files f
            \(whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND "))
            ORDER BY f.mtime_ns DESC
            LIMIT ?
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(values: bindValues + [.int(Int64(limit))], to: statement)
            let results = try collectResults(from: statement, parsedQuery: parsedQuery, includeFTSRank: false)
            debugLog("search metadataOnly query=\(parsedQuery.rawQuery) results=\(results.count)")
            return results
        }

        let maxUnquotedTermLength = parsedQuery.searchTerms
            .filter { !$0.isQuotedPhrase }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .max() ?? 0
        let candidateLimit: Int
        if parsedQuery.searchTerms.count == 1 && maxUnquotedTermLength <= 4 {
            candidateLimit = max(limit * 2, 80)
        } else {
            candidateLimit = max(limit * 4, 80)
        }
        let ftsQuery = makeFTSQuery(from: parsedQuery.searchTerms)
        guard !ftsQuery.isEmpty else {
            return try pathLikeFallbackResults(
                for: parsedQuery,
                whereClauses: whereClauses,
                bindValues: bindValues,
                limit: limit
            )
        }

        let sql = """
        SELECT
            f.rel_path,
            f.stem,
            f.ext,
            f.class,
            f.title,
            '' AS content_text,
            f.mtime_ns,
            -bm25(file_fts, 1.75, 1.15, 0.95, 1.35, 0.35) AS base_rank,
            snippet(file_fts, 4, '[', ']', ' … ', 12) AS match_snippet
        FROM file_fts
        JOIN files f ON f.id = file_fts.rowid
        WHERE file_fts MATCH ?
          \(whereClauses.isEmpty ? "" : "AND " + whereClauses.joined(separator: " AND "))
        ORDER BY base_rank DESC, f.mtime_ns DESC
        LIMIT ?
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(ftsQuery)] + bindValues + [.int(Int64(candidateLimit))], to: statement)
        let candidates = try collectResults(from: statement, parsedQuery: parsedQuery, includeFTSRank: true)
        let results = Array(candidates.prefix(limit))
        if results.isEmpty {
            let quotedFallbackResults = try quotedExactFallbackResults(
                for: parsedQuery,
                whereClauses: whereClauses,
                bindValues: bindValues,
                limit: limit
            )
            if !quotedFallbackResults.isEmpty {
                debugLog("search fts+quotedFallback query=\(parsedQuery.rawQuery) fts=\(ftsQuery) terms=\(parsedQuery.terms.count) facets=\(parsedQuery.facets.count) results=\(quotedFallbackResults.count)")
                return quotedFallbackResults
            }

            let fallbackResults = try pathLikeFallbackResults(
                for: parsedQuery,
                whereClauses: whereClauses,
                bindValues: bindValues,
                limit: limit
            )
            debugLog("search fts+fallback query=\(parsedQuery.rawQuery) fts=\(ftsQuery) terms=\(parsedQuery.terms.count) facets=\(parsedQuery.facets.count) results=\(fallbackResults.count)")
            return fallbackResults
        }
        debugLog("search fts query=\(parsedQuery.rawQuery) fts=\(ftsQuery) terms=\(parsedQuery.terms.count) facets=\(parsedQuery.facets.count) results=\(results.count)")
        return results
    }

    func suggestions(for parsedQuery: NoteSearchParsedQuery, supportedFacetKeys: [String]) throws -> [NoteSearchSuggestion] {
        guard let context = parsedQuery.completionContext else { return [] }

        switch context {
        case .facetKey(let prefix, let replacementRange):
            return facetKeySuggestions(prefix: prefix, replacementRange: replacementRange, supportedFacetKeys: supportedFacetKeys)

        case .facetValue(let key, let prefix, let replacementRange):
            return try facetValueSuggestions(key: key, prefix: prefix, replacementRange: replacementRange)

        case .term(let prefix, let replacementRange):
            var suggestions = facetKeySuggestions(prefix: prefix, replacementRange: replacementRange, supportedFacetKeys: supportedFacetKeys)
            suggestions.append(contentsOf: try fileSuggestions(prefix: prefix, replacementRange: replacementRange))
            return Array(suggestions.prefix(Self.maxSuggestionCount))
        }
    }

    private func collectResults(
        from statement: OpaquePointer?,
        parsedQuery: NoteSearchParsedQuery,
        includeFTSRank: Bool
    ) throws -> [NoteSearchResult] {
        var results: [NoteSearchResult] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let relativePath = columnString(statement, index: 0)
            let stem = columnString(statement, index: 1)
            let title = stem.isEmpty ? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent : stem
            let ext = columnString(statement, index: 2)
            let fileClass = columnString(statement, index: 3)
            let headingTitle = columnOptionalString(statement, index: 4)
            let contentText = columnString(statement, index: 5)
            let mtimeNS = columnInt64(statement, index: 6)
            let modifiedDate = Date(timeIntervalSince1970: Double(mtimeNS) / 1_000_000_000)
            let baseRank = includeFTSRank ? columnDouble(statement, index: 7) : 0
            let matchSnippet = includeFTSRank ? (columnOptionalString(statement, index: 8) ?? "") : ""

            let snippet = snippetText(
                matchSnippet: matchSnippet,
                contentText: contentText,
                headingTitle: headingTitle,
                ext: ext,
                searchTerms: parsedQuery.searchTerms
            )
            let score: Int
            if includeFTSRank {
                score = Int(baseRank * 1000)
            } else {
                score = rankedScore(
                    baseRank: baseRank,
                    rawQuery: parsedQuery.rawQuery,
                    searchTerms: parsedQuery.searchTerms,
                    title: title,
                    headingTitle: headingTitle,
                    relativePath: relativePath,
                    fileClass: fileClass,
                    modifiedDate: modifiedDate
                )
            }

            results.append(
                NoteSearchResult(
                    title: title,
                    relativePath: relativePath,
                    snippet: snippet,
                    modifiedDate: modifiedDate,
                    score: score
                )
            )
        }

        if !includeFTSRank {
            results.sort { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                switch (lhs.modifiedDate, rhs.modifiedDate) {
                case let (left?, right?):
                    return left > right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }

        return results
    }

    private func rankedScore(
        baseRank: Double,
        rawQuery: String,
        searchTerms: [SearchQueryTerm],
        title: String,
        headingTitle: String?,
        relativePath: String,
        fileClass: String,
        modifiedDate: Date?
    ) -> Int {
        var score = Int(baseRank * 1000)
        let lowerTitle = title.lowercased()
        let lowerHeading = headingTitle?.lowercased() ?? ""
        let lowerPath = relativePath.lowercased()
        let pathSegments = lowerPath.split(separator: "/").map(String.init)
        let normalizedTerms = searchTerms
            .map { normalizeSearchComparable($0.text) }
            .filter { !$0.isEmpty }
        let normalizedJoinedQuery = normalizeSearchComparable(normalizedTerms.joined(separator: " "))
        let basename = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent.lowercased()
        let normalizedBasename = normalizeSearchComparable(basename)
        let normalizedTitle = normalizeSearchComparable(title)
        let normalizedPath = normalizeSearchComparable(relativePath)
        let normalizedSegments = pathSegments.map(normalizeSearchComparable)

        for searchTerm in searchTerms {
            let normalizedTerm = normalizeSearchComparable(searchTerm.text)
            guard !normalizedTerm.isEmpty else { continue }

            if containsWord(normalizedTerm, in: lowerTitle) {
                score += 160
            } else if lowerTitle.contains(normalizedTerm) {
                score += 120
            }

            if !lowerHeading.isEmpty {
                if containsWord(normalizedTerm, in: lowerHeading) {
                    score += 80
                } else if lowerHeading.contains(normalizedTerm) {
                    score += 50
                }
            }

            if pathSegments.contains(where: { containsWord(normalizedTerm, in: $0) || $0 == normalizedTerm }) {
                score += 90
            } else if lowerPath.contains(normalizedTerm) {
                score += 55
            }

            if searchTerm.isQuotedPhrase {
                if normalizedTitle.contains(normalizedTerm) {
                    score += 260
                }
                if !lowerHeading.isEmpty, normalizeSearchComparable(lowerHeading).contains(normalizedTerm) {
                    score += 140
                }
                if normalizedPath.contains(normalizedTerm) {
                    score += 240
                }
            }
        }

        if !normalizedJoinedQuery.isEmpty {
            if normalizedBasename == normalizedJoinedQuery {
                score += 1600
            } else if normalizedBasename.hasPrefix(normalizedJoinedQuery) {
                score += 900
            } else if normalizedBasename.contains(normalizedJoinedQuery) {
                score += 600
            }

            if normalizedTitle == normalizedJoinedQuery {
                score += 800
            } else if normalizedTitle.contains(normalizedJoinedQuery) {
                score += 320
            }

            if normalizedSegments.contains(normalizedJoinedQuery) {
                score += 460
            }
        }

        if !normalizedTerms.isEmpty {
            let normalizedTermSet = Set(normalizedTerms)
            let basenameWords = Set(normalizedBasename.split(separator: " ").map(String.init))
            if normalizedTermSet.isSubset(of: basenameWords) {
                score += 720
            }

            if normalizedSegments.contains(where: { segment in
                let words = Set(segment.split(separator: " ").map(String.init))
                return normalizedTermSet.isSubset(of: words)
            }) {
                score += 260
            }
        }

        let normalizedRawQuery = normalizeSearchComparable(rawQuery)
        if !normalizedRawQuery.isEmpty {
            if lowerPath == rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                score += 2400
            } else if normalizedPath == normalizedRawQuery {
                score += 1600
            }
        }

        if fileClass.localizedCaseInsensitiveCompare("record") == .orderedSame {
            score += 8
        }

        if let modifiedDate {
            let ageDays = Date().timeIntervalSince(modifiedDate) / 86_400
            if ageDays <= 30 {
                score += 18
            } else if ageDays <= 180 {
                score += 10
            } else if ageDays <= 365 {
                score += 4
            }
        }

        return score
    }

    private func snippetText(
        matchSnippet: String,
        contentText: String,
        headingTitle: String?,
        ext: String,
        searchTerms: [SearchQueryTerm]
    ) -> String {
        let trimmedSnippet = compactWhitespace(
            matchSnippet
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
        )
        if !trimmedSnippet.isEmpty {
            return trimmedSnippet.prefixString(220)
        }

        if let headingTitle {
            let trimmedHeading = headingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHeading.isEmpty {
                return trimmedHeading.prefixString(220)
            }
        }

        if let excerpt = bestExcerpt(from: contentText, searchTerms: searchTerms) {
            return excerpt
        }

        let fallback = compactWhitespace(contentText)
        if !fallback.isEmpty {
            return fallback.prefixString(220)
        }

        return ext.isEmpty ? "(No preview available)" : "(.\(ext) file)"
    }

    private func bestExcerpt(from contentText: String, searchTerms: [SearchQueryTerm]) -> String? {
        let compacted = compactWhitespace(contentText)
        guard !compacted.isEmpty else { return nil }

        let nsText = compacted as NSString
        let textLength = nsText.length
        guard textLength > 0 else { return nil }

        let preferredTerms = searchTerms
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for term in preferredTerms {
            let foundRange = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            guard foundRange.location != NSNotFound else { continue }

            let contextBefore = 56
            let contextAfter = 136
            let start = max(0, foundRange.location - contextBefore)
            let end = min(textLength, NSMaxRange(foundRange) + contextAfter)
            let excerptRange = NSRange(location: start, length: max(0, end - start))
            var excerpt = nsText.substring(with: excerptRange)
            if start > 0 {
                excerpt = "… " + excerpt
            }
            if end < textLength {
                excerpt += " …"
            }
            return compactWhitespace(excerpt).prefixString(220)
        }

        return compacted.prefixString(220)
    }

    private func facetKeySuggestions(prefix: String, replacementRange: NSRange, supportedFacetKeys: [String]) -> [NoteSearchSuggestion] {
        let normalizedPrefix = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = supportedFacetKeys.filter {
            normalizedPrefix.isEmpty || $0.hasPrefix(normalizedPrefix)
        }

        return Array(keys.prefix(Self.maxSuggestionCount)).map { key in
            NoteSearchSuggestion(
                kind: .facetKey,
                label: key + ":",
                insertText: key + ":",
                detail: "Facet filter",
                replacementRange: replacementRange
            )
        }
    }

    private func facetValueSuggestions(key: String, prefix: String, replacementRange: NSRange) throws -> [NoteSearchSuggestion] {
        let normalizedKey = key.lowercased()
        let normalizedPrefix = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedKey == "is" {
            return ["archived", "text"]
                .filter { normalizedPrefix.isEmpty || $0.hasPrefix(normalizedPrefix) }
                .map {
                    NoteSearchSuggestion(
                        kind: .facetValue,
                        label: $0,
                        insertText: $0 + " ",
                        detail: "Built-in facet",
                        replacementRange: replacementRange
                    )
                }
        }

        let column: String
        switch normalizedKey {
        case "class":
            column = "class"
        case "workspace":
            column = "workspace"
        case "entity":
            column = "entity"
        case "asset":
            column = "asset_bucket"
        case "library":
            column = "library_bucket"
        case "root":
            column = "top_root"
        case "ext":
            column = "ext"
        default:
            return []
        }

        let sql = """
        SELECT DISTINCT \(column)
        FROM files
        WHERE \(column) IS NOT NULL
          AND TRIM(\(column)) <> ''
          AND LOWER(\(column)) LIKE ?
        ORDER BY \(column) COLLATE NOCASE ASC
        LIMIT ?
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let likeValue = normalizedPrefix.isEmpty ? "%" : normalizedPrefix + "%"
        try bind(values: [.text(likeValue), .int(Int64(Self.maxSuggestionCount))], to: statement)

        var suggestions: [NoteSearchSuggestion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let value = columnString(statement, index: 0)
            guard !value.isEmpty else { continue }
            suggestions.append(
                NoteSearchSuggestion(
                    kind: .facetValue,
                    label: value,
                    insertText: value + " ",
                    detail: "Indexed value",
                    replacementRange: replacementRange
                )
            )
        }

        return suggestions
    }

    private func fileSuggestions(prefix: String, replacementRange: NSRange) throws -> [NoteSearchSuggestion] {
        let normalizedPrefix = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return [] }

        let sql = """
        SELECT rel_path, stem, class, ext, mtime_ns
        FROM files
        WHERE LOWER(name) LIKE ?
           OR LOWER(rel_path) LIKE ?
           OR LOWER(COALESCE(title, '')) LIKE ?
        ORDER BY
            CASE
                WHEN LOWER(name) LIKE ? THEN 0
                WHEN LOWER(rel_path) LIKE ? THEN 1
                ELSE 2
            END,
            mtime_ns DESC
        LIMIT ?
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let containsLike = "%" + normalizedPrefix + "%"
        let prefixLike = normalizedPrefix + "%"
        try bind(
            values: [
                .text(containsLike), .text(containsLike), .text(containsLike),
                .text(prefixLike), .text(prefixLike), .int(Int64(Self.maxSuggestionCount))
            ],
            to: statement
        )

        var suggestions: [NoteSearchSuggestion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let relPath = columnString(statement, index: 0)
            let stem = columnString(statement, index: 1)
            let fileClass = columnString(statement, index: 2)
            let ext = columnString(statement, index: 3)
            let displayDetail = [
                stem.isEmpty ? nil : stem,
                fileClass.isEmpty ? nil : fileClass,
                ext.isEmpty ? nil : ".\(ext)"
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            let insertText: String
            if relPath.contains(where: { $0.isWhitespace }) {
                insertText = "\"\(relPath)\" "
            } else {
                insertText = relPath + " "
            }

            suggestions.append(
                NoteSearchSuggestion(
                    kind: .file,
                    label: relPath,
                    insertText: insertText,
                    detail: displayDetail.isEmpty ? nil : displayDetail,
                    replacementRange: replacementRange
                )
            )
        }

        return suggestions
    }

    private func buildRecord(for document: NoteSearchDocument, facetMap: NVModernSearchFacetMap) throws -> IndexedFileRecord {
        let relPath = document.relativePath
        let url = document.fileURL
        let ext = url.pathExtension.lowercased()
        let topRoot = facetMap.mappedValue(for: "root", relativePath: relPath)
            ?? relPath.split(separator: "/").first.map(String.init)
            ?? ""
        let classValue = facetMap.mappedValue(for: "class", relativePath: relPath)
            ?? fallbackClass(relativePath: relPath)
        let archiveMappedValue = facetMap.mappedValue(for: "is", relativePath: relPath)?.lowercased()
        let isArchived = archiveMappedValue == "archived"
            || classValue.localizedCaseInsensitiveCompare("archive") == .orderedSame
            || topRoot.lowercased().contains("archive")

        let extracted = extractText(from: url, isTextFile: document.isTextFile, pathExtension: ext)
        didExtractDocumentForTesting?(relPath)
        let title = extracted.title?.prefixString(200)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let statFileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let fileSize = document.fileSize ?? statFileSize ?? 0
        let mtimeNS: Int64
        if let modifiedDate = document.modifiedDate {
            mtimeNS = Int64(modifiedDate.timeIntervalSince1970 * 1_000_000_000)
        } else {
            let modifiedDate = attributes?[.modificationDate] as? Date
            mtimeNS = Int64((modifiedDate ?? .distantPast).timeIntervalSince1970 * 1_000_000_000)
        }

        return IndexedFileRecord(
            relPath: relPath,
            dirPath: URL(fileURLWithPath: relPath).deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/.")),
            name: url.lastPathComponent,
            stem: url.deletingPathExtension().lastPathComponent,
            ext: ext,
            topRoot: topRoot,
            fileClass: classValue,
            workspace: facetMap.mappedValue(for: "workspace", relativePath: relPath),
            entity: facetMap.mappedValue(for: "entity", relativePath: relPath),
            assetBucket: facetMap.mappedValue(for: "asset", relativePath: relPath),
            libraryBucket: facetMap.mappedValue(for: "library", relativePath: relPath),
            sizeBytes: max(0, fileSize),
            mtimeNS: mtimeNS,
            // Reuses the hash of the bytes the extractor already read; only
            // extractors that shell out fall back to a second full read.
            sha256: extracted.contentHash ?? sha256(for: url),
            isArchived: isArchived,
            isText: extracted.isText,
            title: title,
            pathTokens: tokenize(relPath),
            nameTokens: tokenize(url.lastPathComponent),
            contentText: extracted.text,
            contentSource: extracted.source
        )
    }

    private func fallbackClass(relativePath: String) -> String {
        let topRoot = relativePath.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        if topRoot.contains("archive") {
            return "archive"
        }
        return "unknown"
    }

    private func upsert(record: IndexedFileRecord) throws {
        if let existingID = try fetchRowID(relativePath: record.relPath) {
            try deleteFTSRow(rowID: existingID)
            let sql = """
            UPDATE files SET
                dir_path = ?,
                name = ?,
                stem = ?,
                ext = ?,
                top_root = ?,
                class = ?,
                workspace = ?,
                entity = ?,
                asset_bucket = ?,
                library_bucket = ?,
                size_bytes = ?,
                mtime_ns = ?,
                sha256 = ?,
                is_archived = ?,
                is_text = ?,
                title = ?,
                path_tokens = ?,
                name_tokens = ?,
                content_text = ?,
                content_source = ?,
                indexed_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(record: record, rowID: existingID, to: statement, includeRelativePath: false)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(message: "Could not update search index row")
            }
            try insertFTSRow(rowID: existingID, record: record)
            return
        }

        let sql = """
        INSERT INTO files (
            rel_path, dir_path, name, stem, ext, top_root, class, workspace, entity, asset_bucket,
            library_bucket, size_bytes, mtime_ns, sha256, is_archived, is_text, title, path_tokens,
            name_tokens, content_text, content_source
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(record: record, rowID: nil, to: statement, includeRelativePath: true)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not insert search index row")
        }
        let rowID = sqlite3_last_insert_rowid(database)
        try insertFTSRow(rowID: rowID, record: record)
    }

    private func bind(record: IndexedFileRecord, rowID: Int64?, to statement: OpaquePointer?, includeRelativePath: Bool) throws {
        var values: [SQLiteBindValue] = []
        if includeRelativePath {
            values.append(.text(record.relPath))
        }
        values.append(contentsOf: [
            .text(record.dirPath),
            .text(record.name),
            .text(record.stem),
            .text(record.ext),
            .text(record.topRoot),
            .text(record.fileClass),
            .text(record.workspace),
            .text(record.entity),
            .text(record.assetBucket),
            .text(record.libraryBucket),
            .int(record.sizeBytes),
            .int(record.mtimeNS),
            .text(record.sha256),
            .int(record.isArchived ? 1 : 0),
            .int(record.isText ? 1 : 0),
            .text(record.title),
            .text(record.pathTokens),
            .text(record.nameTokens),
            .text(record.contentText),
            .text(record.contentSource)
        ])
        if let rowID {
            values.append(.int(rowID))
        }
        try bind(values: values, to: statement)
    }

    private func deleteRecord(relativePath: String) throws {
        guard let existingID = try fetchRowID(relativePath: relativePath) else { return }
        try deleteFTSRow(rowID: existingID)
        let statement = try prepare("DELETE FROM files WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(values: [.int(existingID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not delete search index row")
        }
    }

    private func deleteFTSRow(rowID: Int64) throws {
        let statement = try prepare("DELETE FROM file_fts WHERE rowid = ?")
        defer { sqlite3_finalize(statement) }
        try bind(values: [.int(rowID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not delete FTS row")
        }
    }

    private func insertFTSRow(rowID: Int64, record: IndexedFileRecord) throws {
        let sql = "INSERT INTO file_fts(rowid, name, rel_path, path_tokens, name_tokens, content_text) VALUES (?, ?, ?, ?, ?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(
            values: [
                .int(rowID),
                .text(record.name),
                .text(record.relPath),
                .text(record.pathTokens),
                .text(record.nameTokens),
                .text(record.contentText)
            ],
            to: statement
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not insert FTS row")
        }
    }

    private func fetchAllIndexedPaths() throws -> Set<String> {
        let statement = try prepare("SELECT rel_path FROM files")
        defer { sqlite3_finalize(statement) }
        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            paths.insert(columnString(statement, index: 0))
        }
        return paths
    }

    private func fetchAllIndexedMetadataByPath() throws -> [String: IndexedFileMetadata] {
        let statement = try prepare("SELECT rel_path, size_bytes, mtime_ns FROM files")
        defer { sqlite3_finalize(statement) }

        var metadataByPath: [String: IndexedFileMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let relativePath = columnString(statement, index: 0)
            metadataByPath[relativePath] = IndexedFileMetadata(
                sizeBytes: columnInt64(statement, index: 1),
                mtimeNS: columnInt64(statement, index: 2)
            )
        }
        return metadataByPath
    }

    private func fetchRowID(relativePath: String) throws -> Int64? {
        let statement = try prepare("SELECT id FROM files WHERE rel_path = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(relativePath)], to: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return columnInt64(statement, index: 0)
        }
        return nil
    }

    private func buildWhereClauses(_ groupedFacets: [String: [SearchFacetFilter]]) -> ([String], [SQLiteBindValue]) {
        var clauses: [String] = []
        var bindValues: [SQLiteBindValue] = []

        let columnByFacetKey: [String: String] = [
            "class": "LOWER(f.class)",
            "ext": "LOWER(f.ext)",
            "workspace": "LOWER(f.workspace)",
            "entity": "LOWER(f.entity)",
            "asset": "LOWER(f.asset_bucket)",
            "library": "LOWER(f.library_bucket)",
            "root": "LOWER(f.top_root)"
        ]

        for key in groupedFacets.keys.sorted() {
            let values = groupedFacets[key, default: []].map { $0.value.lowercased() }.filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }

            if key == "is" {
                for value in values {
                    switch value {
                    case "archived":
                        clauses.append("f.is_archived = 1")
                    case "text":
                        clauses.append("f.is_text = 1")
                    default:
                        break
                    }
                }
                continue
            }

            guard let column = columnByFacetKey[key] else { continue }
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            clauses.append("\(column) IN (\(placeholders))")
            bindValues.append(contentsOf: values.map(SQLiteBindValue.text))
        }

        return (clauses, bindValues)
    }

    private func quotedExactFallbackResults(
        for parsedQuery: NoteSearchParsedQuery,
        whereClauses: [String],
        bindValues: [SQLiteBindValue],
        limit: Int
    ) throws -> [NoteSearchResult] {
        guard parsedQuery.searchTerms.count == 1,
              let searchTerm = parsedQuery.searchTerms.first,
              searchTerm.isQuotedPhrase || looksLikeExactFilenameQuery(searchTerm.text) else {
            return []
        }

        let normalizedTerm = searchTerm.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTerm.isEmpty else { return [] }

        let exactLike = normalizedTerm
        let prefixLike = normalizedTerm + "%"
        let containsLike = "%" + normalizedTerm + "%"

        let sql = """
        SELECT
            f.rel_path,
            f.stem,
            f.ext,
            f.class,
            f.title,
            f.content_text,
            f.mtime_ns
        FROM files f
        WHERE (
            LOWER(f.stem) = ?
            OR LOWER(f.name) = ?
            OR LOWER(f.name) LIKE ?
            OR LOWER(f.rel_path) LIKE ?
            OR LOWER(COALESCE(f.title, '')) LIKE ?
        )
          \(whereClauses.isEmpty ? "" : "AND " + whereClauses.joined(separator: " AND "))
        ORDER BY
            CASE
                WHEN LOWER(f.stem) = ? THEN 0
                WHEN LOWER(f.name) = ? THEN 1
                WHEN LOWER(f.name) LIKE ? THEN 2
                ELSE 3
            END,
            f.mtime_ns DESC
        LIMIT ?
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(
            values: [
                .text(exactLike),
                .text(exactLike),
                .text(prefixLike),
                .text(containsLike),
                .text(containsLike)
            ] + bindValues + [
                .text(exactLike),
                .text(exactLike),
                .text(prefixLike),
                .int(Int64(limit))
            ],
            to: statement
        )
        return try collectResults(from: statement, parsedQuery: parsedQuery, includeFTSRank: false)
    }

    private func pathLikeFallbackResults(
        for parsedQuery: NoteSearchParsedQuery,
        whereClauses: [String],
        bindValues: [SQLiteBindValue],
        limit: Int
    ) throws -> [NoteSearchResult] {
        guard parsedQuery.searchTerms.count == 1,
              let fallbackTerm = parsedQuery.searchTerms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              looksLikePathLikeQuery(fallbackTerm) else {
            return []
        }

        let normalizedTerm = fallbackTerm.lowercased()
        let exactLike = normalizedTerm
        let containsLike = "%" + normalizedTerm + "%"
        let prefixLike = normalizedTerm + "%"

        let sql = """
        SELECT
            f.rel_path,
            f.stem,
            f.ext,
            f.class,
            f.title,
            f.content_text,
            f.mtime_ns
        FROM files f
        WHERE (
            LOWER(f.rel_path) = ?
            OR LOWER(f.rel_path) LIKE ?
            OR LOWER(f.rel_path) LIKE ?
            OR LOWER(f.name) = ?
            OR LOWER(f.name) LIKE ?
            OR LOWER(f.stem) = ?
        )
          \(whereClauses.isEmpty ? "" : "AND " + whereClauses.joined(separator: " AND "))
        ORDER BY
            CASE
                WHEN LOWER(f.rel_path) = ? THEN 0
                WHEN LOWER(f.name) = ? THEN 1
                WHEN LOWER(f.rel_path) LIKE ? THEN 2
                WHEN LOWER(f.name) LIKE ? THEN 3
                ELSE 4
            END,
            f.mtime_ns DESC
        LIMIT ?
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(
            values: [
                .text(exactLike),
                .text(containsLike),
                .text(prefixLike),
                .text(exactLike),
                .text(prefixLike),
                .text(exactLike)
            ] + bindValues + [
                .text(exactLike),
                .text(exactLike),
                .text(prefixLike),
                .text(prefixLike),
                .int(Int64(limit))
            ],
            to: statement
        )
        return try collectResults(from: statement, parsedQuery: parsedQuery, includeFTSRank: false)
    }

    private func makeFTSQuery(from searchTerms: [SearchQueryTerm]) -> String {
        var groups: [String] = []
        var pendingPlainTerms: [SearchQueryTerm] = []

        func flushPendingPlainTerms() {
            guard !pendingPlainTerms.isEmpty else { return }
            if let group = makePlainTermFTSGroup(from: pendingPlainTerms) {
                groups.append(group)
            }
            pendingPlainTerms.removeAll()
        }

        for searchTerm in searchTerms {
            if searchTerm.isQuotedPhrase {
                flushPendingPlainTerms()
                if let phraseQuery = makeQuotedPhraseFTSPiece(for: searchTerm) {
                    groups.append(phraseQuery)
                }
                continue
            }

            pendingPlainTerms.append(searchTerm)
        }

        flushPendingPlainTerms()
        return groups.joined(separator: " AND ")
    }

    private func makeQuotedPhraseFTSPiece(for searchTerm: SearchQueryTerm) -> String? {
        let trimmed = searchTerm.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedPhrase = compactWhitespace(
            trimmed.replacingOccurrences(of: "\"", with: " ")
        )
        guard !normalizedPhrase.isEmpty else { return nil }
        return "\"\(escapeFTSPhrase(normalizedPhrase))\""
    }

    private func makePlainTermFTSGroup(from plainTerms: [SearchQueryTerm]) -> String? {
        let basePieces = plainTerms.compactMap { makePlainFTSPiece(for: $0) }
        guard !basePieces.isEmpty else { return nil }

        let baseQuery = basePieces.joined(separator: " AND ")
        guard plainTerms.count >= 2 else {
            return baseQuery
        }

        let joinedAlternatives = joinedPhraseAlternatives(for: plainTerms)
            .map { "\"\(escapeFTSPhrase($0))\"" }
        guard !joinedAlternatives.isEmpty else {
            return baseQuery
        }

        return "(\(baseQuery) OR \(joinedAlternatives.joined(separator: " OR ")))"
    }

    private func makePlainFTSPiece(for searchTerm: SearchQueryTerm) -> String? {
        let trimmed = searchTerm.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed.replacingOccurrences(
            of: "[^A-Za-z0-9._/-]+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }

        if looksLikePathLikeQuery(sanitized) {
            return "\"\(escapeFTSPhrase(sanitized))\""
        }

        let separatorParts = normalizedSeparatedSearchTokens(from: sanitized)
        guard separatorParts.count >= 2 else {
            return sanitized + "*"
        }

        var alternatives = uniqueFTSAlternatives([
            sanitized + "*",
            "(" + separatorParts.map { $0 + "*" }.joined(separator: " AND ") + ")"
        ])
        alternatives.append(contentsOf: uniqueFTSAlternatives(joinedPhraseAlternatives(for: separatorParts).map { "\"\(escapeFTSPhrase($0))\"" }))
        return "(\(uniqueFTSAlternatives(alternatives).joined(separator: " OR ")))"
    }

    private func joinedPhraseAlternatives(for plainTerms: [SearchQueryTerm]) -> [String] {
        let joinableTerms = plainTerms.compactMap { normalizedJoinableSearchToken($0.text) }
        guard joinableTerms.count == plainTerms.count, joinableTerms.count >= 2 else {
            return []
        }

        return joinedPhraseAlternatives(for: joinableTerms)
    }

    private func joinedPhraseAlternatives(for tokens: [String]) -> [String] {
        guard tokens.count >= 2 else { return [] }
        let separators = ["-", "_", "/", "."]
        return separators.map { tokens.joined(separator: $0) }
    }

    private func normalizedSeparatedSearchTokens(from text: String) -> [String] {
        let normalized = compactWhitespace(
            text.lowercased().replacingOccurrences(
                of: "[-_]+",
                with: " ",
                options: .regularExpression
            )
        )
        return normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func uniqueFTSAlternatives(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private func normalizedJoinableSearchToken(_ text: String) -> String? {
        let normalized = compactWhitespace(
            text.lowercased().replacingOccurrences(
                of: "[^a-z0-9]+",
                with: " ",
                options: .regularExpression
            )
        )
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count == 1, let token = parts.first, !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Extracts indexable text. `contentHash` is returned whenever the file's
    /// bytes were read here, so `buildRecord` does not have to read the file a
    /// second time just to hash it.
    private func extractText(
        from url: URL,
        isTextFile: Bool,
        pathExtension: String
    ) -> (text: String, source: String, isText: Bool, title: String?, contentHash: String?) {
        if isTextFile || Self.textExtensions.contains(pathExtension) {
            guard let data = try? Data(contentsOf: url) else {
                return ("", "direct", true, nil, nil)
            }
            let hash = Self.hexHash(of: data)
            if let text = decodeString(from: data), !text.isEmpty {
                let clipped = String(text.prefix(Self.maxExtractedCharacters))
                return (clipped, "direct", true, firstHeadingOrLine(in: clipped), hash)
            }
            return ("", "direct", true, nil, hash)
        }

        if pathExtension == "pdf" {
            if let text = PDFDocument(url: url)?.string, !text.isEmpty {
                let clipped = String(text.prefix(Self.maxExtractedCharacters))
                return (clipped, "pdfkit", true, firstHeadingOrLine(in: clipped), nil)
            }
            if let text = runTextExtractionCommand("/usr/bin/mdls", arguments: ["-name", "kMDItemTextContent", "-raw", url.path]), !text.isEmpty {
                let clipped = String(text.prefix(Self.maxExtractedCharacters))
                return (clipped, "mdls", true, firstHeadingOrLine(in: clipped), nil)
            }
            return ("", "none", false, nil, nil)
        }

        if Self.documentExtensions.contains(pathExtension) {
            if let text = runTextExtractionCommand("/usr/bin/textutil", arguments: ["-convert", "txt", "-stdout", url.path]), !text.isEmpty {
                let clipped = String(text.prefix(Self.maxExtractedCharacters))
                return (clipped, "textutil", true, firstHeadingOrLine(in: clipped), nil)
            }
            if let text = runTextExtractionCommand("/usr/bin/mdls", arguments: ["-name", "kMDItemTextContent", "-raw", url.path]), !text.isEmpty {
                let clipped = String(text.prefix(Self.maxExtractedCharacters))
                return (clipped, "mdls", true, firstHeadingOrLine(in: clipped), nil)
            }
        }

        return ("", "none", false, nil, nil)
    }

    private func decodeString(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .unicode) { return text }
        return String(data: data, encoding: .ascii)
    }

    private static func hexHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func runTextExtractionCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard output != "(null)", !output.isEmpty else { return nil }
        return output
    }

    private func firstHeadingOrLine(in text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                return heading.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
        return nil
    }

    private func tokenize(_ text: String) -> String {
        let lowercased = text.lowercased()
        var tokens: [String] = []
        var seen = Set<String>()

        func appendToken(_ token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            tokens.append(trimmed)
        }

        appendToken(lowercased)

        let pathSegments = lowercased.split(separator: "/").map(String.init)
        for segment in pathSegments {
            appendToken(segment)

            let normalizedSegment = segment.replacingOccurrences(
                of: "[^a-z0-9]+",
                with: " ",
                options: .regularExpression
            )
            for part in normalizedSegment.split(separator: " ") {
                appendToken(String(part))
            }

            let basename = URL(fileURLWithPath: segment).deletingPathExtension().lastPathComponent
            if !basename.isEmpty {
                appendToken(basename)
                let normalizedBasename = basename.replacingOccurrences(
                    of: "[^a-z0-9]+",
                    with: " ",
                    options: .regularExpression
                )
                for part in normalizedBasename.split(separator: " ") {
                    appendToken(String(part))
                }
            }
        }

        return tokens.joined(separator: " ")
    }

    private func sha256(for url: URL) -> String {
        guard let stream = InputStream(url: url) else { return "" }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1_048_576
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 { break }
            if readCount == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: readCount))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func containsWord(_ token: String, in text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0 == token })
    }

    private func normalizeSearchComparable(_ text: String) -> String {
        compactWhitespace(
            text.lowercased().replacingOccurrences(
                of: "[^a-z0-9]+",
                with: " ",
                options: .regularExpression
            )
        )
    }

    private func looksLikePathLikeQuery(_ text: String) -> Bool {
        text.contains("/") || text.contains(".")
    }

    private func looksLikeExactFilenameQuery(_ text: String) -> Bool {
        text.contains("-") || text.contains("_") || text.contains(".")
    }

    private func escapeFTSPhrase(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: " ")
    }

    private func compactWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkForInterruption(_ interruptionCheck: InterruptionCheck?) throws {
        do {
            try interruptionCheck?()
        } catch is CancellationError {
            throw IndexingInterruption.cancelled
        }
    }

    private func beginTransaction() throws {
        try exec("BEGIN IMMEDIATE TRANSACTION")
    }

    private func commitTransaction() throws {
        try exec("COMMIT TRANSACTION")
    }

    private func rollbackTransaction() throws {
        try exec("ROLLBACK TRANSACTION")
    }

    /// Marks the index complete for `facetMap`, unless a rebuild for that same
    /// facet map is still working through its batches — an incremental pass
    /// must never flag a half-built index as usable.
    private func markFacetMapCompleteIfNoRebuildPending(facetMap: NVModernSearchFacetMap) throws {
        let fingerprint = Self.facetMapFingerprint(for: facetMap)
        if let pendingFingerprint = try metaValue(Self.rebuildCursorFingerprintKey),
           pendingFingerprint == fingerprint {
            return
        }
        try setMeta(key: "facet_map_fingerprint", value: fingerprint)
    }

    private func metaValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM index_meta WHERE key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(key)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnString(statement, index: 0)
    }

    private func fetchStoredContentHash(relativePath: String) throws -> String? {
        let statement = try prepare("SELECT sha256 FROM files WHERE rel_path = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(relativePath)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnString(statement, index: 0)
    }

    private func setMeta(key: String, value: String) throws {
        let sql = "INSERT INTO index_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values: [.text(key), .text(value)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(message: "Could not update search metadata")
        }
    }

    private func exec(_ sql: String) throws {
        guard let database else { return }
        var errorPointer: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(database, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorPointer)
            throw databaseError(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw databaseError(message: "Search index is not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Could not prepare SQLite statement")
        }
        return statement
    }

    private enum SQLiteBindValue {
        case text(String?)
        case int(Int64)
    }

    private func bind(values: [SQLiteBindValue], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let sqliteIndex = Int32(index + 1)
            switch value {
            case .text(let stringValue):
                if let stringValue {
                    guard sqlite3_bind_text(statement, sqliteIndex, stringValue, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                        throw databaseError(message: "Could not bind SQLite text parameter")
                    }
                } else {
                    guard sqlite3_bind_null(statement, sqliteIndex) == SQLITE_OK else {
                        throw databaseError(message: "Could not bind SQLite null parameter")
                    }
                }
            case .int(let intValue):
                guard sqlite3_bind_int64(statement, sqliteIndex, intValue) == SQLITE_OK else {
                    throw databaseError(message: "Could not bind SQLite integer parameter")
                }
            }
        }
    }

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnString(statement, index: index)
    }

    private func columnInt64(_ statement: OpaquePointer?, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private func columnDouble(_ statement: OpaquePointer?, index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private func databaseError(message: String, database: OpaquePointer? = nil) -> NSError {
        let db = database ?? self.database
        let sqliteMessage = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? message
        return NSError(domain: "NVModern.SearchIndex", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: sqliteMessage])
    }

    private static func indexMetadata(rootURL: URL) -> IndexMetadata? {
        guard let targetURL = try? databaseURL(for: rootURL),
              FileManager.default.fileExists(atPath: targetURL.path) else {
            return nil
        }

        if let metadata = readIndexMetadata(at: targetURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) {
            return metadata
        }

        // A WAL database whose `-shm` file is gone cannot be read through a
        // read-only connection, and treating that as "no index" would make
        // every launch rebuild from scratch. Retry read/write — never CREATE,
        // so a missing database still reports no index.
        return readIndexMetadata(at: targetURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
    }

    /// Reads index metadata over a short-lived connection. Returns nil when the
    /// database could not be read at all, as opposed to being readable with
    /// some keys missing.
    private static func readIndexMetadata(at targetURL: URL, flags: Int32) -> IndexMetadata? {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close(db)
            }
        }

        guard sqlite3_open_v2(targetURL.path, &db, flags, nil) == SQLITE_OK,
              let db else {
            #if DEBUG
            print("[NVModern][SearchIndex] metadata open failed flags=\(flags) db=\(targetURL.path)")
            #endif
            return nil
        }
        sqlite3_exec(db, "PRAGMA busy_timeout=2000", nil, nil, nil)

        var readFailed = false
        func metaValue(_ key: String) -> String? {
            let sql = "SELECT value FROM index_meta WHERE key = ? LIMIT 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                readFailed = true
                #if DEBUG
                print("[NVModern][SearchIndex] metadata prepare failed key=\(key) error=\(String(cString: sqlite3_errmsg(db)))")
                #endif
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                readFailed = true
                return nil
            }
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                return String(cString: text)
            }
            if stepResult != SQLITE_ROW && stepResult != SQLITE_DONE {
                readFailed = true
                #if DEBUG
                print("[NVModern][SearchIndex] metadata read failed key=\(key) error=\(String(cString: sqlite3_errmsg(db)))")
                #endif
            }
            return nil
        }

        let metadata = IndexMetadata(
            schemaVersion: metaValue("schema_version"),
            rootPath: metaValue("root_path"),
            facetMapFingerprint: metaValue("facet_map_fingerprint")
        )
        return readFailed ? nil : metadata
    }

    /// Stable identity of a facet map, used to decide whether an in-flight
    /// rebuild can be coalesced with a newer request or has to be restarted.
    static func facetFingerprint(for facetMap: NVModernSearchFacetMap) -> String {
        facetMapFingerprint(for: facetMap)
    }

    private static func facetMapFingerprint(for facetMap: NVModernSearchFacetMap) -> String {
        let serialized = facetMap.mappingsByFacetKey
            .keys
            .sorted()
            .flatMap { facetKey -> [String] in
                let mappings = facetMap.mappingsByFacetKey[facetKey, default: [:]]
                return mappings.keys.sorted().map { prefix in
                    let value = mappings[prefix, default: ""]
                    return [facetKey, prefix, value]
                        .map(Self.escapeFacetMetadataComponent)
                        .joined(separator: "\u{001F}")
                }
            }
            .joined(separator: "\u{001E}")

        return SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func escapeFacetMetadataComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\u{001E}", with: "\\u001E")
            .replacingOccurrences(of: "\u{001F}", with: "\\u001F")
    }

    /// Cache directory holding the index for `rootURL`. Exposed so tests can
    /// clean up after themselves.
    static func indexDirectoryURL(for rootURL: URL) -> URL {
        let standardizedPath = rootURL.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(standardizedPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("nvmodern", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
    }

    private static func databaseURL(for rootURL: URL) throws -> URL {
        indexDirectoryURL(for: rootURL).appendingPathComponent("search-v2.sqlite", isDirectory: false)
    }
}

private extension String {
    func prefixString(_ count: Int) -> String {
        String(prefix(count))
    }
}
