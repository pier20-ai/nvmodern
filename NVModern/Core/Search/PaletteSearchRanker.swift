import Foundation

/// Shared, explainable ranking for the finite catalogs shown by the palette.
///
/// Ranking is ordinal rather than a weighted numeric blend. Every query term
/// gets its best field-local match; candidates compare their weakest term
/// first, then phrase/path coherence, then the provider's fallback rank.
enum PaletteSearchRanker {
    struct Candidate<ID: Hashable & Sendable>: Sendable {
        let id: ID
        let label: String
        /// General/root to specific/leaf.
        let items: [String]
        /// Secondary searchable fields. Values stay separate so fuzzy matches
        /// cannot jump between a title, keyword, category, and implementation ID.
        let properties: [String: [String]]
        /// Lower values win only after every search-relevance dimension ties.
        let fallbackRank: Int

        init(
            id: ID,
            label: String,
            items: [String],
            properties: [String: [String]] = [:],
            fallbackRank: Int = 100
        ) {
            self.id = id
            self.label = label
            self.items = items
            self.properties = properties
            self.fallbackRank = fallbackRank
        }
    }

    struct RankedCandidate<ID: Hashable & Sendable>: Sendable {
        let candidate: Candidate<ID>
        let rank: CandidateRank
        let matches: [MatchEvidence]
    }

    struct MatchEvidence: Hashable, Sendable {
        let term: String
        let fieldName: String
        let fieldValue: String
        let specificity: Specificity
    }

    enum Specificity: Int, Comparable, Hashable, Sendable {
        case fuzzy = 1
        case substring = 2
        case prefix = 3
        case exactToken = 4
        case exactField = 5

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct CandidateRank: Hashable, Sendable, Comparable {
        fileprivate let termRanks: [AtomicRank]
        fileprivate let coherence: Coherence
        fileprivate let fallback: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            for (left, right) in zip(lhs.termRanks, rhs.termRanks) where left != right {
                return left < right
            }
            if lhs.termRanks.count != rhs.termRanks.count {
                return lhs.termRanks.count < rhs.termRanks.count
            }
            if lhs.coherence != rhs.coherence { return lhs.coherence < rhs.coherence }
            return lhs.fallback < rhs.fallback
        }
    }

    fileprivate struct AtomicRank: Hashable, Sendable, Comparable {
        let specificity: Specificity
        /// Items are 2, properties are 1. Specificity is compared first, so an
        /// exact curated alias can still beat a prefix title.
        let locationKind: Int
        /// Items use negative distance from leaf; properties use declared priority.
        let locationDetail: Int
        let quality: Quality

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
            if lhs.locationKind != rhs.locationKind { return lhs.locationKind < rhs.locationKind }
            if lhs.locationDetail != rhs.locationDetail { return lhs.locationDetail < rhs.locationDetail }
            return lhs.quality < rhs.quality
        }
    }

    fileprivate struct Quality: Hashable, Sendable, Comparable {
        let first: Int
        let second: Int
        let third: Int
        let fourth: Int

        static let neutral = Quality(first: 0, second: 0, third: 0, fourth: 0)

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.first != rhs.first { return lhs.first < rhs.first }
            if lhs.second != rhs.second { return lhs.second < rhs.second }
            if lhs.third != rhs.third { return lhs.third < rhs.third }
            return lhs.fourth < rhs.fourth
        }
    }

    fileprivate struct Coherence: Hashable, Sendable, Comparable {
        let phraseSpecificity: Int
        let fieldOrder: Int
        let adjacentItems: Int

        static let none = Coherence(phraseSpecificity: 0, fieldOrder: 0, adjacentItems: 0)

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.phraseSpecificity != rhs.phraseSpecificity {
                return lhs.phraseSpecificity < rhs.phraseSpecificity
            }
            if lhs.fieldOrder != rhs.fieldOrder { return lhs.fieldOrder < rhs.fieldOrder }
            return lhs.adjacentItems < rhs.adjacentItems
        }
    }

    private struct Query {
        let terms: [String]
        let phrase: String
        let hierarchyParts: [String]
    }

    private struct Field {
        let name: String
        let value: String
        let locationKind: Int
        let locationDetail: Int
        let itemIndex: Int?
    }

    private struct TermMatch {
        let evidence: MatchEvidence
        let rank: AtomicRank
        let itemIndex: Int?
    }

    private static let propertyPriorities = [
        "aliases": 50,
        "keywords": 50,
        "category": 40,
        "extension": 40,
        "provider": 30,
        "tags": 20,
        "method": 10,
        "id": 0,
    ]

    static func rank<ID: Hashable & Sendable>(
        query rawQuery: String,
        candidates: [Candidate<ID>]
    ) -> [RankedCandidate<ID>] {
        let query = parseQuery(rawQuery)
        return candidates.compactMap { rank(query: query, candidate: $0) }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                let titleOrder = lhs.candidate.label.localizedStandardCompare(rhs.candidate.label)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return String(describing: lhs.candidate.id) < String(describing: rhs.candidate.id)
            }
    }

    static func pathItems(_ relativePath: String) -> [String] {
        relativePath.split(separator: "/").map(String.init)
    }

    // MARK: Candidate ranking

    private static func rank<ID: Hashable & Sendable>(
        query: Query,
        candidate: Candidate<ID>
    ) -> RankedCandidate<ID>? {
        if query.terms.isEmpty {
            return RankedCandidate(
                candidate: candidate,
                rank: CandidateRank(termRanks: [], coherence: .none, fallback: -candidate.fallbackRank),
                matches: []
            )
        }
        guard orderedItemAssignment(query: query, candidate: candidate) else { return nil }

        var matches: [TermMatch] = []
        for term in query.terms {
            guard let match = bestMatch(for: term, candidate: candidate) else { return nil }
            matches.append(match)
        }

        // Leximin: compare the weakest term before any stronger term can help.
        let termRanks = matches.map(\.rank).sorted()
        let candidateRank = CandidateRank(
            termRanks: termRanks,
            coherence: coherence(query: query, candidate: candidate, matches: matches),
            fallback: -candidate.fallbackRank
        )
        return RankedCandidate(
            candidate: candidate,
            rank: candidateRank,
            matches: matches.map(\.evidence)
        )
    }

    private static func bestMatch<ID: Hashable & Sendable>(
        for term: String,
        candidate: Candidate<ID>
    ) -> TermMatch? {
        fields(for: candidate)
            .compactMap { fieldMatch(term: term, field: $0) }
            .max { $0.rank < $1.rank }
    }

    private static func orderedItemAssignment<ID: Hashable & Sendable>(
        query: Query,
        candidate: Candidate<ID>
    ) -> Bool {
        guard !query.hierarchyParts.isEmpty else { return true }
        var nextItemIndex = 0
        for part in query.hierarchyParts {
            var found = false
            while nextItemIndex < candidate.items.count {
                let field = itemField(
                    value: candidate.items[nextItemIndex],
                    index: nextItemIndex,
                    count: candidate.items.count
                )
                nextItemIndex += 1
                if fieldMatch(term: part, field: field) != nil {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    private static func coherence<ID: Hashable & Sendable>(
        query: Query,
        candidate: Candidate<ID>,
        matches: [TermMatch]
    ) -> Coherence {
        let phraseSpecificity = fields(for: candidate)
            .compactMap { fieldMatch(term: query.phrase, field: $0)?.rank.specificity.rawValue }
            .max() ?? 0
        let fieldNames = matches.map(\.evidence.fieldName)
        let sameField = Set(fieldNames).count == 1 ? 1 : 0
        let itemIndices = matches.compactMap(\.itemIndex)
        let allItems = itemIndices.count == matches.count
        let orderedItems = allItems && itemIndices == itemIndices.sorted()
        let adjacentItems = orderedItems && zip(itemIndices, itemIndices.dropFirst()).allSatisfy {
            $1 - $0 <= 1
        }
        return Coherence(
            phraseSpecificity: phraseSpecificity,
            fieldOrder: sameField + (orderedItems ? 1 : 0),
            adjacentItems: adjacentItems ? 1 : 0
        )
    }

    // MARK: Atomic field matching

    private static func fieldMatch(term: String, field: Field) -> TermMatch? {
        let candidate = normalized(field.value)
        guard !candidate.isEmpty else { return nil }
        let candidateTokens = candidate.split(separator: " ").map(String.init)

        if candidate == term {
            return match(term: term, field: field, specificity: .exactField, quality: .neutral)
        }

        let exactIndices = candidateTokens.indices.filter { candidateTokens[$0] == term }
        if let tokenIndex = exactIndices.map({ semanticTokenIndex(candidateTokens, at: $0) }).min() {
            let quality = Quality(
                first: -tokenIndex,
                second: -candidateTokens.count,
                third: -candidate.count,
                fourth: 0
            )
            return match(term: term, field: field, specificity: .exactToken, quality: quality)
        }

        let prefixIndices = candidateTokens.indices.filter { candidateTokens[$0].hasPrefix(term) }
        if let rawIndex = prefixIndices.min(by: {
            semanticTokenIndex(candidateTokens, at: $0) < semanticTokenIndex(candidateTokens, at: $1)
        }) {
            let semanticIndex = semanticTokenIndex(candidateTokens, at: rawIndex)
            let quality = Quality(
                first: -semanticIndex,
                second: -(candidateTokens[rawIndex].count - term.count),
                third: -candidate.count,
                fourth: 0
            )
            return match(term: term, field: field, specificity: .prefix, quality: quality)
        }

        if let range = candidate.range(of: term) {
            let start = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let quality = Quality(first: -start, second: -candidate.count, third: 0, fourth: 0)
            return match(term: term, field: field, specificity: .substring, quality: quality)
        }

        guard let positions = subsequencePositions(term: term, candidate: candidate),
              let first = positions.first,
              let last = positions.last else {
            return nil
        }
        let span = last - first + 1
        let gaps = span - positions.count
        let characters = Array(candidate)
        let boundaryStart = first == 0 || characters[first - 1] == " " ? 1 : 0
        let quality = Quality(
            first: boundaryStart,
            second: longestConsecutiveRun(positions),
            third: -gaps,
            fourth: -span
        )
        return match(term: term, field: field, specificity: .fuzzy, quality: quality)
    }

    private static func match(
        term: String,
        field: Field,
        specificity: Specificity,
        quality: Quality
    ) -> TermMatch {
        TermMatch(
            evidence: MatchEvidence(
                term: term,
                fieldName: field.name,
                fieldValue: field.value,
                specificity: specificity
            ),
            rank: AtomicRank(
                specificity: specificity,
                locationKind: field.locationKind,
                locationDetail: field.locationDetail,
                quality: quality
            ),
            itemIndex: field.itemIndex
        )
    }

    // MARK: Fields and normalization

    private static func fields<ID: Hashable & Sendable>(for candidate: Candidate<ID>) -> [Field] {
        var result = candidate.items.indices.map {
            itemField(value: candidate.items[$0], index: $0, count: candidate.items.count)
        }
        for propertyName in candidate.properties.keys.sorted() {
            let priority = propertyPriorities[propertyName] ?? 0
            for (index, value) in candidate.properties[propertyName, default: []].enumerated() {
                result.append(
                    Field(
                        name: "properties.\(propertyName)[\(index)]",
                        value: value,
                        locationKind: 1,
                        locationDetail: priority,
                        itemIndex: nil
                    )
                )
            }
        }
        return result
    }

    private static func itemField(value: String, index: Int, count: Int) -> Field {
        Field(
            name: "items[\(index)]",
            value: value,
            locationKind: 2,
            locationDetail: -(count - 1 - index),
            itemIndex: index
        )
    }

    private static func parseQuery(_ raw: String) -> Query {
        let phrase = normalized(raw)
        let hierarchyParts = raw.contains("/")
            ? raw.split(separator: "/").map { normalized(String($0)) }.filter { !$0.isEmpty }
            : []
        return Query(
            terms: phrase.split(separator: " ").map(String.init),
            phrase: phrase,
            hierarchyParts: hierarchyParts
        )
    }

    private static func normalized(_ value: String) -> String {
        var expanded = ""
        var previousWasLowercaseOrNumber = false
        for character in value {
            let isAlphaNumeric = character.isLetter || character.isNumber
            if !isAlphaNumeric {
                expanded.append(" ")
                previousWasLowercaseOrNumber = false
                continue
            }
            if character.isUppercase && previousWasLowercaseOrNumber {
                expanded.append(" ")
            }
            expanded.append(character)
            previousWasLowercaseOrNumber = character.isLowercase || character.isNumber
        }

        let folded = expanded
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        var collapsed = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                collapsed.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                collapsed.append(" ")
                lastWasSpace = true
            }
        }
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    private static func semanticTokenIndex(_ tokens: [String], at index: Int) -> Int {
        var ignored = 0
        for token in tokens.prefix(index) {
            guard token.allSatisfy(\.isNumber) else { break }
            ignored += 1
        }
        return index - ignored
    }

    private static func subsequencePositions(term: String, candidate: String) -> [Int]? {
        let pattern = Array(term)
        let characters = Array(candidate)
        var positions: [Int] = []
        var cursor = 0
        for wanted in pattern {
            var found: Int?
            while cursor < characters.count {
                if characters[cursor] == wanted {
                    found = cursor
                    cursor += 1
                    break
                }
                cursor += 1
            }
            guard let found else { return nil }
            positions.append(found)
        }
        return positions
    }

    private static func longestConsecutiveRun(_ positions: [Int]) -> Int {
        guard !positions.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for (left, right) in zip(positions, positions.dropFirst()) {
            current = right == left + 1 ? current + 1 : 1
            longest = max(longest, current)
        }
        return longest
    }
}
