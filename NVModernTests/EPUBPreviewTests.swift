import Foundation
import XCTest
@testable import nvModern

@MainActor
final class EPUBPreviewTests: XCTestCase {
    func testWorkspaceEPUBFileUsesReadOnlyEPUBSurface() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-epub-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Classification is extension-based; the web reader owns package validation.
        try Data("epub fixture placeholder".utf8)
            .write(to: rootURL.appendingPathComponent("Book.epub"))

        let model = NotesWorkspaceModel(projectRootPath: rootURL.path)
        _ = await model.waitForInitialSnapshot()
        let context = try XCTUnwrap(model.contextForNote(relativePath: "Book.epub"))

        XCTAssertEqual(context.kind, .epub)
        XCTAssertEqual(context.mimeType, "application/epub+zip")
        XCTAssertEqual(context.body, "")
        XCTAssertFalse(context.kind.isEditable)
        XCTAssertEqual(
            WorkspaceOpenedDocument.workspaceNote(relativePath: "Book.epub").tabPresentation.icon,
            "book.closed"
        )
    }
}
