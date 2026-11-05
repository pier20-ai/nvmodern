import Foundation

enum SearchSyntaxKind: Hashable {
    case plainTerm
    case quotedPhrase
    case facetKey
    case facetValue
    case unknownFacetKey
    case punctuation
}

struct SearchSyntaxSpan: Hashable {
    let range: NSRange
    let kind: SearchSyntaxKind
}

struct SearchFacetFilter: Hashable {
    let key: String
    let value: String
}

struct SearchQueryTerm: Hashable {
    let text: String
    let isQuotedPhrase: Bool
}

enum SearchCompletionContext: Hashable {
    case term(prefix: String, replacementRange: NSRange)
    case facetKey(prefix: String, replacementRange: NSRange)
    case facetValue(key: String, prefix: String, replacementRange: NSRange)
}

struct NoteSearchParsedQuery: Hashable {
    let rawQuery: String
    let searchTerms: [SearchQueryTerm]
    let facets: [SearchFacetFilter]
    let syntaxSpans: [SearchSyntaxSpan]
    let completionContext: SearchCompletionContext?

    var terms: [String] {
        searchTerms.map(\.text)
    }
}

struct NoteSearchSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case facetKey
        case facetValue
        case file
    }

    let kind: Kind
    let label: String
    let insertText: String
    let detail: String?
    let replacementRange: NSRange

    var id: String {
        "\(kind)-\(replacementRange.location)-\(replacementRange.length)-\(insertText)"
    }
}

struct NoteSearchIndexStatus: Hashable {
    enum Phase: String, Hashable {
        case ready
        case rebuilding
        case catchingUp
        case liveUpdatePending
        case failed
    }

    let phase: Phase
    let isStale: Bool
    let activeGeneration: Int
    let completedGeneration: Int
    let message: String?
    /// Documents committed so far by the running rebuild, when one is running.
    let indexedCount: Int?
    /// Documents the running rebuild has to get through in total.
    let totalCount: Int?

    init(
        phase: Phase,
        isStale: Bool,
        activeGeneration: Int,
        completedGeneration: Int,
        message: String?,
        indexedCount: Int? = nil,
        totalCount: Int? = nil
    ) {
        self.phase = phase
        self.isStale = isStale
        self.activeGeneration = activeGeneration
        self.completedGeneration = completedGeneration
        self.message = message
        self.indexedCount = indexedCount
        self.totalCount = totalCount
    }

    static let ready = NoteSearchIndexStatus(
        phase: .ready,
        isStale: false,
        activeGeneration: 0,
        completedGeneration: 0,
        message: nil
    )

    var isBusy: Bool {
        switch phase {
        case .rebuilding, .catchingUp, .liveUpdatePending:
            return true
        case .ready, .failed:
            return false
        }
    }
}

struct NoteSearchResponse: Hashable {
    let results: [NoteSearchResult]
    let suggestions: [NoteSearchSuggestion]
    let indexStatus: NoteSearchIndexStatus
}

enum SearchQueryParser {
    static func parse(query: String, cursorLocationUTF16: Int? = nil, supportedFacetKeys: [String]) -> NoteSearchParsedQuery {
        let supportedFacetKeySet = Set(supportedFacetKeys.map { $0.lowercased() })
        let nsQuery = query as NSString
        let length = nsQuery.length
        let clampedCursor = cursorLocationUTF16.map { max(0, min(length, $0)) }

        var syntaxSpans: [SearchSyntaxSpan] = []
        var facets: [SearchFacetFilter] = []
        var searchTerms: [SearchQueryTerm] = []
        var completionContext: SearchCompletionContext?
        var index = 0

        while index < length {
            while index < length, CharacterSet.whitespacesAndNewlines.contains(scalar(at: nsQuery, index: index)) {
                index += 1
            }
            guard index < length else { break }

            let tokenStart = index
            let startsWithQuote = nsQuery.substring(with: NSRange(location: index, length: 1)) == "\""
            if startsWithQuote {
                index += 1
                while index < length, nsQuery.substring(with: NSRange(location: index, length: 1)) != "\"" {
                    index += 1
                }
                if index < length {
                    index += 1
                }
            } else {
                while index < length, !CharacterSet.whitespacesAndNewlines.contains(scalar(at: nsQuery, index: index)) {
                    index += 1
                }
            }

            let tokenRange = NSRange(location: tokenStart, length: index - tokenStart)
            guard tokenRange.length > 0 else { continue }

            let tokenText = nsQuery.substring(with: tokenRange)
            let cursorIsInsideToken = clampedCursor.map { $0 >= tokenRange.location && $0 <= NSMaxRange(tokenRange) } ?? false

            if tokenText.hasPrefix("\"") {
                let innerText = normalizePhraseToken(tokenText)
                syntaxSpans.append(SearchSyntaxSpan(range: tokenRange, kind: .quotedPhrase))
                if !innerText.isEmpty {
                    searchTerms.append(SearchQueryTerm(text: innerText, isQuotedPhrase: true))
                }
                if cursorIsInsideToken {
                    completionContext = .term(prefix: innerText, replacementRange: tokenRange)
                }
                continue
            }

            if let colonRange = tokenText.range(of: ":") {
                let keyText = String(tokenText[..<colonRange.lowerBound])
                let valueText = String(tokenText[colonRange.upperBound...])
                let normalizedKey = keyText.lowercased()
                let keyLength = (keyText as NSString).length
                let colonLocation = tokenRange.location + keyLength
                let valueLocation = colonLocation + 1
                let valueLength = max(0, tokenRange.length - keyLength - 1)
                let recognizedFacet = supportedFacetKeySet.contains(normalizedKey)

                let keyRange = NSRange(location: tokenRange.location, length: keyLength)
                let punctuationRange = NSRange(location: colonLocation, length: min(1, tokenRange.length - keyLength))
                let valueRange = NSRange(location: valueLocation, length: valueLength)

                syntaxSpans.append(
                    SearchSyntaxSpan(
                        range: keyRange,
                        kind: recognizedFacet ? .facetKey : .unknownFacetKey
                    )
                )
                if punctuationRange.length > 0 {
                    syntaxSpans.append(SearchSyntaxSpan(range: punctuationRange, kind: .punctuation))
                }
                if valueRange.length > 0 {
                    syntaxSpans.append(
                        SearchSyntaxSpan(
                            range: valueRange,
                            kind: recognizedFacet ? .facetValue : .plainTerm
                        )
                    )
                }

                let normalizedValue = normalizeFacetValue(valueText)
                if recognizedFacet, !normalizedValue.isEmpty {
                    facets.append(
                        SearchFacetFilter(
                            key: normalizedKey,
                            value: normalizedValue
                        )
                    )
                }

                if cursorIsInsideToken {
                    let cursor = clampedCursor ?? NSMaxRange(tokenRange)
                    if cursor <= colonLocation {
                        completionContext = .facetKey(prefix: keyText, replacementRange: tokenRange)
                    } else {
                        completionContext = .facetValue(
                            key: normalizedKey,
                            prefix: normalizedValue,
                            replacementRange: valueRange
                        )
                    }
                }
                continue
            }

            syntaxSpans.append(SearchSyntaxSpan(range: tokenRange, kind: .plainTerm))
            let normalizedTerm = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedTerm.isEmpty {
                searchTerms.append(SearchQueryTerm(text: normalizedTerm, isQuotedPhrase: false))
            }
            if cursorIsInsideToken {
                completionContext = .term(prefix: normalizedTerm, replacementRange: tokenRange)
            }
        }

        if completionContext == nil, let clampedCursor {
            completionContext = .term(prefix: "", replacementRange: NSRange(location: clampedCursor, length: 0))
        }

        return NoteSearchParsedQuery(
            rawQuery: query,
            searchTerms: searchTerms,
            facets: facets,
            syntaxSpans: syntaxSpans,
            completionContext: completionContext
        )
    }

    private static func normalizePhraseToken(_ tokenText: String) -> String {
        var normalized = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("\"") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("\"") {
            normalized.removeLast()
        }
        return compactWhitespace(normalized)
    }

    private static func normalizeFacetValue(_ valueText: String) -> String {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("\"") {
            return normalizePhraseToken(trimmed)
        }
        return trimmed
    }

    private static func compactWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scalar(at string: NSString, index: Int) -> UnicodeScalar {
        let value = string.character(at: index)
        return UnicodeScalar(value) ?? UnicodeScalar(32)
    }
}
