import XCTest
@testable import nvModern

final class NVModernURLSchemeTests: XCTestCase {
    func testPercentEncodedAbsoluteFilePath() throws {
        let link = try parse("nvmodern://file/%2FUsers%2Fexample%2Fnotes%2FIdea.md")
        XCTAssertEqual(link, .file(path: "/Users/example/notes/Idea.md", line: nil, heading: nil))
    }

    func testUnencodedAbsoluteFilePath() throws {
        let link = try parse("nvmodern://file//Users/example/notes/Idea.md")
        XCTAssertEqual(link, .file(path: "/Users/example/notes/Idea.md", line: nil, heading: nil))
    }

    func testFilePathWithSpaceAmpersandAndLine() throws {
        let link = try parse("nvmodern://file//Users/example/My%20Notes/A%26B.md?line=12")
        XCTAssertEqual(
            link,
            .file(path: "/Users/example/My Notes/A&B.md", line: 12, heading: nil)
        )
    }

    func testWorkspaceRelativeFilePath() throws {
        let link = try parse("nvmodern://file/10-Workspaces/21-Storefront/Idea.md")
        XCTAssertEqual(
            link,
            .file(path: "10-Workspaces/21-Storefront/Idea.md", line: nil, heading: nil)
        )
    }

    func testWorkspaceRelativeFilePathWithHeading() throws {
        let link = try parse("nvmodern://file/Inbox/Idea.md?heading=Next%20steps&line=3")
        XCTAssertEqual(
            link,
            .file(path: "Inbox/Idea.md", line: 3, heading: "Next steps")
        )
    }

    /// Links shared before the workspace query was retired keep parsing; the
    /// unknown query key is simply ignored and resolution is root-relative.
    func testRetiredWorkspaceQueryIsIgnored() throws {
        let link = try parse("nvmodern://file/Inbox/Idea.md?workspace=%2FUsers%2Fexample%2Fnotes")
        XCTAssertEqual(link, .file(path: "Inbox/Idea.md", line: nil, heading: nil))
    }

    func testEmptyFilePathIsRejected() {
        switch NVModernURLScheme.parse("nvmodern://file/") {
        case .failure(.relativeFilePath):
            break
        case let other:
            XCTFail("expected relativeFilePath, got \(other)")
        }
    }

    /// Chat documents were retired; their links are now an unknown route.
    func testRetiredChatLinkIsAnUnknownRoute() {
        switch NVModernURLScheme.parse("nvmodern://chat/claude/3f2a9c1e-4b8d-4f1a-9c2e-8a7b6c5d4e3f") {
        case .failure(.unknownRoute("chat")):
            break
        case let other:
            XCTFail("expected unknownRoute(chat), got \(other)")
        }
    }

    func testUnknownRouteIsRejected() {
        switch NVModernURLScheme.parse("nvmodern://bogus/x") {
        case .failure(.unknownRoute("bogus")):
            break
        case let other:
            XCTFail("expected unknownRoute, got \(other)")
        }
    }

    func testHeadingQuery() throws {
        let link = try parse("nvmodern://file/%2FUsers%2Fexample%2Fnotes%2FInbox%2FIdea.md?heading=Next%20steps")
        XCTAssertEqual(
            link,
            .file(path: "/Users/example/notes/Inbox/Idea.md", line: nil, heading: "Next steps")
        )
    }

    func testRelativeFileLinkRoundTrip() throws {
        let raw = NVModernURLScheme.fileLinkURL(
            relativePath: "10-Workspaces/Idea.md",
            line: 4,
            heading: "Next steps"
        )
        XCTAssertEqual(raw, "nvmodern://file/10-Workspaces/Idea.md?line=4&heading=Next%20steps")
        let link = try parse(raw)
        XCTAssertEqual(
            link,
            .file(path: "10-Workspaces/Idea.md", line: 4, heading: "Next steps")
        )
    }

    func testURLHostReconstructionForUnencodedFile() throws {
        let url = try XCTUnwrap(URL(string: "nvmodern://file//Users/example/notes/Idea.md"))
        let reconstructed = NVModernURLScheme.rawString(from: url)
        let link = try NVModernURLScheme.parse(reconstructed).get()
        XCTAssertEqual(link, .file(path: "/Users/example/notes/Idea.md", line: nil, heading: nil))
    }

    /// Foundation URLs prepend a slash to relative paths, so a relative link
    /// that round-trips through `URL` arrives looking absolute; the router
    /// resolves the ambiguity by trying workspace roots first. The parse itself
    /// just carries the path and query through.
    func testURLHostReconstructionOfRelativeLink() throws {
        let raw = NVModernURLScheme.fileLinkURL(relativePath: "Inbox/Idea.md")
        let url = try XCTUnwrap(URL(string: raw))
        let reconstructed = NVModernURLScheme.rawString(from: url)
        let link = try NVModernURLScheme.parse(reconstructed).get()
        XCTAssertEqual(link, .file(path: "/Inbox/Idea.md", line: nil, heading: nil))
    }

    private func parse(_ raw: String) throws -> NVModernURLScheme.Link {
        try NVModernURLScheme.parse(raw).get()
    }
}
