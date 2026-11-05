import Foundation

indirect enum ActionValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ActionValue])
    case object([String: ActionValue])

    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case null
        case bool
        case int
        case double
        case string
        case array
        case object
    }

    var kind: Kind {
        switch self {
        case .null: return .null
        case .bool: return .bool
        case .int: return .int
        case .double: return .double
        case .string: return .string
        case .array: return .array
        case .object: return .object
        }
    }

    var objectValue: [String: ActionValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [ActionValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    init(_ value: Any?) {
        guard let value else {
            self = .null
            return
        }

        switch value {
        case let actionValue as ActionValue:
            self = actionValue
        case is NSNull:
            self = .null
        // Foundation/JSC boxes 0 and 1 as NSNumber, which also cast to Bool.
        // Inspect boxed identity before Swift's scalar bridging casts.
        case let number as NSNumber where type(of: value) is NSNumber.Type:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.rounded(.towardZero) == number.doubleValue {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let float as Float:
            self = .double(Double(float))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.rounded(.towardZero) == number.doubleValue {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map(ActionValue.init))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(ActionValue.init))
        default:
            self = .string(String(describing: value))
        }
    }

    func jsonObject() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.jsonObject() }
        case .object(let values):
            return values.mapValues { $0.jsonObject() }
        }
    }

    static func fromEncodable<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> ActionValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(ActionValue.self, from: data)
    }

    static func object(_ pairs: [(String, ActionValue)]) -> ActionValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKeys.self) {
            var object: [String: ActionValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(ActionValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [ActionValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(ActionValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported action value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKeys.self)
            for key in values.keys.sorted() {
                guard let codingKey = DynamicCodingKeys(stringValue: key),
                      let value = values[key]
                else {
                    continue
                }
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

extension ActionValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self = .null
    }
}

extension ActionValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension ActionValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension ActionValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension ActionValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ActionValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: ActionValue...) {
        self = .array(elements)
    }
}

extension ActionValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, ActionValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
