import Foundation

struct CSVGridSaveSnapshot {
    let text: String
    let data: Data
    let encoding: String.Encoding
    let newlineStyle: CSVGridNewlineStyle
    let hasUTF8BOM: Bool
}

enum CSVGridNewlineStyle {
    case lf
    case crlf
    case cr

    var separator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    static func detect(from source: String) -> CSVGridNewlineStyle {
        if source.contains("\r\n") { return .crlf }
        if source.contains("\r") { return .cr }
        return .lf
    }
}

struct CSVGridDocument {
    enum Mode {
        case plainCSV
        case extended
    }

    enum FrontmatterStyle {
        case toml
        case yaml

        var fence: String {
            switch self {
            case .toml: return "+++"
            case .yaml: return "---"
            }
        }
    }

    struct Column {
        var title: String
        var format: String?
    }

    var mode: Mode
    var columns: [Column]
    var rows: [[String]]
    var encoding: String.Encoding
    var newlineStyle: CSVGridNewlineStyle
    var hasUTF8BOM: Bool
    var frontmatterStyle: FrontmatterStyle?
    var preservedFrontmatterLines: [String]
    var statusColors: [String: String]

    var rowCount: Int {
        rows.count
    }

    var columnCount: Int {
        columns.count
    }

    var isExtendedDocument: Bool {
        mode == .extended
    }

    func value(atDisplayRow row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else {
            return ""
        }
        return rows[row][column]
    }

    mutating func setValue(_ value: String, atDisplayRow row: Int, column: Int) {
        guard row >= 0, column >= 0 else { return }
        ensureColumnCount(atLeast: column + 1)

        while rows.count <= row {
            rows.append(Array(repeating: "", count: columns.count))
        }

        if rows[row].count < columns.count {
            rows[row].append(contentsOf: Array(repeating: "", count: columns.count - rows[row].count))
        }

        rows[row][column] = value
    }

    mutating func ensureColumnCount(atLeast minimumCount: Int) {
        guard minimumCount > columns.count else { return }
        for index in columns.count..<minimumCount {
            columns.append(Column(title: defaultColumnTitle(for: index), format: nil))
        }
        for rowIndex in rows.indices where rows[rowIndex].count < columns.count {
            rows[rowIndex].append(contentsOf: Array(repeating: "", count: columns.count - rows[rowIndex].count))
        }
    }

    mutating func insertColumn(at index: Int, column: Column? = nil) {
        let insertionIndex = min(max(0, index), columns.count)
        let newColumn = column ?? Column(title: defaultColumnTitle(for: insertionIndex), format: nil)
        columns.insert(newColumn, at: insertionIndex)
        for rowIndex in rows.indices {
            if rows[rowIndex].count < columns.count - 1 {
                rows[rowIndex].append(contentsOf: Array(repeating: "", count: (columns.count - 1) - rows[rowIndex].count))
            }
            rows[rowIndex].insert("", at: min(insertionIndex, rows[rowIndex].count))
        }
    }

    @discardableResult
    mutating func removeColumn(at index: Int) -> Column? {
        guard columns.indices.contains(index) else { return nil }
        let removed = columns.remove(at: index)
        for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
            rows[rowIndex].remove(at: index)
        }
        return removed
    }

    mutating func moveColumn(from sourceIndex: Int, to destinationIndex: Int) {
        guard columns.indices.contains(sourceIndex) else { return }
        let boundedDestination = min(max(0, destinationIndex), columns.count)
        let column = columns.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < boundedDestination ? boundedDestination - 1 : boundedDestination
        columns.insert(column, at: min(max(0, adjustedDestination), columns.count))

        for rowIndex in rows.indices where rows[rowIndex].indices.contains(sourceIndex) {
            let value = rows[rowIndex].remove(at: sourceIndex)
            let destination = min(max(0, adjustedDestination), rows[rowIndex].count)
            rows[rowIndex].insert(value, at: destination)
        }
    }

    mutating func insertRow(at index: Int, values: [String]? = nil) {
        let insertionIndex = min(max(0, index), rows.count)
        ensureColumnCount(atLeast: max(columns.count, values?.count ?? 0))
        var row = Array(repeating: "", count: columns.count)
        if let values {
            for (columnIndex, value) in values.enumerated() where columnIndex < row.count {
                row[columnIndex] = value
            }
        }
        rows.insert(row, at: insertionIndex)
    }

    @discardableResult
    mutating func removeRow(at index: Int) -> [String]? {
        guard rows.indices.contains(index) else { return nil }
        return rows.remove(at: index)
    }

    mutating func moveRow(from sourceIndex: Int, to destinationIndex: Int) {
        guard rows.indices.contains(sourceIndex) else { return }
        let row = rows.remove(at: sourceIndex)
        let boundedDestination = min(max(0, destinationIndex), rows.count + 1)
        let adjustedDestination = sourceIndex < boundedDestination ? boundedDestination - 1 : boundedDestination
        rows.insert(row, at: min(max(0, adjustedDestination), rows.count))
    }

    func serialized() -> String {
        CSVGridFileCodec.serialize(document: self)
    }

    func serializedSnapshot() -> CSVGridSaveSnapshot {
        let text = serialized()
        let data = CSVGridFileCodec.serializedData(for: self, text: text)
        return CSVGridSaveSnapshot(
            text: text,
            data: data,
            encoding: encoding,
            newlineStyle: newlineStyle,
            hasUTF8BOM: hasUTF8BOM
        )
    }

    static func load(from fileURL: URL) throws -> CSVGridDocument {
        try CSVGridFileCodec.load(from: fileURL)
    }

    private func defaultColumnTitle(for index: Int) -> String {
        "Column \(index + 1)"
    }
}
