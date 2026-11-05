import AppKit
import Foundation

/// Annotations: labelled, visual-only marks over a text document. An agent
/// (usually over MCP) places them to point at passages it is explaining; the
/// reader places them to ask about a passage, and the agent answers in place.
/// They live in the editor only — never in the file or its undo history.
///
/// Each action takes an optional `path`. When given, the document is found in
/// an open tab (selecting that tab without activating the app, so a user
/// typing in a terminal beside nvModern keeps focus) or opened, and the action
/// waits briefly for its editor to load.
@MainActor
enum WorkspaceAnnotationBuiltinActions {
    static func register(into registry: ActionRegistry) {
        registry.register(addDescriptor) { request, context in
            struct AddArgs: Decodable {
                let annotations: [ActionValue]
                let replace: Bool?
                let reveal: Bool?
            }
            let args = try request.decodeArgs(AddArgs.self)
            guard !args.annotations.isEmpty else {
                throw ActionError.invalidArguments("annotations must contain at least one item")
            }
            var payload: [String: ActionValue] = [
                "op": "add",
                "annotations": .array(args.annotations),
                "reveal": .bool(args.reveal ?? true)
            ]
            if args.replace == true {
                payload["replace"] = "agent"
            }
            return try await perform(payload, request: request, context: context)
        }

        registry.register(removeDescriptor) { request, context in
            struct RemoveArgs: Decodable {
                let labels: [ActionValue]?
                let ids: [String]?
                let author: String?
            }
            let args = (try? request.decodeArgs(RemoveArgs.self)) ?? RemoveArgs(labels: nil, ids: nil, author: nil)
            var payload: [String: ActionValue] = ["op": "remove"]
            if let labels = args.labels { payload["labels"] = .array(labels.compactMap(labelValue)) }
            if let ids = args.ids { payload["ids"] = .array(ids.map { .string($0) }) }
            if let author = args.author {
                guard author == "agent" || author == "user" else {
                    throw ActionError.invalidArguments("author must be agent or user")
                }
                payload["author"] = .string(author)
            }
            return try await perform(payload, request: request, context: context)
        }

        registry.register(listDescriptor) { request, context in
            try await perform(["op": "list"], request: request, context: context)
        }

        registry.register(revealDescriptor) { request, context in
            struct RevealArgs: Decodable {
                let label: ActionValue
            }
            let args = try request.decodeArgs(RevealArgs.self)
            guard let label = labelValue(args.label) else {
                throw ActionError.invalidArguments("label must be a string or number")
            }
            let result = try await perform(
                ["op": "reveal", "target": label],
                request: request,
                context: context
            )
            guard result.objectValue?["revealed"]?.boolValue == true else {
                throw ActionError.invalidArguments(
                    "No anchored annotation with that label or id",
                    details: ["label": label]
                )
            }
            return result
        }

        registry.register(questionsDescriptor) { request, context in
            struct QuestionArgs: Decodable {
                let includeAnswered: Bool?
            }
            let args = (try? request.decodeArgs(QuestionArgs.self)) ?? QuestionArgs(includeAnswered: nil)
            return try await perform(
                ["op": "list", "author": "user", "unansweredOnly": .bool(args.includeAnswered != true)],
                request: request,
                context: context
            )
        }

        registry.register(answerDescriptor) { request, context in
            struct AnswerArgs: Decodable {
                let label: ActionValue
                let answer: String
                let by: String?
            }
            let args = try request.decodeArgs(AnswerArgs.self)
            guard let label = labelValue(args.label) else {
                throw ActionError.invalidArguments("label must be a string or number")
            }
            var payload: [String: ActionValue] = ["op": "answer", "target": label, "answer": .string(args.answer)]
            if let by = args.by?.trimmingCharacters(in: .whitespacesAndNewlines), !by.isEmpty {
                payload["answeredBy"] = .string(by)
            }
            let result = try await perform(payload, request: request, context: context)
            guard result.objectValue?["answered"]?.boolValue == true else {
                throw ActionError.invalidArguments(
                    "No annotation with that label or id",
                    details: ["label": label]
                )
            }
            return result
        }

        registry.register(exportDescriptor) { request, context in
            struct ExportArgs: Decodable {
                let to: String?
                let format: String?
            }
            let args = (try? request.decodeArgs(ExportArgs.self)) ?? ExportArgs(to: nil, format: nil)
            let format = (args.format ?? "markdown").lowercased()
            guard ["markdown", "md", "json"].contains(format) else {
                throw ActionError.invalidArguments("format must be markdown or json")
            }
            let listed = try await perform(["op": "list"], request: request, context: context)
            guard let documentPath = listed.objectValue?["absolutePath"]?.stringValue else {
                throw ActionError.unavailable("The document has no file to export beside; pass to")
            }
            let annotations = listed.objectValue?["annotations"]?.arrayValue ?? []
            let json = format == "json"
            let destination = try exportDestination(args.to, documentPath: documentPath, json: json)
            let contents = json
                ? try exportJSON(annotations, documentPath: documentPath)
                : exportMarkdown(annotations, documentPath: documentPath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                throw ActionError.unavailable(
                    "Could not write the export: \(error.localizedDescription)",
                    details: ["to": .string(destination.path)]
                )
            }
            return [
                "written": .string(destination.path),
                "count": .int(annotations.count),
                "format": .string(json ? "json" : "markdown"),
                "absolutePath": .string(documentPath)
            ]
        }

        registry.register(askDescriptor) { _, context in
            guard let runtime = WorkspaceActionRouter.runtime(for: context.resolvedTarget) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            if runtime.currentEditorCommandTargetSnapshot()?.surfaceKind == .pdf {
                let result = await runtime.performEditorAnnotationRequest(["op": "ask"])
                guard result?.objectValue?["performed"]?.boolValue == true else {
                    throw ActionError.unavailable("Select some text in the PDF first")
                }
                return [
                    "performed": .bool(true),
                    "windowID": .string(runtime.windowID),
                    "workspaceID": .string(runtime.workspaceID),
                    "tabID": ActionValue(runtime.selectedTabID)
                ]
            }
            guard runtime.performCurrentEditorBridgeCommand("beginAnnotationQuestion") else {
                throw ActionError.unavailable("Available only in an editable text document")
            }
            return [
                "performed": .bool(true),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }
    }

    /// Labels are strings, but callers (and the CLI's argument coercion) often
    /// send numbers for numeric labels.
    private static func labelValue(_ value: ActionValue) -> ActionValue? {
        switch value {
        case .string:
            return value
        case .int(let number):
            return .string(String(number))
        default:
            return nil
        }
    }

    // MARK: - Export

    private static func exportDestination(_ raw: String?, documentPath: String, json: Bool) throws -> URL {
        let documentURL = URL(fileURLWithPath: documentPath)
        let defaultName = documentURL.deletingPathExtension().lastPathComponent + (json ? ".annotations.json" : ".annotations.md")
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return documentURL.deletingLastPathComponent().appendingPathComponent(defaultName)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : documentURL.deletingLastPathComponent().appendingPathComponent(expanded)
        var isDirectory: ObjCBool = false
        let existingFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if existingFolder || raw.hasSuffix("/") {
            return url.appendingPathComponent(defaultName)
        }
        return url.standardizedFileURL
    }

    /// Document order, with annotations whose text was edited away last.
    private static func exportOrder(_ annotations: [ActionValue]) -> [[String: ActionValue]] {
        let objects = annotations.compactMap(\.objectValue)
        // Text documents give lines and PDFs pages; the source keeps them in reading order.
        return objects.enumerated().sorted { left, right in
            let leftKey = left.element["line"].flatMap(intValue) ?? left.element["page"].flatMap(intValue) ?? Int.max
            let rightKey = right.element["line"].flatMap(intValue) ?? right.element["page"].flatMap(intValue) ?? Int.max
            return leftKey == rightKey ? left.offset < right.offset : leftKey < rightKey
        }.map(\.element)
    }

    private static func intValue(_ value: ActionValue) -> Int? {
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        default: return nil
        }
    }

    private static func exportMarkdown(_ annotations: [ActionValue], documentPath: String) -> String {
        let name = URL(fileURLWithPath: documentPath).lastPathComponent
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
        var lines = ["# Annotations: \(name)", "", "Source: `\(documentPath)`  ", "Exported: \(stamp)", ""]
        let ordered = exportOrder(annotations)
        if ordered.isEmpty {
            lines.append("No annotations.")
        }

        for annotation in ordered {
            let label = annotation["label"]?.stringValue ?? "?"
            let isReader = annotation["author"]?.stringValue == "user"
            let detached = annotation["detached"]?.boolValue == true
            var heading = "## \(label)"
            if let page = annotation["page"].flatMap(intValue) {
                let end = annotation["endPage"].flatMap(intValue) ?? page
                heading += end > page ? " · pages \(page)–\(end)" : " · page \(page)"
            } else if let line = annotation["line"].flatMap(intValue) {
                let end = annotation["endLine"].flatMap(intValue) ?? line
                heading += end > line ? " · lines \(line)–\(end)" : " · line \(line)"
            } else if detached {
                heading += " · no longer in the document"
            }
            lines.append(heading)
            lines.append("")

            let passage = (detached ? nil : annotation["text"]?.stringValue) ?? annotation["quote"]?.stringValue ?? ""
            lines.append(contentsOf: passage.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" })
            lines.append("")

            if let note = annotation["note"]?.stringValue, !note.isEmpty {
                lines.append("**\(isReader ? "Question" : "Note"):** \(note)")
                lines.append("")
            } else if isReader {
                lines.append("*Highlighted without a question.*")
                lines.append("")
            }
            if let answer = annotation["answer"]?.stringValue, !answer.isEmpty {
                var who = annotation["answeredBy"]?.stringValue ?? "Answer"
                if annotation["answerStale"]?.boolValue == true {
                    who += ", to an earlier version of the question"
                }
                lines.append("**Answer (\(who)):** \(answer)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func exportJSON(_ annotations: [ActionValue], documentPath: String) throws -> String {
        let payload: ActionValue = [
            "document": .string(documentPath),
            "exportedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "annotations": .array(exportOrder(annotations).map { .object($0) })
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Request flow

    private static let editorWaitAttempts = 40
    private static let editorWaitInterval: UInt64 = 100_000_000

    private static func perform(
        _ payload: [String: ActionValue],
        request: ActionRequest,
        context: ActionExecutionContext
    ) async throws -> ActionValue {
        struct PathArgs: Decodable {
            let path: String?
        }

        guard var runtime = WorkspaceActionRouter.runtime(for: context.resolvedTarget) else {
            throw ActionError.targetNotFound("Could not resolve a target workspace")
        }

        let requestedPath = ((try? request.decodeArgs(PathArgs.self))?.path ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var documentPath = runtime.currentDocumentSnapshot()?.absolutePath
        if !requestedPath.isEmpty {
            let target = try resolveDocument(requestedPath, runtime: runtime)
            runtime = showDocument(target.document, absolutePath: target.absolutePath, from: runtime)
            documentPath = target.absolutePath
        } else if runtime.currentDocumentSnapshot() == nil {
            throw ActionError.unavailable("No document is open in the selected tab; pass path to open one")
        }

        for attempt in 0..<editorWaitAttempts {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: editorWaitInterval)
            }
            // A newly opened document may land in a new tab, which is its own
            // window runtime; only talk to the one actually showing the file.
            if !requestedPath.isEmpty, let documentPath {
                guard let showing = WorkspaceActionRouter.runtime(showingDocumentAt: documentPath) else {
                    continue
                }
                runtime = showing
            }
            if let result = await runtime.performEditorAnnotationRequest(payload) {
                if let error = result.objectValue?["error"]?.stringValue {
                    throw ActionError.invalidArguments(error)
                }
                return decorate(result, documentPath: documentPath)
            }
        }

        throw ActionError.unavailable(
            "The document is not showing in a text editor. Annotations support Markdown, Org, plain text, and PDF documents, not rendered previews."
        )
    }

    private static func decorate(_ result: ActionValue, documentPath: String?) -> ActionValue {
        guard var object = result.objectValue else { return result }
        if let documentPath {
            object["absolutePath"] = .string(documentPath)
        }
        return .object(object)
    }

    // MARK: - Documents

    private struct TargetDocument {
        let document: WorkspaceOpenedDocument
        let absolutePath: String
    }

    /// Accepts a workspace-relative path, or an absolute/`~` path anywhere on
    /// disk; files outside the project open as external documents.
    private static func resolveDocument(
        _ rawPath: String,
        runtime: any WorkspaceActionRuntime
    ) throws -> TargetDocument {
        let rootURL = URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true).standardizedFileURL
        let expanded = (rawPath as NSString).expandingTildeInPath
        let fileURL = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : rootURL.appendingPathComponent(expanded, isDirectory: false).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ActionError.invalidArguments("No file at path", details: ["path": .string(fileURL.path)])
        }

        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if fileURL.path.hasPrefix(rootPrefix) {
            let relativePath = String(fileURL.path.dropFirst(rootPrefix.count))
            return TargetDocument(document: .workspaceNote(relativePath: relativePath), absolutePath: fileURL.path)
        }
        return TargetDocument(document: .externalMarkdown(filePath: fileURL.path), absolutePath: fileURL.path)
    }

    /// Selects a tab already showing the document, else opens it — in the
    /// current tab when that tab is empty, otherwise in a new one.
    private static func showDocument(
        _ document: WorkspaceOpenedDocument,
        absolutePath: String,
        from runtime: any WorkspaceActionRuntime
    ) -> any WorkspaceActionRuntime {
        if let showing = WorkspaceActionRouter.runtime(showingDocumentAt: absolutePath) {
            if let window = NSApp.window(withWindowNumber: showing.windowNumber),
               let tabGroup = window.tabGroup,
               tabGroup.selectedWindow !== window {
                tabGroup.selectedWindow = window
            }
            // Later calls without a path should follow the document the agent
            // just brought forward, even though the app was not activated.
            WorkspaceActionRouter.markWindowActive(showing.windowNumber)
            return showing
        }
        let disposition: WorkspaceActionOpenDisposition = runtime.currentDocumentSnapshot() == nil ? .currentTab : .newTab
        runtime.openDocument(document, disposition: disposition)
        return runtime
    }

    // MARK: - Descriptors

    private static let pathArgument = ActionArgumentDescriptor(
        name: "path",
        summary: "Document to annotate: workspace-relative or absolute. Omit for the selected tab's document.",
        kind: .string,
        isRequired: false
    )

    private static let addDescriptor = ActionDescriptor(
        method: "workspace.annotations.add",
        title: "Add Annotations",
        summary: "Mark passages in a text document with labelled, visual-only annotations.",
        discussion: "Each annotation anchors by quoting its text ({quote, prefix?, suffix?, occurrence?, label?, style?, color?, note?}). Nothing is written to the file.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "annotations", "agent"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "annotations", summary: "Annotations to add", kind: .array, isRequired: true),
            ActionArgumentDescriptor(name: "replace", summary: "Remove the agent's existing annotations first", kind: .bool, isRequired: false),
            ActionArgumentDescriptor(name: "reveal", summary: "Scroll to the first added annotation (default true)", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Per-annotation anchoring results and the document's annotations", kind: .object)
    )

    private static let removeDescriptor = ActionDescriptor(
        method: "workspace.annotations.remove",
        title: "Remove Annotations",
        summary: "Remove annotations by label, id, or author; with no filter, remove all.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "annotations", "agent"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "labels", summary: "Labels to remove", kind: .array, isRequired: false),
            ActionArgumentDescriptor(name: "ids", summary: "Ids to remove", kind: .array, isRequired: false),
            ActionArgumentDescriptor(name: "author", summary: "agent or user", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Removed count and remaining annotations", kind: .object)
    )

    private static let listDescriptor = ActionDescriptor(
        method: "workspace.annotations.list",
        title: "List Annotations",
        summary: "List a document's annotations with their current text and lines.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "annotations", "agent"],
        arguments: [pathArgument],
        result: ActionResultDescriptor(summary: "The document's annotations", kind: .object)
    )

    private static let questionsDescriptor = ActionDescriptor(
        method: "workspace.annotations.questions",
        title: "List Annotation Questions",
        summary: "List the reader's annotations — their highlights and questions — that have no answer yet.",
        discussion: "Each carries the marked text, its lines, and the question (empty for a plain highlight).",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "annotations", "questions", "agent"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "includeAnswered", summary: "Include answered questions too", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "The reader's annotations", kind: .object)
    )

    private static let answerDescriptor = ActionDescriptor(
        method: "workspace.annotations.answer",
        title: "Answer Annotation",
        summary: "Show an answer beneath an annotation's note, e.g. a reply to the reader's question.",
        discussion: "An empty answer removes the existing one.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "annotations", "questions", "agent"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "label", summary: "Annotation label or id, e.g. Q1", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "answer", summary: "Answer text; light Markdown", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "by", summary: "Who is answering, shown with the answer", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Answer result", kind: .object)
    )

    private static let exportDescriptor = ActionDescriptor(
        method: "workspace.annotations.export",
        title: "Export Annotations",
        summary: "Write a document's annotations, questions, and answers to a file.",
        discussion: "Markdown (default) or JSON, in document order with each marked passage quoted. Defaults to <document name>.annotations.md beside the document; an existing file is replaced.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "annotations", "export"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "to", summary: "Output file or folder; relative paths resolve beside the document", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "format", summary: "markdown or json", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Written file path and annotation count", kind: .object)
    )

    private static let askDescriptor = ActionDescriptor(
        method: "workspace.annotations.ask",
        title: "Ask About Selection",
        summary: "Mark the selection and type a question about it for an agent to answer.",
        discussion: "Opens a question box under the selection (or the caret's line). Enter with no text saves a plain highlight. Also bound to Command-Shift-M in the editor.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "annotations", "questions", "highlight"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Whether the question box opened", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "questionmark.bubble",
            when: "\(editableTextSurfacePaletteCondition) || activeEditor.surface == \"pdf\"",
            title: "Ask about selection",
            rank: 20,
            keywords: ["annotate", "highlight", "question", "comment", "claude", "agent"]
        )
    )

    private static let revealDescriptor = ActionDescriptor(
        method: "workspace.annotations.reveal",
        title: "Reveal Annotation",
        summary: "Scroll an annotation into view and briefly emphasise it.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "annotations", "agent"],
        arguments: [
            pathArgument,
            ActionArgumentDescriptor(name: "label", summary: "Annotation label or id", kind: .string, isRequired: true)
        ],
        result: ActionResultDescriptor(summary: "Reveal result and the document's annotations", kind: .object)
    )
}
