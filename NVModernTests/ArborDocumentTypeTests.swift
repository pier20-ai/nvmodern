import Foundation
import XCTest
@testable import nvModern

@MainActor
final class ArborDocumentTypeTests: XCTestCase {
    func testCreatingOutlineInitializesLanguageHeader() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let relativePath = try fixture.model.createNote(
            inFolderRelativePath: nil,
            fileName: "Plan.outline"
        )

        XCTAssertEqual(relativePath, "Plan.outline")
        XCTAssertEqual(
            try String(contentsOf: fixture.rootURL.appendingPathComponent(relativePath), encoding: .utf8),
            "#lang arbor/0\n"
        )
    }

    func testCreatingMarkdownRemainsUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let relativePath = try fixture.model.createNote(
            inFolderRelativePath: nil,
            fileName: "Plan.md"
        )

        XCTAssertEqual(relativePath, "Plan.md")
        XCTAssertEqual(
            try Data(contentsOf: fixture.rootURL.appendingPathComponent(relativePath)),
            Data()
        )
    }

    func testOpeningHeaderlessOutlineAddsLanguageDirectiveAndUsesTextSurface() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-outline-open-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("Imported.outline")
        try "- Existing block ^existing\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()

        XCTAssertEqual(model.lightweightContextForNote(relativePath: "Imported.outline")?.kind, .text)
        let context = await model.textContextForNote(relativePath: "Imported.outline")

        XCTAssertEqual(context?.kind, .text)
        XCTAssertEqual(context?.body, "#lang arbor/0\n- Existing block ^existing\n")
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "#lang arbor/0\n- Existing block ^existing\n"
        )
    }

    func testOpeningMarkdownDoesNotAddArborLanguageDirective() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-markdown-open-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("Imported.md")
        try "Existing Markdown\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()

        let context = await model.textContextForNote(relativePath: "Imported.md")

        XCTAssertEqual(context?.body, "Existing Markdown\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "Existing Markdown\n")
    }

    func testOutlineWikilinkAutocompleteIncludesWorkspaceTextDocuments() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-outline-link-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "#lang arbor/0\n".write(
            to: rootURL.appendingPathComponent("Current.outline"),
            atomically: true,
            encoding: .utf8
        )
        try "#lang arbor/0\n".write(
            to: rootURL.appendingPathComponent("Roadmap.outline"),
            atomically: true,
            encoding: .utf8
        )
        try "Markdown\n".write(
            to: rootURL.appendingPathComponent("Notes.md"),
            atomically: true,
            encoding: .utf8
        )
        try "* Org\n".write(
            to: rootURL.appendingPathComponent("Research.org"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0]).write(to: rootURL.appendingPathComponent("Image.png"))

        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()
        let suggestions = model.autocompleteWikilinks(
            query: "",
            sourceRelativePath: "Current.outline"
        )
        let targets = Set(suggestions.map(\.insertText))

        XCTAssertTrue(targets.isSuperset(of: [
            "Current.outline",
            "Roadmap.outline",
            "Notes.md",
            "Research.org"
        ]))
        XCTAssertFalse(targets.contains("Image.png"))
    }

    private func makeFixture() async throws -> (rootURL: URL, model: NotesWorkspaceModel) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-outline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()
        return (rootURL, model)
    }
}
