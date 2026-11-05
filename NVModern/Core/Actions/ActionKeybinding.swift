import Foundation

struct ActionKeybindingDefinition: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String?
    let keystroke: String
    let invocation: ActionInvocationReference
    let when: String?

    var identity: String { id }
}

enum ActionInvocationReference: Codable, Hashable, Sendable {
    case method(method: String, args: [String: ActionValue], target: ActionTarget?)
}

extension ActionInvocationReference {
    var methodName: String? {
        guard case .method(let method, _, _) = self else { return nil }
        return method
    }
}

extension ActionInvocationReference {
    private enum CodingKeys: String, CodingKey {
        case kind
        case method
        case args
        case target
        case id
    }

    private enum Kind: String, Codable {
        case method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .method:
            self = .method(
                method: try container.decode(String.self, forKey: .method),
                args: try container.decodeIfPresent([String: ActionValue].self, forKey: .args) ?? [:],
                target: try container.decodeIfPresent(ActionTarget.self, forKey: .target)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .method(let method, let args, let target):
            try container.encode(Kind.method, forKey: .kind)
            try container.encode(method, forKey: .method)
            if !args.isEmpty {
                try container.encode(args, forKey: .args)
            }
            try container.encodeIfPresent(target, forKey: .target)
        }
    }
}
