import Foundation

struct ActionRequest: Codable, Hashable, Sendable {
    let id: String?
    let method: String
    let args: [String: ActionValue]
    let target: ActionTarget
    let source: ActionSource
    let metadata: [String: ActionValue]

    init(
        id: String? = nil,
        method: String,
        args: [String: ActionValue] = [:],
        target: ActionTarget = .automatic,
        source: ActionSource = .internalCall,
        metadata: [String: ActionValue] = [:]
    ) {
        self.id = id
        self.method = method
        self.args = args
        self.target = target
        self.source = source
        self.metadata = metadata
    }

    func decodeArgs<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(args)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ActionError.decodeFailed(
                "Could not decode arguments for method \(method): \(error.localizedDescription)",
                details: [
                    "method": .string(method),
                    "requestedType": .string(String(describing: T.self))
                ]
            )
        }
    }

    func withSocketSource() -> ActionRequest {
        ActionRequest(
            id: id,
            method: method,
            args: args,
            target: target,
            source: source.asSocketSource(),
            metadata: metadata
        )
    }
}

extension ActionRequest {
    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case args
        case target
        case source
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        args = try container.decodeIfPresent([String: ActionValue].self, forKey: .args) ?? [:]
        target = try container.decodeIfPresent(ActionTarget.self, forKey: .target) ?? .automatic
        source = try container.decodeIfPresent(ActionSource.self, forKey: .source) ?? .internalCall
        metadata = try container.decodeIfPresent([String: ActionValue].self, forKey: .metadata) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        if !args.isEmpty {
            try container.encode(args, forKey: .args)
        }
        try container.encode(target, forKey: .target)
        try container.encode(source, forKey: .source)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

struct ActionResponse: Codable, Hashable, Sendable {
    let id: String?
    let ok: Bool
    let result: ActionValue?
    let error: ActionError?

    static func success(id: String?, result: ActionValue) -> ActionResponse {
        ActionResponse(id: id, ok: true, result: result, error: nil)
    }

    static func failure(id: String?, error: ActionError) -> ActionResponse {
        ActionResponse(id: id, ok: false, result: nil, error: error)
    }
}
