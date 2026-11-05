import Foundation
import XCTest
@testable import nvModern

@MainActor
final class HTMLPreviewTests: XCTestCase {
    func testWorkspaceHTMLFileUsesReadOnlyHTMLPreview() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-html-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data("<!doctype html><title>Preview</title><h1>Hello</h1>".utf8)
            .write(to: rootURL.appendingPathComponent("Preview.html"))

        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()
        let context = try XCTUnwrap(model.contextForNote(relativePath: "Preview.html"))

        XCTAssertEqual(context.kind, .html)
        XCTAssertEqual(context.mimeType, "text/html")
        XCTAssertEqual(context.body, "")
        XCTAssertFalse(context.kind.isEditable)
        XCTAssertEqual(
            WorkspaceOpenedDocument.workspaceNote(relativePath: "Preview.html").tabPresentation.icon,
            "globe"
        )
    }
}
