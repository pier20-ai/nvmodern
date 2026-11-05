import XCTest
@testable import nvModern

/// The command palette lists actions straight off `ActionRegistry`, so the
/// registry has to carry everything the old hand-maintained palette command
/// catalog exposed, with availability expressions the evaluator understands.
@MainActor
final class PaletteActionCatalogTests: XCTestCase {

    /// Every method the old palette enum mapped to, listed explicitly so a
    /// dropped descriptor fails here instead of silently vanishing from the UI.
    private let legacyPaletteMethods: [String] = [
        // Create
        "workspace.note.create",
        "workspace.note.createFromClipboard",
        // Workspace / Layout
        "workspace.tab.new",
        "workspace.tab.duplicate",
        "workspace.split.right",
        "workspace.split.down",
        // Document
        "workspace.document.copyPath",
        "workspace.document.copyRelativePath",
        "workspace.document.rename",
        "workspace.document.openParentFolder",
        "workspace.document.showInParentFolder",
        "workspace.document.appearance",
        "workspace.document.find",
        "workspace.note.duplicateCurrent",
        "workspace.document.reveal",
        "workspace.document.openInZed",
        "workspace.document.reload",
        "workspace.document.diff.selectOriginal",
        "workspace.document.diff.compareWithSelected",
        // Format
        "markdown.selection.quote",
        "markdown.selection.unquote",
        // Table
        "markdown.table.insert",
        "markdown.table.row.insertAbove",
        "markdown.table.row.insertBelow",
        "markdown.table.row.delete",
        "markdown.table.row.moveUp",
        "markdown.table.row.moveDown",
        "markdown.table.column.insertLeft",
        "markdown.table.column.insertRight",
        "markdown.table.column.delete",
        "markdown.table.column.moveLeft",
        "markdown.table.column.moveRight",
        "markdown.table.column.alignLeft",
        "markdown.table.column.alignCenter",
        "markdown.table.column.alignRight",
        "markdown.table.cell.clear"
    ]

    /// Verbs the palette only ever lists with a noun bound.
    private let passageMethods = [
        "workspace.passage.quote",
        "workspace.passage.transclude",
        "workspace.passage.copy"
    ]

    private var registry: ActionRegistry {
        let registry = ActionRegistry.shared
        registry.ensureBuiltinsRegistered()
        return registry
    }

    // MARK: - Catalog coverage

    func testEveryLegacyPaletteCommandHasPalettePresentation() {
        for method in legacyPaletteMethods {
            guard let descriptor = registry.descriptor(for: method) else {
                XCTFail("no registry descriptor for \(method)")
                continue
            }
            guard let palette = descriptor.palette else {
                XCTFail("\(method) has no palette presentation")
                continue
            }
            XCTAssertFalse(palette.category.isEmpty, "\(method) has an empty palette category")
            XCTAssertFalse(descriptor.paletteTitle.isEmpty, "\(method) has an empty palette title")
        }
    }

    func testPaletteCategoriesAreFromTheKnownSet() {
        let allowed: Set<String> = [
            "Open", "File", "Document", "Format", "Window", "Capture", "Create", "Appearance", "Help", "User"
        ]
        for descriptor in registry.allDescriptors() {
            guard let palette = descriptor.palette else { continue }
            XCTAssertTrue(
                allowed.contains(palette.category),
                "\(descriptor.method) uses unknown palette category \(palette.category)"
            )
        }
    }

    func testIntrospectionActionsStayOutOfThePalette() {
        let hidden = [
            "app.actions.list",
            "app.actions.describe",
            "app.health.ping",
            "content.query",
            "workspace.search.query",
            "workspace.tabs.list",
            "workspace.note.get",
            "workspace.note.current",
            "workspace.recent.list",
            "workspace.recent.open",
            "workspace.editor.selection.get",
            "workspace.document.jump"
        ]
        for method in hidden {
            guard let descriptor = registry.descriptor(for: method) else {
                XCTFail("no registry descriptor for \(method)")
                continue
            }
            XCTAssertNil(descriptor.palette, "\(method) should not be palette-visible")
        }
    }

    // MARK: - Availability expressions

    /// A workspace with an editable Markdown note open in the selected tab.
    private var textEditorVariables: [String: ActionValue] {
        [
            "activeDocument": [
                "kind": .string("workspaceNote"),
                "title": .string("weekly.md"),
                "relativePath": .string("Notes/weekly.md"),
                "absolutePath": .string("/notes/Notes/weekly.md"),
                "projectRootPath": .string("/notes"),
                "windowID": .string("w1"),
                "workspaceID": .string("ws1"),
                "tabID": .string("t1"),
                "isEditable": .bool(true)
            ],
            "activeEditor": [
                "surface": .string("text"),
                "path": .string("Notes/weekly.md"),
                "isEditable": .bool(true),
                "supportsSelectionReplacement": .bool(true)
            ],
            "activeWorkspace": [
                "windowID": .string("w1"),
                "workspaceID": .string("ws1"),
                "projectRootPath": .string("/notes"),
                "selectedTabID": .string("t1"),
                "hasDiffOriginal": .bool(true),
                "isSidebarVisible": .bool(true)
            ]
        ]
    }

    /// A launchpad tab: no document, no editor, no diff original.
    private var emptyWorkspaceVariables: [String: ActionValue] {
        [
            "activeDocument": .null,
            "activeEditor": .null,
            "activeWorkspace": [
                "windowID": .string("w1"),
                "workspaceID": .string("ws1"),
                "projectRootPath": .string("/notes"),
                "selectedTabID": .string("t1"),
                "hasDiffOriginal": .bool(false),
                "isSidebarVisible": .bool(true)
            ]
        ]
    }

    /// Root identifiers the automation context actually publishes. A typo in a
    /// `when` string would otherwise silently evaluate to false forever.
    func testPaletteConditionsOnlyReferenceKnownContextVariables() {
        let known: Set<String> = [
            "activeDocument", "activeEditor", "activeWorkspace",
            "clipboard", "app", "source", "uuid",
            "nowISO8601", "nowDate", "nowTime", "nowUnix"
        ]

        for descriptor in registry.allDescriptors() {
            guard let when = descriptor.palette?.when else { continue }
            for root in Self.identifierRoots(in: when) {
                XCTAssertTrue(
                    known.contains(root),
                    "\(descriptor.method) references unknown context variable \(root) in when: \(when)"
                )
            }
        }
    }

    func testFormatAndTableActionsAreHiddenWithoutATextEditor() {
        let formatMethods = [
            "markdown.selection.quote",
            "markdown.selection.unquote",
            "markdown.table.insert",
            "markdown.table.row.insertAbove",
            "markdown.table.column.alignCenter",
            "markdown.table.cell.clear"
        ]

        for method in formatMethods {
            guard let when = registry.descriptor(for: method)?.palette?.when else {
                XCTFail("\(method) has no palette condition")
                continue
            }
            XCTAssertTrue(
                ActionExpressionEvaluator.evaluate(when, variables: textEditorVariables),
                "\(method) should be available with a text editor open"
            )
            XCTAssertFalse(
                ActionExpressionEvaluator.evaluate(when, variables: emptyWorkspaceVariables),
                "\(method) should be hidden with no text editor"
            )
        }
    }

    func testDocumentAndDiffConditions() {
        func when(_ method: String) -> String? {
            registry.descriptor(for: method)?.palette?.when
        }

        guard let reveal = when("workspace.document.reveal"),
              let refile = when("workspace.note.refile"),
              let compare = when("workspace.document.diff.compareWithSelected") else {
            return XCTFail("missing palette conditions")
        }

        XCTAssertTrue(ActionExpressionEvaluator.evaluate(reveal, variables: textEditorVariables))
        XCTAssertFalse(ActionExpressionEvaluator.evaluate(reveal, variables: emptyWorkspaceVariables))

        XCTAssertTrue(ActionExpressionEvaluator.evaluate(refile, variables: textEditorVariables))
        XCTAssertFalse(ActionExpressionEvaluator.evaluate(refile, variables: emptyWorkspaceVariables))

        XCTAssertTrue(ActionExpressionEvaluator.evaluate(compare, variables: textEditorVariables))
        XCTAssertFalse(ActionExpressionEvaluator.evaluate(compare, variables: emptyWorkspaceVariables))
    }

    func testUnconditionalActionsStayVisibleInAnEmptyWorkspace() {
        for method in ["workspace.tab.new"] {
            guard let descriptor = registry.descriptor(for: method) else {
                XCTFail("no registry descriptor for \(method)")
                continue
            }
            XCTAssertNil(descriptor.palette?.when, "\(method) should not be gated")
        }
    }

    // MARK: - Argument pickers

    func testArgumentPickersTheFrameStackCollects() {
        let expected: [String: (String, ActionArgumentPicker)] = [
            "workspace.note.refile": ("folder", .workspaceFolder),
            "workspace.theme.select": ("id", .editorTheme),
            "workspace.document.theme.select": ("id", .editorTheme),
            "workspace.document.width.select": ("width", .documentWidth),
            "workspace.document.rename": ("name", .text),
            "workspace.note.create": ("fileName", .text)
        ]

        for (method, expectation) in expected {
            guard let descriptor = registry.descriptor(for: method) else {
                XCTFail("no registry descriptor for \(method)")
                continue
            }
            guard let argument = descriptor.paletteArgumentToCollect(given: [:]) else {
                XCTFail("\(method) collects no argument")
                continue
            }
            XCTAssertEqual(argument.name, expectation.0, "wrong argument for \(method)")
            XCTAssertEqual(argument.picker, expectation.1, "wrong picker for \(method)")
        }
    }

    func testSuppliedArgumentsSkipTheirPicker() {
        guard let descriptor = registry.descriptor(for: "workspace.note.refile") else {
            return XCTFail("missing workspace.note.refile")
        }
        XCTAssertNil(descriptor.paletteArgumentToCollect(given: ["folder": .string("Archive")]))
    }

    // MARK: - Passage verbs

    func testPassageVerbsExistAndAreListedOnlyWhenBound() {
        for method in passageMethods {
            guard let palette = registry.descriptor(for: method)?.palette else {
                XCTFail("no palette presentation for \(method)")
                continue
            }
            XCTAssertTrue(palette.listedOnlyWhenBound, "\(method) should not list in root")
            XCTAssertEqual(palette.argumentName(for: .passage), "path")
            XCTAssertEqual(palette.resolvedSubject, .document)
            XCTAssertNil(palette.when, "\(method) is gated by its noun, not by a condition")
        }
    }

    // MARK: - Batch verbs

    func testBatchVerbsOptInExplicitly() {
        for method in ["workspace.note.refile", "workspace.document.copyPath", "workspace.document.copyRelativePath"] {
            XCTAssertEqual(
                registry.descriptor(for: method)?.palette?.acceptsBatch,
                true,
                "\(method) should accept a batch subject"
            )
            XCTAssertEqual(
                registry.descriptor(for: method)?.palette?.argumentName(for: .note),
                "path",
                "\(method) needs a note noun to be batchable"
            )
        }

        // Everything else stays single-subject unless it says otherwise.
        XCTAssertNotEqual(registry.descriptor(for: "workspace.document.rename")?.palette?.acceptsBatch, true)
    }

    func testRefileAcceptsAPathArgument() {
        guard let descriptor = registry.descriptor(for: "workspace.note.refile") else {
            return XCTFail("missing workspace.note.refile")
        }
        XCTAssertTrue(descriptor.arguments.contains { $0.name == "path" })
    }

    // MARK: - Noun binding

    func testNounArgumentsBindNotesAndFolders() {
        let noteVerbs = [
            "workspace.document.copyPath",
            "workspace.document.copyRelativePath",
            "workspace.document.rename",
            "workspace.document.openParentFolder",
            "workspace.document.showInParentFolder",
            "workspace.note.openInNewTab",
            "workspace.note.refile",
            "workspace.stack.push"
        ]
        for method in noteVerbs {
            XCTAssertEqual(
                registry.descriptor(for: method)?.palette?.argumentName(for: .note),
                "path",
                "\(method) should bind a note noun to its path argument"
            )
        }

        let folderVerbs = [
            "workspace.note.create",
            "workspace.note.createFromClipboard"
        ]
        for method in folderVerbs {
            XCTAssertEqual(
                registry.descriptor(for: method)?.palette?.argumentName(for: .folder),
                "folder",
                "\(method) should bind a folder noun to its folder argument"
            )
        }
    }

    // MARK: - Helpers

    /// Root segments of every dotted path in an expression, ignoring string
    /// literals, numbers, and the boolean/null keywords.
    private static func identifierRoots(in expression: String) -> Set<String> {
        var roots: Set<String> = []
        var current = ""
        var inString = false
        var stringDelimiter: Character = "\""

        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            guard !["true", "false", "null"].contains(current) else { return }
            guard Double(current) == nil else { return }
            roots.insert(current.split(separator: ".").first.map(String.init) ?? current)
        }

        for character in expression {
            if inString {
                if character == stringDelimiter { inString = false }
                continue
            }
            if character == "\"" || character == "'" {
                flush()
                inString = true
                stringDelimiter = character
                continue
            }
            if character.isLetter || character.isNumber || character == "." || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return roots
    }
}
