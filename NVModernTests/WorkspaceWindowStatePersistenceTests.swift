import XCTest
@testable import nvModern

final class WorkspaceWindowStatePersistenceTests: XCTestCase {
    func testOlderWindowSnapshotDefaultsSidebarState() throws {
        let data = Data(
            """
            {
              "tabs": [],
              "selectedTabIndex": 0
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(PersistedWorkspaceWindowState.self, from: data)

        XCTAssertFalse(state.isSidebarVisible)
        XCTAssertEqual(state.sidebarWidth, 288)
        XCTAssertEqual(state.sidebarExpandedFolderPaths, [])
        XCTAssertNil(state.sidebarFocusedRootPath)
    }

    /// Focus mode was removed, but session files written before that still
    /// carry its flag. Decoding must ignore it rather than fail.
    func testWindowSnapshotIgnoresRemovedFocusModeField() throws {
        let data = Data(
            """
            {
              "isFocusMode": true,
              "isSidebarVisible": true,
              "sidebarWidth": 316,
              "tabs": [],
              "selectedTabIndex": 0
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(PersistedWorkspaceWindowState.self, from: data)

        XCTAssertTrue(state.isSidebarVisible)
        XCTAssertEqual(state.sidebarWidth, 316)
    }

    func testWindowSnapshotRoundTripsSidebarState() throws {
        let original = PersistedWorkspaceWindowState(
            frame: nil,
            isSidebarVisible: true,
            sidebarWidth: 316,
            sidebarExpandedFolderPaths: ["Projects", "Projects/nvModern"],
            sidebarFocusedRootPath: "Projects/nvModern"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PersistedWorkspaceWindowState.self, from: data)

        XCTAssertTrue(restored.isSidebarVisible)
        XCTAssertEqual(restored.sidebarWidth, 316)
        XCTAssertEqual(restored.sidebarExpandedFolderPaths, ["Projects", "Projects/nvModern"])
        XCTAssertEqual(restored.sidebarFocusedRootPath, "Projects/nvModern")
    }
}
