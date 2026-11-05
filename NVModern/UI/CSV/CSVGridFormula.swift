import Foundation
import JavaScriptCore

struct CSVGridFormulaColumnBinding {
    let column: Int
    let title: String
    let alias: String
}

enum CSVGridFormulaComputedValue {
    case evaluating
    case value(String)
    case error(String)
}

enum CSVGridFormula {
    static func expression(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.count > 4 else {
            return nil
        }
        return String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func columnBindings(columns: [CSVGridDocument.Column]) -> [CSVGridFormulaColumnBinding] {
        var usedAliases = Set<String>()
        return columns.enumerated().map { index, column in
            let baseAlias = makeJavaScriptIdentifier(from: column.title, fallback: "column\(index + 1)")
            var alias = baseAlias
            var suffix = 2
            while usedAliases.contains(alias) {
                alias = "\(baseAlias)_\(suffix)"
                suffix += 1
            }
            usedAliases.insert(alias)
            return CSVGridFormulaColumnBinding(column: index, title: column.title, alias: alias)
        }
    }

    static func referencedColumns(in expression: String, bindings: [CSVGridFormulaColumnBinding]) -> Set<Int> {
        let aliasToColumn = Dictionary(uniqueKeysWithValues: bindings.map { ($0.alias, $0.column) })
        let titleToColumn = Dictionary(uniqueKeysWithValues: bindings.map { ($0.title, $0.column) })
        var referencedColumns = Set<Int>()

        if let rowReferenceRegex = try? NSRegularExpression(pattern: #"row\s*\[\s*([\"'])(.*?)\1\s*\]"#) {
            let nsExpression = expression as NSString
            let matches = rowReferenceRegex.matches(in: expression, range: NSRange(location: 0, length: nsExpression.length))
            for match in matches where match.numberOfRanges > 2 {
                let title = nsExpression.substring(with: match.range(at: 2))
                if let column = titleToColumn[title] {
                    referencedColumns.insert(column)
                }
            }
        }

        if let identifierRegex = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#) {
            let reservedNames: Set<String> = [
                "row", "Math", "true", "false", "null", "undefined", "NaN", "Infinity",
                "Number", "String", "Boolean", "Date", "Array", "Object", "JSON",
                "min", "max", "round", "concat", "coalesce", "iff"
            ]
            let nsExpression = expression as NSString
            let matches = identifierRegex.matches(in: expression, range: NSRange(location: 0, length: nsExpression.length))
            for match in matches {
                let token = nsExpression.substring(with: match.range)
                guard !reservedNames.contains(token), let column = aliasToColumn[token] else { continue }
                referencedColumns.insert(column)
            }
        }

        return referencedColumns
    }

    static func makeJavaScriptIdentifier(from title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let scalarView = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        var identifier = String(scalarView)
        while identifier.contains("__") {
            identifier = identifier.replacingOccurrences(of: "__", with: "_")
        }
        identifier = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if identifier.isEmpty { identifier = fallback }
        if let first = identifier.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            identifier = "_\(identifier)"
        }
        return identifier
    }

    static func primitive(from value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.caseInsensitiveCompare("true") == .orderedSame { return true }
        if trimmed.caseInsensitiveCompare("false") == .orderedSame { return false }
        if let number = Double(trimmed) { return number }
        return value
    }
}

enum CSVGridFormulaEngine {
    enum FormulaError: LocalizedError {
        case evaluationFailed(String)

        var errorDescription: String? {
            switch self {
            case .evaluationFailed(let message): return message
            }
        }
    }

    static func evaluate(expression: String, row: [String: Any], globals: [String: Any]) throws -> String {
        guard let context = JSContext() else {
            throw FormulaError.evaluationFailed("JavaScript context unavailable")
        }

        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        context.evaluateScript("""
        const min = (...values) => Math.min(...values);
        const max = (...values) => Math.max(...values);
        const round = (value, digits = 0) => {
          const factor = Math.pow(10, digits);
          return Math.round(value * factor) / factor;
        };
        const concat = (...parts) => parts.filter((part) => part !== null && part !== undefined).join(\"\");
        const coalesce = (...parts) => {
          for (const part of parts) {
            if (part !== null && part !== undefined && part !== \"\") return part;
          }
          return \"\";
        };
        const iff = (condition, truthy, falsy) => condition ? truthy : falsy;
        """)

        context.setObject(row, forKeyedSubscript: "row" as NSString)
        for (name, value) in globals {
            context.setObject(value, forKeyedSubscript: name as NSString)
        }

        let wrappedExpression = "(() => { 'use strict'; return (\(expression)); })()"
        guard let result = context.evaluateScript(wrappedExpression) else {
            throw FormulaError.evaluationFailed(exceptionMessage ?? "Formula did not return a value")
        }
        if let exceptionMessage {
            throw FormulaError.evaluationFailed(exceptionMessage)
        }
        if result.isUndefined || result.isNull { return "" }
        if result.isBoolean { return result.toBool() ? "true" : "false" }
        if result.isNumber {
            let numericValue = result.toDouble()
            if numericValue.isFinite, numericValue.rounded(.towardZero) == numericValue {
                return String(Int64(numericValue))
            }
            return String(numericValue)
        }
        if result.isString { return result.toString() }
        if let array = result.toArray() {
            return array.map { String(describing: $0) }.joined(separator: ", ")
        }
        return result.toString()
    }
}
