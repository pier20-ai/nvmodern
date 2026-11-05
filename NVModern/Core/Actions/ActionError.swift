import Foundation

struct ActionError: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: Code
    let message: String
    let details: [String: ActionValue]

    init(code: Code, message: String, details: [String: ActionValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    var errorDescription: String? {
        message
    }

    enum Code: String, Codable, CaseIterable, Hashable, Sendable {
        case unknownMethod = "unknown_method"
        case invalidArguments = "invalid_arguments"
        case invalidTarget = "invalid_target"
        case targetNotFound = "target_not_found"
        case capabilityDenied = "capability_denied"
        case unavailable = "unavailable"
        case notImplemented = "not_implemented"
        case decodeFailed = "decode_failed"
        case encodeFailed = "encode_failed"
        case executionFailed = "execution_failed"
    }

    static func unknownMethod(_ method: String) -> ActionError {
        ActionError(
            code: .unknownMethod,
            message: "Unknown action method: \(method)",
            details: ["method": .string(method)]
        )
    }

    static func invalidArguments(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .invalidArguments, message: message, details: details)
    }

    static func invalidTarget(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .invalidTarget, message: message, details: details)
    }

    static func targetNotFound(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .targetNotFound, message: message, details: details)
    }

    static func capabilityDenied(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .capabilityDenied, message: message, details: details)
    }

    static func unavailable(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .unavailable, message: message, details: details)
    }

    static func notImplemented(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .notImplemented, message: message, details: details)
    }

    static func decodeFailed(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .decodeFailed, message: message, details: details)
    }

    static func encodeFailed(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .encodeFailed, message: message, details: details)
    }

    static func executionFailed(_ message: String, details: [String: ActionValue] = [:]) -> ActionError {
        ActionError(code: .executionFailed, message: message, details: details)
    }
}
