import Foundation

@MainActor
enum ContentBuiltinActions {
    static func register(into registry: ActionRegistry) {
        registry.register(headingSubtreeDescriptor) { request, context in
            struct Args: Decodable {
                let documentPath: String
                let headingSlug: String
                let projection: ActionContentProjection?
                let includeHeading: Bool?
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(Args.self)
            let result = try await contentSurface.headingSubtree(
                documentPath: args.documentPath,
                headingSlug: args.headingSlug,
                projection: args.projection,
                includeHeading: args.includeHeading ?? true,
                target: request.target
            )
            return try ActionValue.fromEncodable(result)
        }

        registry.register(backlinksQueryDescriptor) { request, context in
            struct Args: Decodable {
                let targetPath: String
                let projection: ActionContentProjection?
                let includeTransclusions: Bool?
                let limit: Int?
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(Args.self)
            let result = try await contentSurface.backlinks(
                to: args.targetPath,
                projection: args.projection,
                includeTransclusions: args.includeTransclusions ?? true,
                limit: args.limit,
                target: request.target
            )
            return try ActionValue.fromEncodable(result)
        }

        registry.register(exportCSVDescriptor) { request, context in
            struct Args: Decodable {
                let query: ActionContentQuery
                let columns: [String]?
                let includeHeader: Bool?
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(Args.self)
            let result = try await contentSurface.runQuery(args.query, target: request.target)
            let columns = preferredColumns(from: result.records, explicit: args.columns)
            let csv = serializeCSV(records: result.records, columns: columns, includeHeader: args.includeHeader ?? true)

            return [
                "csv": .string(csv),
                "columns": .array(columns.map(ActionValue.string)),
                "rowCount": .int(result.records.count),
                "diagnostics": .array(result.diagnostics.map(ActionValue.string))
            ]
        }

        registry.register(writeCSVDescriptor) { request, context in
            struct Args: Decodable {
                let query: ActionContentQuery
                let destinationPath: String
                let columns: [String]?
                let includeHeader: Bool?
                let createDirectories: Bool?
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(Args.self)
            let result = try await contentSurface.runQuery(args.query, target: request.target)
            let columns = preferredColumns(from: result.records, explicit: args.columns)
            let csv = serializeCSV(records: result.records, columns: columns, includeHeader: args.includeHeader ?? true)
            let destinationURL = ActionProjectPathResolver.resolveFileURL(path: args.destinationPath, target: request.target)

            if args.createDirectories ?? true {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try csv.write(to: destinationURL, atomically: true, encoding: .utf8)

            return [
                "destinationPath": .string(destinationURL.path),
                "columns": .array(columns.map(ActionValue.string)),
                "rowCount": .int(result.records.count),
                "diagnostics": .array(result.diagnostics.map(ActionValue.string))
            ]
        }
    }

    private static func preferredColumns(from records: [ActionContentRecord], explicit: [String]?) -> [String] {
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        var ordered: [String] = []
        var seen = Set<String>()
        for record in records {
            for key in record.fields.keys.sorted() where !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        return ordered
    }

    private static func serializeCSV(records: [ActionContentRecord], columns: [String], includeHeader: Bool) -> String {
        var rows: [[String]] = []
        if includeHeader {
            rows.append(columns)
        }

        for record in records {
            rows.append(columns.map { column in
                stringValue(record.fields[column])
            })
        }

        return rows.map(serializeCSVRow).joined(separator: "\n")
    }

    private static func serializeCSVRow(_ row: [String]) -> String {
        row.map { field in
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
                return "\"\(escaped)\""
            }
            return escaped
        }.joined(separator: ",")
    }

    private static func stringValue(_ value: ActionValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null:
            return ""
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .string(let string):
            return string
        case .array(let values):
            return values.map { stringValue($0) }.joined(separator: " | ")
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\(key)=\(stringValue(object[key]))"
            }
            return pairs.joined(separator: "; ")
        }
    }

    private static let headingSubtreeDescriptor = ActionDescriptor(
        method: "content.heading.subtree",
        title: "Get Heading Subtree",
        summary: "Return all structural records that belong to a heading section in a document.",
        discussion: "Useful for extracting a section, summarizing the contents of one heading, or exporting a subsection to another format.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .project,
        capabilities: [.contentRead, .contentSemanticRead],
        tags: ["content", "heading", "subtree", "structure"],
        arguments: [
            ActionArgumentDescriptor(name: "documentPath", summary: "Relative document path", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "headingSlug", summary: "Heading slug to locate", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "projection", summary: "Optional output projection", kind: .object, isRequired: false),
            ActionArgumentDescriptor(name: "includeHeading", summary: "Whether to include the heading record itself", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Records contained within the heading subtree", kind: .object)
    )

    private static let backlinksQueryDescriptor = ActionDescriptor(
        method: "content.backlinks.query",
        title: "Query Backlinks",
        summary: "Return wikilink records that point at a target note path.",
        discussion: "Designed for backlink panes, graph generation, and workflows like 'all notes linking to X'.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .project,
        capabilities: [.contentRead],
        tags: ["content", "backlinks", "wikilink"],
        arguments: [
            ActionArgumentDescriptor(name: "targetPath", summary: "Target note path or basename to match", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "projection", summary: "Optional output projection", kind: .object, isRequired: false),
            ActionArgumentDescriptor(name: "includeTransclusions", summary: "Whether to include ![[transclusions]]", kind: .bool, isRequired: false),
            ActionArgumentDescriptor(name: "limit", summary: "Optional result limit", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Backlink query records", kind: .object)
    )

    private static let exportCSVDescriptor = ActionDescriptor(
        method: "content.query.exportCSV",
        title: "Export Content Query as CSV",
        summary: "Run a content query and return CSV text without writing a file.",
        discussion: "Useful for scripts, previews, clipboard workflows, and future interactive markdown outputs.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .project,
        capabilities: [.contentRead],
        tags: ["content", "csv", "export"],
        arguments: [
            ActionArgumentDescriptor(name: "query", summary: "Content query to run", kind: .object, isRequired: true),
            ActionArgumentDescriptor(name: "columns", summary: "Optional explicit column order", kind: .array, isRequired: false),
            ActionArgumentDescriptor(name: "includeHeader", summary: "Whether to include the header row", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "CSV export payload", kind: .object)
    )

    private static let writeCSVDescriptor = ActionDescriptor(
        method: "content.query.writeCSV",
        title: "Write Content Query to CSV",
        summary: "Run a content query and write the results to a CSV file.",
        discussion: "This is the first bridge from content understanding back into project data artifacts such as registries, dashboards, and reports.",
        domain: .content,
        mutationKind: .mutating,
        targetRequirement: .project,
        capabilities: [.contentRead, .contentWrite],
        tags: ["content", "csv", "write"],
        arguments: [
            ActionArgumentDescriptor(name: "query", summary: "Content query to run", kind: .object, isRequired: true),
            ActionArgumentDescriptor(name: "destinationPath", summary: "Destination file path relative to the target project or absolute", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "columns", summary: "Optional explicit column order", kind: .array, isRequired: false),
            ActionArgumentDescriptor(name: "includeHeader", summary: "Whether to include the header row", kind: .bool, isRequired: false),
            ActionArgumentDescriptor(name: "createDirectories", summary: "Whether to create parent directories automatically", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "CSV write metadata", kind: .object)
    )
}
