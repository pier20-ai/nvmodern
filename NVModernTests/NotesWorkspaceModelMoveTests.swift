import Foundation
import XCTest
@testable import nvModern

@MainActor
final class NotesWorkspaceModelMoveTests: XCTestCase {
    func testMoveWorkspaceNoteMovesFileIntoExistingFolder() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let destinationFolderURL = fixture.rootURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolderURL,
            withIntermediateDirectories: true
        )
        let sourceURL = fixture.rootURL.appendingPathComponent("Inbox.md", isDirectory: false)
        try Data("hello".utf8).write(to: sourceURL)

        let movedPath = try fixture.model.moveWorkspaceNote(
            relativePath: "Inbox.md",
            toFolderRelativePath: "Archive"
        )

        XCTAssertEqual(movedPath, "Archive/Inbox.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(
            try String(contentsOf: destinationFolderURL.appendingPathComponent("Inbox.md"), encoding: .utf8),
            "hello"
        )
    }

    func testMoveWorkspaceNoteRejectsDestinationCollision() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let destinationFolderURL = fixture.rootURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolderURL,
            withIntermediateDirectories: true
        )
        let sourceURL = fixture.rootURL.appendingPathComponent("Inbox.md", isDirectory: false)
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing".utf8).write(
            to: destinationFolderURL.appendingPathComponent("Inbox.md", isDirectory: false)
        )

        XCTAssertThrowsError(
            try fixture.model.moveWorkspaceNote(
                relativePath: "Inbox.md",
                toFolderRelativePath: "Archive"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testMoveWorkspaceItemsMovesFilesAndFoldersTogether() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let destinationFolderURL = fixture.rootURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: fixture.rootURL.appendingPathComponent("Inbox.md"))
        let sourceFolderURL = fixture.rootURL.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolderURL, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: sourceFolderURL.appendingPathComponent("image.txt"))

        let movedPaths = try fixture.model.moveWorkspaceItems(
            relativePaths: ["Inbox.md", "Assets"],
            toFolderRelativePath: "Archive"
        )

        XCTAssertEqual(movedPaths["Inbox.md"], "Archive/Inbox.md")
        XCTAssertEqual(movedPaths["Assets"], "Archive/Assets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("Inbox.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFolderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFolderURL.appendingPathComponent("Inbox.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFolderURL.appendingPathComponent("Assets/image.txt").path))
    }

    func testMoveWorkspaceItemsPreflightsAllCollisionsBeforeMovingAnything() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let destinationFolderURL = fixture.rootURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)
        let firstSourceURL = fixture.rootURL.appendingPathComponent("First.md")
        let secondSourceURL = fixture.rootURL.appendingPathComponent("Second.md")
        try Data("first".utf8).write(to: firstSourceURL)
        try Data("second".utf8).write(to: secondSourceURL)
        try Data("collision".utf8).write(to: destinationFolderURL.appendingPathComponent("Second.md"))

        XCTAssertThrowsError(
            try fixture.model.moveWorkspaceItems(
                relativePaths: ["First.md", "Second.md"],
                toFolderRelativePath: "Archive"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFolderURL.appendingPathComponent("First.md").path))
    }

    func testMoveWorkspaceItemsRejectsMovingFolderIntoDescendant() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let childURL = fixture.rootURL.appendingPathComponent("Projects/Active", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try fixture.model.moveWorkspaceItems(
                relativePaths: ["Projects"],
                toFolderRelativePath: "Projects/Active"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: childURL.path))
    }

    func testMoveWorkspaceItemsRejectsNestedSelectionBeforeMovingParent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let sourceFileURL = fixture.rootURL.appendingPathComponent("Projects/Plan.md")
        try FileManager.default.createDirectory(
            at: sourceFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plan".utf8).write(to: sourceFileURL)
        try FileManager.default.createDirectory(
            at: fixture.rootURL.appendingPathComponent("Archive"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try fixture.model.moveWorkspaceItems(
                relativePaths: ["Projects", "Projects/Plan.md"],
                toFolderRelativePath: "Archive"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("Archive/Projects").path))
    }

    private func makeFixture() throws -> (rootURL: URL, model: NotesWorkspaceModel) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-refile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return (rootURL, NotesWorkspaceModel(projectRootPath: rootURL.path))
    }
}
