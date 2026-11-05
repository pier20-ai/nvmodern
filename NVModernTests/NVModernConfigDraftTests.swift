import XCTest
import TOMLKit
@testable import nvModern

/// Round-trip + invariant tests for the unified workspace draft model.
final class NVModernConfigDraftTests: XCTestCase {

    func testFiletypeDefaultsRoundTrip() throws {
        let toml = """
        [filetypes.org]
        theme = "cyanotype"
        font_family = "IBM Plex Mono"
        """

        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.filetypes["org"], NVModernFiletypeDraft(theme: "cyanotype", font_family: "IBM Plex Mono"))
        XCTAssertFalse(draft.migratedOrgFontFamily)

        let encoded = try TOMLEncoder().encode(draft)
        let reDecoded = try TOMLDecoder().decode(NVModernConfigDraft.self, from: encoded)
        XCTAssertEqual(reDecoded.filetypes["org"], draft.filetypes["org"])
    }

    func testRetiredOrgFontFamilyBecomesOrgFiletypeFont() throws {
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: #"org_font_family = "IBM Plex Mono""#)
        XCTAssertEqual(draft.filetypes["org"]?.font_family, "IBM Plex Mono")
        XCTAssertTrue(draft.migratedOrgFontFamily)

        let encoded = try TOMLEncoder().encode(draft)
        XCTAssertFalse(encoded.contains("org_font_family"))
        XCTAssertTrue(encoded.contains("filetypes"))

        let diagnostics = NVModernConfigSchema.shared.diagnostics(for: draft, configURL: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("org_font_family is retired") })
    }

    func testExplicitFiletypeFontWinsOverRetiredOrgFontFamily() throws {
        let toml = """
        org_font_family = "Google Sans Code"

        [filetypes.org]
        font_family = "Berkeley Mono"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.filetypes["org"]?.font_family, "Berkeley Mono")
    }

    func testEmptyFiletypeTablesAreNotWritten() throws {
        var draft = NVModernConfigDraft()
        draft.filetypes["md"] = NVModernFiletypeDraft(theme: "  ", font_family: nil)
        let encoded = try TOMLEncoder().encode(draft)
        XCTAssertFalse(encoded.contains("filetypes"))
        XCTAssertEqual(draft, NVModernConfigDraft())
    }

    func testUnknownFiletypeThemeIsReported() throws {
        let toml = """
        root = "\(NSTemporaryDirectory())"

        [filetypes.org]
        theme = "no-such-theme"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        let diagnostics = NVModernConfigSchema.shared.diagnostics(for: draft, configURL: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("filetypes.org theme not found: no-such-theme") })
    }

    func testFiletypeLookupUsesLowercasedExtension() {
        let org = NVModernFiletypeAppearance(themeID: "cyanotype", fontFamily: nil, editorThemeCSS: ":root {}")
        let defaults = NVModernDocumentDefaultsConfig(width: .comfortable, filetypes: ["org": org])
        XCTAssertEqual(defaults.filetype(forPath: "notes/Plan.ORG"), org)
        XCTAssertNil(defaults.filetype(forPath: "notes/plan.md"))
        XCTAssertNil(defaults.filetype(forPath: nil))
    }

    /// Captures and scratchpads moved to plugins. A config written before
    /// that still loads, and the retired tables are not written back.
    func testRetiredCaptureTablesAreIgnored() throws {
        let toml = """
        root = "/tmp/notes"

        [capture]
        scratchpad_path = "00-Capture/Scratchpads"
        daily_path = "Daily"

        [[capture.options]]
        key = "d"
        title = "Daily Note"
        kind = "daily"

        [[quick_capture]]
        file = "/tmp/Inbox.md"
        keybinding = "cmd+shift+space"
        mode = "full"
        """

        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.root, "/tmp/notes")

        let encoded = try TOMLEncoder().encode(draft)
        for retired in ["capture", "scratchpad_path", "daily_path", "options"] {
            XCTAssertFalse(encoded.contains(retired), "\(retired) should not be written back")
        }
    }

    /// Chat documents were retired with their `[agents]` and `[chat]` tables.
    /// Existing configs still parse, and the tables are not written back.
    func testRetiredAgentsAndChatTablesAreIgnored() throws {
        let toml = """
        root = "/tmp/notes"

        [agents]
        default_provider = "codex"
        max_live_sessions = 3

        [agents.claude]
        permission_mode = "acceptEdits"
        allowed_tools = ["Read", "Grep"]

        [chat]
        auto_stage_edits = false
        """

        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.root, "/tmp/notes")

        let encoded = try TOMLEncoder().encode(draft)
        for retired in ["agents", "chat", "auto_stage_edits", "default_provider"] {
            XCTAssertFalse(encoded.contains(retired), "\(retired) should not be written back")
        }
    }

    func testRetiredActionTablesAreIgnoredAndWarnedAbout() throws {
        let toml = """
        root = "/tmp"
        [[actions]]
        id = "old"
        [[actions.steps]]
        method = "app.health.ping"
        [[keybindings]]
        id = "old-binding"
        keystroke = "cmd+shift+d"
        action = "old"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertTrue(draft.containsRetiredActionTables)
        let encoded = try TOMLEncoder().encode(draft)
        XCTAssertFalse(encoded.contains("[[actions]]"))
        XCTAssertFalse(encoded.contains("old-binding"))
        let diagnostics = NVModernConfigSchema.shared.diagnostics(for: draft, configURL: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("[[actions]]") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("retired action") })
    }

    // MARK: - Legacy root only

    func testLegacyRootOnlySynthesizesProject() throws {
        let toml = #"root = "/tmp/notes""#
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)

        XCTAssertEqual(draft.projects.count, 1)
        XCTAssertEqual(draft.projects.first?.path, "/tmp/notes")
        XCTAssertNotNil(draft.defaultProjectID)
        XCTAssertEqual(draft.defaultProject?.path, "/tmp/notes")
        XCTAssertEqual(draft.root, "/tmp/notes")
    }

    func testLegacyRootRoundTripEmitsProjectsBlock() throws {
        let toml = #"root = "/tmp/notes""#
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        let encoded = try TOMLEncoder().encode(draft)
        let reDecoded = try TOMLDecoder().decode(NVModernConfigDraft.self, from: encoded)

        XCTAssertEqual(reDecoded.root, "/tmp/notes")
        XCTAssertEqual(reDecoded.projects.count, 1)
        XCTAssertEqual(reDecoded.projects.first?.path, "/tmp/notes")
        XCTAssertEqual(reDecoded.defaultProject?.path, "/tmp/notes")
    }

    // MARK: - Root + matching project

    func testRootMatchingProjectKeepsSinglePath() throws {
        let toml = """
        root = "/tmp/notes"
        [[projects]]
        name = "Notes"
        path = "/tmp/notes"
        icon = "books.vertical.fill"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)

        XCTAssertEqual(draft.projects.count, 1, "should not duplicate the project")
        XCTAssertEqual(draft.projects.first?.name, "Notes")
        XCTAssertEqual(draft.projects.first?.icon, "books.vertical.fill")
        XCTAssertEqual(draft.defaultProject?.name, "Notes")
    }

    func testTildeAndTrailingSlashesNormalize() throws {
        let toml = """
        root = "/Users/me/Notes/"
        [[projects]]
        name = "Notes"
        path = "/Users/me/Notes"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.projects.count, 1, "trailing-slash difference should still match")
        XCTAssertEqual(draft.defaultProject?.name, "Notes")
    }

    // MARK: - Projects without root

    func testProjectsWithoutRootMarkFirstAsDefault() throws {
        let toml = """
        [[projects]]
        name = "Alpha"
        path = "/tmp/alpha"
        [[projects]]
        name = "Beta"
        path = "/tmp/beta"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        XCTAssertEqual(draft.defaultProject?.name, "Alpha")
        XCTAssertEqual(draft.root, "/tmp/alpha")
    }

    func testProjectsWithoutRootRoundTripWritesDerivedRoot() throws {
        let toml = """
        [[projects]]
        name = "Alpha"
        path = "/tmp/alpha"
        """
        let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: toml)
        let encoded = try TOMLEncoder().encode(draft)
        let reDecoded = try TOMLDecoder().decode(NVModernConfigDraft.self, from: encoded)
        XCTAssertEqual(reDecoded.root, "/tmp/alpha")
    }

    // MARK: - Empty

    func testEmptyDraftEncodesEmpty() throws {
        let draft = NVModernConfigDraft()
        XCTAssertNil(draft.defaultProjectID)
        XCTAssertNil(draft.root)
        let encoded = try TOMLEncoder().encode(draft)
        let reDecoded = try TOMLDecoder().decode(NVModernConfigDraft.self, from: encoded)
        XCTAssertNil(reDecoded.root)
        XCTAssertTrue(reDecoded.projects.isEmpty)
    }

    // MARK: - Default-project invariant

    func testAddProjectOnEmptyMakesItDefault() {
        var draft = NVModernConfigDraft()
        let project = NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha")
        draft.addProject(project)
        XCTAssertEqual(draft.defaultProject?.path, "/tmp/alpha")
    }

    func testRemoveDefaultProjectPromotesAnother() {
        var draft = NVModernConfigDraft()
        let alpha = NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha")
        let beta = NVModernProjectDraft(name: "Beta", path: "/tmp/beta")
        draft.addProject(alpha)
        draft.addProject(beta)
        XCTAssertEqual(draft.defaultProject?.name, "Alpha")

        draft.removeProject(id: alpha._uiID)
        XCTAssertEqual(draft.defaultProject?.name, "Beta", "should promote remaining project")
    }

    func testRemoveLastProjectClearsDefault() {
        var draft = NVModernConfigDraft()
        let alpha = NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha")
        draft.addProject(alpha)
        draft.removeProject(id: alpha._uiID)
        XCTAssertNil(draft.defaultProjectID)
        XCTAssertNil(draft.root)
    }

    func testSetDefaultProject() {
        var draft = NVModernConfigDraft()
        draft.addProject(NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha"))
        let beta = NVModernProjectDraft(name: "Beta", path: "/tmp/beta")
        draft.addProject(beta)

        draft.setDefaultProject(id: beta._uiID)
        XCTAssertEqual(draft.defaultProject?.name, "Beta")
    }

    func testSetDefaultIgnoresUnknownID() {
        var draft = NVModernConfigDraft()
        draft.addProject(NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha"))
        let originalID = draft.defaultProjectID
        draft.setDefaultProject(id: UUID())
        XCTAssertEqual(draft.defaultProjectID, originalID, "unknown id should not change default")
    }

    func testRootSetterSynthesizesProject() {
        var draft = NVModernConfigDraft()
        draft.root = "/tmp/synth"
        XCTAssertEqual(draft.projects.count, 1)
        XCTAssertEqual(draft.defaultProject?.path, "/tmp/synth")
    }

    func testRootSetterLinksToExistingProject() {
        var draft = NVModernConfigDraft()
        let alpha = NVModernProjectDraft(name: "Alpha", path: "/tmp/alpha")
        let beta = NVModernProjectDraft(name: "Beta", path: "/tmp/beta")
        draft.addProject(alpha)
        draft.addProject(beta)

        draft.root = "/tmp/beta"
        XCTAssertEqual(draft.projects.count, 2, "shouldn't synthesize when one matches")
        XCTAssertEqual(draft.defaultProject?.name, "Beta")
    }
}
