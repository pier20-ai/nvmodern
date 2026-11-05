import Foundation

/// User editor themes for the `editorTheme` picker.
///
/// The registry's own list already leads with the reserved `system` entry,
/// which `workspace.theme.select` treats exactly like the id `none` (both clear
/// the selection). No separate "System default" row is synthesised here: a
/// second row meaning the same thing would only be a duplicate.
@MainActor
final class EditorThemesPaletteProvider: PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .editorThemes = source, let pending = frame.pendingCommand else { return [] }

        let directory = UserEditorThemeSelection.themesDirectory()
        let themes = EditorThemeRegistry.availableThemes(in: directory)
        let selectedID = (pending.method == "workspace.document.theme.select"
            ? context.currentDocumentThemeID
            : UserEditorThemeSelection.selectedThemeID() ?? EditorThemeRegistry.systemThemeID).lowercased()

        let orderedThemes: [AvailableEditorTheme]
        if query.text.isEmpty {
            orderedThemes = themes
        } else {
            let themesByID = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0) })
            let candidates = themes.enumerated().map { index, theme in
                PaletteSearchRanker.Candidate(
                    id: theme.id,
                    label: theme.title,
                    items: [theme.title],
                    properties: [
                        "aliases": [theme.id],
                        "keywords": [theme.subtitle].compactMap { $0 },
                    ],
                    fallbackRank: index
                )
            }
            orderedThemes = PaletteSearchRanker.rank(query: query.text, candidates: candidates)
                .compactMap { themesByID[$0.candidate.id] }
        }
        let items = orderedThemes.map { theme in
            let isSelected = theme.id.lowercased() == selectedID
            let base = theme.subtitle ?? (theme.isBundled ? "Built-in theme" : "Custom theme")
            return PaletteItem(
                id: "theme:\(theme.id)",
                title: theme.title,
                subtitle: isSelected ? "\(base) · Selected" : base,
                iconSystemName: "paintpalette",
                activation: pending.filled(with: .string(theme.id))
            )
        }

        return [PaletteSection(id: "themes", title: "Themes", items: items)]
    }
}
