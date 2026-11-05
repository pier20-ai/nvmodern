import Foundation

/// Future-facing content surface abstractions for actions that operate *inside* notes.
///
/// The goal is to let the action system expose structured note content externally, not
/// just imperative app controls. These types are transport-safe and intentionally more
/// query-oriented than UI-oriented so they can back socket automation, interactive
/// markdown, semantic search, CSV joins, and future embeddings-based workflows.
struct ActionTextRange: Codable, Hashable, Sendable {
    let startLine: Int
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
}

enum ActionContentNodeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case document
    case frontmatter
    case heading
    case paragraph
    case blockquote
    case list
    case listItem
    case taskItem
    case wikilink
    case inlineLink
    case tag
    case mention
    case codeFence
    case table
    case transclusion
    case csvRow
    case csvCell
}

struct ActionContentAddress: Codable, Hashable, Sendable {
    let documentPath: String
    let nodeKind: ActionContentNodeKind
    let identifier: String?
    let headingSlug: String?
    let range: ActionTextRange?

    init(
        documentPath: String,
        nodeKind: ActionContentNodeKind,
        identifier: String? = nil,
        headingSlug: String? = nil,
        range: ActionTextRange? = nil
    ) {
        self.documentPath = documentPath
        self.nodeKind = nodeKind
        self.identifier = identifier
        self.headingSlug = headingSlug
        self.range = range
    }
}

struct ActionContentSelector: Codable, Hashable, Sendable {
    var documentPath: String?
    var nodeKinds: [ActionContentNodeKind]
    var headingSlug: String?
    var wikilinkTarget: String?
    var tag: String?
    var mention: String?
    var taskState: String?
    var frontmatterField: String?
    var textContains: String?

    init(
        documentPath: String? = nil,
        nodeKinds: [ActionContentNodeKind] = [],
        headingSlug: String? = nil,
        wikilinkTarget: String? = nil,
        tag: String? = nil,
        mention: String? = nil,
        taskState: String? = nil,
        frontmatterField: String? = nil,
        textContains: String? = nil
    ) {
        self.documentPath = documentPath
        self.nodeKinds = nodeKinds
        self.headingSlug = headingSlug
        self.wikilinkTarget = wikilinkTarget
        self.tag = tag
        self.mention = mention
        self.taskState = taskState
        self.frontmatterField = frontmatterField
        self.textContains = textContains
    }
}

struct ActionContentProjection: Codable, Hashable, Sendable {
    let fields: [String]
    let includeText: Bool
    let includeAttributes: Bool

    init(fields: [String] = [], includeText: Bool = false, includeAttributes: Bool = true) {
        self.fields = fields
        self.includeText = includeText
        self.includeAttributes = includeAttributes
    }
}

enum ActionContentJoinKind: String, Codable, CaseIterable, Hashable, Sendable {
    case inner
    case left
    case right
    case full
}

struct ActionContentJoinSpec: Codable, Hashable, Sendable {
    let leftField: String
    let rightField: String
    let kind: ActionContentJoinKind
}

struct ActionSemanticQuery: Codable, Hashable, Sendable {
    let text: String
    let modelIdentifier: String?
    let limit: Int?
    let minimumScore: Double?

    init(text: String, modelIdentifier: String? = nil, limit: Int? = nil, minimumScore: Double? = nil) {
        self.text = text
        self.modelIdentifier = modelIdentifier
        self.limit = limit
        self.minimumScore = minimumScore
    }
}

struct ActionContentQuery: Codable, Hashable, Sendable {
    let selector: ActionContentSelector
    let projection: ActionContentProjection?
    let semantic: ActionSemanticQuery?
    let join: ActionContentJoinSpec?
    let limit: Int?

    init(
        selector: ActionContentSelector,
        projection: ActionContentProjection? = nil,
        semantic: ActionSemanticQuery? = nil,
        join: ActionContentJoinSpec? = nil,
        limit: Int? = nil
    ) {
        self.selector = selector
        self.projection = projection
        self.semantic = semantic
        self.join = join
        self.limit = limit
    }
}

struct ActionContentNode: Codable, Hashable, Sendable {
    let address: ActionContentAddress
    let title: String?
    let text: String?
    let attributes: [String: ActionValue]
}

struct ActionContentRecord: Codable, Hashable, Sendable {
    let address: ActionContentAddress?
    let fields: [String: ActionValue]
}

struct ActionContentQueryResult: Codable, Hashable, Sendable {
    let records: [ActionContentRecord]
    let diagnostics: [String]

    static let empty = ActionContentQueryResult(records: [], diagnostics: [])
}

struct ActionContentSurfaceCapabilities: Codable, Hashable, Sendable {
    let supportsStructuralQueries: Bool
    let supportsSemanticQueries: Bool
    let supportsJoins: Bool
    let supportsWrites: Bool

    static let unavailable = ActionContentSurfaceCapabilities(
        supportsStructuralQueries: false,
        supportsSemanticQueries: false,
        supportsJoins: false,
        supportsWrites: false
    )
}

@MainActor
protocol ActionContentSurface {
    var capabilities: ActionContentSurfaceCapabilities { get }

    func fetchNode(at address: ActionContentAddress, target: ActionTarget) async throws -> ActionContentNode
    func runQuery(_ query: ActionContentQuery, target: ActionTarget) async throws -> ActionContentQueryResult
    func headingSubtree(
        documentPath: String,
        headingSlug: String,
        projection: ActionContentProjection?,
        includeHeading: Bool,
        target: ActionTarget
    ) async throws -> ActionContentQueryResult
    func backlinks(
        to targetPath: String,
        projection: ActionContentProjection?,
        includeTransclusions: Bool,
        limit: Int?,
        target: ActionTarget
    ) async throws -> ActionContentQueryResult
}
