import XCTest
@testable import nvModern

/// The resolver decides what a frame shows. These tests drive it against a
/// throwaway `ActionRegistry` and hand-built context variables so they assert
/// layout and pre-fill rules rather than whatever the real catalog happens to
/// contain today.
@MainActor
final class PaletteResultsResolverTests: XCTestCase {

    // MARK: - Fixtures

    private var registry: ActionRegistry!
    private var notesModel: NotesWorkspaceModel!
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-palette-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: true
        )
        notesModel = NotesWorkspaceModel(projectRootPath: temporaryRoot.path)
        registry = ActionRegistry()
        for descriptor in Self.fixtureDescriptors {
            registry.register(descriptor) { _, _ in .null }
        }
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        registry = nil
        notesModel = nil
        temporaryRoot = nil
        try await super.tearDown()
    }

    /// One descriptor per category we care about ordering, plus a hidden one,
    /// noun-bearing ones, a batch verb, and a bound-only passage verb.
    private static var fixtureDescriptors: [ActionDescriptor] {
        [
            descriptor(method: "test.workspace.newTab", title: "New tab", category: "Window"),
            descriptor(method: "test.file.reload", title: "Reload current document", category: "File", rank: 210),
            descriptor(method: "test.layout.splitRight", title: "Split right", category: "Window"),
            descriptor(method: "test.create.daily", title: "Daily note", category: "Create",
                       arguments: [
                           ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false)
                       ],
                       nounArguments: ["folder": "folder"]),
            descriptor(method: "test.document.copyPath", title: "Copy Path", category: "Document",
                       arguments: [
                           ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false)
                       ],
                       nounArguments: ["note": "path"],
                       acceptsBatch: true),
            descriptor(method: "test.document.rename", title: "Rename…", category: "Document",
                       arguments: [
                           ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false),
                           ActionArgumentDescriptor(name: "name", summary: "New name", kind: .string, isRequired: true, picker: .text)
                       ],
                       nounArguments: ["note": "path"]),
            descriptor(method: "test.format.quote", title: "Quote Selected", category: "Format"),
            descriptor(method: "test.table.insert", title: "Add table", category: "Format", rank: 30),
            descriptor(method: "test.appearance.theme", title: "Editor theme", category: "Appearance"),
            descriptor(method: "test.hidden.gated", title: "Gated action", category: "Window",
                       when: "activeEditor.surface == \"text\""),
            descriptor(method: "test.document.openInNewTab", title: "Open in new tab", category: "Document",
                       when: "activeDocument",
                       arguments: [
                           ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false)
                       ],
                       nounArguments: ["note": "path"]),
            descriptor(method: "test.passage.quote", title: "Quote into current note", category: "Document",
                       arguments: [
                           ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false)
                       ],
                       nounArguments: ["passage": "path"],
                       listedOnlyWhenBound: true),
            // Value-bearing verbs, keyed off the real method names the value
            // table uses.
            descriptor(method: "workspace.note.refile", title: "Refile to…", category: "Document",
                       arguments: [
                           ActionArgumentDescriptor(name: "folder", summary: "Folder", kind: .string, isRequired: false, picker: .workspaceFolder),
                           ActionArgumentDescriptor(name: "path", summary: "Note", kind: .string, isRequired: false)
                       ],
                       nounArguments: ["note": "path"],
                       acceptsBatch: true),
            descriptor(method: "workspace.theme.select", title: "Editor theme…", category: "Appearance",
                       arguments: [
                           ActionArgumentDescriptor(name: "id", summary: "Theme", kind: .string, isRequired: true, picker: .editorTheme)
                       ])
        ]
    }

    private static func descriptor(
        method: String,
        title: String,
        category: String,
        rank: Int = 100,
        when: String? = nil,
        arguments: [ActionArgumentDescriptor] = [],
        nounArguments: [String: String] = [:],
        acceptsBatch: Bool = false,
        listedOnlyWhenBound: Bool = false
    ) -> ActionDescriptor {
        ActionDescriptor(
            method: method,
            title: title,
            summary: title,
            discussion: nil,
            domain: .workspace,
            mutationKind: .mutating,
            targetRequirement: .workspace,
            capabilities: [],
            tags: [],
            arguments: arguments,
            result: nil,
            palette: ActionPalettePresentation(
                category: category,
                iconSystemName: "bolt",
                when: when,
                title: title,
                rank: rank,
                nounArguments: nounArguments,
                acceptsBatch: acceptsBatch,
                listedOnlyWhenBound: listedOnlyWhenBound
            )
        )
    }

    /// A launchpad-ish workspace: no editor, so the gated fixture is hidden.
    private var variablesWithoutEditor: [String: ActionValue] {
        ["activeDocument": .null, "activeEditor": .null]
    }

    func testPageWidthPickerListsInspectorChoicesAndFillsTheActionArgument() async throws {
        ActionRegistry.shared.ensureBuiltinsRegistered()
        let descriptor = try XCTUnwrap(ActionRegistry.shared.descriptor(for: "workspace.document.width.select"))
        guard case .push(let frame) = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: [:], target: .automatic) else {
            return XCTFail("Page width must open a choice frame")
        }
        let context = PaletteContext(notesModel: notesModel, projectRootPath: temporaryRoot.path, currentDocumentWidth: .extraWide)
        let resolver = makeResolver()
        let items = await resolver.sections(frame: frame, rawQuery: "", context: context).flatMap(\.items)
        XCTAssertEqual(items.map(\.title), DocumentInspectorWidth.allCases.map(\.title))
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == "width:extraWide" }?.subtitle).contains("Selected"))
        let filtered = await resolver.sections(frame: frame, rawQuery: "full", context: context).flatMap(\.items)
        XCTAssertEqual(filtered.map(\.id), ["width:full"])
        XCTAssertEqual(filtered.first?.activation, .runAction(method: descriptor.method, args: ["width": .string("full")], target: .automatic))
    }

    func testDocumentThemePickerMarksTheDocumentsThemeAsSelected() async throws {
        ActionRegistry.shared.ensureBuiltinsRegistered()
        let descriptor = try XCTUnwrap(ActionRegistry.shared.descriptor(for: "workspace.document.theme.select"))
        guard case .push(let frame) = PaletteActionPlanner.activation(for: descriptor, suppliedArgs: [:], target: .automatic) else {
            return XCTFail("Document theme must open a choice frame")
        }
        let context = PaletteContext(notesModel: notesModel, projectRootPath: temporaryRoot.path, currentDocumentThemeID: "system")
        let items = await makeResolver().sections(frame: frame, rawQuery: "", context: context).flatMap(\.items)
        let system = try XCTUnwrap(items.first { $0.id == "theme:system" })
        XCTAssertTrue(try XCTUnwrap(system.subtitle).contains("Selected"))
        XCTAssertEqual(system.activation, .runAction(method: descriptor.method, args: ["id": .string("system")], target: .automatic))
        XCTAssertEqual(items.filter { $0.subtitle?.contains("Selected") == true }.count, 1)
    }

    // MARK: - Document outline

    private var outlineFixture: [DocumentOutlineItem] {
        [
            DocumentOutlineItem(id: "deploy", level: 1, title: "Deployment", destination: .text(from: 0, to: 12, line: 1)),
            DocumentOutlineItem(id: "rollback", level: 2, title: "Rollback", destination: .text(from: 13, to: 24, line: 2)),
            DocumentOutlineItem(id: "deep", level: 7, title: "Details", destination: .text(from: 25, to: 38, line: 3)),
            DocumentOutlineItem(id: "testing", level: 1, title: "Testing", destination: .text(from: 39, to: 49, line: 4)),
            DocumentOutlineItem(id: "rollback2", level: 2, title: "Rollback", destination: .text(from: 50, to: 62, line: 5))
        ]
    }

    private var outlineContext: PaletteContext {
        PaletteContext(
            notesModel: notesModel, projectRootPath: temporaryRoot.path,
            outlineItems: outlineFixture, activeOutlineItemID: "rollback"
        )
    }

    func testOutlineListsEveryHeadingInDocumentOrderWithStructuralIndentation() async {
        let items = await makeResolver().sections(frame: .outline, rawQuery: "", context: outlineContext).flatMap(\.items)
        XCTAssertEqual(items.map(\.id), ["deploy", "rollback", "deep", "testing", "rollback2"])
        XCTAssertEqual(items.map(\.indentation), [0, 1, 2, 0, 1])
        XCTAssertEqual(items.last?.subtitle, "5")
        XCTAssertEqual(items.last?.activation, .jumpToOutlineItem(id: "rollback2"))
    }

    func testOutlineSearchUsesAncestorsAndDistinguishesDuplicateTitles() async {
        let resolver = makeResolver()
        let scoped = await resolver.sections(frame: .outline, rawQuery: "dep rlbk", context: outlineContext).flatMap(\.items)
        XCTAssertEqual(scoped.first?.id, "rollback")
        XCTAssertEqual(scoped.first?.snippet, "Deployment")
        XCTAssertEqual(scoped.first?.indentation, 0)
        XCTAssertFalse(scoped.contains { $0.id == "rollback2" })
        let duplicates = await resolver.sections(frame: .outline, rawQuery: "rollback", context: outlineContext).flatMap(\.items)
        XCTAssertEqual(duplicates.prefix(2).map(\.id), ["rollback", "rollback2"])
        XCTAssertEqual(duplicates.prefix(2).compactMap(\.snippet), ["Deployment", "Testing"])
    }

    func testOutlineDoesNotApplyRootPrefixesOrTruncateLongDocuments() async {
        let headings = (0..<100).map { index in
            DocumentOutlineItem(id: "h\(index)", level: 1, title: "Heading \(index)", destination: .text(from: index, to: index, line: index + 1))
        }
        let context = PaletteContext(notesModel: notesModel, projectRootPath: temporaryRoot.path, outlineItems: headings)
        let resolver = makeResolver()
        let all = await resolver.sections(frame: .outline, rawQuery: "", context: context).flatMap(\.items)
        XCTAssertEqual(all.count, 100)
        let prefixed = await resolver.sections(frame: .outline, rawQuery: "#Heading 99", context: context).flatMap(\.items)
        XCTAssertEqual(prefixed.first?.id, "h99")
    }

    func testOutlineSelectsCurrentSectionWithoutPreviewAndCanReturnToRoot() async throws {
        let session = PaletteSession(resolver: makeResolver())
        session.makeContext = { self.outlineContext }
        var frames: [String] = []
        session.onFrameChanged = { frames.append($0.id) }
        session.open(preset: .outline)
        for _ in 0..<100 where session.resolveGeneration == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(session.resolveGeneration, 0)
        XCTAssertEqual(session.stack.selectedItemID, "rollback")
        XCTAssertFalse(session.shouldPreviewOutlineSelection)
        session.moveSelection(by: 1)
        XCTAssertEqual(session.stack.selectedItemID, "deep")
        XCTAssertTrue(session.shouldPreviewOutlineSelection)
        session.toggleMode(.pin)
        XCTAssertTrue(session.modes.isEmpty)
        session.applyPresetShortcut(.root)
        XCTAssertTrue(session.stack.top.spec.isRoot)
        XCTAssertEqual(frames, ["outline", "root"])
        session.handleDidClose()
    }

    // MARK: - Long tail and recency

    func testLongTailVerbsHideUntilTyped() async {
        let context = makeContext(currentDocumentRelativePath: "Inbox/mini.md", currentDocumentTitle: "mini.md")
        let menu = await makeResolver().sections(frame: .root, rawQuery: ">", context: context)
        XCTAssertFalse(menu.flatMap(\.items).contains { $0.actionMethod == "test.file.reload" })

        let typed = await makeResolver().sections(frame: .root, rawQuery: ">relo", context: context)
        XCTAssertTrue(typed.flatMap(\.items).contains { $0.actionMethod == "test.file.reload" })
    }

    func testTypedActionsUseOneGlobalRankingInsteadOfCategoryOrder() async {
        let context = makeContext(currentDocumentRelativePath: "Inbox/mini.md", currentDocumentTitle: "mini.md")
        let sections = await makeResolver().sections(frame: .root, rawQuery: ">rename", context: context)

        XCTAssertEqual(sections.map(\.title), ["Actions"])
        XCTAssertEqual(sections.first?.items.first?.actionMethod, "test.document.rename")
    }

    func testRecentVerbsLeadTheEmptyMenuAndLeaveTheirSections() async {
        let store = makeRecentStore()
        store.record("test.format.quote")
        store.record("test.file.reload")
        let context = makeContext(currentDocumentRelativePath: "Inbox/mini.md", currentDocumentTitle: "mini.md")
        let sections = await makeResolver(recentStore: store).sections(frame: .root, rawQuery: ">", context: context)

        XCTAssertEqual(sections.first?.title, "Recent")
        XCTAssertEqual(sections.first?.items.compactMap(\.actionMethod), ["test.file.reload", "test.format.quote"])
        let format = sections.first { $0.title == "Format" }
        XCTAssertFalse(format?.items.contains { $0.actionMethod == "test.format.quote" } ?? false)

        let typed = await makeResolver(recentStore: store).sections(frame: .root, rawQuery: ">quo", context: context)
        XCTAssertFalse(typed.contains { $0.title == "Recent" })
    }

    func testCaptureMenuKeepsRankOrderAndIconsWithoutRecentSection() async {
        let captures = [
            ("test.capture.org", "Add to daily.org", "calendar", 5),
            ("test.capture.note", "New Note", "note.text.badge.plus", 10),
            ("test.capture.canvas", "New Excalidraw Note", "scribble.variable", 200)
        ]
        for (method, title, icon, rank) in captures {
            var action = Self.descriptor(method: method, title: title, category: "Capture", rank: rank)
            action.palette?.iconSystemName = icon
            registry.register(action) { _, _ in .null }
        }
        let store = makeRecentStore()
        store.record("test.capture.canvas")
        store.record("test.capture.note")
        let resolver = makeResolver(recentStore: store)

        for context in [makeContext(), makeContext(currentDocumentRelativePath: "Inbox/mini.md")] {
            let sections = await resolver.sections(frame: .capture, rawQuery: "", context: context)
            XCTAssertEqual(sections.map(\.title), ["Capture"])
            XCTAssertEqual(sections.flatMap(\.items).compactMap(\.actionMethod), captures.map { $0.0 })
            XCTAssertEqual(sections.flatMap(\.items).compactMap(\.iconSystemName), captures.map { $0.2 })

            let filtered = await resolver.sections(frame: .capture, rawQuery: "Excalidraw", context: context)
            XCTAssertEqual(filtered.map(\.title), ["Capture"])
            XCTAssertEqual(filtered.flatMap(\.items).compactMap(\.actionMethod), ["test.capture.canvas"])
        }
    }

    private func makeRecentStore() -> PaletteRecentVerbsStore {
        PaletteRecentVerbsStore(
            defaults: UserDefaults(suiteName: "PaletteResultsResolverTests.\(UUID().uuidString)")!,
            storageKey: "recents"
        )
    }

    private func makeResolver(
        variables: [String: ActionValue]? = nil,
        passagesProvider: PassagesPaletteProvider? = nil,
        recentStore: PaletteRecentVerbsStore? = nil
    ) -> PaletteResultsResolver {
        let vars = variables ?? variablesWithoutEditor
        return PaletteResultsResolver(
            passagesProvider: passagesProvider,
            actionsProvider: ActionsPaletteProvider(
                registry: registry,
                recentStore: recentStore ?? makeRecentStore(),
                variables: { vars }
            )
        )
    }

    private func makeContext(
        currentDocumentRelativePath: String? = nil,
        currentDocumentTitle: String? = nil,
        currentFolderRelativePath: String? = nil,
        currentThemeTitle: String = "System",
        isCompactToolbarEnabled: Bool = false,
        isSidebarVisible: Bool = true
    ) -> PaletteContext {
        PaletteContext(
            notesModel: notesModel,
            openTabEntries: [],
            currentDocumentRelativePath: currentDocumentRelativePath,
            currentDocumentTitle: currentDocumentTitle,
            currentFolderRelativePath: currentFolderRelativePath,
            projectRootPath: temporaryRoot.path,
            windowNumber: nil,
            currentThemeTitle: currentThemeTitle,
            isCompactToolbarEnabled: isCompactToolbarEnabled,
            isSidebarVisible: isSidebarVisible
        )
    }

    /// The workspace scan is asynchronous, so a test that writes files has to
    /// wait for the index rather than assume `reload()` was synchronous.
    private func waitForIndexedItem(atRelativePath relativePath: String) async throws {
        for _ in 0..<300 {
            let indexed = notesModel.childrenByFolder.values.contains { children in
                children.contains { $0.relativePath == relativePath }
            }
            if indexed { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("workspace index never contained \(relativePath)")
    }

    // MARK: - Root layout

    func testSiblingPresetListsOnlyNotesInCurrentDocumentsFolder() async throws {
        let sibling = temporaryRoot.appendingPathComponent("Inbox/sibling.md")
        let nestedFolder = temporaryRoot.appendingPathComponent("Inbox/Nested", isDirectory: true)
        try Data("# Sibling".utf8).write(to: sibling)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data("# Nested".utf8).write(to: nestedFolder.appendingPathComponent("nested.md"))
        notesModel.reloadConfiguration()
        try await waitForIndexedItem(atRelativePath: "Inbox/sibling.md")

        let sections = await makeResolver().sections(
            frame: .siblings,
            rawQuery: "",
            context: makeContext(currentDocumentRelativePath: "Inbox/current.md")
        )

        XCTAssertEqual(sections.flatMap(\.items).map(\.title), ["sibling.md"])
    }

    func testSiblingPresetUsesCurrentMillerFolderOnLaunchpad() async throws {
        try Data("# Sibling".utf8).write(to: temporaryRoot.appendingPathComponent("Inbox/sibling.md"))
        notesModel.reloadConfiguration()
        try await waitForIndexedItem(atRelativePath: "Inbox/sibling.md")

        let sections = await makeResolver().sections(
            frame: .siblings,
            rawQuery: "sib",
            context: makeContext(currentFolderRelativePath: "Inbox")
        )

        XCTAssertEqual(sections.flatMap(\.items).map(\.title), ["sibling.md"])
    }

    func testEmptyRootLeadsWithTheCurrentTabAndListsNoVerbs() async throws {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )

        let lead = try XCTUnwrap(sections.first)
        XCTAssertEqual(lead.id, "open")
        // The first row carries no header of its own.
        XCTAssertEqual(lead.title, "")
        let first = try XCTUnwrap(lead.items.first)
        XCTAssertEqual(first.title, "mini.md")
        XCTAssertEqual(first.subtitle, "current tab")
        XCTAssertEqual(first.target, .workspaceNote(relativePath: "Inbox/mini.md"))
        XCTAssertEqual(first.activation, .openNote(relativePath: "Inbox/mini.md"))

        // Root is files only now: no verb sections at all.
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.actionMethod == nil })
        XCTAssertFalse(sections.contains { $0.id.hasPrefix("verbs") })
    }

    func testEmptyRootOmitsTheCurrentTabRowWithNoDocument() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "",
            context: makeContext()
        )
        // Nothing open, nothing recent, and no verbs to fall back on.
        XCTAssertTrue(sections.isEmpty)
    }

    func testEmptyRootPutsRecentsUnderOneHeaderAfterTheCurrentTab() async throws {
        try "one".write(
            to: temporaryRoot.appendingPathComponent("Inbox/one.md"),
            atomically: true,
            encoding: .utf8
        )
        try "two".write(
            to: temporaryRoot.appendingPathComponent("Inbox/two.md"),
            atomically: true,
            encoding: .utf8
        )
        notesModel.reload()
        try await waitForIndexedItem(atRelativePath: "Inbox/two.md")

        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/one.md",
                currentDocumentTitle: "one.md"
            )
        )

        XCTAssertEqual(sections.map(\.id), ["open", "recent"])
        XCTAssertEqual(sections.first?.items.map(\.title), ["one.md"])

        let recent = try XCTUnwrap(sections.last)
        XCTAssertEqual(recent.title, "Recent")
        let paths = recent.items.compactMap { $0.target?.noteRelativePath }
        XCTAssertTrue(paths.contains("Inbox/two.md"))
        // The current document leads the list; it is not repeated under Recent.
        XCTAssertFalse(paths.contains("Inbox/one.md"))
        // Recents say where a note lives, and nothing else.
        XCTAssertEqual(recent.items.first?.subtitle, "Inbox")
    }

    func testTypedRootListsNotesOnly() async throws {
        try "one".write(
            to: temporaryRoot.appendingPathComponent("Inbox/one.md"),
            atomically: true,
            encoding: .utf8
        )
        notesModel.reload()
        try await waitForIndexedItem(atRelativePath: "Inbox/one.md")

        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "one",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )

        XCTAssertEqual(sections.map(\.id), ["notes"])
        XCTAssertEqual(sections.first?.items.compactMap { $0.target?.noteRelativePath }, ["Inbox/one.md"])
    }

    func testTypedRootOffersNoVerbsAndNoContentSearchRow() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "ne",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )

        XCTAssertFalse(sections.contains { $0.id == "verbs" })
        XCTAssertFalse(sections.contains { $0.id == "prompt" })
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.actionMethod == nil })
    }

    // MARK: - Prefixes

    func testActionsScopeGroupsVerbsBySubject() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )
        XCTAssertEqual(sections.map(\.title), ["Document", "Format", "Window", "Create", "Appearance"])
    }

    func testActionsScopeDropsTheDocumentGroupWithNoDocument() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext()
        )
        XCTAssertEqual(sections.map(\.title), ["Window", "Create", "Appearance"])
    }

    func testBoundOnlyVerbsNeverAppearInRoot() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )
        XCTAssertFalse(sections.flatMap(\.items).contains { $0.actionMethod == "test.passage.quote" })
    }

    func testPassagesPrefixRoutesToThePassagesProvider() async {
        let fake = FakePassagesProvider()
        let sections = await makeResolver(passagesProvider: fake).sections(
            frame: .root,
            rawQuery: "/trust",
            context: makeContext()
        )
        XCTAssertEqual(fake.receivedQueries, ["trust"])
        XCTAssertEqual(sections.map(\.id), ["passages"])
        let item = sections.first?.items.first
        XCTAssertEqual(item?.activation, .openNote(relativePath: "Notes/mini.md", findTerm: "trust"))
        XCTAssertEqual(
            item?.target,
            .passage(relativePath: "Notes/mini.md", snippet: "a trust snippet", term: "trust")
        )
    }

    func testPassagesPrefixIgnoresAOneCharacterQuery() async {
        let fake = FakePassagesProvider()
        let sections = await makeResolver(passagesProvider: fake).sections(
            frame: .root,
            rawQuery: "/t",
            context: makeContext()
        )
        XCTAssertTrue(sections.isEmpty)
        XCTAssertTrue(fake.receivedQueries.isEmpty)
    }

    func testFoldersPrefixListsEveryFolderWithBrowseActivation() async throws {
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("Inbox/Archive", isDirectory: true),
            withIntermediateDirectories: true
        )
        notesModel.reload()
        try await waitForIndexedItem(atRelativePath: "Inbox/Archive")

        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: "#",
            context: makeContext(currentDocumentRelativePath: "Inbox/mini.md")
        )

        let folders = try XCTUnwrap(sections.first)
        XCTAssertEqual(folders.id, "folders")
        let paths = folders.items.compactMap { item -> String? in
            if case .openFolder(let relativePath) = item.activation { return relativePath }
            return nil
        }
        // The workspace root and the note's own folder both stay listed:
        // browsing is not a destination picker.
        XCTAssertTrue(paths.contains(""))
        XCTAssertTrue(paths.contains("Inbox"))
        XCTAssertEqual(paths.count, folders.items.count)
    }

    // MARK: - Verbs frames

    func testBoundNoteTargetListsOnlyNoteVerbsAndPrefillsThePath() async {
        let target = PaletteTarget.workspaceNote(relativePath: "Inbox/weekly.md")
        let sections = await makeResolver().sections(
            frame: .verbs(for: target),
            rawQuery: "",
            context: makeContext()
        )

        XCTAssertEqual(sections.map(\.title), ["Document"])
        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        // No document is open in this fixture, yet the bound verbs gated on
        // `activeDocument` still list: the noun replaces the current document.
        XCTAssertEqual(
            methods,
            [
                "test.document.copyPath",
                "test.document.rename",
                "test.document.openInNewTab",
                "workspace.note.refile"
            ]
        )

        let copyPath = sections.flatMap(\.items).first { $0.actionMethod == "test.document.copyPath" }
        XCTAssertEqual(
            copyPath?.activation,
            .runAction(
                method: "test.document.copyPath",
                args: ["path": .string("Inbox/weekly.md")],
                target: .automatic
            )
        )

        // A verb still missing a picker argument pushes a frame rather than
        // running with the noun alone.
        let rename = sections.flatMap(\.items).first { $0.actionMethod == "test.document.rename" }
        guard case .push(let frame)? = rename?.activation else {
            return XCTFail("rename should push its text argument frame")
        }
        XCTAssertEqual(frame.pendingCommand?.args, ["path": .string("Inbox/weekly.md")])
        XCTAssertEqual(frame.pendingCommand?.argumentName, "name")
        XCTAssertEqual(frame.subjectTarget, target)
    }

    /// `Cmd+K Cmd+K`: the noun is the document the tab already shows, so the
    /// frame is that tab's whole menu rather than only the note verbs.
    func testBoundActiveDocumentAlsoListsWindowAndWorkspaceVerbs() async {
        let sections = await makeResolver().sections(
            frame: .verbs(for: .workspaceNote(relativePath: "Inbox/mini.md")),
            rawQuery: "",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )

        XCTAssertEqual(sections.map(\.title), ["Document", "Format", "Window", "Create", "Appearance"])

        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        // A note verb, still bound to the noun…
        XCTAssertTrue(methods.contains("test.document.copyPath"))
        // …alongside verbs that take no note at all.
        XCTAssertTrue(methods.contains("test.layout.splitRight"))
        XCTAssertTrue(methods.contains("test.workspace.newTab"))
        // Bound-only verbs still need their own noun.
        XCTAssertFalse(methods.contains("test.passage.quote"))

        let copyPath = sections.flatMap(\.items).first { $0.actionMethod == "test.document.copyPath" }
        XCTAssertEqual(
            copyPath?.activation,
            .runAction(
                method: "test.document.copyPath",
                args: ["path": .string("Inbox/mini.md")],
                target: .automatic
            )
        )
    }

    /// Any other note gets its file verbs and nothing else.
    func testBoundOtherNoteKeepsOneFileVerbSection() async {
        let sections = await makeResolver().sections(
            frame: .verbs(for: .workspaceNote(relativePath: "Inbox/weekly.md")),
            rawQuery: "",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )

        XCTAssertEqual(sections.map(\.title), ["Document"])
        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        XCTAssertFalse(methods.contains("test.layout.splitRight"))
        XCTAssertFalse(methods.contains("test.workspace.newTab"))
        XCTAssertTrue(methods.contains("test.document.copyPath"))
    }

    func testBoundPassageListsOnlyPassageVerbsAndBindsSnippetAndTerm() async {
        let target = PaletteTarget.passage(
            relativePath: "Notes/mini.md",
            snippet: "a trust snippet",
            term: "trust"
        )
        let sections = await makeResolver().sections(
            frame: .verbs(for: target),
            rawQuery: "",
            context: makeContext()
        )

        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        XCTAssertEqual(methods, ["test.passage.quote"])
        XCTAssertEqual(
            sections.flatMap(\.items).first?.activation,
            .runAction(
                method: "test.passage.quote",
                args: [
                    "path": .string("Notes/mini.md"),
                    "snippet": .string("a trust snippet"),
                    "term": .string("trust")
                ],
                target: .automatic
            )
        )
    }

    func testBatchSubjectListsOnlyBatchVerbs() async {
        let target = PaletteTarget.batch([
            .workspaceNote(relativePath: "a.md"),
            .workspaceNote(relativePath: "b.md")
        ])
        let sections = await makeResolver().sections(
            frame: .verbs(for: target),
            rawQuery: "",
            context: makeContext()
        )

        XCTAssertEqual(sections.map(\.title), ["Document"])
        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        XCTAssertEqual(methods, ["test.document.copyPath", "workspace.note.refile"])

        // A batch binds nothing up front: the session expands it per member.
        let copyPath = sections.flatMap(\.items).first { $0.actionMethod == "test.document.copyPath" }
        XCTAssertEqual(
            copyPath?.activation,
            .runAction(method: "test.document.copyPath", args: [:], target: .automatic)
        )
    }

    // MARK: - Values

    func testVerbValuesComeFromTheContext() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(
                currentDocumentRelativePath: "Journal/2026/weekly.md",
                currentDocumentTitle: "weekly.md",
                currentThemeTitle: "Arbor"
            )
        )
        let items = sections.flatMap(\.items)

        XCTAssertEqual(items.first { $0.actionMethod == "workspace.note.refile" }?.value, "2026")
        XCTAssertEqual(items.first { $0.actionMethod == "workspace.theme.select" }?.value, "Arbor")
    }

    func testRefileValueReadsWorkspaceForARootNote() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(
                currentDocumentRelativePath: "weekly.md",
                currentDocumentTitle: "weekly.md"
            )
        )
        let refile = sections.flatMap(\.items).first { $0.actionMethod == "workspace.note.refile" }
        XCTAssertEqual(refile?.value, "Workspace")
    }

    // MARK: - Gating and pre-fill

    func testGatedActionsAreExcludedWhenTheirConditionIsFalse() async {
        let hidden = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext()
        )
        XCTAssertFalse(hidden.flatMap(\.items).contains { $0.actionMethod == "test.hidden.gated" })

        let editorVariables: [String: ActionValue] = [
            "activeDocument": .null,
            "activeEditor": ["surface": .string("text")]
        ]
        let shown = await makeResolver(variables: editorVariables).sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext()
        )
        XCTAssertTrue(shown.flatMap(\.items).contains { $0.actionMethod == "test.hidden.gated" })
    }

    func testUnboundVerbsStayGatedByTheirCondition() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(
                currentDocumentRelativePath: "Inbox/mini.md",
                currentDocumentTitle: "mini.md"
            )
        )
        let methods = Set(sections.flatMap(\.items).compactMap(\.actionMethod))
        XCTAssertFalse(methods.contains("test.document.openInNewTab"))
        XCTAssertTrue(methods.contains("test.document.copyPath"))
    }

    func testFolderNounActionsInheritTheCurrentFolder() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(currentFolderRelativePath: "Journal/2026")
        )

        let daily = sections.flatMap(\.items).first { $0.actionMethod == "test.create.daily" }
        XCTAssertEqual(
            daily?.activation,
            .runAction(
                method: "test.create.daily",
                args: ["folder": .string("Journal/2026")],
                target: .automatic
            )
        )
    }

    func testFolderNounActionsRunWithoutAFolderAtTheWorkspaceRoot() async {
        let sections = await makeResolver().sections(
            frame: .root,
            rawQuery: ">",
            context: makeContext(currentFolderRelativePath: nil)
        )

        let daily = sections.flatMap(\.items).first { $0.actionMethod == "test.create.daily" }
        XCTAssertEqual(
            daily?.activation,
            .runAction(method: "test.create.daily", args: [:], target: .automatic)
        )
    }
}

/// Stands in for the search engine so the passages route can be asserted
/// without an index.
@MainActor
private final class FakePassagesProvider: PassagesPaletteProvider {
    private(set) var receivedQueries: [String] = []

    override func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .passages = source else { return [] }
        receivedQueries.append(query.text)
        let snippet = "a \(query.text) snippet"
        return [
            PaletteSection(
                id: "passages",
                title: "Passages",
                items: [
                    PaletteItem(
                        id: "content:Notes/mini.md",
                        title: "mini.md",
                        snippet: snippet,
                        activation: .openNote(relativePath: "Notes/mini.md", findTerm: query.text),
                        target: .passage(
                            relativePath: "Notes/mini.md",
                            snippet: snippet,
                            term: query.text
                        )
                    )
                ]
            )
        ]
    }
}
