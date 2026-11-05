import Foundation

struct PaletteNoteCandidate: Sendable {
    let name: String
    let relativePath: String
}

struct PaletteRankedNote: Sendable {
    let relativePath: String
    let name: String
}

/// Shared field-aware ranking over each note's path segments.
enum PaletteNoteRanker {
    static func rank(
        query: String,
        candidates: [PaletteNoteCandidate],
        limit: Int
    ) -> [PaletteRankedNote] {
        let searchCandidates = candidates.map { candidate in
            PaletteSearchRanker.Candidate(
                id: candidate.relativePath,
                label: candidate.name,
                items: PaletteSearchRanker.pathItems(candidate.relativePath),
                properties: [
                    "extension": [(candidate.relativePath as NSString).pathExtension]
                        .filter { !$0.isEmpty }
                ]
            )
        }
        let candidatesByPath = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.relativePath, $0) }
        )
        return PaletteSearchRanker.rank(query: query, candidates: searchCandidates)
            .prefix(limit)
            .compactMap { ranked in
                guard let candidate = candidatesByPath[ranked.candidate.id] else { return nil }
                return PaletteRankedNote(relativePath: candidate.relativePath, name: candidate.name)
            }
    }
}

/// Notes, open tabs, and recently modified notes.
@MainActor
final class NotesPaletteProvider: PaletteSourceProvider {
    static let perSectionLimit = 5
    static let totalLimit = 15

    /// Grayscale file-type glyph. Titles hide the extension, so this is the
    /// only cue telling `notes.md` from `notes.org` or `report.pdf`.
    static func icon(forRelativePath relativePath: String) -> String {
        switch (relativePath as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "txt": return "doc.text"
        case "org": return "list.bullet.rectangle"
        case "pdf": return "doc.richtext"
        case "csv", "tsv": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg": return "photo"
        case "html", "htm": return "globe"
        case "epub": return "book.closed"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        default: return "doc"
        }
    }

    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        switch source {
        case .openTabs:
            return [PaletteSection(id: "open", title: "Open tabs", items: openTabItems(context: context))]
        case .recentNotes:
            return [PaletteSection(id: "recent", title: "Recent", items: recentItems(context: context))]
        case .notes:
            return await [PaletteSection(id: "notes", title: "Notes", items: rankedItems(query: query.text, context: context))]
        case .siblingNotes:
            return [PaletteSection(id: "siblings", title: "", items: siblingItems(query: query.text, context: context))]
        default:
            return []
        }
    }

    /// The tab's own document as the first row of an empty root, so `Cmd+K`
    /// twice lands in its verbs. Not a source of its own: root is the only
    /// frame that wants it, and only ever one of it.
    func currentDocumentItem(context: PaletteContext) -> PaletteItem? {
        guard let relativePath = context.currentDocumentRelativePath else { return nil }
        let name = context.currentDocumentTitle ?? (relativePath as NSString).lastPathComponent
        return PaletteItem(
            id: "current:\(relativePath)",
            title: name,
            subtitle: "current tab",
            iconSystemName: Self.icon(forRelativePath: relativePath),
            activation: .openNote(relativePath: relativePath),
            target: .workspaceNote(relativePath: relativePath)
        )
    }

    // MARK: Sources

    private func openTabItems(context: PaletteContext) -> [PaletteItem] {
        let notesByPath = notesByRelativePath(context: context)
        return context.openTabEntries.compactMap { entry -> PaletteItem? in
            guard let note = notesByPath[entry.relativePath] else { return nil }
            return openTabItem(entry: entry, name: note.name, subtitle: "open tab")
        }
        .prefix(Self.perSectionLimit)
        .map { $0 }
    }

    private func recentItems(context: PaletteContext) -> [PaletteItem] {
        let allNotes = collectAllNotes(context: context)
        let openTabPaths = Set(context.openTabEntries.map(\.relativePath))
        return allNotes
            .filter { $0.modifiedDate != nil && !openTabPaths.contains($0.relativePath) }
            .sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
            .prefix(Self.perSectionLimit)
            .map { note in
                noteItem(
                    relativePath: note.relativePath,
                    name: note.name,
                    subtitle: Self.folderLabel(for: note.relativePath)
                )
            }
    }

    private func rankedItems(query: String, context: PaletteContext) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }

        let allNotes = collectAllNotes(context: context)
        let candidates = allNotes.map { note in
            PaletteNoteCandidate(name: note.name, relativePath: note.relativePath)
        }
        let limit = Self.totalLimit
        let ranked = await Task.detached(priority: .userInitiated) {
            PaletteNoteRanker.rank(query: query, candidates: candidates, limit: limit)
        }.value
        guard !Task.isCancelled else { return [] }

        let notesByPath = Dictionary(allNotes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var firstOpenEntryByPath: [String: WorkspaceOpenDocumentPathEntry] = [:]
        for entry in context.openTabEntries where firstOpenEntryByPath[entry.relativePath] == nil {
            firstOpenEntryByPath[entry.relativePath] = entry
        }

        return ranked.compactMap { candidate -> PaletteItem? in
            guard let note = notesByPath[candidate.relativePath] else { return nil }
            let folder = Self.parentFolder(of: note.relativePath)
            if let entry = firstOpenEntryByPath[candidate.relativePath] {
                let subtitle = folder.isEmpty ? "open tab" : "\(folder) · open tab"
                return openTabItem(entry: entry, name: note.name, subtitle: subtitle)
            }
            return noteItem(
                relativePath: note.relativePath,
                name: note.name,
                subtitle: Self.folderLabel(for: note.relativePath)
            )
        }
    }

    private func siblingItems(query: String, context: PaletteContext) -> [PaletteItem] {
        let folder = context.currentNoteFolderRelativePath ?? context.currentFolderRelativePath ?? ""
        let notes = context.notesModel.childrenByFolder[folder, default: []]
            .filter { $0.kind == .note }
        let orderedNotes: [MillerItem]
        if query.isEmpty {
            orderedNotes = notes.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } else {
            let notesByPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
            let candidates = notes.map { note in
                PaletteSearchRanker.Candidate(
                    id: note.relativePath,
                    label: note.name,
                    items: PaletteSearchRanker.pathItems(note.relativePath),
                    properties: [
                        "extension": [(note.relativePath as NSString).pathExtension]
                            .filter { !$0.isEmpty }
                    ]
                )
            }
            orderedNotes = PaletteSearchRanker.rank(query: query, candidates: candidates)
                .compactMap { notesByPath[$0.candidate.id] }
        }
        return orderedNotes.prefix(Self.totalLimit).map { note in
            noteItem(
                relativePath: note.relativePath,
                name: note.name,
                subtitle: Self.folderLabel(for: note.relativePath)
            )
        }
    }

    // MARK: Items

    private func noteItem(relativePath: String, name: String, subtitle: String) -> PaletteItem {
        PaletteItem(
            id: "quick:\(relativePath)",
            title: name,
            subtitle: subtitle,
            iconSystemName: Self.icon(forRelativePath: relativePath),
            activation: .openNote(relativePath: relativePath),
            target: .workspaceNote(relativePath: relativePath)
        )
    }

    private func openTabItem(
        entry: WorkspaceOpenDocumentPathEntry,
        name: String,
        subtitle: String
    ) -> PaletteItem {
        PaletteItem(
            id: "open:\(entry.tabID)",
            title: name,
            subtitle: subtitle,
            iconSystemName: Self.icon(forRelativePath: entry.relativePath),
            activation: .focusTab(tabID: entry.tabID),
            target: .openTab(tabID: entry.tabID, relativePath: entry.relativePath)
        )
    }

    // MARK: Helpers

    private func notesByRelativePath(context: PaletteContext) -> [String: MillerItem] {
        Dictionary(
            collectAllNotes(context: context).map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Flattens `childrenByFolder` into one list of note items, de-duplicating
    /// by relative path in case a file appears in more than one children list.
    private func collectAllNotes(context: PaletteContext) -> [MillerItem] {
        var seen = Set<String>()
        var notes: [MillerItem] = []
        for (_, children) in context.notesModel.childrenByFolder {
            for item in children where item.kind == .note {
                if seen.insert(item.relativePath).inserted {
                    notes.append(item)
                }
            }
        }
        return notes
    }

    static func parentFolder(of relativePath: String) -> String {
        if let slashIndex = relativePath.lastIndex(of: "/") {
            return String(relativePath[..<slashIndex])
        }
        return ""
    }

    /// The only meta a note row carries: where it lives.
    static func folderLabel(for relativePath: String) -> String {
        let folder = parentFolder(of: relativePath)
        return folder.isEmpty ? "Workspace" : folder
    }
}
