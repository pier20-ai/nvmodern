import Foundation

enum ActionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case appRead = "app.read"
    case appWrite = "app.write"
    case workspaceRead = "workspace.read"
    case workspaceWrite = "workspace.write"
    case noteRead = "note.read"
    case noteWrite = "note.write"
    case contentRead = "content.read"
    case contentWrite = "content.write"
    case contentSemanticRead = "content.semantic.read"
    case contentSemanticWrite = "content.semantic.write"
    case automationExecute = "automation.execute"
}

enum ActionMutationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnly
    case mutating
}

enum ActionExecutionDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case app
    case workspace
    case content
    case automation
    case introspection
}

enum ActionTargetRequirement: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case app
    case window
    case workspace
    case tab
    case project
    case document
    case content
}

/// How the command palette collects a missing argument when a user activates
/// an action interactively. Transport clients (CLI, socket, MCP) ignore this;
/// it only tells the palette which picker frame to push.
enum ActionArgumentPicker: String, Codable, Hashable, Sendable {
    /// Free text typed into the palette input.
    case text
    /// A workspace folder relative path (empty string for the root).
    case workspaceFolder
    /// A user editor theme id.
    case editorTheme
    case documentWidth
}

struct ActionArgumentDescriptor: Codable, Hashable, Sendable {
    let name: String
    let summary: String
    let kind: ActionValue.Kind
    let isRequired: Bool
    /// Palette picker for this argument. Nil means the palette never prompts
    /// for it; the action runs with whatever the caller supplies.
    var picker: ActionArgumentPicker? = nil

    init(
        name: String,
        summary: String,
        kind: ActionValue.Kind,
        isRequired: Bool,
        picker: ActionArgumentPicker? = nil
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.isRequired = isRequired
        self.picker = picker
    }
}

/// Kinds of noun the palette can bind to an action (noun → verb).
enum ActionPaletteNoun: String, Codable, Hashable, Sendable, CaseIterable {
    /// A workspace note; the bound value is its relative path.
    case note
    /// A workspace folder; the bound value is its relative path ("" for root).
    case folder
    /// A full-text match inside a note; the bound value is the note's relative
    /// path, alongside `snippet` and `term`.
    case passage
}

/// Who a verb acts on when nothing is bound. The palette's root menu is
/// grouped by this: "on <file>", "on This window", "on Workspace".
enum ActionPaletteSubject: String, Codable, Hashable, Sendable, CaseIterable {
    /// The document open in the selected tab.
    case document
    /// The window and its tabs/splits.
    case window
    /// The workspace as a whole.
    case workspace

    /// The subject a category implies when a descriptor does not name one, so
    /// no existing `palette:` block has to be edited.
    static func derived(fromCategory category: String) -> ActionPaletteSubject {
        switch category {
        case "Open", "File", "Document", "Format", "Table":
            return .document
        case "Window", "Layout", "Tabs", "Workspace":
            return .window
        default:
            // Create, Appearance, and anything new.
            return .workspace
        }
    }
}

/// Opt-in command palette presentation for an action. Actions without this
/// are still invocable through every transport but are not listed in the
/// palette (introspection, headless queries, and so on).
struct ActionPalettePresentation: Codable, Hashable, Sendable {
    /// Section the action is grouped under when the palette query is empty.
    var category: String
    /// SF Symbol shown in the row.
    var iconSystemName: String?
    /// `ActionExpressionEvaluator` expression over the automation context
    /// variables. When it evaluates false the action is hidden. Nil means
    /// always available.
    var when: String?
    /// Overrides the descriptor title in the palette (e.g. "New note here"
    /// instead of "Create Workspace Note").
    var title: String?
    /// Position within the category when the query is empty. Lower comes
    /// first; ties fall back to title order. Menus are read top-down, so the
    /// common verbs (open, refile, rename) should not lose to alphabet.
    var rank: Int
    /// Ranks at or above this are the long tail: reachable by typing, but
    /// not shown in the empty menu, so the menu stays as short as the verbs
    /// people actually reach for.
    static let longTailRank = 200
    var isLongTail: Bool { rank >= Self.longTailRank }
    /// Extra search terms matched alongside the title and category.
    var keywords: [String]
    /// Nouns this action can act on, mapped to the argument that receives
    /// the noun's value. A note noun with `["note": "path"]` makes the palette
    /// list this action in the note's verbs frame and run it with
    /// `path = <relativePath>`. Handlers must default to the current document
    /// when the argument is absent so plain invocation keeps working.
    var nounArguments: [String: String]
    /// Explicit subject group for the root menu. Nil derives one from the
    /// category, which is what every pre-existing descriptor relies on.
    var subject: ActionPaletteSubject?
    /// Whether the verb can run over several bound nouns at once. Only these
    /// appear in a multi-select batch's verbs frame.
    var acceptsBatch: Bool
    /// The verb Enter runs on a bare noun of the kind this verb accepts.
    var isDefaultVerb: Bool
    /// Verbs that only make sense with a noun already bound (a passage's
    /// "Quote into current note"). They never appear in root or `>`.
    var listedOnlyWhenBound: Bool
    /// Title used instead of `title` once a noun is bound ("New note here…"
    /// rather than "New note…" in a folder's verbs frame).
    var boundTitle: String?

    init(
        category: String,
        iconSystemName: String? = nil,
        when: String? = nil,
        title: String? = nil,
        rank: Int = 100,
        keywords: [String] = [],
        nounArguments: [String: String] = [:],
        subject: ActionPaletteSubject? = nil,
        acceptsBatch: Bool = false,
        isDefaultVerb: Bool = false,
        listedOnlyWhenBound: Bool = false,
        boundTitle: String? = nil
    ) {
        self.category = category
        self.iconSystemName = iconSystemName
        self.when = when
        self.title = title
        self.rank = rank
        self.keywords = keywords
        self.nounArguments = nounArguments
        self.subject = subject
        self.acceptsBatch = acceptsBatch
        self.isDefaultVerb = isDefaultVerb
        self.listedOnlyWhenBound = listedOnlyWhenBound
        self.boundTitle = boundTitle
    }

    /// The declared subject, or the one the category implies.
    var resolvedSubject: ActionPaletteSubject {
        subject ?? ActionPaletteSubject.derived(fromCategory: category)
    }

    func argumentName(for noun: ActionPaletteNoun) -> String? {
        nounArguments[noun.rawValue]
    }
}

struct ActionResultDescriptor: Codable, Hashable, Sendable {
    let summary: String
    let kind: ActionValue.Kind
}

struct ActionDescriptor: Codable, Hashable, Sendable, Identifiable {
    let method: String
    let title: String
    let summary: String
    let discussion: String?
    let domain: ActionExecutionDomain
    let mutationKind: ActionMutationKind
    let targetRequirement: ActionTargetRequirement
    let capabilities: [ActionCapability]
    let tags: [String]
    let arguments: [ActionArgumentDescriptor]
    let result: ActionResultDescriptor?
    /// Present only for actions the command palette lists.
    var palette: ActionPalettePresentation? = nil

    init(
        method: String,
        title: String,
        summary: String,
        discussion: String?,
        domain: ActionExecutionDomain,
        mutationKind: ActionMutationKind,
        targetRequirement: ActionTargetRequirement,
        capabilities: [ActionCapability],
        tags: [String],
        arguments: [ActionArgumentDescriptor],
        result: ActionResultDescriptor?,
        palette: ActionPalettePresentation? = nil
    ) {
        self.method = method
        self.title = title
        self.summary = summary
        self.discussion = discussion
        self.domain = domain
        self.mutationKind = mutationKind
        self.targetRequirement = targetRequirement
        self.capabilities = capabilities
        self.tags = tags
        self.arguments = arguments
        self.result = result
        self.palette = palette
    }

    var id: String {
        method
    }

    /// Title shown in the palette: the palette override when present, else
    /// the descriptor title.
    var paletteTitle: String {
        palette?.title ?? title
    }

    /// Title in a noun-bound verbs frame, where a verb can read differently
    /// ("New note here…" once a folder is the subject).
    var paletteBoundTitle: String {
        palette?.boundTitle ?? paletteTitle
    }

    /// The first argument the palette must collect before this action can
    /// run: a required argument with a picker, or any picker-bearing argument
    /// when none is required. Nil means the action runs immediately.
    func paletteArgumentToCollect(given suppliedArgs: [String: ActionValue]) -> ActionArgumentDescriptor? {
        let candidates = arguments.filter { $0.picker != nil && suppliedArgs[$0.name] == nil }
        return candidates.first(where: \.isRequired) ?? candidates.first
    }
}
