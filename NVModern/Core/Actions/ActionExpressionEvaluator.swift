import Foundation

@MainActor
enum ActionExpressionEvaluator {
    static func evaluate(_ expression: String, variables: [String: ActionValue]) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return evaluateOr(trimmed, variables: variables)
    }

    static func resolveValue(path: String, variables: [String: ActionValue]) -> ActionValue? {
        let components = path.split(separator: ".").map(String.init)
        guard let first = components.first else { return nil }

        var current = variables[first]
        for component in components.dropFirst() {
            guard case .object(let object)? = current else { return nil }
            current = object[component]
        }
        return current
    }

    static func truthy(_ value: ActionValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null:
            return false
        case .bool(let bool):
            return bool
        case .int(let int):
            return int != 0
        case .double(let double):
            return double != 0
        case .string(let string):
            return !string.isEmpty
        case .array(let values):
            return !values.isEmpty
        case .object(let values):
            return !values.isEmpty
        }
    }

    private static func evaluateOr(_ expression: String, variables: [String: ActionValue]) -> Bool {
        let parts = splitTopLevel(expression, separator: "||")
        if parts.count > 1 {
            return parts.contains { evaluateAnd($0, variables: variables) }
        }
        return evaluateAnd(expression, variables: variables)
    }

    private static func evaluateAnd(_ expression: String, variables: [String: ActionValue]) -> Bool {
        let parts = splitTopLevel(expression, separator: "&&")
        if parts.count > 1 {
            return parts.allSatisfy { evaluateUnary($0, variables: variables) }
        }
        return evaluateUnary(expression, variables: variables)
    }

    private static func evaluateUnary(_ expression: String, variables: [String: ActionValue]) -> Bool {
        let trimmed = trimOuterParentheses(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("!") {
            return !evaluateUnary(String(trimmed.dropFirst()), variables: variables)
        }

        if let comparison = parseComparison(trimmed) {
            let lhs = resolveOperand(comparison.left, variables: variables)
            let rhs = resolveOperand(comparison.right, variables: variables)
            switch comparison.operator {
            case .equal:
                return lhs == rhs
            case .notEqual:
                return lhs != rhs
            }
        }

        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        return truthy(resolveOperand(trimmed, variables: variables))
    }

    private static func resolveOperand(_ operand: String, variables: [String: ActionValue]) -> ActionValue? {
        let trimmed = trimOuterParentheses(operand.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(String(trimmed.dropFirst().dropLast()))
        }

        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" { return .null }
        if let int = Int(trimmed) { return .int(int) }
        if let double = Double(trimmed) { return .double(double) }
        return resolveValue(path: trimmed, variables: variables)
    }

    private static func trimOuterParentheses(_ expression: String) -> String {
        var current = expression
        while current.hasPrefix("("), current.hasSuffix(")"), isWrappedByBalancedParentheses(current) {
            current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    private static func isWrappedByBalancedParentheses(_ expression: String) -> Bool {
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        for (index, character) in expression.enumerated() {
            switch character {
            case "\"" where !inSingleQuote:
                inDoubleQuote.toggle()
            case "'" where !inDoubleQuote:
                inSingleQuote.toggle()
            case "(" where !inSingleQuote && !inDoubleQuote:
                depth += 1
            case ")" where !inSingleQuote && !inDoubleQuote:
                depth -= 1
                if depth == 0 && index != expression.count - 1 {
                    return false
                }
            default:
                break
            }
        }

        return depth == 0 && !inSingleQuote && !inDoubleQuote
    }

    private static func splitTopLevel(_ expression: String, separator: String) -> [String] {
        var parts: [String] = []
        var start = expression.startIndex
        var index = expression.startIndex
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        while index < expression.endIndex {
            let character = expression[index]

            switch character {
            case "\"" where !inSingleQuote:
                inDoubleQuote.toggle()
            case "'" where !inDoubleQuote:
                inSingleQuote.toggle()
            case "(" where !inSingleQuote && !inDoubleQuote:
                depth += 1
            case ")" where !inSingleQuote && !inDoubleQuote:
                depth = max(0, depth - 1)
            default:
                break
            }

            if depth == 0, !inSingleQuote, !inDoubleQuote,
               expression[index...].hasPrefix(separator) {
                parts.append(String(expression[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                index = expression.index(index, offsetBy: separator.count)
                start = index
                continue
            }

            index = expression.index(after: index)
        }

        parts.append(String(expression[start..<expression.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func parseComparison(_ expression: String) -> (left: String, `operator`: ComparisonOperator, right: String)? {
        if let range = findTopLevelOperator("==", in: expression) {
            return (
                left: String(expression[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                operator: .equal,
                right: String(expression[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if let range = findTopLevelOperator("!=", in: expression) {
            return (
                left: String(expression[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                operator: .notEqual,
                right: String(expression[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return nil
    }

    private static func findTopLevelOperator(_ op: String, in expression: String) -> Range<String.Index>? {
        var index = expression.startIndex
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        while index < expression.endIndex {
            let character = expression[index]
            switch character {
            case "\"" where !inSingleQuote:
                inDoubleQuote.toggle()
            case "'" where !inDoubleQuote:
                inSingleQuote.toggle()
            case "(" where !inSingleQuote && !inDoubleQuote:
                depth += 1
            case ")" where !inSingleQuote && !inDoubleQuote:
                depth = max(0, depth - 1)
            default:
                break
            }

            if depth == 0, !inSingleQuote, !inDoubleQuote,
               expression[index...].hasPrefix(op) {
                let end = expression.index(index, offsetBy: op.count)
                return index..<end
            }

            index = expression.index(after: index)
        }

        return nil
    }

    private enum ComparisonOperator {
        case equal
        case notEqual
    }
}
