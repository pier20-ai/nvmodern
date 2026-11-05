import Foundation
import XCTest
@testable import nvModern

final class WorkspaceNoteFileReadTests: XCTestCase {
    func testNormalizedRelativePathRejectsTraversal() {
        XCTAssertEqual(WorkspaceNoteFileRead.normalizedRelativePath("Inbox/Idea.md"), "Inbox/Idea.md")
        XCTAssertEqual(WorkspaceNoteFileRead.normalizedRelativePath("/Inbox/Idea.md"), "Inbox/Idea.md")
        XCTAssertNil(WorkspaceNoteFileRead.normalizedRelativePath("../secret.md"))
        XCTAssertNil(WorkspaceNoteFileRead.normalizedRelativePath("Inbox/../../secret.md"))
        XCTAssertNil(WorkspaceNoteFileRead.normalizedRelativePath(""))
    }

    func testFileURLRejectsEscapingTheProjectRoot() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        XCTAssertNotNil(WorkspaceNoteFileRead.fileURL(relativePath: "Inbox.md", projectRoot: rootURL))
        XCTAssertNil(WorkspaceNoteFileRead.fileURL(relativePath: "../Outside.md", projectRoot: rootURL))
    }

    func testReadReturnsBodyAndTruncation() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("Inbox.md")
        try Data("hello world".utf8).write(to: fileURL)

        let full = try WorkspaceNoteFileRead.read(relativePath: "Inbox.md", projectRoot: rootURL)
        XCTAssertEqual(full.relativePath, "Inbox.md")
        XCTAssertEqual(full.title, "Inbox.md")
        XCTAssertEqual(full.body, "hello world")
        XCTAssertFalse(full.truncated)

        let truncated = try WorkspaceNoteFileRead.read(
            relativePath: "Inbox.md",
            projectRoot: rootURL,
            maxBytes: 5
        )
        XCTAssertEqual(truncated.body, "hello")
        XCTAssertTrue(truncated.truncated)
        XCTAssertEqual(truncated.byteCount, 11)
    }

    func testReadMissingFileThrowsNotFound() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        XCTAssertThrowsError(
            try WorkspaceNoteFileRead.read(relativePath: "Missing.md", projectRoot: rootURL)
        ) { error in
            XCTAssertEqual(error as? WorkspaceNoteFileReadError, .notFound)
        }
    }

    func testReadDirectoryThrowsNotAFile() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Inbox"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try WorkspaceNoteFileRead.read(relativePath: "Inbox", projectRoot: rootURL)
        ) { error in
            XCTAssertEqual(error as? WorkspaceNoteFileReadError, .notAFile)
        }
    }

    private func makeRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-note-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

@MainActor
final class WorkspaceActionGetterTests: XCTestCase {
    func testGetterDescriptorsAreRegistered() {
        let registry = ActionRegistry()
        registry.ensureBuiltinsRegistered()

        let methods = [
            "workspace.search.query",
            "workspace.note.get",
            "workspace.editor.selection.get",
            "workspace.tabs.list",
            "workspace.project.current",
            "workspace.context.current",
            "workspace.editor.cursorContext.get",
            "workspace.projects.list"
        ]

        for method in methods {
            let descriptor = registry.descriptor(for: method)
            XCTAssertNotNil(descriptor, method)
            XCTAssertEqual(descriptor?.mutationKind, .readOnly, method)
        }

        XCTAssertEqual(
            registry.descriptor(for: "workspace.projects.list")?.targetRequirement,
            ActionTargetRequirement.none
        )
        XCTAssertEqual(registry.descriptor(for: "workspace.editor.selection.replace")?.mutationKind, .mutating)
        XCTAssertEqual(registry.descriptor(for: "workspace.document.jump")?.mutationKind, .readOnly)
        XCTAssertNotNil(registry.descriptor(for: "workspace.editor.selection.replace"))
        XCTAssertNotNil(registry.descriptor(for: "workspace.document.jump"))
    }

    func testSearchQueryRequiresANonEmptyQuery() async throws {
        let registry = ActionRegistry()
        registry.ensureBuiltinsRegistered()
        guard let handler = registry.handler(for: "workspace.search.query") else {
            return XCTFail("missing workspace.search.query handler")
        }

        let request = ActionRequest(
            method: "workspace.search.query",
            args: ["query": .string("   ")]
        )
        let context = ActionExecutionContext(
            source: .internalCall,
            target: .automatic,
            resolvedTarget: .unresolved,
            registry: registry,
            contentSurface: nil,
            now: Date()
        )

        do {
            _ = try await handler(request, context)
            XCTFail("expected invalid arguments")
        } catch let error as ActionError {
            XCTAssertEqual(error.code, .invalidArguments)
        }
    }
}
