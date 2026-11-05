import Foundation
import XCTest
@testable import nvModern

@MainActor
final class NotesWorkspaceSymlinkTests: XCTestCase {
    private var root: URL!
    private let body = "* Daily note\n\nsymlinkregression searchable content\n"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("days"), withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent("days/daily.org"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testFileLinksKeepAliasNamesAndUseTargetMetadataInBrowserAndSearch() async throws {
        try link("today.alex.org", to: "days/daily.org")
        try link("today.sam.org", to: root.appendingPathComponent("days/daily.org").path)
        try link("chained.org", to: "today.alex.org")
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let scanned = await model.waitForInitialSnapshot()
        XCTAssertTrue(scanned)

        let paths = Set(model.columns(for: []).flatMap { $0 }.map(\.relativePath))
        let aliases: Set<String> = ["today.alex.org", "today.sam.org", "chained.org"]
        XCTAssertTrue(paths.isSuperset(of: aliases))
        for alias in aliases {
            let context = try XCTUnwrap(model.contextForNote(relativePath: alias))
            XCTAssertEqual(context.kind, .text)
            XCTAssertEqual(context.relativePath, alias)
            XCTAssertEqual(context.body, body)
            XCTAssertEqual(context.fileSize, Int64(body.utf8.count))
            XCTAssertEqual(context.modifiedDate, model.contextForNote(relativePath: "days/daily.org")?.modifiedDate)
        }

        let deadline = Date().addingTimeInterval(10)
        var searchPaths: Set<String> = []
        repeat {
            let response = await model.search(query: "symlinkregression")
            searchPaths = Set(response.results.map(\.relativePath))
            if searchPaths.isSuperset(of: aliases) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        XCTAssertTrue(searchPaths.isSuperset(of: aliases))
    }

    func testFolderLinksKeepAliasPathsAndStopAtAncestorCycles() async throws {
        try link("linked-days", to: "days")
        try link("days/self", to: ".")
        try link("days/back-to-root", to: "..")
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let scanned = await model.waitForInitialSnapshot()
        XCTAssertTrue(scanned)

        let rootItems = model.columns(for: []).flatMap { $0 }
        XCTAssertEqual(rootItems.first { $0.relativePath == "linked-days" }?.kind, .folder)
        let columns = model.columns(for: ["linked-days"])
        XCTAssertEqual(columns.last?.map(\.relativePath), ["linked-days/daily.org"])
        XCTAssertEqual(model.contextForNote(relativePath: "linked-days/daily.org")?.body, body)
        XCTAssertNil(model.contextForNote(relativePath: "linked-days/self/daily.org"))
        XCTAssertEqual(model.columns(for: ["days"]).last?.map(\.relativePath), ["days/daily.org"])
    }

    func testBrokenCyclicHiddenAndOutOfWorkspaceLinksAreExcluded() async throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try body.write(to: outside.appendingPathComponent("outside.org"), atomically: true, encoding: .utf8)
        try link("broken.org", to: "missing.org")
        try link("cycle-a.org", to: "cycle-b.org")
        try link("cycle-b.org", to: "cycle-a.org")
        try link(".hidden.org", to: "days/daily.org")
        try link("outside.org", to: outside.appendingPathComponent("outside.org").path)
        try link("outside-folder", to: outside.path)
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let scanned = await model.waitForInitialSnapshot()
        XCTAssertTrue(scanned)

        let rootPaths = Set(model.columns(for: []).dropFirst().flatMap { $0 }.map(\.relativePath))
        XCTAssertEqual(rootPaths, ["days"])
        XCTAssertNil(WorkspaceNoteFileRead.fileURL(relativePath: "outside.org", projectRoot: root))
    }

    func testSavingTextAndDataUpdatesTargetAndPreservesLink() async throws {
        try link("today.org", to: "days/daily.org")
        try link("chained.org", to: "today.org")
        try link("linked-days", to: "days")
        let model = NotesWorkspaceModel(projectRootPath: root.path)
        let scanned = await model.waitForInitialSnapshot()
        XCTAssertTrue(scanned)

        try model.saveTextNote(relativePath: "today.org", body: "* Sync edit")
        try assertLinkAndTarget("* Sync edit")
        try model.saveTextNote(relativePath: "chained.org", body: "* Chained edit")
        try assertLinkAndTarget("* Chained edit")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("chained.org").path), "today.org")
        try await model.saveTextNoteAsync(relativePath: "today.org", body: "* Async edit")
        try assertLinkAndTarget("* Async edit")
        try model.saveDataNote(relativePath: "today.org", data: Data("* Data edit".utf8))
        try assertLinkAndTarget("* Data edit")
        try await WorkspaceFileIO.shared.writeData(Data("* Async data edit".utf8), to: root.appendingPathComponent("today.org"))
        try assertLinkAndTarget("* Async data edit")
        try await model.saveTextNoteAsync(relativePath: "linked-days/daily.org", body: "* Folder alias edit")
        try assertLinkAndTarget("* Folder alias edit")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("linked-days").path), "days")
    }

    func testActionReadReportsTargetByteCount() throws {
        try link("today.org", to: "days/daily.org")
        let result = try WorkspaceNoteFileRead.read(relativePath: "today.org", projectRoot: root, maxBytes: 5)
        XCTAssertEqual(result.relativePath, "today.org")
        XCTAssertEqual(result.body, String(body.prefix(5)))
        XCTAssertEqual(result.byteCount, body.utf8.count)
        XCTAssertTrue(result.truncated)
    }

    func testLiveSyncReportsTargetEditsForFileAndFolderAliases() async throws {
        try link("today.org", to: "days/daily.org")
        try link("linked-days", to: "days")
        let controller = WorkspaceLiveSyncController(rootURL: root)
        defer { controller.stop() }
        let changed = expectation(description: "Target edit reaches both aliases")
        changed.assertForOverFulfill = false
        controller.onUpdate = { update in
            if update.externalModifiedPaths.isSuperset(of: ["today.org", "linked-days/daily.org"]) {
                changed.fulfill()
            }
        }

        try "* External edit with a different size".write(
            to: root.appendingPathComponent("days/daily.org"), atomically: true, encoding: .utf8
        )
        await fulfillment(of: [changed], timeout: 10)
    }

    func testLiveSyncRecognizesSavingThroughAliasAsSelfWrite() async throws {
        try link("today.org", to: "days/daily.org")
        let controller = WorkspaceLiveSyncController(rootURL: root)
        defer { controller.stop() }
        let confirmed = expectation(description: "Alias save is a self-write")
        confirmed.assertForOverFulfill = false
        controller.onUpdate = { update in
            if update.selfWriteConfirmedPaths.contains("today.org") {
                XCTAssertFalse(update.externalModifiedPaths.contains("today.org"))
                confirmed.fulfill()
            }
        }
        let edited = "* Saved through alias"
        let token = controller.beginLocalWrite(relativePath: "today.org", expectedData: Data(edited.utf8), reason: "test")
        try await WorkspaceFileIO.shared.writeText(edited, to: root.appendingPathComponent("today.org"))
        controller.completeLocalWrite(token, fileURL: root.appendingPathComponent("today.org"))
        await fulfillment(of: [confirmed], timeout: 10)
    }

    func testLiveSyncReportsRetargetingAnAlias() async throws {
        try link("today.org", to: "days/daily.org")
        try "* Tomorrow".write(to: root.appendingPathComponent("days/tomorrow.org"), atomically: true, encoding: .utf8)
        let controller = WorkspaceLiveSyncController(rootURL: root)
        defer { controller.stop() }
        let retargeted = expectation(description: "Retargeted alias is modified")
        retargeted.assertForOverFulfill = false
        controller.onUpdate = { update in
            if update.externalModifiedPaths.contains("today.org") {
                retargeted.fulfill()
            }
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("today.org"))
        try link("today.org", to: "days/tomorrow.org")
        await fulfillment(of: [retargeted], timeout: 10)
    }

    private func link(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
    }

    private func assertLinkAndTarget(_ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("today.org").path),
            "days/daily.org", file: file, line: line
        )
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("days/daily.org"), encoding: .utf8),
            expected, file: file, line: line
        )
    }
}
