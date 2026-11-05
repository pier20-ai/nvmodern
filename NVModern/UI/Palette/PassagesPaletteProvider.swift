import Foundation

/// Full-text passages through `NotesWorkspaceModel.search(query:)`, which in
/// turn drives `NoteSearchEngine`.
@MainActor
class PassagesPaletteProvider: PaletteSourceProvider {
    static let resultLimit = 15

    /// Whether the last search answered while the index was still being
    /// rebuilt, so the empty state can say so instead of "no matches".
    private(set) var lastResponseWasRebuilding = false

    /// Rebuild progress reported with the last search, when the index was
    /// still building, so the empty state can name how far along it is.
    private(set) var lastRebuildIndexedCount: Int?
    private(set) var lastRebuildTotalCount: Int?

    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .passages = source, !query.text.isEmpty else { return [] }

        let response = await context.notesModel.search(query: query.text)
        guard !Task.isCancelled else { return [] }
        lastResponseWasRebuilding = response.indexStatus.phase == .rebuilding
        lastRebuildIndexedCount = response.indexStatus.indexedCount
        lastRebuildTotalCount = response.indexStatus.totalCount
        paletteDebugLog("passages.response query=\(query.text.debugDescription) results=\(response.results.count) status=\(response.indexStatus.phase.rawValue) indexed=\(response.indexStatus.indexedCount.map(String.init) ?? "-")/\(response.indexStatus.totalCount.map(String.init) ?? "-")")

        let term = query.text
        let items = response.results.prefix(Self.resultLimit).map { result in
            let snippet = Self.cleanedSnippet(result.snippet)
            return PaletteItem(
                id: "content:\(result.relativePath)",
                title: result.title,
                subtitle: result.displayPath,
                snippet: snippet,
                iconSystemName: NotesPaletteProvider.icon(forRelativePath: result.relativePath),
                // The passage's default verb: open the note, then hand the
                // term to the in-document find bar.
                activation: .openNote(relativePath: result.relativePath, findTerm: term),
                target: .passage(
                    relativePath: result.relativePath,
                    snippet: snippet,
                    term: term
                )
            )
        }
        return [PaletteSection(id: "passages", title: "Passages", items: Array(items))]
    }

    /// Strip SQLite FTS snippet markers (`[` / `]`) so the bold-highlight pass
    /// applies cleanly against the plain term.
    static func cleanedSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }
}
