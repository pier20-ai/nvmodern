import Foundation

// The command palette is a sentence: subject · verb · object. Each slot is a
// frame — a set of item sources, a query, and a selection — and the frames
// form a stack. `Cmd+K` opens the root slot, whose noun kind the prefixes
// `> / @ #` change; Tab commits a slot and pushes the next one.
//
// Root is always files: the active tab's document is the first row, so
// `Cmd+K Cmd+K` steps straight into that document's verbs. Verbs never share
// the root list with nouns.
//
// This file is framework-agnostic: no AppKit or SwiftUI. Providers that fill
// frames with items and the view that renders them live in `UI/`.

/// Accent family for a frame. The UI maps it to `DesignTokens.Accent`.
enum PaletteAccent: String, Hashable, Sendable, Codable {
    case nav
    case intent
    case search
}

/// A noun the palette can denote — the subject of a sentence. Nouns preview
/// and can be bound as the subject of a pushed verbs frame (noun → verb).
indirect enum PaletteTarget: Hashable, Sendable {
    case workspaceNote(relativePath: String)
    case openTab(tabID: String, relativePath: String?)
    case folder(relativePath: String)
    /// A full-text match inside a note: the note, the matched text, and the
    /// term that found it.
    case passage(relativePath: String, snippet: String, term: String)
    /// Several nouns marked in multi-select, bound as one subject.
    case batch([PaletteTarget])

    /// Path of the note this noun denotes, when it denotes one.
    var noteRelativePath: String? {
        switch self {
        case .workspaceNote(let relativePath):
            return relativePath
        case .openTab(_, let relativePath):
            return relativePath
        case .passage(let relativePath, _, _):
            return relativePath
        case .folder, .batch:
            return nil
        }
    }

    /// The noun kind actions declare in `nounArguments`, when this target
    /// maps to one. A batch is not a noun kind: it is checked member by member.
    var nounKind: ActionPaletteNoun? {
        switch self {
        case .workspaceNote:
            return .note
        case .openTab(_, let relativePath):
            return relativePath == nil ? nil : .note
        case .folder:
            return .folder
        case .passage:
            return .passage
        case .batch:
            return nil
        }
    }

    /// The value handed to a verb's noun argument.
    var nounValue: ActionValue? {
        switch self {
        case .workspaceNote(let relativePath):
            return .string(relativePath)
        case .openTab(_, let relativePath):
            return relativePath.map(ActionValue.string)
        case .folder(let relativePath):
            return .string(relativePath)
        case .passage(let relativePath, _, _):
            return .string(relativePath)
        case .batch:
            return nil
        }
    }

    /// The nouns a batch subject stands for; a single noun stands for itself.
    var batchMembers: [PaletteTarget] {
        if case .batch(let members) = self { return members }
        return [self]
    }

    /// Short human label for the sentence chip ("weekly.md", "3 notes").
    var breadcrumbLabel: String {
        switch self {
        case .workspaceNote(let relativePath):
            return (relativePath as NSString).lastPathComponent
        case .openTab(_, let relativePath):
            return relativePath.map { ($0 as NSString).lastPathComponent } ?? "Tab"
        case .folder(let relativePath):
            return relativePath.isEmpty ? "Workspace" : (relativePath as NSString).lastPathComponent
        case .passage(let relativePath, let snippet, _):
            return "\u{201C}\(Self.snippetHead(snippet))\u{2026}\u{201D} in \((relativePath as NSString).lastPathComponent)"
        case .batch(let members):
            return "\(members.count) notes"
        }
    }

    /// First 26 characters of a passage snippet, collapsed onto one line.
    static func snippetHead(_ snippet: String) -> String {
        let flattened = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(26))
    }
}

/// Modes layered over the whole session rather than over one frame.
enum PaletteMode: String, CaseIterable, Hashable, Sendable {
    /// The selected note is pushed into the editor behind the palette.
    case preview
    /// Space marks note rows; the marks bind as one batch subject.
    case multiSelect
    /// The palette stays open after a run, reset to root.
    case pin

    /// One quiet word for the footer's mode indicator.
    var label: String {
        switch self {
        case .preview: return "preview"
        case .multiSelect: return "select"
        case .pin: return "pin"
        }
    }
}

/// A choice a plugin is waiting on (`nv.ui.pick` and friends). The palette
/// opens a standalone frame for it; activating a row resolves the request and
/// closing the palette cancels it.
struct PalettePluginPick: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// Rows the plugin supplied.
        case items
        /// One row: whatever was typed.
        case text
        /// A workspace note; resolves with its relative path.
        case note
        /// A workspace folder; resolves with its relative path ("" for root).
        case folder
    }

    var requestID: String
    var kind: Kind
    var placeholder: String?
    var initialText: String?
}

/// What fills a frame. Each kind is served by one provider in the UI layer.
enum PaletteSourceKind: Hashable, Sendable {
    /// Workspace-note tabs open anywhere in the window.
    case openTabs
    /// Recently modified notes (empty-query suggestion).
    case recentNotes
    /// Filename / path matching over every note.
    case notes
    /// Notes directly beside the active document or Miller folder.
    case siblingNotes
    /// Headings in the active document, including unsaved edits.
    case outline
    /// Full-text passages via the search engine.
    case passages
    /// Registry actions with palette presentation. `category` restricts to
    /// one section; nil lists every category.
    case actions(category: String?)
    /// Workspace folders (refile destinations and the like).
    case folders
    /// User editor themes.
    case editorThemes
    case documentWidths
    /// A single row that accepts the typed query as a text argument.
    case textInput
}

/// An action waiting on one more argument. The frame that carries it collects
/// `argumentName`; activating an item merges the value and runs the action.
struct PalettePendingCommand: Hashable, Sendable {
    var method: String
    var args: [String: ActionValue]
    var target: ActionTarget
    var argumentName: String
    var argumentPicker: ActionArgumentPicker

    func filled(with value: ActionValue) -> PaletteActivation {
        filled(with: [argumentName: value])
    }

    /// Some pickers supply more than the collected argument; they merge
    /// every value.
    func filled(with values: [String: ActionValue]) -> PaletteActivation {
        var merged = args
        for (key, value) in values {
            merged[key] = value
        }
        return .runAction(method: method, args: merged, target: target)
    }
}

/// Static description of one slot in the sentence. Root is the only preset;
/// verbs (noun → verb) and object (verb → object) frames are built on the fly.
struct PaletteFrameSpec: Hashable, Sendable, Identifiable {
    var id: String
    /// Breadcrumb label shown in the header.
    var title: String
    var placeholder: String
    var iconSystemName: String
    var accent: PaletteAccent
    var sources: [PaletteSourceKind]
    /// Noun bound as the action target for `actions` sources in this frame.
    var boundTarget: PaletteTarget?
    /// Argument collection state when this frame exists to fill an argument.
    var pendingCommand: PalettePendingCommand?
    var primaryActionLabel: String
    var supportsNewTabActivation: Bool
    var initialQuery: String
    /// Object frames only: the subject the verb already has. Nil means the
    /// implicit active document, which the header draws as a ghost chip.
    var subjectTarget: PaletteTarget?
    /// Set on a frame that exists to answer a plugin. Every activation in it
    /// resolves the request instead of opening or running anything.
    var pluginPick: PalettePluginPick?

    init(
        id: String,
        title: String,
        placeholder: String,
        iconSystemName: String,
        accent: PaletteAccent,
        sources: [PaletteSourceKind],
        boundTarget: PaletteTarget? = nil,
        pendingCommand: PalettePendingCommand? = nil,
        primaryActionLabel: String = "open",
        supportsNewTabActivation: Bool = false,
        initialQuery: String = "",
        subjectTarget: PaletteTarget? = nil
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.iconSystemName = iconSystemName
        self.accent = accent
        self.sources = sources
        self.boundTarget = boundTarget
        self.pendingCommand = pendingCommand
        self.primaryActionLabel = primaryActionLabel
        self.supportsNewTabActivation = supportsNewTabActivation
        self.initialQuery = initialQuery
        self.subjectTarget = subjectTarget
    }

    var isRoot: Bool {
        id == PaletteFrameSpec.root.id
    }

    var isArgumentFrame: Bool {
        pendingCommand != nil
    }

    // MARK: Presets

    /// `Cmd+K`. The one root slot: files, with the active tab's document first,
    /// and `/ @ # >` to change the noun kind. The sources list is vestigial
    /// here — `PaletteResultsResolver` decides root's layout from the query
    /// scope.
    static let root = PaletteFrameSpec(
        id: "root",
        title: "Search",
        placeholder: "Type a note, or / # for passages, folders",
        iconSystemName: "magnifyingglass",
        accent: .nav,
        sources: [],
        primaryActionLabel: "open",
        supportsNewTabActivation: true
    )

    /// Root with a query already typed. Used by the presets that are now a
    /// prefix over root (`>` actions, `/` content search).
    static func root(query: String) -> PaletteFrameSpec {
        var spec = PaletteFrameSpec.root
        spec.initialQuery = query
        return spec
    }

    static let siblings = PaletteFrameSpec(
        id: "siblings",
        title: "Open Sibling",
        placeholder: "Choose a file in this folder",
        iconSystemName: "folder",
        accent: .nav,
        sources: [.siblingNotes],
        primaryActionLabel: "open",
        supportsNewTabActivation: true
    )

    static let outline = PaletteFrameSpec(
        id: "outline",
        title: "Go to Heading",
        placeholder: "Search headings",
        iconSystemName: "list.bullet.indent",
        accent: .nav,
        sources: [.outline],
        primaryActionLabel: "jump"
    )

    /// `Cmd+N`: every action in the `Capture` category. Captures are plain
    /// actions (plugins register them), so this is a verbs frame, not a picker.
    static let capture = PaletteFrameSpec(
        id: "capture",
        title: "Capture",
        placeholder: "Which capture?",
        iconSystemName: "square.and.pencil",
        accent: .intent,
        sources: [.actions(category: captureCategory)],
        primaryActionLabel: "capture"
    )

    static let captureCategory = "Capture"

    /// A plugin's picker. The query is taken literally: `#` and `/` are text
    /// here, not scope prefixes.
    static func pluginPick(_ pick: PalettePluginPick) -> PaletteFrameSpec {
        let placeholder: String
        let icon: String
        let sources: [PaletteSourceKind]
        switch pick.kind {
        case .items:
            (placeholder, icon, sources) = ("Choose", "list.bullet", [])
        case .text:
            (placeholder, icon, sources) = ("Type a value", "character.cursor.ibeam", [])
        case .note:
            (placeholder, icon, sources) = ("Which note?", "doc.text", [.notes])
        case .folder:
            (placeholder, icon, sources) = ("Which folder?", "folder", [.folders])
        }
        var spec = PaletteFrameSpec(
            id: "plugin.pick:\(pick.requestID)",
            title: "Choose",
            placeholder: pick.placeholder ?? placeholder,
            iconSystemName: icon,
            accent: .intent,
            sources: sources,
            primaryActionLabel: "choose",
            initialQuery: pick.initialText ?? ""
        )
        spec.pluginPick = pick
        return spec
    }

    /// Verbs applicable to a noun the user selected and pressed Tab on.
    static func verbs(for target: PaletteTarget) -> PaletteFrameSpec {
        PaletteFrameSpec(
            id: "verbs:\(target.breadcrumbLabel)",
            title: target.breadcrumbLabel,
            placeholder: "Do what?",
            iconSystemName: "bolt.fill",
            accent: .intent,
            sources: [.actions(category: nil)],
            boundTarget: target,
            primaryActionLabel: "run"
        )
    }

    /// Collects one argument for an action. The picker decides the sources.
    static func argument(
        _ argument: ActionArgumentDescriptor,
        picker: ActionArgumentPicker,
        for descriptor: ActionDescriptor,
        pending: PalettePendingCommand,
        subjectTarget: PaletteTarget? = nil
    ) -> PaletteFrameSpec {
        let sources: [PaletteSourceKind]
        let placeholder: String
        let icon: String
        let accent: PaletteAccent
        let primaryLabel: String
        switch picker {
        case .text:
            sources = [.textInput]
            placeholder = argument.summary
            icon = "character.cursor.ibeam"
            accent = .intent
            primaryLabel = "use"
        case .workspaceFolder:
            sources = [.folders]
            placeholder = "Which folder?"
            icon = "folder"
            accent = .nav
            primaryLabel = "choose"
        case .documentWidth:
            sources = [.documentWidths]
            placeholder = "Which page width?"
            icon = "arrow.left.and.right"
            accent = .intent
            primaryLabel = "select"
        case .editorTheme:
            sources = [.editorThemes]
            placeholder = "Which theme?"
            icon = "paintpalette"
            accent = .intent
            primaryLabel = "select"
        }
        return PaletteFrameSpec(
            id: "arg:\(descriptor.method):\(argument.name)",
            title: descriptor.paletteTitle,
            placeholder: placeholder,
            iconSystemName: descriptor.palette?.iconSystemName ?? icon,
            accent: accent,
            sources: sources,
            pendingCommand: pending,
            primaryActionLabel: primaryLabel,
            subjectTarget: subjectTarget
        )
    }
}

/// A palette surface summoned by a shortcut, a menu item, or a notification.
///
/// A preset resolves to the *initial stack* rather than to a single frame:
/// Capture and Refile are the root frame with an argument frame already pushed
/// on top, so Backspace over an empty query lands the user back in search
/// instead of closing the palette.
enum PalettePreset: Hashable, Sendable {
    /// `Cmd+K`.
    case root
    /// `Cmd+Shift+K`.
    case actions
    /// `Cmd+Shift+F`.
    case contentSearch(initialQuery: String)
    /// `Cmd+N`: every action in the `Capture` category, standalone.
    case capture
    /// `Cmd+O`: files beside the current document or Miller folder.
    case siblings
    /// `Cmd+Shift+O`: headings in the active document.
    case outline
    /// Root plus the verbs frame for the tab's document: what `⌘K` `⇥` reaches
    /// by hand, exposed so automation and smoke tests can land there directly.
    case documentVerbs
    /// A picker a plugin asked for; standalone, with no shortcut of its own.
    case pluginPick(PalettePluginPick)

    /// Glyphs shown at the trailing edge of the palette input.
    var shortcutLabel: String {
        switch self {
        case .root: return "⌘K"
        case .actions: return "⌘⇧K"
        case .contentSearch: return "⌘⇧F"
        case .capture: return "⌘N"
        case .siblings: return "⌘O"
        case .outline: return "⌘⇧O"
        case .documentVerbs: return "⌘K"
        case .pluginPick: return ""
        }
    }

    /// Stable label for breadcrumb logging.
    var debugLabel: String {
        switch self {
        case .root: return "root"
        case .actions: return "actions"
        case .contentSearch: return "contentSearch"
        case .capture: return "capture"
        case .siblings: return "siblings"
        case .outline: return "outline"
        case .documentVerbs: return "documentVerbs"
        case .pluginPick(let pick): return "pluginPick.\(pick.kind.rawValue)"
        }
    }

    /// Whether this preset carries the query text across a swap while the
    /// palette is already open.
    var preservesQueryOnSwap: Bool {
        switch self {
        case .root, .actions, .contentSearch: return true
        case .capture, .siblings, .outline, .documentVerbs, .pluginPick: return false
        }
    }
}

/// What happens when an item is activated.
enum PaletteActivation: Hashable, Sendable {
    /// A note's default verb. `findTerm` is a passage's matched text: the note
    /// opens and the in-document find bar seeds itself with it.
    case openNote(relativePath: String, findTerm: String? = nil)
    /// A folder's default verb: select it in the Miller browser.
    case openFolder(relativePath: String)
    case focusTab(tabID: String)
    case jumpToOutlineItem(id: String)
    case runAction(method: String, args: [String: ActionValue], target: ActionTarget)
    case push(PaletteFrameSpec)
    /// Answer a plugin's picker with this value.
    case pluginPick(requestID: String, value: ActionValue)
}

extension PaletteActivation {
    /// The side-stack push a note row's Shift-Return runs, or nil for rows
    /// that are not a plain note open (folders, verbs, passages).
    static func sideStackPush(for activation: PaletteActivation) -> PaletteActivation? {
        guard case .openNote(let relativePath, let findTerm) = activation,
              findTerm == nil,
              !relativePath.isEmpty else {
            return nil
        }
        return .runAction(
            method: "workspace.stack.push",
            args: ["path": .string(relativePath)],
            target: .automatic
        )
    }
}

struct PaletteItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// Right-aligned meta ("Create", folder path, "open tab").
    var subtitle: String?
    /// Second line under the title (content snippet).
    var snippet: String?
    /// File-type glyph for nouns, or the action's symbol in the Capture menu.
    var iconSystemName: String?
    /// Configured shortcut glyphs for actions ("⌘⇧D").
    var shortcutLabel: String?
    /// The verb's current value, shown before the chevron ("Arbor", "2
    /// options", "on"). Takes the place of the subtitle when present.
    var value: String?
    var activation: PaletteActivation
    /// The noun this item denotes, when it denotes one.
    var target: PaletteTarget?
    /// The registry method behind an action item, for the recent list.
    var actionMethod: String?
    /// Hierarchy depth for document-order outline rows; search results are flat.
    var indentation: Int

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        snippet: String? = nil,
        iconSystemName: String? = nil,
        shortcutLabel: String? = nil,
        value: String? = nil,
        activation: PaletteActivation,
        target: PaletteTarget? = nil,
        actionMethod: String? = nil,
        indentation: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.iconSystemName = iconSystemName
        self.shortcutLabel = shortcutLabel
        self.value = value
        self.activation = activation
        self.target = target
        self.actionMethod = actionMethod
        self.indentation = indentation
    }

    /// Rows with a submenu draw a chevron; Right Arrow / Tab pushes them.
    var hasSubmenu: Bool {
        if case .push = activation { return true }
        return false
    }
}

/// A run of rows under one optional header. An empty title draws no header.
struct PaletteSection: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var items: [PaletteItem]

    init(id: String, title: String, items: [PaletteItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Query scoping typed as a prefix: the noun kind the root slot denotes.
/// `>` verbs, `/` passages, `#` folders; anything else is notes.
struct PaletteQueryScope: Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        case all
        case actions
        case passages
        case folders
    }

    let scope: Scope
    /// The query with any prefix and surrounding whitespace removed.
    let text: String

    /// Prefix characters, in the order the placeholder advertises them.
    static let prefixes: [(Character, Scope)] = [
        (">", .actions),
        ("/", .passages),
        ("#", .folders)
    ]

    /// The prefix that produced this scope, for rebuilding a raw query.
    var prefix: String {
        Self.prefixes.first { $0.1 == scope }.map { String($0.0) } ?? ""
    }

    static func parse(_ raw: String) -> PaletteQueryScope {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first,
           let match = prefixes.first(where: { $0.0 == first }) {
            return PaletteQueryScope(
                scope: match.1,
                text: trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return PaletteQueryScope(scope: .all, text: trimmed)
    }
}

/// Live state for one frame on the stack.
struct PaletteFrameState: Identifiable {
    let spec: PaletteFrameSpec
    var query: String
    var selectedItemID: String?
    var sections: [PaletteSection] = []

    var id: String { spec.id }

    var items: [PaletteItem] {
        sections.flatMap(\.items)
    }

    var selectedItem: PaletteItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    init(spec: PaletteFrameSpec) {
        self.spec = spec
        self.query = spec.initialQuery
        self.selectedItemID = nil
    }
}

/// The stack itself. Push when an item needs a submenu or an argument; pop on
/// Backspace over an empty query or on Escape with more than one frame.
@MainActor
final class PaletteStack: ObservableObject {
    @Published private(set) var frames: [PaletteFrameState]

    init(root: PaletteFrameSpec) {
        frames = [PaletteFrameState(spec: root)]
    }

    /// Opens directly onto a stack: presets like Capture and Refile start with
    /// their argument frame already pushed over the root search frame.
    init(frames specs: [PaletteFrameSpec]) {
        let resolved = specs.isEmpty ? [PaletteFrameSpec.root] : specs
        frames = resolved.map(PaletteFrameState.init(spec:))
    }

    var top: PaletteFrameState {
        frames[frames.count - 1]
    }

    var depth: Int {
        frames.count
    }

    var canPop: Bool {
        frames.count > 1
    }

    /// Breadcrumb labels from the root frame down to the top.
    var breadcrumb: [String] {
        frames.map(\.spec.title)
    }

    func push(_ spec: PaletteFrameSpec) {
        frames.append(PaletteFrameState(spec: spec))
    }

    @discardableResult
    func pop() -> Bool {
        guard canPop else { return false }
        frames.removeLast()
        return true
    }

    func reset(to spec: PaletteFrameSpec) {
        frames = [PaletteFrameState(spec: spec)]
    }

    func reset(to specs: [PaletteFrameSpec]) {
        let resolved = specs.isEmpty ? [PaletteFrameSpec.root] : specs
        frames = resolved.map(PaletteFrameState.init(spec:))
    }

    func updateTop(_ mutate: (inout PaletteFrameState) -> Void) {
        var state = frames[frames.count - 1]
        mutate(&state)
        frames[frames.count - 1] = state
    }

    var query: String {
        get { top.query }
        set { updateTop { $0.query = newValue } }
    }

    var selectedItemID: String? {
        get { top.selectedItemID }
        set { updateTop { $0.selectedItemID = newValue } }
    }

    /// Replaces the top frame's sections and, by default, keeps the selection
    /// when the selected item survives. Query changes opt out so freshly
    /// filtered results always start at the first row.
    func setSections(_ sections: [PaletteSection], preservingSelection: Bool = true) {
        updateTop { state in
            state.sections = sections
            let items = state.items
            if preservingSelection,
               let selected = state.selectedItemID,
               items.contains(where: { $0.id == selected }) {
                return
            }
            state.selectedItemID = items.first?.id
        }
    }

    func selectFirstItem() {
        updateTop { state in
            state.selectedItemID = state.items.first?.id
        }
    }

    func moveSelection(by delta: Int) {
        updateTop { state in
            let items = state.items
            guard !items.isEmpty else { return }
            let current = state.selectedItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            let next = (current + delta + items.count) % items.count
            state.selectedItemID = items[next].id
        }
    }
}

/// Prevents a stationary pointer from reclaiming palette selection when a
/// query rebuilds or scrolls the rows underneath it. Hover remains suppressed
/// until the pointer leaves a deliberate box around its position at the edit.
struct PaletteHoverSelectionGate {
    static let deadZoneHalfExtent: CGFloat = 12

    private(set) var suppressionOrigin: CGPoint?

    mutating func suppress(at point: CGPoint) {
        suppressionOrigin = point
    }

    mutating func reset() {
        suppressionOrigin = nil
    }

    mutating func allowsSelection(at point: CGPoint) -> Bool {
        guard let origin = suppressionOrigin else { return true }
        let stayedInsideDeadZone = abs(point.x - origin.x) <= Self.deadZoneHalfExtent
            && abs(point.y - origin.y) <= Self.deadZoneHalfExtent
        guard !stayedInsideDeadZone else { return false }
        suppressionOrigin = nil
        return true
    }
}

/// Builds the item or frame an action descriptor produces in a frame,
/// resolving argument collection and noun binding in one place so the
/// actions provider and the activation handler agree.
enum PaletteActionPlanner {
    /// The activation for a descriptor: run it now, or push an argument
    /// frame when a picker-bearing argument is still missing.
    static func activation(
        for descriptor: ActionDescriptor,
        suppliedArgs: [String: ActionValue],
        target: ActionTarget,
        subjectTarget: PaletteTarget? = nil
    ) -> PaletteActivation {
        if let argument = descriptor.paletteArgumentToCollect(given: suppliedArgs),
           let picker = argument.picker {
            let pending = PalettePendingCommand(
                method: descriptor.method,
                args: suppliedArgs,
                target: target,
                argumentName: argument.name,
                argumentPicker: picker
            )
            return .push(
                .argument(
                    argument,
                    picker: picker,
                    for: descriptor,
                    pending: pending,
                    subjectTarget: subjectTarget
                )
            )
        }
        return .runAction(method: descriptor.method, args: suppliedArgs, target: target)
    }

    /// Whether an action applies to a bound noun: it must declare an
    /// argument for that noun kind in its palette presentation. A batch
    /// additionally requires the verb to opt into batch runs and to apply to
    /// every member.
    static func applies(_ descriptor: ActionDescriptor, to target: PaletteTarget) -> Bool {
        if case .batch(let members) = target {
            guard descriptor.palette?.acceptsBatch == true, !members.isEmpty else { return false }
            return members.allSatisfy { applies(descriptor, to: $0) }
        }
        return boundArgs(for: descriptor, target: target) != nil
    }

    /// The arguments that bind a noun to an action, or nil when the action
    /// does not accept that noun. A batch binds nothing: the session expands
    /// it and binds each member in turn.
    static func boundArgs(for descriptor: ActionDescriptor, target: PaletteTarget) -> [String: ActionValue]? {
        guard let palette = descriptor.palette,
              let nounKind = target.nounKind,
              let argumentName = palette.argumentName(for: nounKind),
              let value = target.nounValue else {
            return nil
        }

        var bound: [String: ActionValue] = [argumentName: value]
        switch target {
        case .passage(_, let snippet, let term):
            bound["snippet"] = .string(snippet)
            bound["term"] = .string(term)
        default:
            break
        }
        return bound
    }
}
