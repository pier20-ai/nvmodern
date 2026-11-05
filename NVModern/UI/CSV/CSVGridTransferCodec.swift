import Foundation

enum CSVGridTransferCodec {
    private static func isNewlineCharacter(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || String(character) == "\r\n"
    }

    static func parseRows(from input: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentValue = ""
        var inQuotes = false
        var justClosedQuote = false
        var index = input.startIndex

        func finishField() {
            currentRow.append(currentValue)
            currentValue = ""
            justClosedQuote = false
        }

        func finishRow() {
            finishField()
            rows.append(currentRow)
            currentRow = []
        }

        while index < input.endIndex {
            let character = input[index]

            if inQuotes {
                if character == "\"" {
                    let nextIndex = input.index(after: index)
                    if nextIndex < input.endIndex, input[nextIndex] == "\"" {
                        currentValue.append("\"")
                        index = input.index(after: nextIndex)
                        continue
                    }
                    inQuotes = false
                    justClosedQuote = true
                    index = input.index(after: index)
                    continue
                }
                currentValue.append(character)
                index = input.index(after: index)
                continue
            }

            if justClosedQuote {
                if character == delimiter {
                    finishField()
                    index = input.index(after: index)
                    continue
                }
                if isNewlineCharacter(character) {
                    finishRow()
                    index = input.index(after: index)
                    continue
                }
                if character == " " || character == "\t" {
                    index = input.index(after: index)
                    continue
                }
                justClosedQuote = false
            }

            if character == delimiter {
                finishField()
                index = input.index(after: index)
                continue
            }

            if isNewlineCharacter(character) {
                finishRow()
                index = input.index(after: index)
                continue
            }

            if character == "\"", currentValue.isEmpty {
                inQuotes = true
                index = input.index(after: index)
                continue
            }

            currentValue.append(character)
            index = input.index(after: index)
        }

        finishField()
        let hasTrailingNewline = input.hasSuffix("\n") || input.hasSuffix("\r") || input.hasSuffix("\r\n")
        let trailingBlankLine = !rows.isEmpty && currentRow.count == 1 && currentRow[0].isEmpty && hasTrailingNewline
        if !trailingBlankLine {
            rows.append(currentRow)
        }

        if rows.count == 1, rows[0].count == 1, rows[0][0].isEmpty, input.isEmpty {
            return []
        }

        return rows
    }

    static func serializeRow(_ row: [String], delimiter: Character) -> String {
        row.map { serializeField($0, delimiter: delimiter) }.joined(separator: String(delimiter))
    }

    static func serializeField(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") || value.contains("\t")
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
