import Foundation

/// Curated MCP tool surface. The adapter flattens agent-friendly names
/// (`path`, `project`) onto action args and `ActionTarget`; it does not
/// dump the full action registry.
struct ActionMCPTool: Equatable, Sendable {
    var name: String
    var method: String
    var title: String
    var description: String
    var properties: [ActionMCPProperty]
    var aliases: [ActionMCPAlias]
    var includesProject: Bool

    func invocation(from arguments: [String: ActionValue]) -> ActionMCPInvocation {
        var args = arguments
        var target = ActionTarget.automatic

        if includesProject, let project = args.removeValue(forKey: "project")?.stringValue {
            let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                target.project = Self.projectSelector(trimmed)
            }
        }

        for alias in aliases {
            if let value = args.removeValue(forKey: alias.from) {
                args[alias.to] = value
            }
        }

        return ActionMCPInvocation(method: method, args: args, target: target)
    }

    func inputSchema() -> ActionValue {
        var schemaProperties: [String: ActionValue] = [:]
        var required: [ActionValue] = []

        for property in listedProperties() {
            var propertySchema: [String: ActionValue] = [
                "type": .string(property.jsonType.rawValue),
                "description": .string(property.summary)
            ]
            if let values = property.enumValues, !values.isEmpty {
                propertySchema["enum"] = .array(values.map { .string($0) })
            }
            if let items = property.items {
                propertySchema["items"] = items
            }
            schemaProperties[property.name] = .object(propertySchema)
            if property.required {
                required.append(.string(property.name))
            }
        }

        var schema: [String: ActionValue] = [
            "type": .string("object"),
            "properties": .object(schemaProperties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required)
        }
        return .object(schema)
    }

    func listedProperties() -> [ActionMCPProperty] {
        var listed = properties
        if includesProject {
            listed.append(ActionMCPCatalog.projectProperty)
        }
        return listed
    }

    private static func projectSelector(_ raw: String) -> ActionTarget.ProjectSelector {
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return .rootPath((raw as NSString).expandingTildeInPath)
        }
        return .named(raw)
    }
}

struct ActionMCPProperty: Equatable, Sendable {
    enum JSONType: String, Equatable, Sendable {
        case string
        case integer
        case number
        case boolean
        case object
        case array
    }

    var name: String
    var summary: String
    var jsonType: JSONType
    var required: Bool
    var enumValues: [String]? = nil
    /// JSON schema for array elements.
    var items: ActionValue? = nil
}

struct ActionMCPAlias: Equatable, Sendable {
    var from: String
    var to: String
}

struct ActionMCPInvocation: Equatable, Sendable {
    var method: String
    var args: [String: ActionValue]
    var target: ActionTarget
}

enum ActionMCPCatalog {
    static let projectProperty = ActionMCPProperty(
        name: "project",
        summary: "Optional project name or absolute root path. Defaults to the frontmost workspace.",
        jsonType: .string,
        required: false
    )

    private static let openInProperty = ActionMCPProperty(
        name: "openIn",
        summary: "Where to open the document",
        jsonType: .string,
        required: false,
        enumValues: ["currentTab", "newTab"]
    )

    private static let annotationItemSchema: ActionValue = [
        "type": "object",
        "properties": [
            "quote": ["type": "string", "description": "Exact source text to mark; whitespace differences are tolerated"],
            "label": ["type": "string", "description": "Badge text; defaults to the next number"],
            "style": ["type": "string", "enum": ["highlight", "underline", "box"], "description": "Default highlight"],
            "color": [
                "type": "string",
                "enum": ["yellow", "blue", "green", "pink", "purple", "orange", "red"],
                "description": "Defaults by label number so neighbours differ"
            ],
            "note": [
                "type": "string",
                "description": "Explanation shown beside the passage in nvModern's margin: 1-4 sentences, light Markdown (**bold**, *italic*, `code`, - lists). Give the same substance you say in chat."
            ],
            "prefix": ["type": "string", "description": "Text just before the quote, to pick among repeats"],
            "suffix": ["type": "string", "description": "Text just after the quote, to pick among repeats"],
            "occurrence": ["type": "integer", "description": "1-based match to use when the quote repeats"]
        ],
        "required": ["quote"],
        "additionalProperties": false
    ]

    static let tools: [ActionMCPTool] = [
        makeTool(
            name: "ping",
            method: "app.health.ping",
            title: "Ping nvModern",
            description: "Check that the nvModern app is running and the action socket is reachable.",
            includesProject: false
        ),
        makeTool(
            name: "get_help",
            method: "app.help.get",
            title: "Get nvModern Help",
            description: "Read nvModern's built-in help. With no arguments, lists help providers (e.g. calc). With provider, returns that provider's full Markdown reference. With provider and topic, returns one topic. Check this before guessing how a feature, shortcut, or calc function works.",
            properties: [
                ActionMCPProperty(name: "provider", summary: "Help provider id from the listing", jsonType: .string, required: false),
                ActionMCPProperty(name: "topic", summary: "Topic id within the provider", jsonType: .string, required: false)
            ],
            includesProject: false
        ),
        makeTool(
            name: "get_context",
            method: "workspace.context.current",
            title: "Get Workspace Context",
            description: "Return what the user is looking at: project, open tabs, visible viewport text, selection, and cursor. Prefer this before reading notes."
        ),
        makeTool(
            name: "get_project",
            method: "workspace.project.current",
            title: "Get Current Project",
            description: "Return the active project name and root path."
        ),
        makeTool(
            name: "list_projects",
            method: "workspace.projects.list",
            title: "List Projects",
            description: "List configured nvModern projects. Includes the current project when a workspace is available."
        ),
        makeTool(
            name: "get_open_tabs",
            method: "workspace.tabs.list",
            title: "List Open Tabs",
            description: "List tabs in the target workspace window."
        ),
        makeTool(
            name: "search_notes",
            method: "workspace.search.query",
            title: "Search Notes",
            description: "Full-text search of the current project's note index. Uses the same query language as nvModern content search, including facet prefixes.",
            properties: [
                ActionMCPProperty(name: "query", summary: "Full-text search query", jsonType: .string, required: true),
                ActionMCPProperty(name: "limit", summary: "Maximum hits to return (default 20, cap 80)", jsonType: .integer, required: false)
            ]
        ),
        makeTool(
            name: "get_active_note",
            method: "workspace.note.current",
            title: "Get Active Note",
            description: "Return metadata for the document in the selected tab. Does not include body text; use get_note for the body."
        ),
        makeTool(
            name: "get_note",
            method: "workspace.note.get",
            title: "Get Note",
            description: "Read a workspace note by relative path without opening a tab. Body is truncated at maxBytes (default 48KiB, cap 256KiB).",
            properties: [
                ActionMCPProperty(name: "path", summary: "Workspace-relative note path", jsonType: .string, required: true),
                ActionMCPProperty(name: "maxBytes", summary: "Maximum body bytes to return", jsonType: .integer, required: false)
            ],
            aliases: [ActionMCPAlias(from: "path", to: "relativePath")]
        ),
        makeTool(
            name: "get_selection",
            method: "workspace.editor.selection.get",
            title: "Get Selection",
            description: "Return the current text selection and its line range from the focused editor (including a focused child-pane editor), or the selection and page range in the selected tab's PDF."
        ),
        makeTool(
            name: "get_cursor_context",
            method: "workspace.editor.cursorContext.get",
            title: "Get Cursor Context",
            description: "Return text around the caret in the focused editor (about 12 lines / 2000 characters)."
        ),
        makeTool(
            name: "replace_selection",
            method: "workspace.editor.selection.replace",
            title: "Replace Selection",
            description: "Replace the current selection in the focused editor. If the selection is empty, inserts at the caret.",
            properties: [
                ActionMCPProperty(name: "text", summary: "Replacement or insertion text", jsonType: .string, required: true)
            ]
        ),
        makeTool(
            name: "jump_in_document",
            method: "workspace.document.jump",
            title: "Jump in Document",
            description: "Jump to a Markdown heading or 1-based line in the current document.",
            properties: [
                ActionMCPProperty(name: "heading", summary: "Heading text or slug", jsonType: .string, required: false),
                ActionMCPProperty(name: "line", summary: "1-based line number", jsonType: .integer, required: false)
            ]
        ),
        makeTool(
            name: "open_note",
            method: "workspace.note.open",
            title: "Open Note",
            description: "Open a workspace note in the current tab or a new tab.",
            properties: [
                ActionMCPProperty(name: "path", summary: "Workspace-relative note path", jsonType: .string, required: true),
                openInProperty
            ],
            aliases: [ActionMCPAlias(from: "path", to: "relativePath")]
        ),
        makeTool(
            name: "open_in_side_stack",
            method: "workspace.stack.push",
            title: "Open in Side Stack",
            description: """
            Show a note as a read-only card in the side stack, the column beside the document the user is reading, \
            without navigating away from it. Use it to put reference notes (definitions, specs, related notes) next to \
            what the user reads. Pass heading or block to show only that section. If the note (and section) is already \
            in the stack, its card is revealed instead of duplicated. Markdown, Org, and plain-text notes only.
            """,
            properties: [
                ActionMCPProperty(name: "path", summary: "Workspace-relative note path or note name", jsonType: .string, required: true),
                ActionMCPProperty(name: "heading", summary: "Optional heading to focus the card on", jsonType: .string, required: false),
                ActionMCPProperty(name: "block", summary: "Optional ^block id to focus the card on (without ^)", jsonType: .string, required: false)
            ]
        ),
        makeTool(
            name: "create_note",
            method: "workspace.note.create",
            title: "Create Note",
            description: "Create a workspace note, optionally opening it.",
            properties: [
                ActionMCPProperty(name: "fileName", summary: "File name to create, including extension", jsonType: .string, required: true),
                ActionMCPProperty(name: "folder", summary: "Optional parent folder relative path", jsonType: .string, required: false),
                ActionMCPProperty(name: "body", summary: "Optional initial note body", jsonType: .string, required: false),
                ActionMCPProperty(name: "open", summary: "Whether to open the note (default true)", jsonType: .boolean, required: false),
                openInProperty
            ]
        ),
        makeTool(
            name: "list_recent",
            method: "workspace.recent.list",
            title: "List Recent Documents",
            description: "List recently opened documents in the target project.",
            properties: [
                ActionMCPProperty(name: "limit", summary: "Maximum items to return (default 12)", jsonType: .integer, required: false)
            ]
        ),
        makeTool(
            name: "open_recent",
            method: "workspace.recent.open",
            title: "Open Recent Document",
            description: "Open a recently opened document by id or relative path.",
            properties: [
                ActionMCPProperty(name: "id", summary: "Recent-item id from list_recent", jsonType: .string, required: false),
                ActionMCPProperty(name: "path", summary: "Workspace-relative path", jsonType: .string, required: false),
                openInProperty
            ],
            aliases: [ActionMCPAlias(from: "path", to: "relativePath")]
        ),
        makeTool(
            name: "get_backlinks",
            method: "content.backlinks.query",
            title: "Get Backlinks",
            description: "Return notes that wikilink to a target path or basename.",
            properties: [
                ActionMCPProperty(name: "path", summary: "Target note path or basename", jsonType: .string, required: true),
                ActionMCPProperty(name: "includeTransclusions", summary: "Include ![[transclusions]]", jsonType: .boolean, required: false),
                ActionMCPProperty(name: "limit", summary: "Optional result limit", jsonType: .integer, required: false)
            ],
            aliases: [ActionMCPAlias(from: "path", to: "targetPath")]
        ),
        makeTool(
            name: "get_heading",
            method: "content.heading.subtree",
            title: "Get Heading Subtree",
            description: "Return the structural records under a heading in a document.",
            properties: [
                ActionMCPProperty(name: "path", summary: "Workspace-relative document path", jsonType: .string, required: true),
                ActionMCPProperty(name: "heading", summary: "Heading slug to locate", jsonType: .string, required: true),
                ActionMCPProperty(name: "includeHeading", summary: "Include the heading record itself", jsonType: .boolean, required: false)
            ],
            aliases: [
                ActionMCPAlias(from: "path", to: "documentPath"),
                ActionMCPAlias(from: "heading", to: "headingSlug")
            ]
        ),
        makeTool(
            name: "annotate",
            method: "workspace.annotations.add",
            title: "Annotate Document",
            description: """
            Mark passages in a document the user has open in nvModern so they can follow along while you explain in chat. \
            Each mark shows a small label badge (e.g. 1, 2, 3) beside highlighted, underlined, or boxed text; refer to it in your reply as (1), (2). \
            Give each a note: it is shown beside the passage in the margin (or opens under it when the user clicks the badge in a narrow window), so the user can read your explanation alongside the text. \
            Marks are visual only: never written to the file and not in undo history. \
            Anchor each annotation by quoting the exact document source text (Markdown syntax included) — a phrase or sentence is best. \
            Add prefix/suffix or occurrence when the quote repeats. Labels default to the next number. \
            Check each result: notFound means the quote didn't match; ambiguous means it repeats and the first match was used. \
            Pass path to open the document first. Works on Markdown, Org, plain text, and PDF documents (in PDFs, quote the page text; results report page numbers).
            """,
            properties: [
                ActionMCPProperty(
                    name: "path",
                    summary: "Document path: workspace-relative, or absolute anywhere on disk. Omit for the document in the selected tab.",
                    jsonType: .string,
                    required: false
                ),
                ActionMCPProperty(
                    name: "annotations",
                    summary: "Passages to mark, in reading order",
                    jsonType: .array,
                    required: true,
                    items: annotationItemSchema
                ),
                ActionMCPProperty(name: "replace", summary: "Remove your existing annotations first (default false)", jsonType: .boolean, required: false),
                ActionMCPProperty(name: "reveal", summary: "Scroll to the first added annotation (default true)", jsonType: .boolean, required: false)
            ]
        ),
        makeTool(
            name: "list_annotations",
            method: "workspace.annotations.list",
            title: "List Annotations",
            description: "List the annotations on a document with their label, author (agent or user), note, and current text and lines. Detached annotations lost their text to edits.",
            properties: [
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false)
            ]
        ),
        makeTool(
            name: "reveal_annotation",
            method: "workspace.annotations.reveal",
            title: "Reveal Annotation",
            description: "Scroll an annotation into view in nvModern and emphasise it and its note (in a narrow window this opens the note under the passage), e.g. when you start discussing it.",
            properties: [
                ActionMCPProperty(name: "label", summary: "Annotation label (or id)", jsonType: .string, required: true),
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false)
            ]
        ),
        makeTool(
            name: "get_questions",
            method: "workspace.annotations.questions",
            title: "Get Reader Questions",
            description: """
            Return what the user marked in nvModern while reading: each has a label (Q1, Q2…), the marked text, its lines, \
            and their question (empty for a plain highlight, which means "explain this"). Unanswered ones by default. \
            Call this when the user says they asked or highlighted something in nvModern (e.g. "?", "next", "answer my questions"). \
            Answer each in chat and with answer_question so the reply also appears beside the passage.
            """,
            properties: [
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false),
                ActionMCPProperty(name: "includeAnswered", summary: "Include questions you already answered", jsonType: .boolean, required: false)
            ]
        ),
        makeTool(
            name: "answer_question",
            method: "workspace.annotations.answer",
            title: "Answer Reader Question",
            description: """
            Show your answer beneath the user's question (or highlight) in nvModern's margin, next to the passage they marked, \
            and scroll it into view. Keep it to the substance — 1-6 sentences, light Markdown (**bold**, *italic*, `code`, - lists); \
            longer discussion can stay in chat. Answering again replaces the answer; an empty answer removes it.
            """,
            properties: [
                ActionMCPProperty(name: "label", summary: "Question label, e.g. Q1", jsonType: .string, required: true),
                ActionMCPProperty(name: "answer", summary: "Answer text", jsonType: .string, required: true),
                ActionMCPProperty(name: "by", summary: "Your name, shown with the answer, e.g. Claude", jsonType: .string, required: false),
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false)
            ]
        ),
        makeTool(
            name: "export_annotations",
            method: "workspace.annotations.export",
            title: "Export Annotations",
            description: """
            Write a document's annotations to a file: every mark in document order with its quoted passage, \
            your notes, the user's questions, and the answers. Markdown by default, or JSON. \
            Defaults to <document name>.annotations.md beside the document (replacing an earlier export); \
            pass `to` for another file or folder. Use when the user asks to export, save, or keep the discussion.
            """,
            properties: [
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false),
                ActionMCPProperty(name: "to", summary: "Output file or folder; relative paths resolve beside the document", jsonType: .string, required: false),
                ActionMCPProperty(name: "format", summary: "Output format (default markdown)", jsonType: .string, required: false, enumValues: ["markdown", "json"])
            ]
        ),
        makeTool(
            name: "clear_annotations",
            method: "workspace.annotations.remove",
            title: "Clear Annotations",
            description: "Remove annotations from a document. Filter by labels or author; with no filter, removes all of them.",
            properties: [
                ActionMCPProperty(name: "path", summary: "Document path; omit for the selected tab's document", jsonType: .string, required: false),
                ActionMCPProperty(name: "labels", summary: "Labels to remove", jsonType: .array, required: false, items: ["type": "string"]),
                ActionMCPProperty(name: "author", summary: "Only remove annotations by this author", jsonType: .string, required: false, enumValues: ["agent", "user"])
            ]
        )
    ]

    static func tool(named name: String) -> ActionMCPTool? {
        tools.first { $0.name == name }
    }

    private static func makeTool(
        name: String,
        method: String,
        title: String,
        description: String,
        properties: [ActionMCPProperty] = [],
        aliases: [ActionMCPAlias] = [],
        includesProject: Bool = true
    ) -> ActionMCPTool {
        ActionMCPTool(
            name: name,
            method: method,
            title: title,
            description: description,
            properties: properties,
            aliases: aliases,
            includesProject: includesProject
        )
    }
}
