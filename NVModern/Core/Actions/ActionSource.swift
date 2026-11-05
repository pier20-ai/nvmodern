import Foundation

struct ActionSource: Codable, Hashable, Sendable {
    let kind: Kind
    let identifier: String?
    let metadata: [String: ActionValue]

    init(kind: Kind, identifier: String? = nil, metadata: [String: ActionValue] = [:]) {
        self.kind = kind
        self.identifier = identifier
        self.metadata = metadata
    }

    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case internalCall = "internal"
        case keybinding
        case menu
        case socket
        case webBridge
        case automation
        case test
    }

    static let internalCall = ActionSource(kind: .internalCall)

    static func socket(client: String, identifier: String? = nil) -> ActionSource {
        ActionSource(
            kind: .socket,
            identifier: identifier,
            metadata: ["client": .string(client)]
        )
    }

    func asSocketSource() -> ActionSource {
        ActionSource(kind: .socket, identifier: identifier, metadata: metadata)
    }
}

extension ActionSource {
    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        metadata = try container.decodeIfPresent([String: ActionValue].self, forKey: .metadata) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}
