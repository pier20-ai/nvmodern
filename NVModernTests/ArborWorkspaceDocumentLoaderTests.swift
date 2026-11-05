import Foundation
import XCTest
@testable import nvModern

final class ArborWorkspaceDocumentLoaderTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborWorkspaceDocumentLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testLoadsOutlineDocumentsWithWorkspaceRelativeIdentity() throws {
        try write("#lang arbor/0\n- Root ^root\n", to: "Root.outline")
        try write("#lang arbor/0\n- Nested ^nested\n", to: "Projects/Nested.OUTLINE")
        try write("ignored", to: "Notes.md")
        try write("#lang arbor/0\n- Hidden ^hidden\n", to: ".hidden.outline")

        let documents = ArborWorkspaceDocumentLoader.load(from: rootURL)

        XCTAssertEqual(documents.map(\.id), ["Projects/Nested.OUTLINE", "Root.outline"])
        XCTAssertEqual(documents.map(\.path), ["Projects/Nested.OUTLINE", "Root.outline"])
        XCTAssertEqual(documents.map(\.revision), [0, 0])
        XCTAssertTrue(documents[0].source.contains("Nested"))
    }

    private func write(_ source: String, to relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: url, atomically: true, encoding: .utf8)
    }
}
