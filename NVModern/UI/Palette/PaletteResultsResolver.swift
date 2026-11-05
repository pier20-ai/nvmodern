import Foundation

/// Decides what a frame shows.
///
/// Root is the sentence's first slot, and the only frame whose layout is not
/// simply "the frame's sources, in order". It is always files: empty it is the
/// active tab's document, the other open tabs, then recents; typed it is
/// ranked notes and nothing else. Verbs live one step in, behind Tab. A prefix
/// (`> / @ #`) changes the noun kind the slot denotes.
@MainActor
final class PaletteResultsResolver {
    /// Coalescing delays, ported from the views these providers replace.
    enum Debounce {
        static let notesNanoseconds: UInt64 = 35_000_000
        static let passagesNanoseconds: UInt64 = 140_000_000
    }

    let notesProvider: NotesPaletteProvider
    let passagesProvider: PassagesPaletteProvider
    let actionsProvider: ActionsPaletteProvider
    let foldersProvider: FoldersPaletteProvider
    let editorThemesProvider: EditorThemesPaletteProvider
    let textInputProvider: TextInputPaletteProvider
    let documentWidthsProvider = DocumentWidthsPaletteProvider()
    let outlineProvider = OutlinePaletteProvider()

    /// Notes shown in a typed root query. Root is the only place they appear,
    /// so it can afford a longer list than when it also carried verbs.
    static let rootNoteLimit = 12
    /// Below this the passages scope is not worth a search.
    static let passagesMinimumQueryLength = 2

    /// Providers are optional so a caller (a test, usually) can substitute one
    /// without naming the other seven. Default arguments cannot construct them:
    /// they are evaluated outside the main actor.
    init(
        notesProvider: NotesPaletteProvider? = nil,
        passagesProvider: PassagesPaletteProvider? = nil,
        actionsProvider: ActionsPaletteProvider? = nil,
        foldersProvider: FoldersPaletteProvider? = nil,
        editorThemesProvider: EditorThemesPaletteProvider? = nil,
        textInputProvider: TextInputPaletteProvider? = nil
    ) {
        self.notesProvider = notesProvider ?? NotesPaletteProvider()
        self.passagesProvider = passagesProvider ?? PassagesPaletteProvider()
        self.actionsProvider = actionsProvider ?? ActionsPaletteProvider()
        self.foldersProvider = foldersProvider ?? FoldersPaletteProvider()
        self.editorThemesProvider = editorThemesProvider ?? EditorThemesPaletteProvider()
        self.textInputProvider = textInputProvider ?? TextInputPaletteProvider()
    }

    /// The delay a query change should wait out before this frame re-resolves.
    func debounceNanoseconds(for frame: PaletteFrameSpec, rawQuery: String) -> UInt64 {
        let sources = activeSources(frame: frame, scope: PaletteQueryScope.parse(rawQuery))
        var delay: UInt64 = 0
        for source in sources {
            switch source {
            case .notes:
                delay = max(delay, Debounce.notesNanoseconds)
            case .passages:
                delay = max(delay, Debounce.passagesNanoseconds)
            default:
                break
            }
        }
        return delay
    }

    func sections(
        frame: PaletteFrameSpec,
        rawQuery: String,
        context: PaletteContext
    ) async -> [PaletteSection] {
        let scope = frame.sources == [.outline] || frame.pluginPick != nil
            ? PaletteQueryScope(scope: .all, text: rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            : PaletteQueryScope.parse(rawQuery)

        if let pick = frame.pluginPick {
            switch pick.kind {
            case .items, .text:
                return nonEmpty(PluginPickCenter.shared.sections(for: pick, query: scope.text))
            case .note:
                // Recents until something is typed, like root.
                let source: PaletteSourceKind = scope.text.isEmpty ? .recentNotes : .notes
                return nonEmpty(await sections(for: source, scope: scope, frame: frame, context: context))
            case .folder:
                return nonEmpty(await sections(for: .folders, scope: scope, frame: frame, context: context))
            }
        }

        guard frame.isRoot else {
            return await concatenated(
                sources: frame.sources,
                scope: scope,
                frame: frame,
                context: context
            )
        }

        switch scope.scope {
        case .actions:
            return nonEmpty(await sections(for: .actions(category: nil), scope: scope, frame: frame, context: context))
        case .passages:
            return nonEmpty(await sections(for: .passages, scope: scope, frame: frame, context: context))
        case .folders:
            return nonEmpty(await sections(for: .folders, scope: scope, frame: frame, context: context))
        case .all:
            return scope.text.isEmpty
                ? await emptyRootSections(scope: scope, frame: frame, context: context)
                : await typedRootSections(scope: scope, frame: frame, context: context)
        }
    }

    // MARK: Root layout

    /// One list of files. The tab's own document leads it — unheaded, selected
    /// by default — so `Cmd+K Cmd+K` steps into its verbs; then the other open
    /// tabs, then recents under a single header.
    private func emptyRootSections(
        scope: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        async let openTabs = sections(for: .openTabs, scope: scope, frame: frame, context: context)
        async let recents = sections(for: .recentNotes, scope: scope, frame: frame, context: context)

        let currentPath = context.currentDocumentRelativePath
        let currentItem = notesProvider.currentDocumentItem(context: context)
        let openItems = await openTabs
            .flatMap(\.items)
            .filter { $0.target?.noteRelativePath != currentPath }
        let recentItems = await recents
            .flatMap(\.items)
            .filter { $0.target?.noteRelativePath != currentPath }

        return nonEmpty([
            PaletteSection(id: "open", title: "", items: [currentItem].compactMap { $0 } + openItems),
            PaletteSection(id: "recent", title: "Recent", items: recentItems)
        ])
    }

    /// Typed: ranked notes, and nothing else. The placeholder already teaches
    /// `/` for contents, and Tab already reaches a note's verbs.
    private func typedRootSections(
        scope: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        let notes = await sections(for: .notes, scope: scope, frame: frame, context: context)
        return nonEmpty(notes.map { section in
            var trimmed = section
            trimmed.items = Array(section.items.prefix(Self.rootNoteLimit))
            return trimmed
        })
    }

    // MARK: Source dispatch

    private func concatenated(
        sources: [PaletteSourceKind],
        scope: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        var result: [PaletteSection] = []
        for source in sources {
            result += await sections(for: source, scope: scope, frame: frame, context: context)
        }
        return nonEmpty(result)
    }

    private func sections(
        for source: PaletteSourceKind,
        scope: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        switch source {
        case .openTabs, .recentNotes, .notes, .siblingNotes:
            return await notesProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .passages:
            guard scope.text.count >= Self.passagesMinimumQueryLength else { return [] }
            return await passagesProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .actions:
            return await actionsProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .folders:
            return await foldersProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .documentWidths:
            return await documentWidthsProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .editorThemes:
            return await editorThemesProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .textInput:
            return await textInputProvider.sections(for: source, query: scope, frame: frame, context: context)
        case .outline:
            return await outlineProvider.sections(for: source, query: scope, frame: frame, context: context)
        }
    }

    /// Which sources the frame would actually consult for this query. Used for
    /// the debounce; the assembly above is the authority on ordering.
    private func activeSources(frame: PaletteFrameSpec, scope: PaletteQueryScope) -> [PaletteSourceKind] {
        guard frame.isRoot else { return frame.sources }
        switch scope.scope {
        case .actions: return [.actions(category: nil)]
        case .passages: return [.passages]
        case .folders: return [.folders]
        case .all:
            return scope.text.isEmpty ? [.openTabs, .recentNotes] : [.notes]
        }
    }

    private func nonEmpty(_ sections: [PaletteSection]) -> [PaletteSection] {
        sections.filter { !$0.items.isEmpty }
    }
}
