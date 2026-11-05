import Foundation
import XCTest
@testable import nvModern

@MainActor
final class NotesWorkspaceModelCreationTests: XCTestCase {
    func testCreatedTextCanOpenBeforeIndexAndIncludesLatestWrittenBody() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let path = try model.createNote(inFolderRelativePath: nil, fileName: "Draft.md")
        XCTAssertEqual(model.contextForNote(relativePath: path)?.kind, .text)
        XCTAssertEqual(model.contextForNote(relativePath: path)?.body, "")
        try model.saveTextNote(relativePath: path, body: "# Draft\n\nKnown body")
        XCTAssertEqual(model.contextForNote(relativePath: path)?.body, "# Draft\n\nKnown body")
        XCTAssertNil(model.textContextLoadDescriptorForNote(relativePath: path))
    }

    func testIndexedNoteReturnsToDiskAuthority() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let path = try model.createNote(inFolderRelativePath: nil, fileName: "Draft.org")
        try model.saveTextNote(relativePath: path, body: "* Initial")
        model.reload()
        let scanned = await model.waitForInitialSnapshot()
        XCTAssertTrue(scanned)
        try "* External edit".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        XCTAssertEqual(model.contextForNote(relativePath: path)?.body, "* External edit")
        XCTAssertNotNil(model.textContextLoadDescriptorForNote(relativePath: path))
    }

    func testNonTextCreationDoesNotBecomeTextAndDeletedSeedDoesNotResolve() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let canvas = try model.createNote(inFolderRelativePath: nil, fileName: "Drawing.excalidraw")
        XCTAssertNil(model.contextForNote(relativePath: canvas))
        let text = try model.createNote(inFolderRelativePath: nil, fileName: "Draft.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent(text))
        XCTAssertNil(model.contextForNote(relativePath: text))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvmodern-creation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
