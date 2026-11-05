import XCTest
@testable import nvModern

final class PreviewFilePathResolverTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/workspace")
    private let homeURL = URL(fileURLWithPath: "/Users/example")

    func testRelativePathUsesAbsoluteSourceFileDirectory() throws {
        let resolved = try XCTUnwrap(resolve("d/e.png", sourcePath: "/a/b/c.md"))
        XCTAssertEqual(resolved.path, "/a/b/d/e.png")
    }

    func testRelativePathUsesWorkspaceSourceFileDirectory() throws {
        let resolved = try XCTUnwrap(resolve("images/photo.png", sourcePath: "notes/trips/day.md"))
        XCTAssertEqual(resolved.path, "/workspace/notes/trips/images/photo.png")
    }

    func testDotSegmentsAreStandardizedRelativeToSourceFile() throws {
        let resolved = try XCTUnwrap(resolve("./images/../assets/cover.png", sourcePath: "/a/b/c.md"))
        XCTAssertEqual(resolved.path, "/a/b/assets/cover.png")

        let parentResolved = try XCTUnwrap(resolve("../../shared/cover.png", sourcePath: "/a/b/c.md"))
        XCTAssertEqual(parentResolved.path, "/shared/cover.png")
    }

    func testAbsolutePathDoesNotUseSourceOrWorkspaceRoot() throws {
        let resolved = try XCTUnwrap(resolve("/var/tmp/cover.png", sourcePath: "/a/b/c.md"))
        XCTAssertEqual(resolved.path, "/var/tmp/cover.png")
    }

    func testTildePathUsesHomeDirectory() throws {
        let resolved = try XCTUnwrap(resolve("~/Pictures/cover.png", sourcePath: "/a/b/c.md"))
        XCTAssertEqual(resolved.path, "/Users/example/Pictures/cover.png")
    }

    private func resolve(_ path: String, sourcePath: String?) -> URL? {
        PreviewFilePathResolver.resolve(
            path: path,
            sourcePath: sourcePath,
            rootURL: rootURL,
            homeDirectoryURL: homeURL
        )
    }
}
