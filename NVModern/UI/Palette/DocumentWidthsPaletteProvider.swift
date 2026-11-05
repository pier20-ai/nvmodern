import Foundation

@MainActor
final class DocumentWidthsPaletteProvider: PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .documentWidths = source, let pending = frame.pendingCommand else { return [] }
        let widths = DocumentInspectorWidth.allCases
        let candidates = widths.enumerated().map { index, width in
            PaletteSearchRanker.Candidate(
                id: width.rawValue,
                label: width.title,
                items: [width.title],
                properties: ["aliases": [width.rawValue], "size": [width.cssValue]],
                fallbackRank: index
            )
        }
        let ordered = query.text.isEmpty
            ? widths
            : PaletteSearchRanker.rank(query: query.text, candidates: candidates)
                .compactMap { DocumentInspectorWidth(rawValue: $0.candidate.id) }
        let items = ordered.map { width in
            PaletteItem(
                id: "width:\(width.rawValue)",
                title: width.title,
                subtitle: width == context.currentDocumentWidth ? "\(width.cssValue) · Selected" : width.cssValue,
                iconSystemName: "arrow.left.and.right",
                activation: pending.filled(with: .string(width.rawValue))
            )
        }
        return [PaletteSection(id: "widths", title: "Page width", items: items)]
    }
}
