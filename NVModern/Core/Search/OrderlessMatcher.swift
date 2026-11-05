import Foundation

/// Orderless completion matching for compact command and file catalogs.
///
/// Space-separated pattern components may match in any order. Each component
/// uses its best available style: literal substring, regular expression, word
/// prefix, initialism, concatenated word prefixes, or flex subsequence.
enum OrderlessMatcher {
    struct CompiledPattern {
        fileprivate let components: [PatternComponent]

        func score(candidate: String) -> Int? {
            OrderlessMatcher.score(self, candidate: candidate)
        }
    }

    static func matches(_ pattern: String, candidate: String) -> Bool {
        score(pattern, candidate: candidate) != nil
    }

    static func score(_ pattern: String, candidate: String) -> Int? {
        compile(pattern).score(candidate: candidate)
    }

    static func compile(_ pattern: String) -> CompiledPattern {
        let components = pattern
            .split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
            .map { value in
                PatternComponent(
                    value: value,
                    regularExpression: value.rangeOfCharacter(from: regexMetacharacters) == nil
                        ? nil
                        : try? NSRegularExpression(pattern: value, options: [.caseInsensitive])
                )
            }

        return CompiledPattern(components: components)
    }

    private static func score(_ pattern: CompiledPattern, candidate: String) -> Int? {
        guard !pattern.components.isEmpty else { return 0 }

        let normalizedCandidate = normalized(candidate)
        let words = candidateWords(candidate)
        var total = 0

        for component in pattern.components {
            guard let componentScore = bestComponentScore(
                component,
                candidate: normalizedCandidate,
                words: words
            ) else {
                return nil
            }
            total += componentScore
        }

        return total
    }

    private static func bestComponentScore(
        _ component: PatternComponent,
        candidate: String,
        words: [String]
    ) -> Int? {
        var scores: [Int] = []

        if let range = candidate.range(of: component.value) {
            scores.append(candidate.distance(from: candidate.startIndex, to: range.lowerBound))
        }

        if let regexScore = regularExpressionScore(component, candidate: candidate) {
            scores.append(100 + regexScore)
        }

        if let wordIndex = words.firstIndex(where: { $0.hasPrefix(component.value) }) {
            scores.append(180 + wordIndex)
        }

        if let initialismScore = initialismScore(component.value, words: words) {
            scores.append(260 + initialismScore)
        }

        if let prefixScore = concatenatedWordPrefixScore(component.value, words: words) {
            scores.append(320 + prefixScore)
        }

        if let flexScore = flexScore(component.value, candidate: candidate) {
            scores.append(500 + flexScore)
        }

        return scores.min()
    }

    private static func regularExpressionScore(_ component: PatternComponent, candidate: String) -> Int? {
        guard let regex = component.regularExpression else {
            return nil
        }

        let fullRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: fullRange) else { return nil }
        return match.range.location
    }

    private static func initialismScore(_ component: String, words: [String]) -> Int? {
        let characters = Array(component)
        guard characters.count >= 2 else { return nil }

        var componentIndex = 0
        var skippedWords = 0
        for (wordIndex, word) in words.enumerated() {
            guard componentIndex < characters.count else { break }
            if word.first == characters[componentIndex] {
                componentIndex += 1
            } else if componentIndex > 0 {
                skippedWords += 1
            }
            if componentIndex == characters.count {
                return wordIndex + skippedWords
            }
        }
        return nil
    }

    private static func concatenatedWordPrefixScore(_ component: String, words: [String]) -> Int? {
        let pattern = Array(component)
        guard pattern.count >= 2, words.count >= 2 else { return nil }
        let wordCharacters = words.map(Array.init)
        var memo: [PrefixMemoKey: Int] = [:]

        func search(patternIndex: Int, wordIndex: Int, usedWords: Int) -> Int? {
            if patternIndex == pattern.count {
                return usedWords >= 2 ? 0 : nil
            }
            guard wordIndex < wordCharacters.count else { return nil }

            let key = PrefixMemoKey(
                patternIndex: patternIndex,
                wordIndex: wordIndex,
                usedWords: min(usedWords, 2)
            )
            if let cached = memo[key] {
                return cached
            }

            var best: Int?
            for candidateWordIndex in wordIndex..<wordCharacters.count {
                let word = wordCharacters[candidateWordIndex]
                let remaining = pattern.count - patternIndex
                let maximumLength = min(word.count, remaining)
                guard maximumLength > 0 else { continue }

                for length in 1...maximumLength {
                    let patternSlice = Array(pattern[patternIndex..<(patternIndex + length)])
                    guard Array(word.prefix(length)) == patternSlice else { continue }
                    guard let tail = search(
                        patternIndex: patternIndex + length,
                        wordIndex: candidateWordIndex + 1,
                        usedWords: usedWords + 1
                    ) else {
                        continue
                    }

                    let score = tail + candidateWordIndex - wordIndex + (word.count - length)
                    best = min(best ?? score, score)
                }
            }

            if let best {
                memo[key] = best
            }
            return best
        }

        return search(patternIndex: 0, wordIndex: 0, usedWords: 0)
    }

    private static func flexScore(_ component: String, candidate: String) -> Int? {
        let pattern = Array(component)
        let candidateCharacters = Array(candidate)
        guard !pattern.isEmpty else { return 0 }

        var patternIndex = 0
        var firstMatchIndex: Int?
        var previousMatchIndex: Int?
        var gapPenalty = 0

        for (candidateIndex, character) in candidateCharacters.enumerated() {
            guard character == pattern[patternIndex] else { continue }
            firstMatchIndex = firstMatchIndex ?? candidateIndex
            if let previousMatchIndex {
                gapPenalty += max(0, candidateIndex - previousMatchIndex - 1)
            }
            previousMatchIndex = candidateIndex
            patternIndex += 1
            if patternIndex == pattern.count {
                return (firstMatchIndex ?? 0) + gapPenalty
            }
        }

        return nil
    }

    private static func candidateWords(_ candidate: String) -> [String] {
        var expanded = ""
        var previousWasLowercaseOrNumber = false

        for character in candidate {
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

        return expanded
            .split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static let regexMetacharacters = CharacterSet(charactersIn: "^$.*+?()[]{}|\\")

    fileprivate struct PatternComponent {
        let value: String
        let regularExpression: NSRegularExpression?
    }

    private struct PrefixMemoKey: Hashable {
        let patternIndex: Int
        let wordIndex: Int
        let usedWords: Int
    }
}
