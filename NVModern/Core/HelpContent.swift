import Foundation

/// Portable, data-only content shared by native discovery and the React detail renderer.
struct HelpProvider: Codable, Equatable {
    var id: String
    var title: String
    var topics: [HelpTopic]
}

struct HelpTopic: Codable, Equatable {
    struct Example: Codable, Equatable {
        var code: String
        var result: String?
    }
    struct Insertion: Codable, Equatable {
        var id: String
        var label: String
        var template: String
    }
    struct Shortcut: Codable, Equatable {
        var keys: String
        var action: String
    }
    var id: String
    var title: String
    var category: String
    var summary: String
    var keywords: [String]
    var signatures: [String]
    var aliases: [String]
    var examples: [Example]
    var insertions: [Insertion]
    var shortcuts: [Shortcut]?

    func matches(_ query: String) -> Bool {
        let text = ([title, category, summary] + keywords + aliases + signatures).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }
}
