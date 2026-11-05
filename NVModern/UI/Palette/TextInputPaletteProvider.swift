import Foundation

/// The single row a free-text argument frame offers: "use what I typed".
///
/// An empty query yields no items on purpose — the frame's placeholder is the
/// instruction, and an empty state row repeating it would be noise.
@MainActor
final class TextInputPaletteProvider: PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .textInput = source,
              let pending = frame.pendingCommand,
              !query.text.isEmpty else {
            return []
        }

        let item = PaletteItem(
            id: "text:\(query.text)",
            title: "Use \u{201C}\(query.text)\u{201D}",
            iconSystemName: frame.iconSystemName,
            activation: pending.filled(with: .string(query.text))
        )
        return [PaletteSection(id: "text", title: "", items: [item])]
    }
}
