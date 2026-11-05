import Foundation

enum ArborKernelProtocolVersion {
    static let current = "arbor-kernel/1"
}

struct ArborKernelDocument: Codable, Equatable, Sendable {
    var id: String?
    var path: String
    var revision: Int
    var source: String

    init(id: String? = nil, path: String, revision: Int, source: String) {
        self.id = id
        self.path = path
        self.revision = revision
        self.source = source
    }
}

struct ArborKernelIntent: Codable, Equatable, Sendable {
    var op: String
    var text: String
}

struct ArborKernelEffectOutcome: Codable, Equatable, Sendable {
    var ok: Bool
    var value: ArborKernelJSONValue?
    var message: String?
}

struct ArborKernelRequest: Encodable, Equatable, Sendable {
    var protocolVersion: String
    var id: String
    var operation: String
    var document: ArborKernelDocument
    var previousDerivedUIDs: [String]
    var documentID: String?
    var queryID: String?
    var producerID: String?
    var mode: String?
    var arguments: [String: ArborKernelJSONValue]?
    var resultID: String?
    var intent: ArborKernelIntent?
    var executionID: String?
    var effectOutcome: ArborKernelEffectOutcome?

    init(
        id: String = UUID().uuidString,
        document: ArborKernelDocument,
        previousDerivedUIDs: [String] = []
    ) {
        protocolVersion = ArborKernelProtocolVersion.current
        self.id = id
        operation = "evaluate"
        self.document = document
        self.previousDerivedUIDs = previousDerivedUIDs
        documentID = nil
        queryID = nil
        producerID = nil
        mode = nil
        arguments = nil
        resultID = nil
        intent = nil
        executionID = nil
        effectOutcome = nil
    }

    private init(
        protocolVersion: String,
        id: String,
        operation: String,
        document: ArborKernelDocument,
        previousDerivedUIDs: [String],
        documentID: String?,
        queryID: String?,
        producerID: String?,
        mode: String?,
        arguments: [String: ArborKernelJSONValue]?,
        resultID: String? = nil,
        intent: ArborKernelIntent? = nil,
        executionID: String? = nil,
        effectOutcome: ArborKernelEffectOutcome? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.operation = operation
        self.document = document
        self.previousDerivedUIDs = previousDerivedUIDs
        self.documentID = documentID
        self.queryID = queryID
        self.producerID = producerID
        self.mode = mode
        self.arguments = arguments
        self.resultID = resultID
        self.intent = intent
        self.executionID = executionID
        self.effectOutcome = effectOutcome
    }

    static func replaceDocument(
        id: String = UUID().uuidString,
        document: ArborKernelDocument
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "document/replace",
            document: document,
            previousDerivedUIDs: [],
            documentID: nil,
            queryID: nil,
            producerID: nil,
            mode: nil,
            arguments: nil
        )
    }

    static func runQuery(
        id: String = UUID().uuidString,
        documentID: String,
        revision: Int,
        queryID: String,
        arguments: [String: ArborKernelJSONValue] = [:]
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "query/run",
            document: ArborKernelDocument(path: "", revision: revision, source: ""),
            previousDerivedUIDs: [],
            documentID: documentID,
            queryID: queryID,
            producerID: nil,
            mode: nil,
            arguments: arguments
        )
    }

    static func getView(
        id: String = UUID().uuidString,
        documentID: String,
        revision: Int,
        queryID: String? = nil,
        arguments: [String: ArborKernelJSONValue] = [:]
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "view/get",
            document: ArborKernelDocument(path: "", revision: revision, source: ""),
            previousDerivedUIDs: [],
            documentID: documentID,
            queryID: queryID,
            producerID: nil,
            mode: nil,
            arguments: arguments
        )
    }

    static func runProducer(
        id: String = UUID().uuidString,
        documentID: String,
        revision: Int,
        producerID: String,
        mode: String,
        arguments: [String: ArborKernelJSONValue] = [:]
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "producer/run",
            document: ArborKernelDocument(path: "", revision: revision, source: ""),
            previousDerivedUIDs: [],
            documentID: documentID,
            queryID: nil,
            producerID: producerID,
            mode: mode,
            arguments: arguments
        )
    }

    static func applyIntent(
        id: String = UUID().uuidString,
        documentID: String,
        revision: Int,
        resultID: String,
        intent: ArborKernelIntent
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "intent/apply",
            document: ArborKernelDocument(path: "", revision: revision, source: ""),
            previousDerivedUIDs: [],
            documentID: documentID,
            queryID: nil,
            producerID: nil,
            mode: nil,
            arguments: nil,
            resultID: resultID,
            intent: intent
        )
    }

    static func completeEffect(
        id: String = UUID().uuidString,
        executionID: String,
        outcome: ArborKernelEffectOutcome
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "effect/complete",
            document: ArborKernelDocument(path: "", revision: 0, source: ""),
            previousDerivedUIDs: [],
            documentID: nil,
            queryID: nil,
            producerID: nil,
            mode: nil,
            arguments: nil,
            executionID: executionID,
            effectOutcome: outcome
        )
    }

    static func cancelEffect(
        id: String = UUID().uuidString,
        executionID: String
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "effect/cancel",
            document: ArborKernelDocument(path: "", revision: 0, source: ""),
            previousDerivedUIDs: [],
            documentID: nil,
            queryID: nil,
            producerID: nil,
            mode: nil,
            arguments: nil,
            executionID: executionID
        )
    }

    static func completeMutation(
        id: String = UUID().uuidString,
        executionID: String,
        outcome: ArborKernelEffectOutcome
    ) -> ArborKernelRequest {
        ArborKernelRequest(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: "mutation/complete",
            document: ArborKernelDocument(path: "", revision: 0, source: ""),
            previousDerivedUIDs: [],
            documentID: nil,
            queryID: nil,
            producerID: nil,
            mode: nil,
            arguments: nil,
            executionID: executionID,
            effectOutcome: outcome
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id
        case operation = "op"
        case document
        case previousDerivedUIDs
        case documentID
        case revision
        case queryID
        case producerID
        case mode
        case arguments
        case resultID
        case intent
        case executionID
        case effectOutcome = "outcome"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(id, forKey: .id)
        try container.encode(operation, forKey: .operation)
        switch operation {
        case "evaluate":
            try container.encode(document, forKey: .document)
            try container.encode(previousDerivedUIDs, forKey: .previousDerivedUIDs)
        case "document/replace":
            try container.encode(document, forKey: .document)
        case "query/run":
            try container.encode(documentID, forKey: .documentID)
            try container.encode(document.revision, forKey: .revision)
            try container.encode(queryID, forKey: .queryID)
            try container.encode(arguments ?? [:], forKey: .arguments)
        case "view/get":
            try container.encode(documentID, forKey: .documentID)
            try container.encode(document.revision, forKey: .revision)
            try container.encodeIfPresent(queryID, forKey: .queryID)
            try container.encode(arguments ?? [:], forKey: .arguments)
        case "producer/run":
            try container.encode(documentID, forKey: .documentID)
            try container.encode(document.revision, forKey: .revision)
            try container.encode(producerID, forKey: .producerID)
            try container.encode(mode, forKey: .mode)
            try container.encode(arguments ?? [:], forKey: .arguments)
        case "intent/apply":
            try container.encode(documentID, forKey: .documentID)
            try container.encode(document.revision, forKey: .revision)
            try container.encode(resultID, forKey: .resultID)
            try container.encode(intent, forKey: .intent)
        case "effect/complete", "mutation/complete":
            try container.encode(executionID, forKey: .executionID)
            try container.encode(effectOutcome, forKey: .effectOutcome)
        case "effect/cancel":
            try container.encode(executionID, forKey: .executionID)
        default:
            try container.encode(document, forKey: .document)
        }
    }
}

struct ArborKernelResponseDocument: Codable, Equatable, Sendable {
    var id: String?
    var path: String
    var revision: Int?
    var source: String?

    init(id: String? = nil, path: String, revision: Int? = nil, source: String? = nil) {
        self.id = id
        self.path = path
        self.revision = revision
        self.source = source
    }
}

struct ArborKernelBlock: Codable, Equatable, Sendable {
    var uid: String
    var depth: Int
    var body: String
    var line: Int
    var parentUID: String?
}

struct ArborKernelDiagnostic: Codable, Equatable, Sendable {
    var severity: String
    var code: String
    var message: String
    var line: Int?
    var column: Int?
}

struct ArborKernelPatch: Codable, Equatable, Sendable {
    var operation: String
    var uid: String
    var revision: Int
    var value: ArborKernelJSONValue?
    var display: String?

    private enum CodingKeys: String, CodingKey {
        case operation = "op"
        case uid
        case revision
        case value
        case display
    }
}

struct ArborKernelQueryDeclaration: Codable, Equatable, Sendable {
    var uid: String
    var revision: Int
    var source: String
}

struct ArborKernelViewCell: Codable, Equatable, Sendable {
    var kind: String
    var value: ArborKernelJSONValue?
    var display: String
    var blockID: String?
    var documentID: String?
    var path: String?
    var markdown: String?
}

struct ArborKernelViewRow: Codable, Equatable, Sendable {
    var id: String
    var cells: [ArborKernelViewCell]
}

struct ArborKernelViewResult: Codable, Equatable, Sendable {
    var id: String
    var producerID: String
    var kind: String
    var presentation: String
    var status: String
    var display: String?
    var value: ArborKernelJSONValue?
    var inputs: [String]
    var columns: [String]
    var rows: [ArborKernelViewRow]
    var diagnostics: [ArborKernelDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case id
        case producerID
        case kind
        case presentation
        case status
        case display
        case value
        case inputs
        case columns
        case rows
        case diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        producerID = try container.decode(String.self, forKey: .producerID)
        kind = try container.decode(String.self, forKey: .kind)
        presentation = try container.decode(String.self, forKey: .presentation)
        status = try container.decode(String.self, forKey: .status)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        value = try container.decodeIfPresent(ArborKernelJSONValue.self, forKey: .value)
        inputs = try container.decodeIfPresent([String].self, forKey: .inputs) ?? []
        columns = try container.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try container.decodeIfPresent([ArborKernelViewRow].self, forKey: .rows) ?? []
        diagnostics = try container.decodeIfPresent([ArborKernelDiagnostic].self, forKey: .diagnostics) ?? []
    }
}

struct ArborKernelProducerResult: Codable, Equatable, Sendable {
    var key: String
    var markdown: String
    var origin: ArborKernelOrigin?
    var updatePolicy: String?

    init(
        key: String,
        markdown: String,
        origin: ArborKernelOrigin? = nil,
        updatePolicy: String? = nil
    ) {
        self.key = key
        self.markdown = markdown
        self.origin = origin
        self.updatePolicy = updatePolicy
    }
}

struct ArborKernelOrigin: Codable, Equatable, Sendable {
    var blockID: String
    var documentID: String
    var path: String
}

struct ArborKernelEffectCapability: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var resource: String
    var summary: String
}

struct ArborKernelEffect: Codable, Equatable, Sendable {
    var executionID: String
    var handler: String
    var arguments: [ArborKernelJSONValue]
    var capability: ArborKernelEffectCapability?
    var limits: ArborKernelEffectLimits
}

struct ArborKernelEffectLimits: Codable, Equatable, Sendable {
    var timeoutMs: Int
    var maxOutputBytes: Int
}

struct ArborKernelMutation: Codable, Equatable, Sendable {
    var executionID: String
    var summary: [String]
    var operationCount: Int
    var destructive: Bool
    var capability: ArborKernelEffectCapability
    var expectedSource: String
    var document: ArborKernelDocument
}

struct ArborKernelResponse: Codable, Equatable, Sendable {
    var protocolVersion: String
    var id: String
    var operation: String?
    var ok: Bool
    var revision: Int
    var acceptedRevision: Int?
    var worldRevision: Int?
    var documentID: String?
    var outcome: String?
    var document: ArborKernelResponseDocument?
    var blocks: [ArborKernelBlock]
    var patches: [ArborKernelPatch]
    var queries: [ArborKernelQueryDeclaration]
    var factCount: Int?
    var queryIDs: [String]
    var queryID: String?
    var columns: [String]
    var rows: [[ArborKernelJSONValue]]
    var views: [ArborKernelViewResult]
    var producerID: String?
    var kind: String?
    var mode: String?
    var generation: Int?
    var inputHash: String?
    var results: [ArborKernelProducerResult]
    var status: String?
    var effect: ArborKernelEffect?
    var mutation: ArborKernelMutation?
    var origin: ArborKernelOrigin?
    var text: String?
    var expectedSource: String?
    var diagnostics: [ArborKernelDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id
        case operation = "op"
        case ok
        case revision
        case acceptedRevision
        case worldRevision
        case documentID
        case outcome
        case document
        case blocks
        case patches
        case queries
        case factCount
        case queryIDs
        case queryID
        case columns
        case rows
        case views
        case producerID
        case kind
        case mode
        case generation
        case inputHash
        case results
        case status
        case effect
        case mutation
        case origin
        case text
        case expectedSource
        case diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        id = try container.decode(String.self, forKey: .id)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        ok = try container.decode(Bool.self, forKey: .ok)
        revision = try container.decode(Int.self, forKey: .revision)
        acceptedRevision = try container.decodeIfPresent(Int.self, forKey: .acceptedRevision)
        worldRevision = try container.decodeIfPresent(Int.self, forKey: .worldRevision)
        documentID = try container.decodeIfPresent(String.self, forKey: .documentID)
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        document = try container.decodeIfPresent(ArborKernelResponseDocument.self, forKey: .document)
        blocks = try container.decodeIfPresent([ArborKernelBlock].self, forKey: .blocks) ?? []
        patches = try container.decodeIfPresent([ArborKernelPatch].self, forKey: .patches) ?? []
        queries = try container.decodeIfPresent([ArborKernelQueryDeclaration].self, forKey: .queries) ?? []
        factCount = try container.decodeIfPresent(Int.self, forKey: .factCount)
        queryIDs = try container.decodeIfPresent([String].self, forKey: .queryIDs) ?? []
        queryID = try container.decodeIfPresent(String.self, forKey: .queryID)
        columns = try container.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try container.decodeIfPresent([[ArborKernelJSONValue]].self, forKey: .rows) ?? []
        views = try container.decodeIfPresent([ArborKernelViewResult].self, forKey: .views) ?? []
        producerID = try container.decodeIfPresent(String.self, forKey: .producerID)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation)
        inputHash = try container.decodeIfPresent(String.self, forKey: .inputHash)
        results = try container.decodeIfPresent([ArborKernelProducerResult].self, forKey: .results) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status)
        effect = try container.decodeIfPresent(ArborKernelEffect.self, forKey: .effect)
        mutation = try container.decodeIfPresent(ArborKernelMutation.self, forKey: .mutation)
        origin = try container.decodeIfPresent(ArborKernelOrigin.self, forKey: .origin)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        expectedSource = try container.decodeIfPresent(String.self, forKey: .expectedSource)
        diagnostics = try container.decodeIfPresent([ArborKernelDiagnostic].self, forKey: .diagnostics) ?? []
    }

    init(
        protocolVersion: String,
        id: String,
        operation: String? = nil,
        ok: Bool,
        revision: Int,
        acceptedRevision: Int? = nil,
        worldRevision: Int? = nil,
        documentID: String? = nil,
        outcome: String? = nil,
        document: ArborKernelResponseDocument? = nil,
        blocks: [ArborKernelBlock] = [],
        patches: [ArborKernelPatch] = [],
        queries: [ArborKernelQueryDeclaration] = [],
        factCount: Int? = nil,
        queryIDs: [String] = [],
        queryID: String? = nil,
        columns: [String] = [],
        rows: [[ArborKernelJSONValue]] = [],
        views: [ArborKernelViewResult] = [],
        producerID: String? = nil,
        kind: String? = nil,
        mode: String? = nil,
        generation: Int? = nil,
        inputHash: String? = nil,
        results: [ArborKernelProducerResult] = [],
        status: String? = nil,
        effect: ArborKernelEffect? = nil,
        mutation: ArborKernelMutation? = nil,
        origin: ArborKernelOrigin? = nil,
        text: String? = nil,
        expectedSource: String? = nil,
        diagnostics: [ArborKernelDiagnostic] = []
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.operation = operation
        self.ok = ok
        self.revision = revision
        self.acceptedRevision = acceptedRevision
        self.worldRevision = worldRevision
        self.documentID = documentID
        self.outcome = outcome
        self.document = document
        self.blocks = blocks
        self.patches = patches
        self.queries = queries
        self.factCount = factCount
        self.queryIDs = queryIDs
        self.queryID = queryID
        self.columns = columns
        self.rows = rows
        self.views = views
        self.producerID = producerID
        self.kind = kind
        self.mode = mode
        self.generation = generation
        self.inputHash = inputHash
        self.results = results
        self.status = status
        self.effect = effect
        self.mutation = mutation
        self.origin = origin
        self.text = text
        self.expectedSource = expectedSource
        self.diagnostics = diagnostics
    }

    static func failure(
        id: String,
        operation: String? = nil,
        revision: Int,
        path: String,
        code: String,
        message: String
    ) -> ArborKernelResponse {
        ArborKernelResponse(
            protocolVersion: ArborKernelProtocolVersion.current,
            id: id,
            operation: operation,
            ok: false,
            revision: revision,
            document: ArborKernelResponseDocument(path: path),
            blocks: [],
            patches: [],
            queries: [],
            diagnostics: [
                ArborKernelDiagnostic(
                    severity: "error",
                    code: code,
                    message: message,
                    line: nil,
                    column: nil
                )
            ]
        )
    }
}

enum ArborKernelJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ArborKernelJSONValue])
    case object([String: ArborKernelJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ArborKernelJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ArborKernelJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Arbor kernel JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
