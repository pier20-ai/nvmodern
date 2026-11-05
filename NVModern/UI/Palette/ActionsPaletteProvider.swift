import Foundation

/// Registry actions with a palette presentation — the verbs of the sentence.
///
/// The whole action list is one place now: menus, keybindings, plugins, the
/// socket, and this provider all read the same descriptors, so an action can
/// never be in the palette but missing from automation, or the reverse.
///
/// Two groupings come out of here. With no noun bound the verbs group by
/// subject — the document, "Window", "Workspace" — which is what the `>` scope
/// shows. With a noun bound the frame is one section headed by that noun,
/// listing only the verbs that accept it.
///
/// One exception, and it is the common case: when the bound noun *is* the
/// document the tab already shows (`Cmd+K Cmd+K`), the frame is the whole menu
/// for that tab — its file verbs first, then Window, then Workspace — because
/// there is no other subject left for the palette to mean.
@MainActor
final class ActionsPaletteProvider: PaletteSourceProvider {
    /// Section order in a verbs list: what acts on the file first, then the
    /// window, then things that make something new. Categories outside this
    /// list sort after it, alphabetically, so a new one is visible, not lost.
    static let categoryOrder = [
        "Open", "File", "Document", "Format", "Window", "Capture", "Create", "Appearance"
    ]

    static let recentSectionID = "verbs.recent"

    private struct ActionEntry {
        let item: PaletteItem
        let category: String
        let subject: ActionPaletteSubject
        let rank: Int
        let searchCandidate: PaletteSearchRanker.Candidate<String>
    }

    /// Arguments the palette always supplies for a given method, on top of any
    /// noun binding. `workspace.note.create` defaults to a new tab for scripted
    /// callers; the palette's "New note…" has always opened in the current tab.
    private static let alwaysSuppliedArgs: [String: [String: ActionValue]] = [
        "workspace.note.create": [
            "open": .bool(true),
            "openIn": .string("currentTab")
        ]
    ]

    /// The current value a verb would change, shown before the chevron. Small
    /// and explicit on purpose: a verb only gets a value when the value is the
    /// thing the user is deciding about.
    static let valueProviders: [String: @MainActor (PaletteContext) -> String?] = [
        "workspace.note.refile": { context in
            guard let folder = context.currentNoteFolderRelativePath else { return nil }
            return folder.isEmpty ? "Workspace" : (folder as NSString).lastPathComponent
        },
        "workspace.document.theme.select": { context in DocumentThemeID(rawValue: context.currentDocumentThemeID).title },
        "workspace.document.width.select": { context in context.currentDocumentWidth.title },
        "workspace.theme.select": { context in context.currentThemeTitle },
        "workspace.toolbar.compact.toggle": { context in context.isCompactToolbarEnabled ? "on" : "off" },
        "workspace.sidebar.toggle": { context in context.isSidebarVisible ? "shown" : "hidden" }
    ]

    private let registry: ActionRegistry
    private let recentStore: PaletteRecentVerbsStore
    private let variablesBuilder: () -> [String: ActionValue]

    /// `registry` is optional for the same reason the resolver's providers are:
    /// a main-actor default argument is not allowed.
    init(
        registry: ActionRegistry? = nil,
        recentStore: PaletteRecentVerbsStore? = nil,
        variables: (() -> [String: ActionValue])? = nil
    ) {
        self.registry = registry ?? .shared
        self.recentStore = recentStore ?? .shared
        self.variablesBuilder = variables ?? {
            // Reaches workspace state, so this must run inside the resolve task
            // and never during a SwiftUI body evaluation.
            ActionAutomationContextBuilder.build(
                source: ActionSource(kind: .internalCall, identifier: "palette"),
                fallbackTarget: .automatic
            ).variables
        }
    }

    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .actions(let category) = source else { return [] }

        let variables = variablesBuilder()
        // The bound noun is the tab's own document: the frame becomes that
        // tab's whole menu rather than only the verbs that take a note.
        let bindsActiveDocument = Self.bindsActiveDocument(frame.boundTarget, context: context)

        var entries: [ActionEntry] = []
        for descriptor in registry.allDescriptors() {
            guard let palette = descriptor.palette else { continue }
            if let category, palette.category != category { continue }
            // Verbs that only make sense on a bound noun ("Quote into current
            // note") never show unbound, and never through the widened
            // active-document frame either.
            if palette.listedOnlyWhenBound,
               frame.boundTarget.flatMap({ PaletteActionPlanner.boundArgs(for: descriptor, target: $0) }) == nil {
                continue
            }
            guard let supplied = suppliedArgs(
                for: descriptor,
                frame: frame,
                context: context,
                allowsUnboundVerbs: bindsActiveDocument
            ) else {
                continue
            }
            // A `when` on a path-taking verb describes its current-document
            // fallback. Once a noun is bound the verb acts on that noun, so
            // the current document no longer gates it — unless the bound noun
            // *is* the current document, where the gate is exactly right.
            let isBoundVerb = frame.boundTarget != nil && !bindsActiveDocument
            if !isBoundVerb,
               let when = palette.when,
               !ActionExpressionEvaluator.evaluate(when, variables: variables) {
                continue
            }

            let activation = PaletteActionPlanner.activation(
                for: descriptor,
                suppliedArgs: supplied,
                target: .automatic,
                subjectTarget: frame.boundTarget
            )
            // Only a verb that actually took the noun reads differently for it
            // ("New note here…"); the window and workspace verbs alongside it
            // in an active-document frame keep their plain titles.
            let bindsNoun: Bool = {
                guard let bound = frame.boundTarget else { return false }
                if case .batch = bound { return true }
                return PaletteActionPlanner.boundArgs(for: descriptor, target: bound) != nil
            }()
            let item = PaletteItem(
                id: "action:\(descriptor.method)",
                title: bindsNoun ? descriptor.paletteBoundTitle : descriptor.paletteTitle,
                // No category on the row: the section header already says who
                // the verb acts on, and the category only ordered the group.
                subtitle: nil,
                iconSystemName: palette.iconSystemName ?? "bolt",
                shortcutLabel: PaletteShortcutResolver.shortcutLabel(
                    forMethod: descriptor.method,
                    projectRootPath: context.projectRootPath
                ),
                value: Self.valueProviders[descriptor.method]?(context),
                activation: activation,
                actionMethod: descriptor.method
            )
            entries.append(
                ActionEntry(
                    item: item,
                    category: palette.category,
                    subject: palette.resolvedSubject,
                    rank: palette.rank,
                    searchCandidate: PaletteSearchRanker.Candidate(
                        id: descriptor.method,
                        label: item.title,
                        items: [item.title],
                        properties: [
                            "aliases": [descriptor.title] + palette.keywords,
                            "category": [palette.category],
                            "tags": descriptor.tags,
                            "method": [descriptor.method],
                        ],
                        fallbackRank: palette.rank
                    )
                )
            )
        }

        if !query.text.isEmpty {
            let entriesByMethod = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.searchCandidate.id, $0)
            })
            let items = PaletteSearchRanker.rank(
                query: query.text,
                candidates: entries.map(\.searchCandidate)
            ).compactMap { ranked -> PaletteItem? in
                guard let entry = entriesByMethod[ranked.candidate.id] else { return nil }
                var item = entry.item
                item.subtitle = entry.category
                return item
            }
            let title = category ?? "Actions"
            return items.isEmpty ? [] : [PaletteSection(id: "verbs.search", title: title, items: items)]
        }

        let ordered = entries.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }

        // Document verbs need a document: a launchpad tab with nothing bound
        // lists only window and workspace verbs.
        let hasDocument = frame.boundTarget != nil || context.currentDocumentRelativePath != nil
        var listed = hasDocument ? ordered : ordered.filter { $0.subject != .document }

        // Capture is a fixed menu: keep every action in its configured order.
        if category == PaletteFrameSpec.captureCategory {
            return Self.categorySections(listed)
        }

        // Typing searches everything. The empty menu shows only the common
        // tier, led by the verbs run most recently, which are lifted out of
        // their sections so nothing repeats.
        let recentMethods = recentStore.methods
        let recentItems = recentMethods.compactMap { method in
            listed.first { $0.item.actionMethod == method }?.item
        }
        let recentIDs = Set(recentItems.map(\.id))
        listed = listed.filter { !recentIDs.contains($0.item.id) && $0.rank < ActionPalettePresentation.longTailRank }
        var sections = Self.categorySections(listed)
        if !recentItems.isEmpty {
            sections.insert(PaletteSection(id: Self.recentSectionID, title: "Recent", items: recentItems), at: 0)
        }
        return sections
    }

    // MARK: Grouping

    /// One section per category, in `categoryOrder`. The noun pill already
    /// names the subject, so no section repeats it.
    private static func categorySections(
        _ ordered: [ActionEntry]
    ) -> [PaletteSection] {
        var byCategory: [String: [PaletteItem]] = [:]
        for entry in ordered {
            byCategory[entry.category, default: []].append(entry.item)
        }
        return orderedCategories(in: byCategory.keys).compactMap { category in
            guard let items = byCategory[category], !items.isEmpty else { return nil }
            return PaletteSection(id: "verbs.\(category)", title: category, items: items)
        }
    }

    /// Whether a bound noun is the document the tab already shows.
    static func bindsActiveDocument(_ target: PaletteTarget?, context: PaletteContext) -> Bool {
        guard let target, let currentPath = context.currentDocumentRelativePath else { return false }
        switch target {
        case .workspaceNote(let relativePath):
            return relativePath == currentPath
        case .openTab(_, let relativePath):
            return relativePath == currentPath
        case .folder, .passage, .batch:
            return false
        }
    }

    // MARK: Argument pre-fill

    /// Arguments the palette hands the action before the planner decides
    /// whether anything is still missing. Returns nil when the action does not
    /// apply to the frame's bound noun at all.
    ///
    /// `allowsUnboundVerbs` is the active-document frame: a verb that takes no
    /// note argument (Split right, Toggle bold) still belongs there, because
    /// the noun it would have bound is the document the tab already shows.
    private func suppliedArgs(
        for descriptor: ActionDescriptor,
        frame: PaletteFrameSpec,
        context: PaletteContext,
        allowsUnboundVerbs: Bool = false
    ) -> [String: ActionValue]? {
        var supplied = Self.alwaysSuppliedArgs[descriptor.method] ?? [:]

        if let boundTarget = frame.boundTarget {
            // A batch binds nothing here: the session runs the verb once per
            // member with that member's own arguments.
            if case .batch = boundTarget {
                guard PaletteActionPlanner.applies(descriptor, to: boundTarget) else { return nil }
                return supplied
            }
            if let bound = PaletteActionPlanner.boundArgs(for: descriptor, target: boundTarget) {
                supplied.merge(bound) { _, new in new }
                return supplied
            }
            guard allowsUnboundVerbs else { return nil }
        }

        // Outside a bound frame, a folder-noun action still acts where the user
        // is standing: this is what the old `folderActionArgs()` did for the
        // daily note, clipboard note, and new note commands.
        if let folder = context.currentFolderRelativePath,
           !folder.isEmpty,
           let argumentName = descriptor.palette?.argumentName(for: .folder) {
            supplied[argumentName] = .string(folder)
        }
        return supplied
    }

    private static func orderedCategories(in categories: some Collection<String>) -> [String] {
        let known = categoryOrder.filter { categories.contains($0) }
        let unknown = categories.filter { !categoryOrder.contains($0) }.sorted()
        return known + unknown
    }
}
