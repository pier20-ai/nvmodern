import Foundation
import TabularData
import TOMLKit
import Yams

enum CSVGridFileCodec {
    static func load(from fileURL: URL) throws -> CSVGridDocument {
        let data = try Data(contentsOf: fileURL)
        let hasUTF8BOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        var usedEncoding = String.Encoding.utf8
        let source = try String(contentsOf: fileURL, usedEncoding: &usedEncoding)
        return parse(source: source, encoding: usedEncoding, newlineStyle: .detect(from: source), hasUTF8BOM: hasUTF8BOM)
    }

    static func serialize(document: CSVGridDocument) -> String {
        let newline = document.newlineStyle.separator
        let csvBody = serializedCSVBody(document: document, newline: newline)

        guard document.mode == .extended else {
            return csvBody
        }

        let style = document.frontmatterStyle ?? .toml
        let frontmatterBody = serializedFrontmatterBody(document: document, style: style)

        if csvBody.isEmpty {
            return "\(style.fence)\(newline)\(frontmatterBody)\(newline)\(style.fence)\(newline)"
        }

        return "\(style.fence)\(newline)\(frontmatterBody)\(newline)\(style.fence)\(newline)\(newline)\(csvBody)"
    }

    static func serializedData(for document: CSVGridDocument, text: String? = nil) -> Data {
        let serializedText = text ?? serialize(document: document)
        var data = serializedText.data(using: document.encoding) ?? serializedText.data(using: .utf8) ?? Data(serializedText.utf8)
        if document.hasUTF8BOM, document.encoding == .utf8, !data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = Data([0xEF, 0xBB, 0xBF]) + data
        }
        return data
    }

    private struct FrontmatterMatch {
        let style: CSVGridDocument.FrontmatterStyle
        let body: String
        let csvBody: String
    }

    private struct ParsedColumn {
        var name: String
        var format: String?
    }

    private struct ParsedFrontmatter {
        var style: CSVGridDocument.FrontmatterStyle
        var preservedLines: [String]
        var columns: [ParsedColumn]
        var statusColors: [String: String]
    }

    private static func parse(source: String, encoding: String.Encoding, newlineStyle: CSVGridNewlineStyle, hasUTF8BOM: Bool) -> CSVGridDocument {
        if let frontmatter = splitFrontmatter(from: source) {
            let parsedFrontmatter = parseFrontmatter(body: frontmatter.body, style: frontmatter.style)
            let bodyRows = trimLeadingEmptyRows(from: trimTrailingEmptyRows(from: parseSeparatedRows(from: frontmatter.csvBody, delimiter: ",")))
            let bodyColumnCount = bodyRows.map(\.count).max() ?? 0
            let totalColumnCount = max(bodyColumnCount, parsedFrontmatter.columns.count)
            let columns = (0..<totalColumnCount).map { index in
                if parsedFrontmatter.columns.indices.contains(index) {
                    let parsed = parsedFrontmatter.columns[index]
                    let name = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return CSVGridDocument.Column(
                        title: name.isEmpty ? "Column \(index + 1)" : name,
                        format: parsed.format
                    )
                }
                return CSVGridDocument.Column(title: "Column \(index + 1)", format: nil)
            }

            return CSVGridDocument(
                mode: .extended,
                columns: columns,
                rows: bodyRows,
                encoding: encoding,
                newlineStyle: newlineStyle,
                hasUTF8BOM: hasUTF8BOM,
                frontmatterStyle: parsedFrontmatter.style,
                preservedFrontmatterLines: parsedFrontmatter.preservedLines,
                statusColors: parsedFrontmatter.statusColors
            )
        }

        let parsedRows = parseSeparatedRows(from: source, delimiter: ",")
        guard !parsedRows.isEmpty else {
            return CSVGridDocument(
                mode: .plainCSV,
                columns: [],
                rows: [],
                encoding: encoding,
                newlineStyle: newlineStyle,
                hasUTF8BOM: hasUTF8BOM,
                frontmatterStyle: nil,
                preservedFrontmatterLines: [],
                statusColors: [:]
            )
        }

        let headerRow = parsedRows[0]
        let dataRows = Array(parsedRows.dropFirst())
        let dataColumnCount = dataRows.map(\.count).max() ?? 0
        let totalColumnCount = max(headerRow.count, dataColumnCount)
        let columns = (0..<totalColumnCount).map { index in
            let title = headerRow.indices.contains(index) ? headerRow[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return CSVGridDocument.Column(title: title.isEmpty ? "Column \(index + 1)" : title, format: nil)
        }

        return CSVGridDocument(
            mode: .plainCSV,
            columns: columns,
            rows: dataRows,
            encoding: encoding,
            newlineStyle: newlineStyle,
            hasUTF8BOM: hasUTF8BOM,
            frontmatterStyle: nil,
            preservedFrontmatterLines: [],
            statusColors: [:]
        )
    }

    private static func serializedCSVBody(document: CSVGridDocument, newline: String) -> String {
        var outputRows: [[String]] = []
        if document.mode == .plainCSV, !document.columns.isEmpty {
            outputRows.append(document.columns.map(\.title))
        }
        for row in trimmedTrailingEmptyRows(from: document.rows, columnCount: document.columns.count) {
            let normalized = (0..<document.columns.count).map { index in
                row.indices.contains(index) ? row[index] : ""
            }
            outputRows.append(normalized)
        }
        return outputRows.map { CSVGridTransferCodec.serializeRow($0, delimiter: ",") }.joined(separator: newline)
    }

    private static func serializedFrontmatterBody(document: CSVGridDocument, style: CSVGridDocument.FrontmatterStyle) -> String {
        switch style {
        case .toml:
            return serializedTOMLFrontmatterBody(document: document)
        case .yaml:
            return serializedYAMLFrontmatterBody(document: document)
        }
    }

    private static func serializedTOMLFrontmatterBody(document: CSVGridDocument) -> String {
        let generatedStatusTable = generatedTOMLStatusTable(document: document)
        let generatedColumnsArray = generatedTOMLColumnsArray(document: document)

        guard let preservedTable = preservedTOMLFrontmatterTable(lines: document.preservedFrontmatterLines) else {
            return joinFrontmatterSections(
                preserved: trimmedPreservedFrontmatterText(lines: document.preservedFrontmatterLines),
                generated: serializedFallbackTOMLFrontmatter(statusTable: generatedStatusTable, columnsArray: generatedColumnsArray)
            )
        }

        if let generatedStatusTable {
            preservedTable["status"] = generatedStatusTable
        } else {
            preservedTable.remove(at: "status")
        }
        if let generatedColumnsArray {
            preservedTable["columns"] = generatedColumnsArray
        } else {
            preservedTable.remove(at: "columns")
        }

        return trimTrailingNewlines(in: preservedTable.convert())
    }

    private static func serializedYAMLFrontmatterBody(document: CSVGridDocument) -> String {
        let generatedStatusObject = generatedYAMLStatusObject(document: document)
        let generatedColumnsObject = generatedYAMLColumnsObject(document: document)

        guard var preservedObject = preservedYAMLFrontmatterObject(lines: document.preservedFrontmatterLines) else {
            return joinFrontmatterSections(
                preserved: trimmedPreservedFrontmatterText(lines: document.preservedFrontmatterLines),
                generated: serializedFallbackYAMLFrontmatter(statusObject: generatedStatusObject, columnsObject: generatedColumnsObject)
            )
        }

        if let generatedStatusObject {
            preservedObject["status"] = generatedStatusObject
        } else {
            preservedObject.removeValue(forKey: "status")
        }
        if let generatedColumnsObject {
            preservedObject["columns"] = generatedColumnsObject
        } else {
            preservedObject.removeValue(forKey: "columns")
        }

        return serializedYAMLString(from: preservedObject)
    }

    private static func splitFrontmatter(from source: String) -> FrontmatterMatch? {
        let pattern = #"\A(\+\+\+|---)(?:\r\n|\n|\r)([\s\S]*?)(?:\r\n|\n|\r)\1(?:\r\n|\n|\r)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: source.utf16.count)),
              match.range.location != NSNotFound,
              let fenceRange = Range(match.range(at: 1), in: source),
              let bodyRange = Range(match.range(at: 2), in: source),
              let fullRange = Range(match.range, in: source) else {
            return nil
        }
        let fence = String(source[fenceRange])
        let rawCSVBody = String(source[fullRange.upperBound...])
        return FrontmatterMatch(
            style: fence == "---" ? .yaml : .toml,
            body: String(source[bodyRange]),
            csvBody: rawCSVBody
        )
    }

    private static func parseFrontmatter(body: String, style: CSVGridDocument.FrontmatterStyle) -> ParsedFrontmatter {
        switch style {
        case .toml: return parseTOMLFrontmatter(body)
        case .yaml: return parseYAMLFrontmatter(body)
        }
    }

    private static func parseTOMLFrontmatter(_ body: String) -> ParsedFrontmatter {
        do {
            let table = try TOMLTable(string: body)
            let columns = parseTOMLColumns(from: table["columns"]?.array)
            let statusColors = parseTOMLStatusColors(from: table["status"]?.table)
            table.remove(at: "columns")
            table.remove(at: "status")
            return ParsedFrontmatter(style: .toml, preservedLines: preservedLines(fromTOMLTable: table), columns: columns, statusColors: statusColors)
        } catch {
            return ParsedFrontmatter(style: .toml, preservedLines: body.components(separatedBy: .newlines), columns: [], statusColors: [:])
        }
    }

    private static func parseYAMLFrontmatter(_ body: String) -> ParsedFrontmatter {
        do {
            guard let loadedObject = try Yams.load(yaml: body) else {
                return ParsedFrontmatter(style: .yaml, preservedLines: [], columns: [], statusColors: [:])
            }
            guard var root = yamlDictionary(from: loadedObject) else {
                return ParsedFrontmatter(style: .yaml, preservedLines: body.components(separatedBy: .newlines), columns: [], statusColors: [:])
            }
            let columns = parseYAMLColumns(from: root["columns"])
            let statusColors = parseYAMLStatusColors(from: root["status"])
            root.removeValue(forKey: "columns")
            root.removeValue(forKey: "status")
            return ParsedFrontmatter(style: .yaml, preservedLines: preservedLines(fromYAMLObject: root), columns: columns, statusColors: statusColors)
        } catch {
            return ParsedFrontmatter(style: .yaml, preservedLines: body.components(separatedBy: .newlines), columns: [], statusColors: [:])
        }
    }

    private static func parseTOMLColumns(from array: TOMLArray?) -> [ParsedColumn] {
        guard let array else { return [] }
        return array.compactMap { entry in
            guard let table = entry.table else { return nil }
            return ParsedColumn(
                name: stringValue(fromTOMLValue: table["name"]) ?? "",
                format: stringValue(fromTOMLValue: table["format"])
            )
        }
    }

    private static func parseTOMLStatusColors(from table: TOMLTable?) -> [String: String] {
        guard let table else { return [:] }
        var statusColors: [String: String] = [:]
        for (key, value) in table {
            if let stringValue = stringValue(fromTOMLValue: value) {
                statusColors[key] = stringValue
            }
        }
        return statusColors
    }

    private static func parseYAMLColumns(from value: Any?) -> [ParsedColumn] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let dictionary = yamlDictionary(from: entry) else { return nil }
            return ParsedColumn(
                name: stringValue(fromYAMLValue: dictionary["name"]) ?? "",
                format: stringValue(fromYAMLValue: dictionary["format"])
            )
        }
    }

    private static func parseYAMLStatusColors(from value: Any?) -> [String: String] {
        guard let dictionary = yamlDictionary(from: value) else { return [:] }
        var statusColors: [String: String] = [:]
        for (key, value) in dictionary {
            if let stringValue = stringValue(fromYAMLValue: value) {
                statusColors[key] = stringValue
            }
        }
        return statusColors
    }

    private static func generatedTOMLStatusTable(document: CSVGridDocument) -> TOMLTable? {
        guard !document.statusColors.isEmpty else { return nil }
        let table = TOMLTable()
        for key in document.statusColors.keys.sorted() {
            table[key] = document.statusColors[key] ?? ""
        }
        return table
    }

    private static func generatedTOMLColumnsArray(document: CSVGridDocument) -> TOMLArray? {
        guard !document.columns.isEmpty else { return nil }
        let array = TOMLArray()
        for column in document.columns {
            let table = TOMLTable()
            table["name"] = column.title
            if let format = column.format {
                table["format"] = format
            }
            array.append(table)
        }
        return array
    }

    private static func generatedYAMLStatusObject(document: CSVGridDocument) -> [String: String]? {
        guard !document.statusColors.isEmpty else { return nil }
        var result: [String: String] = [:]
        for key in document.statusColors.keys.sorted() {
            result[key] = document.statusColors[key] ?? ""
        }
        return result
    }

    private static func generatedYAMLColumnsObject(document: CSVGridDocument) -> [[String: String]]? {
        guard !document.columns.isEmpty else { return nil }
        return document.columns.map { column in
            var object = ["name": column.title]
            if let format = column.format {
                object["format"] = format
            }
            return object
        }
    }

    private static func serializedFallbackTOMLFrontmatter(statusTable: TOMLTable?, columnsArray: TOMLArray?) -> String {
        let table = TOMLTable()
        if let statusTable { table["status"] = statusTable }
        if let columnsArray { table["columns"] = columnsArray }
        guard !table.isEmpty else { return "" }
        return trimTrailingNewlines(in: table.convert())
    }

    private static func serializedFallbackYAMLFrontmatter(statusObject: [String: String]?, columnsObject: [[String: String]]?) -> String {
        var object: [String: Any] = [:]
        if let statusObject { object["status"] = statusObject }
        if let columnsObject { object["columns"] = columnsObject }
        return serializedYAMLString(from: object)
    }

    private static func serializedYAMLString(from object: [String: Any]) -> String {
        guard !object.isEmpty, let yaml = try? Yams.dump(object: object, sortKeys: false) else { return "" }
        return trimTrailingNewlines(in: yaml)
    }

    private static func preservedTOMLFrontmatterTable(lines: [String]) -> TOMLTable? {
        let preservedText = trimmedPreservedFrontmatterText(lines: lines)
        guard !preservedText.isEmpty else { return TOMLTable() }
        return try? TOMLTable(string: preservedText)
    }

    private static func preservedYAMLFrontmatterObject(lines: [String]) -> [String: Any]? {
        let preservedText = trimmedPreservedFrontmatterText(lines: lines)
        guard !preservedText.isEmpty else { return [:] }
        guard let loadedObject = try? Yams.load(yaml: preservedText) else { return nil }
        return yamlDictionary(from: loadedObject)
    }

    private static func trimmedPreservedFrontmatterText(lines: [String]) -> String {
        trimTrailingEmptyLines(from: trimLeadingEmptyLines(from: lines)).joined(separator: "\n")
    }

    private static func joinFrontmatterSections(preserved: String, generated: String) -> String {
        switch (preserved.isEmpty, generated.isEmpty) {
        case (true, true): return ""
        case (false, true): return preserved
        case (true, false): return generated
        case (false, false): return preserved + "\n\n" + generated
        }
    }

    private static func trimTrailingNewlines(in string: String) -> String {
        string.replacingOccurrences(of: #"(?:\r\n|\n|\r)+\z"#, with: "", options: .regularExpression)
    }

    private static func preservedLines(fromTOMLTable table: TOMLTable) -> [String] {
        guard !table.isEmpty else { return [] }
        return table.convert().components(separatedBy: .newlines)
    }

    private static func preservedLines(fromYAMLObject object: [String: Any]) -> [String] {
        guard !object.isEmpty, let yaml = try? Yams.dump(object: object) else { return [] }
        return yaml.components(separatedBy: .newlines)
    }

    private static func stringValue(fromTOMLValue value: TOMLValueConvertible?) -> String? {
        guard let value else { return nil }
        if let string = value.string { return string }
        if let int = value.int { return String(int) }
        if let double = value.double { return String(double) }
        if let bool = value.bool { return bool ? "true" : "false" }
        if let date = value.date { return String(describing: date) }
        if let time = value.time { return String(describing: time) }
        if let dateTime = value.dateTime { return String(describing: dateTime) }
        return nil
    }

    private static func yamlDictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let dictionary = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let stringKey = key as? String else { return nil }
                result[stringKey] = value
            }
            return result
        }
        return nil
    }

    private static func stringValue(fromYAMLValue value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let value?:
            return String(describing: value)
        case nil:
            return nil
        }
    }

    private static func trimLeadingEmptyLines(from lines: [String]) -> [String] {
        var result = lines
        while result.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { result.removeFirst() }
        return result
    }

    private static func trimTrailingEmptyLines(from lines: [String]) -> [String] {
        var result = lines
        while result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { result.removeLast() }
        return result
    }

    private static func trimmedTrailingEmptyRows(from rows: [[String]], columnCount: Int) -> [[String]] {
        guard !rows.isEmpty else { return rows }

        var result = rows
        while let last = result.last {
            let isEmptyRow = (0..<columnCount).allSatisfy { index in
                last.indices.contains(index) ? last[index].isEmpty : true
            }
            guard isEmptyRow else { break }
            result.removeLast()
        }
        return result
    }

    private static func trimLeadingEmptyRows(from rows: [[String]]) -> [[String]] {
        var result = rows
        while let first = result.first, first.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.removeFirst()
        }
        return result
    }

    private static func trimTrailingEmptyRows(from rows: [[String]]) -> [[String]] {
        var result = rows
        while let last = result.last, last.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.removeLast()
        }
        return result
    }

    private static func parseSeparatedRows(from input: String, delimiter: Character) -> [[String]] {
        CSVGridTransferCodec.parseRows(from: input, delimiter: delimiter)
    }

    private static func parseSeparatedRowsUsingTabularData(from input: String, delimiter: Character) -> [[String]]? {
        guard delimiter == ",", let headerRow = parseFirstSeparatedHeaderRow(from: input, delimiter: delimiter) else { return nil }
        var stringTypes: [String: CSVType] = [:]
        for name in headerRow { stringTypes[name] = .string }
        let options = CSVReadingOptions(hasHeaderRow: true, floatingPointType: .double, ignoresEmptyLines: false, usesQuoting: true, usesEscaping: false, delimiter: delimiter)
        guard let data = input.data(using: .utf8),
              let frame = try? DataFrame(csvData: data, types: stringTypes, options: options) else {
            return nil
        }

        let columnCount = frame.columns.count
        let rowCount = frame.shape.rows
        let hasBodyContent = input
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .dropFirst()
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        if columnCount == 0 ||
            columnCount > max(headerRow.count * 2, headerRow.count + 32) ||
            (rowCount == 0 && hasBodyContent) {
            print("[NVModern][CSVCodec] Rejecting TabularData parse headerCols=\(headerRow.count) frameCols=\(columnCount) frameRows=\(rowCount); falling back to transfer parser")
            return nil
        }

        var rows: [[String]] = [frame.columns.map(\.name)]
        for rowIndex in 0..<rowCount {
            var row: [String] = []
            for column in frame.columns {
                let value = column[rowIndex]
                row.append(value as? String ?? value.map { String(describing: $0) } ?? "")
            }
            rows.append(row)
        }
        if !rows.isEmpty, !rows[0].isEmpty {
            rows[0][0] = rows[0][0].replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        return rows
    }

    private static func parseFirstSeparatedHeaderRow(from input: String, delimiter: Character) -> [String]? {
        var row: [String] = []
        var currentValue = ""
        var inQuotes = false
        var index = input.startIndex

        func finishField() {
            row.append(currentValue)
            currentValue = ""
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
                    index = input.index(after: index)
                    continue
                }
                currentValue.append(character)
                index = input.index(after: index)
                continue
            }
            if character == "\"", currentValue.isEmpty {
                inQuotes = true
                index = input.index(after: index)
                continue
            }
            if character == delimiter {
                finishField()
                index = input.index(after: index)
                continue
            }
            if character == "\n" || character == "\r" || String(character) == "\r\n" {
                finishField()
                return row
            }
            currentValue.append(character)
            index = input.index(after: index)
        }
        finishField()
        return row.isEmpty ? nil : row
    }
}
