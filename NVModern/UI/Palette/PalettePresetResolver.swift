import Foundation

/// Turns a `PalettePreset` into the frame stack the palette opens on.
@MainActor
enum PalettePresetResolver {
    static func frames(for preset: PalettePreset) -> [PaletteFrameSpec] {
        switch preset {
        case .root:
            return [.root]
        // Actions and Content Search are no longer frames of their
        // own: each is root with the prefix that scopes the noun slot.
        case .actions:
            return [.root(query: ">")]
        case .contentSearch(let initialQuery):
            return [.root(query: "/\(initialQuery)")]
        case .capture:
            // Standalone, like Outline: Escape closes it and Backspace stays
            // put, because nothing about it reads as a step inside search.
            return [.capture]
        case .siblings:
            return [.siblings]
        case .outline:
            return [.outline]
        case .documentVerbs:
            // The session pushes the verbs frame once it knows the document.
            return [.root]
        case .pluginPick(let pick):
            return [.pluginPick(pick)]
        }
    }
}
