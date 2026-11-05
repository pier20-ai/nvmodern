import XCTest
@testable import nvModern

/// Side stack model (ticket 0031): card identity by path + focus, push
/// de-duplication, persistence, and the action/MCP surface over it.
final class SideStackStateTests: XCTestCase {
    // MARK: - Focus

    func testFocusNormalisesHeadingAndBlock() {
        XCTAssertNil(SideStackFocus(heading: "  ", block: nil))
        XCTAssertNil(SideStackFocus(heading: nil, block: "^"))
        XCTAssertEqual(SideStackFocus(heading: " Intro ", block: "abc")?.heading, "Intro")
        XCTAssertNil(SideStackFocus(heading: " Intro ", block: "abc")?.block)
        XCTAssertEqual(SideStackFocus(heading: nil, block: "^abc")?.block, "abc")
        XCTAssertEqual(SideStackFocus(heading: nil, block: "^abc")?.linkSuffix, "#^abc")
        XCTAssertEqual(SideStackFocus(heading: "Intro", block: nil)?.linkSuffix, "#Intro")
    }

    func testFocusFromWikilinkReference() {
        let heading = parseObsidianWikilinkTarget("Notes/Idea#Next steps|later")
        XCTAssertEqual(SideStackFocus(reference: heading.reference), SideStackFocus(heading: "Next steps", block: nil))

        let block = parseObsidianWikilinkTarget("Idea#^q1")
        let blockFocus = SideStackFocus(reference: block.reference)
        XCTAssertEqual(blockFocus?.block, "q1")
        XCTAssertEqual(blockFocus?.reference.kind, .block)
        XCTAssertEqual(blockFocus?.reference.query, "q1")

        XCTAssertNil(SideStackFocus(reference: parseObsidianWikilinkTarget("Idea").reference))
    }

    // MARK: - Push and de-duplication

    func testPushAddsOnTopAndOpensColumn() {
        var stack = SideStackState()
        XCTAssertFalse(stack.isOpen)

        XCTAssertEqual(stack.push(path: "A.md"), .added(id: "A.md"))
        XCTAssertEqual(stack.push(path: "B.md"), .added(id: "B.md"))
        XCTAssertTrue(stack.isOpen)
        XCTAssertEqual(stack.cards.map(\.path), ["B.md", "A.md"])
    }

    func testSamePathAndFocusIsNotDuplicated() {
        var stack = SideStackState()
        stack.push(path: "A.md")
        stack.push(path: "B.md")
        stack.setCollapsed(true, id: "A.md")

        XCTAssertEqual(stack.push(path: "A.md"), .existing(id: "A.md"))
        XCTAssertEqual(stack.cards.count, 2)
        // Order is kept; the existing card is revealed (and expanded) in place.
        XCTAssertEqual(stack.cards.map(\.path), ["B.md", "A.md"])
        XCTAssertEqual(stack.card(id: "A.md")?.collapsed, false)
    }

    func testDifferentFocusOnSameNoteIsADifferentCard() {
        var stack = SideStackState()
        let intro = SideStackFocus(heading: "Intro", block: nil)
        let block = SideStackFocus(heading: nil, block: "q1")

        XCTAssertEqual(stack.push(path: "A.md", focus: intro), .added(id: "A.md#Intro"))
        XCTAssertEqual(stack.push(path: "A.md", focus: block), .added(id: "A.md#^q1"))
        XCTAssertEqual(stack.push(path: "A.md"), .added(id: "A.md"))
        XCTAssertEqual(stack.push(path: "A.md", focus: SideStackFocus(heading: " Intro ", block: nil)), .existing(id: "A.md#Intro"))
        XCTAssertEqual(stack.cards.count, 3)
        XCTAssertTrue(stack.containsCard(path: "A.md", focus: block))
    }

    func testClosingTheLastCardHidesTheColumn() {
        var stack = SideStackState()
        stack.push(path: "A.md")
        stack.push(path: "B.md")

        XCTAssertTrue(stack.close(id: "B.md"))
        XCTAssertTrue(stack.isOpen)
        XCTAssertFalse(stack.close(id: "missing"))
        XCTAssertTrue(stack.close(id: "A.md"))
        XCTAssertFalse(stack.isOpen)
        XCTAssertTrue(stack.isDefault)
    }

    func testRenamesFollowAndDeletionsDrop() {
        var stack = SideStackState()
        stack.push(path: "Old.md", focus: SideStackFocus(heading: "H", block: nil))
        stack.push(path: "New.md", focus: SideStackFocus(heading: "H", block: nil))
        stack.push(path: "Gone.md")

        XCTAssertTrue(stack.applyRenames(["Old.md": "New.md"]))
        // Renaming onto an existing card's id collapses the two.
        XCTAssertEqual(stack.cards.map(\.id), ["Gone.md", "New.md#H"])

        XCTAssertTrue(stack.removeCards(atPaths: ["Gone.md"]))
        XCTAssertEqual(stack.cards.map(\.id), ["New.md#H"])
        XCTAssertFalse(stack.removeCards(atPaths: ["Other.md"]))
    }

    func testWidthIsClamped() {
        XCTAssertEqual(SideStackState(width: 10).width, SideStackState.widthRange.lowerBound)
        XCTAssertEqual(SideStackState(width: 5_000).width, SideStackState.widthRange.upperBound)
        XCTAssertEqual(SideStackState().resolvedWidth, SideStackState.defaultWidth)
    }

    // MARK: - Persistence

    func testStackRoundTripsThroughTheTabSession() throws {
        var stack = SideStackState(width: 400)
        stack.push(path: "Notes/Ref.md", focus: SideStackFocus(heading: nil, block: "def"))
        stack.push(path: "Notes/Spec.org")
        stack.setCollapsed(true, id: "Notes/Spec.org")
        stack.setShowWholeNote(true, id: "Notes/Ref.md#^def")

        var state = WorkspaceTabState(document: .workspaceNote(relativePath: "Notes/Idea.md"))
        state.sideStack = stack

        let data = try JSONEncoder().encode(state.persisted)
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: data)
        XCTAssertEqual(decoded.sideStack, stack)

        let restored = WorkspaceTabState(persisted: decoded)
        XCTAssertEqual(restored.sideStack, stack)
        XCTAssertEqual(restored.sideStack.cards.first?.collapsed, true)
        XCTAssertEqual(restored.sideStack.card(id: "Notes/Ref.md#^def")?.showWholeNote, true)
        XCTAssertEqual(restored.sideStack.width, 400)
    }

    func testEmptyStackIsNotWritten() throws {
        let state = WorkspaceTabState(document: .workspaceNote(relativePath: "Notes/Idea.md"))
        let data = try JSONEncoder().encode(state.persisted)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["sideStack"])
    }

    func testSessionsWithoutAStackStillDecode() throws {
        let json = """
        {
          "kind": "note",
          "selectedFolderChain": [],
          "selectedNotePath": "Idea.md",
          "millerActiveDepth": 0
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.sideStack)
        XCTAssertEqual(WorkspaceTabState(persisted: decoded).sideStack, .empty)
    }

    func testMalformedCardsAndStacksDegradeGracefully() throws {
        let json = """
        {
          "kind": "note",
          "selectedFolderChain": [],
          "selectedNotePath": "Idea.md",
          "millerActiveDepth": 0,
          "sideStack": {
            "cards": [
              { "path": "A.md", "focus": { "heading": "Intro" } },
              { "focus": { "heading": "No path" } },
              { "path": "A.md", "focus": { "heading": "Intro" }, "collapsed": true },
              { "path": "B.md", "collapsed": "yes" }
            ]
          }
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        let stack = try XCTUnwrap(decoded.sideStack)
        XCTAssertEqual(stack.cards.map(\.id), ["A.md#Intro", "B.md"])
        XCTAssertFalse(stack.cards[1].collapsed)
        // No explicit isOpen: a stack with cards restores open.
        XCTAssertTrue(stack.isOpen)

        let broken = """
        { "kind": "note", "selectedFolderChain": [], "selectedNotePath": "Idea.md", "millerActiveDepth": 0, "sideStack": 42 }
        """
        let brokenDecoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(broken.utf8))
        XCTAssertNil(brokenDecoded.sideStack)
        XCTAssertEqual(brokenDecoded.openedDocument, .workspaceNote(relativePath: "Idea.md"))
    }

    // MARK: - Stackable notes

    func testOnlyTextNotesAreStackable() {
        XCTAssertTrue(SideStackController.isStackable(path: "Notes/A.md"))
        XCTAssertTrue(SideStackController.isStackable(path: "Notes/A.ORG"))
        XCTAssertTrue(SideStackController.isStackable(path: "todo.txt"))
        XCTAssertFalse(SideStackController.isStackable(path: "Docs/Spec.pdf"))
        XCTAssertFalse(SideStackController.isStackable(path: "data.csv"))
        XCTAssertFalse(SideStackController.isStackable(path: "plan.outline"))
    }

    // MARK: - Palette and MCP

    func testShiftReturnPushesNoteRowsOnly() {
        XCTAssertEqual(
            PaletteActivation.sideStackPush(for: .openNote(relativePath: "Notes/A.md")),
            .runAction(method: "workspace.stack.push", args: ["path": .string("Notes/A.md")], target: .automatic)
        )
        XCTAssertNil(PaletteActivation.sideStackPush(for: .openNote(relativePath: "Notes/A.md", findTerm: "x")))
        XCTAssertNil(PaletteActivation.sideStackPush(for: .openFolder(relativePath: "Notes")))
        XCTAssertNil(PaletteActivation.sideStackPush(for: .runAction(method: "workspace.tab.new", args: [:], target: .automatic)))
    }

    func testOpenInSideStackMCPTool() throws {
        let tool = try XCTUnwrap(ActionMCPCatalog.tool(named: "open_in_side_stack"))
        XCTAssertEqual(tool.method, "workspace.stack.push")

        let schema = tool.inputSchema().objectValue
        let properties = schema?["properties"]?.objectValue
        XCTAssertNotNil(properties?["path"])
        XCTAssertNotNil(properties?["heading"])
        XCTAssertNotNil(properties?["block"])
        XCTAssertEqual(schema?["required"], .array([.string("path")]))

        let invocation = tool.invocation(from: [
            "path": .string("Reference/Glossary.md"),
            "heading": .string("Terms"),
            "project": .string("Notes")
        ])
        XCTAssertEqual(invocation.args["path"], .string("Reference/Glossary.md"))
        XCTAssertEqual(invocation.args["heading"], .string("Terms"))
        XCTAssertNil(invocation.args["project"])
        XCTAssertEqual(invocation.target.project, .named("Notes"))
    }
}

@MainActor
final class SideStackActionCatalogTests: XCTestCase {
    private var registry: ActionRegistry {
        let registry = ActionRegistry.shared
        registry.ensureBuiltinsRegistered()
        return registry
    }

    func testStackActionsAreRegistered() {
        for method in [
            "workspace.stack.push",
            "workspace.stack.toggle",
            "workspace.stack.focus",
            "workspace.stack.close",
            "workspace.stack.clear",
            "workspace.stack.list"
        ] {
            XCTAssertNotNil(registry.descriptor(for: method), "\(method) is not registered")
            XCTAssertNotNil(registry.handler(for: method), "\(method) has no handler")
        }
    }

    func testPushIsANoteVerb() throws {
        let palette = try XCTUnwrap(registry.descriptor(for: "workspace.stack.push")?.palette)
        XCTAssertEqual(palette.argumentName(for: .note), "path")
        XCTAssertEqual(palette.title, "Open in side stack")
        XCTAssertEqual(palette.category, "Open")
    }

    func testToggleAndFocusAreListedWithShortcuts() {
        XCTAssertNotNil(registry.descriptor(for: "workspace.stack.toggle")?.palette)
        XCTAssertNotNil(registry.descriptor(for: "workspace.stack.focus")?.palette)
        XCTAssertNil(registry.descriptor(for: "workspace.stack.list")?.palette)
        XCTAssertEqual(
            PaletteShortcutResolver.menuOwnedKeystrokes["workspace.stack.toggle"],
            WorkspaceSideStackBuiltinActions.toggleKeystroke
        )
        XCTAssertEqual(
            PaletteShortcutResolver.menuOwnedKeystrokes["workspace.stack.focus"],
            WorkspaceSideStackBuiltinActions.focusKeystroke
        )
    }

    func testStackShortcutsAreReservedAndUnique() {
        let stackPurposes: Set<String> = ["Toggle Side Stack", "Focus Side Stack"]
        let reservedByStack = Set(
            CommandCatalog.reservedKeystrokes.filter { stackPurposes.contains($0.purpose) }.map(\.keystroke)
        )
        XCTAssertEqual(reservedByStack, [
            Keystroke.normalize(WorkspaceSideStackBuiltinActions.toggleKeystroke),
            Keystroke.normalize(WorkspaceSideStackBuiltinActions.focusKeystroke)
        ])
        let reserved = Set(
            CommandCatalog.reservedKeystrokes.filter { !stackPurposes.contains($0.purpose) }.map(\.keystroke)
        )
        let menuOwned = PaletteShortcutResolver.menuOwnedKeystrokes
            .filter { !$0.key.hasPrefix("workspace.stack.") }
            .map { Keystroke.normalize($0.value) }
        for keystroke in [WorkspaceSideStackBuiltinActions.toggleKeystroke, WorkspaceSideStackBuiltinActions.focusKeystroke] {
            let normalized = Keystroke.normalize(keystroke)
            XCTAssertFalse(reserved.contains(normalized), "\(keystroke) is reserved")
            XCTAssertFalse(menuOwned.contains(normalized), "\(keystroke) is already a menu shortcut")
        }
    }
}
