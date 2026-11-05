import Foundation

/// Uses the editor's live outline rather than reading a potentially older file.
@MainActor
struct OutlinePaletteProvider: PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard source == .outline else { return [] }
        let entries = entries(for: context.outlineItems)
        let text = query.text
        let ordered: [Entry]
        if text.isEmpty {
            ordered = entries
        } else {
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0) })
            ordered = PaletteSearchRanker.rank(
                query: text,
                candidates: entries.enumerated().map { index, entry in
                    PaletteSearchRanker.Candidate(
                        id: entry.item.id,
                        label: entry.item.title,
                        items: entry.parents + [entry.item.title],
                        fallbackRank: index
                    )
                }
            ).compactMap { byID[$0.candidate.id] }
        }
        return [PaletteSection(id: "outline", title: "", items: ordered.map { entry in
            let line: String?
            if case .text(_, _, let number) = entry.item.destination {
                line = String(number)
            } else {
                line = nil
            }
            return PaletteItem(
                id: entry.item.id,
                title: entry.item.title,
                subtitle: line,
                snippet: text.isEmpty || entry.parents.isEmpty ? nil : entry.parents.joined(separator: " › "),
                activation: .jumpToOutlineItem(id: entry.item.id),
                indentation: text.isEmpty ? entry.parents.count : 0
            )
        })]
    }

    private struct Entry {
        let item: DocumentOutlineItem
        let parents: [String]
    }

    private func entries(for items: [DocumentOutlineItem]) -> [Entry] {
        var ancestors: [DocumentOutlineItem] = []
        return items.map { item in
            while let parent = ancestors.last, parent.level >= item.level {
                ancestors.removeLast()
            }
            let entry = Entry(item: item, parents: ancestors.map(\.title))
            ancestors.append(item)
            return entry
        }
    }
}
