import Foundation
import XCTest
@testable import nvModern

final class ScratchpadFileSessionTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("scratch.md")
        try write("original")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testCleanExternalReplacementReloadsAndCloseDoesNotOverwrite() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        try write("external")
        XCTAssertTrue(try session.refresh())
        XCTAssertEqual(session.body, "external")
        XCTAssertFalse(session.isDirty)
        try session.save()
        XCTAssertEqual(try String(contentsOf: file), "external")
    }

    func testSaveDetectsConflictBeforeWatcherArrives() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local unsaved")
        try write("external")
        XCTAssertThrowsError(try session.save())
        XCTAssertTrue(session.hasConflict)
        XCTAssertEqual(session.body, "local unsaved")
        XCTAssertEqual(try String(contentsOf: file), "external")
        XCTAssertThrowsError(try session.save())
    }

    func testWatcherConflictRetainsBufferAndBlocksLaterEdits() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try write("external")
        XCTAssertThrowsError(try session.refresh())
        session.update("more local edits")
        XCTAssertThrowsError(try session.save())
        XCTAssertEqual(session.body, "more local edits")
        XCTAssertEqual(try String(contentsOf: file), "external")
    }

    func testOwnSaveUpdatesBaselineAndDoesNotConflictWithWatcher() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try session.save()
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(try session.refresh())
        try write("external after save")
        XCTAssertTrue(try session.refresh())
        XCTAssertEqual(session.body, "external after save")
    }

    func testDeletedDirtyFileIsNotRecreatedBySave() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try session.save())
        XCTAssertTrue(session.hasConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidUTF8DoesNotReplaceCleanBuffer() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try session.refresh())
        XCTAssertEqual(session.body, "original")
    }

    func testMissingFileIsCreatedAndDirectoryIsRejected() throws {
        try FileManager.default.removeItem(at: file)
        let session = try ScratchpadFileSession(fileURL: file)
        XCTAssertEqual(session.body, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try ScratchpadFileSession(fileURL: directory))
    }

    func testExplicitReloadAcceptsDiskAndUnblocksFutureEdits() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try write("external")
        XCTAssertThrowsError(try session.save())
        try session.reloadDiscardingLocalEdits()
        XCTAssertEqual(session.body, "external")
        XCTAssertFalse(session.hasConflict)
        XCTAssertFalse(session.isDirty)
        session.update("new local edits")
        try session.save()
        XCTAssertEqual(try String(contentsOf: file), "new local edits")
    }

    func testExplicitOverwriteAcceptsLocalAndResumesConflictDetection() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try write("external")
        XCTAssertThrowsError(try session.refresh())
        try session.overwriteWithLocalEdits()
        XCTAssertEqual(try String(contentsOf: file), "local")
        XCTAssertFalse(session.hasConflict)
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(try session.refresh())
        session.update("another edit")
        try write("another external edit")
        XCTAssertThrowsError(try session.save())
    }

    func testFailedReloadRetainsLocalEditsAndConflict() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try session.save())
        XCTAssertThrowsError(try session.reloadDiscardingLocalEdits())
        XCTAssertEqual(session.body, "local")
        XCTAssertTrue(session.hasConflict)
        try session.overwriteWithLocalEdits()
        XCTAssertEqual(try String(contentsOf: file), "local")
    }

    func testFailedOverwriteRetainsLocalEditsAndConflict() throws {
        let session = try ScratchpadFileSession(fileURL: file)
        session.update("local")
        try write("external")
        XCTAssertThrowsError(try session.refresh())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session.overwriteWithLocalEdits())
        XCTAssertEqual(session.body, "local")
        XCTAssertTrue(session.hasConflict)
    }

}
