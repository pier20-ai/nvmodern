import XCTest
@testable import nvModern

@MainActor
final class PaletteModelTests: XCTestCase {

    // MARK: - Query scope

    func testQueryScopeParsesEveryNounPrefix() {
        let verbs = PaletteQueryScope.parse("> split")
        XCTAssertEqual(verbs.scope, .actions)
        XCTAssertEqual(verbs.text, "split")

        let passages = PaletteQueryScope.parse("/trust")
        XCTAssertEqual(passages.scope, .passages)
        XCTAssertEqual(passages.text, "trust")

        // `@` scoped chats, which were retired; it is plain note text now.
        let at = PaletteQueryScope.parse("@ refactor")
        XCTAssertEqual(at.scope, .all)
        XCTAssertEqual(at.text, "@ refactor")

        let folders = PaletteQueryScope.parse("#inbox")
        XCTAssertEqual(folders.scope, .folders)
        XCTAssertEqual(folders.text, "inbox")

        let bare = PaletteQueryScope.parse(">")
        XCTAssertEqual(bare.scope, .actions)
        XCTAssertEqual(bare.text, "")
    }

    func testQueryScopeTrimsPlainQueries() {
        let plain = PaletteQueryScope.parse("  weekly  ")
        XCTAssertEqual(plain.scope, .all)
        XCTAssertEqual(plain.text, "weekly")
        XCTAssertEqual(plain.prefix, "")
    }

    func testQueryScopePrefixRebuildsTheRawQuery() {
        XCTAssertEqual(PaletteQueryScope.parse("/trust").prefix, "/")
        XCTAssertEqual(PaletteQueryScope.parse("@x").prefix, "")
        XCTAssertEqual(PaletteQueryScope.parse("#x").prefix, "#")
        XCTAssertEqual(PaletteQueryScope.parse(">x").prefix, ">")
    }

    // MARK: - Stack

    func testStackPushPopAndBreadcrumb() {
        let stack = PaletteStack(root: .root)
        XCTAssertEqual(stack.depth, 1)
        XCTAssertFalse(stack.canPop)
        XCTAssertFalse(stack.pop())

        let target = PaletteTarget.workspaceNote(relativePath: "Inbox/weekly.md")
        stack.push(.verbs(for: target))
        XCTAssertEqual(stack.depth, 2)
        XCTAssertEqual(stack.breadcrumb, ["Search", "weekly.md"])
        XCTAssertEqual(stack.top.spec.boundTarget, target)

        XCTAssertTrue(stack.pop())
        XCTAssertEqual(stack.depth, 1)
        XCTAssertTrue(stack.top.spec.isRoot)
    }

    func testStackQueryAndSelectionLiveOnTheTopFrame() {
        let stack = PaletteStack(root: .root)
        stack.query = "alpha"
        stack.push(.verbs(for: .folder(relativePath: "Inbox")))
        XCTAssertEqual(stack.query, "")
        stack.query = "gamma"
        XCTAssertEqual(stack.top.query, "gamma")
        stack.pop()
        XCTAssertEqual(stack.query, "alpha")
    }

    func testRootPresetCarriesItsInitialQuery() {
        XCTAssertEqual(PaletteFrameSpec.root(query: ">").initialQuery, ">")
        XCTAssertTrue(PaletteFrameSpec.root(query: "/x").isRoot)
    }

    func testSetSectionsKeepsSurvivingSelectionAndOtherwiseSelectsFirst() {
        let stack = PaletteStack(root: .root)
        stack.setSections([
            PaletteSection(id: "a", title: "A", items: [item("1"), item("2")]),
            PaletteSection(id: "b", title: "B", items: [item("3")])
        ])
        XCTAssertEqual(stack.selectedItemID, "1")

        stack.selectedItemID = "3"
        stack.setSections([
            PaletteSection(id: "b", title: "B", items: [item("3"), item("4")])
        ])
        XCTAssertEqual(stack.selectedItemID, "3")

        stack.setSections([
            PaletteSection(id: "c", title: "C", items: [item("9")])
        ])
        XCTAssertEqual(stack.selectedItemID, "9")

        stack.setSections([])
        XCTAssertNil(stack.selectedItemID)
    }

    func testSetSectionsCanResetSurvivingSelectionToFirst() {
        let stack = PaletteStack(root: .root)
        stack.setSections([
            PaletteSection(id: "a", title: "A", items: [item("1"), item("2"), item("3")])
        ])
        stack.selectedItemID = "2"

        stack.setSections([
            PaletteSection(id: "a", title: "A", items: [item("3"), item("2")])
        ], preservingSelection: false)

        XCTAssertEqual(stack.selectedItemID, "3")
    }

    func testSelectFirstItemAbandonsHoveredSelection() {
        let stack = PaletteStack(root: .root)
        stack.setSections([
            PaletteSection(id: "a", title: "A", items: [item("1"), item("2")])
        ])
        stack.selectedItemID = "2"

        stack.selectFirstItem()

        XCTAssertEqual(stack.selectedItemID, "1")
    }

    func testHoverSelectionGateRequiresPointerToLeaveDeadZone() {
        var gate = PaletteHoverSelectionGate()
        gate.suppress(at: CGPoint(x: 100, y: 200))

        XCTAssertFalse(gate.allowsSelection(at: CGPoint(x: 100, y: 200)))
        XCTAssertFalse(gate.allowsSelection(at: CGPoint(x: 112, y: 188)))
        XCTAssertTrue(gate.allowsSelection(at: CGPoint(x: 113, y: 200)))

        // Once deliberate movement re-enables hover, later rows can select
        // normally without having to cross another dead zone.
        XCTAssertTrue(gate.allowsSelection(at: CGPoint(x: 101, y: 200)))
    }

    func testHoverSelectionGateCanBeResetWithoutMovement() {
        var gate = PaletteHoverSelectionGate()
        gate.suppress(at: CGPoint(x: 10, y: 20))
        gate.reset()

        XCTAssertTrue(gate.allowsSelection(at: CGPoint(x: 10, y: 20)))
    }

    func testMoveSelectionWraps() {
        let stack = PaletteStack(root: .root)
        stack.setSections([
            PaletteSection(id: "a", title: "A", items: [item("1"), item("2"), item("3")])
        ])
        stack.moveSelection(by: -1)
        XCTAssertEqual(stack.selectedItemID, "3")
        stack.moveSelection(by: 1)
        XCTAssertEqual(stack.selectedItemID, "1")
        stack.moveSelection(by: 1)
        XCTAssertEqual(stack.selectedItemID, "2")
    }

    // MARK: - Targets

    func testPassageAndBatchLabels() {
        let passage = PaletteTarget.passage(
            relativePath: "Notes/mini.md",
            snippet: "Agentic GTM requires trust and a great deal more besides",
            term: "trust"
        )
        XCTAssertEqual(passage.nounKind, .passage)
        XCTAssertEqual(passage.noteRelativePath, "Notes/mini.md")
        XCTAssertEqual(passage.breadcrumbLabel, "\u{201C}Agentic GTM requires trust\u{2026}\u{201D} in mini.md")

        let batch = PaletteTarget.batch([
            .workspaceNote(relativePath: "a.md"),
            .workspaceNote(relativePath: "b.md")
        ])
        XCTAssertNil(batch.nounKind)
        XCTAssertNil(batch.nounValue)
        XCTAssertEqual(batch.breadcrumbLabel, "2 notes")
        XCTAssertEqual(batch.batchMembers.count, 2)
        XCTAssertEqual(PaletteTarget.folder(relativePath: "Inbox").batchMembers.count, 1)
    }

    // MARK: - Planner

    func testPlannerRunsImmediatelyWithoutPickers() {
        let descriptor = descriptor(arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false)
        ])
        let activation = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: [:], target: .automatic)
        XCTAssertEqual(activation, .runAction(method: "test.method", args: [:], target: .automatic))
    }

    func testPlannerPushesArgumentFrameForMissingPickerArgument() throws {
        let descriptor = descriptor(arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false, picker: .workspaceFolder)
        ])
        let activation = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: [:], target: .automatic)
        guard case .push(let frame) = activation else {
            return XCTFail("Expected a pushed frame, got \(activation)")
        }
        XCTAssertEqual(frame.sources, [.folders])
        XCTAssertEqual(frame.placeholder, "Which folder?")
        let pending = try XCTUnwrap(frame.pendingCommand)
        XCTAssertEqual(pending.argumentName, "folder")
        XCTAssertEqual(pending.argumentPicker, .workspaceFolder)
        XCTAssertEqual(
            pending.filled(with: .string("Inbox")),
            .runAction(method: "test.method", args: ["folder": .string("Inbox")], target: .automatic)
        )
    }

    func testPlannerCarriesTheSubjectOntoTheObjectFrame() throws {
        let descriptor = descriptor(arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false, picker: .workspaceFolder)
        ])
        let subject = PaletteTarget.workspaceNote(relativePath: "Inbox/weekly.md")
        let activation = PaletteActionPlanner.activation(
            for: descriptor,
            suppliedArgs: [:],
            target: .automatic,
            subjectTarget: subject
        )
        guard case .push(let frame) = activation else {
            return XCTFail("Expected a pushed frame, got \(activation)")
        }
        XCTAssertEqual(frame.subjectTarget, subject)
    }

    func testPlannerSkipsArgumentFrameWhenPickerArgumentAlreadySupplied() {
        let descriptor = descriptor(arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false, picker: .workspaceFolder)
        ])
        let supplied: [String: ActionValue] = ["folder": .string("Inbox")]
        let activation = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: supplied, target: .automatic)
        XCTAssertEqual(activation, .runAction(method: "test.method", args: supplied, target: .automatic))
    }

    func testPlannerPrefersRequiredPickerArgument() throws {
        let descriptor = descriptor(arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false, picker: .workspaceFolder),
            ActionArgumentDescriptor(name: "fileName", summary: "Name", kind: .string, isRequired: true, picker: .text)
        ])
        let activation = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: [:], target: .automatic)
        guard case .push(let frame) = activation else {
            return XCTFail("Expected a pushed frame, got \(activation)")
        }
        XCTAssertEqual(try XCTUnwrap(frame.pendingCommand).argumentName, "fileName")
        XCTAssertEqual(frame.sources, [.textInput])
    }

    func testPendingCommandMergesSeveralPickerValues() {
        let pending = PalettePendingCommand(
            method: "test.pick",
            args: [:],
            target: .automatic,
            argumentName: "id",
            argumentPicker: .text
        )
        let activation = pending.filled(with: ["id": .string("s1"), "extra": .string("x")])
        XCTAssertEqual(
            activation,
            .runAction(method: "test.pick", args: ["id": .string("s1"), "extra": .string("x")], target: .automatic)
        )
    }

    func testNounBindingUsesDeclaredArgumentName() {
        let verb = descriptor(
            arguments: [ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false)],
            palette: ActionPalettePresentation(category: "Document", nounArguments: ["note": "path"])
        )
        let note = PaletteTarget.workspaceNote(relativePath: "Inbox/weekly.md")
        XCTAssertTrue(PaletteActionPlanner.applies(verb, to: note))
        XCTAssertEqual(PaletteActionPlanner.boundArgs(for: verb, target: note), ["path": .string("Inbox/weekly.md")])

        let folder = PaletteTarget.folder(relativePath: "Inbox")
        XCTAssertFalse(PaletteActionPlanner.applies(verb, to: folder))

        let plain = descriptor(arguments: [], palette: ActionPalettePresentation(category: "Layout"))
        XCTAssertFalse(PaletteActionPlanner.applies(plain, to: note))
    }

    func testPassageBindingCarriesSnippetAndTerm() {
        let verb = descriptor(
            arguments: [],
            palette: ActionPalettePresentation(category: "Document", nounArguments: ["passage": "path"])
        )
        let passage = PaletteTarget.passage(relativePath: "a/b.md", snippet: "some text", term: "text")
        XCTAssertEqual(
            PaletteActionPlanner.boundArgs(for: verb, target: passage),
            [
                "path": .string("a/b.md"),
                "snippet": .string("some text"),
                "term": .string("text")
            ]
        )
    }

    func testBatchAppliesOnlyToBatchVerbsThatFitEveryMember() {
        let batchVerb = descriptor(
            arguments: [],
            palette: ActionPalettePresentation(
                category: "Document",
                nounArguments: ["note": "path"],
                acceptsBatch: true
            )
        )
        let singleVerb = descriptor(
            arguments: [],
            palette: ActionPalettePresentation(category: "Document", nounArguments: ["note": "path"])
        )

        let notes = PaletteTarget.batch([
            .workspaceNote(relativePath: "a.md"),
            .workspaceNote(relativePath: "b.md")
        ])
        XCTAssertTrue(PaletteActionPlanner.applies(batchVerb, to: notes))
        XCTAssertFalse(PaletteActionPlanner.applies(singleVerb, to: notes))
        XCTAssertNil(PaletteActionPlanner.boundArgs(for: batchVerb, target: notes))

        // One member the verb does not accept disqualifies the whole batch.
        let mixed = PaletteTarget.batch([
            .workspaceNote(relativePath: "a.md"),
            .folder(relativePath: "Inbox")
        ])
        XCTAssertFalse(PaletteActionPlanner.applies(batchVerb, to: mixed))

        XCTAssertFalse(PaletteActionPlanner.applies(batchVerb, to: .batch([])))
    }

    func testOpenTabWithoutPathIsNotANoun() {
        XCTAssertNil(PaletteTarget.openTab(tabID: "t", relativePath: nil).nounKind)
        XCTAssertEqual(PaletteTarget.openTab(tabID: "t", relativePath: "a.md").nounKind, .note)
        XCTAssertEqual(PaletteTarget.workspaceNote(relativePath: "a/b.md").breadcrumbLabel, "b.md")
        XCTAssertEqual(PaletteTarget.folder(relativePath: "").breadcrumbLabel, "Workspace")
    }

    // MARK: - Subjects

    func testSubjectsAreDerivedFromTheCategoryWhenNotDeclared() {
        XCTAssertEqual(ActionPalettePresentation(category: "Document").resolvedSubject, .document)
        XCTAssertEqual(ActionPalettePresentation(category: "Format").resolvedSubject, .document)
        XCTAssertEqual(ActionPalettePresentation(category: "Table").resolvedSubject, .document)
        XCTAssertEqual(ActionPalettePresentation(category: "Layout").resolvedSubject, .window)
        XCTAssertEqual(ActionPalettePresentation(category: "Workspace").resolvedSubject, .window)
        XCTAssertEqual(ActionPalettePresentation(category: "Create").resolvedSubject, .workspace)
        XCTAssertEqual(ActionPalettePresentation(category: "Appearance").resolvedSubject, .workspace)

        XCTAssertEqual(
            ActionPalettePresentation(category: "Create", subject: .document).resolvedSubject,
            .document
        )
    }

    // MARK: - Helpers

    private func item(_ id: String) -> PaletteItem {
        PaletteItem(id: id, title: id, activation: .openNote(relativePath: id))
    }

    private func descriptor(
        arguments: [ActionArgumentDescriptor],
        palette: ActionPalettePresentation? = ActionPalettePresentation(category: "Document")
    ) -> ActionDescriptor {
        ActionDescriptor(
            method: "test.method",
            title: "Test",
            summary: "Test",
            discussion: nil,
            domain: .workspace,
            mutationKind: .mutating,
            targetRequirement: .workspace,
            capabilities: [],
            tags: [],
            arguments: arguments,
            result: nil,
            palette: palette
        )
    }
}
