import Foundation

struct ArborDocumentPreparation: Equatable, Sendable {
    let source: String
    let insertedLanguageDirective: Bool
}

enum ArborDocumentSource {
    static let pathExtension = "outline"
    static let languageDirective = "#lang arbor/0"

    static func isOutlinePath(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == pathExtension
    }

    static func hasLanguageDirective(_ source: String) -> Bool {
        let sourceWithoutBOM = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        let firstLine = sourceWithoutBOM.components(separatedBy: .newlines).first ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces) == languageDirective
    }

    static func prepareForOpen(path: String, source: String) -> ArborDocumentPreparation {
        guard isOutlinePath(path), !hasLanguageDirective(source) else {
            return ArborDocumentPreparation(source: source, insertedLanguageDirective: false)
        }

        return ArborDocumentPreparation(
            source: source.isEmpty ? "\(languageDirective)\n" : "\(languageDirective)\n\(source)",
            insertedLanguageDirective: true
        )
    }
}
