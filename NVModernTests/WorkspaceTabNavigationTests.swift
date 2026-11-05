import XCTest
@testable import nvModern

final class WorkspaceTabNavigationTests: XCTestCase {
    func testNavigatePushesCurrentDocumentAndClearsForwardHistory() {
        var state = WorkspaceTabState(document: .workspaceNote(relativePath: "Notes/first.md"))
        state.forwardHistory = [.workspaceNote(relativePath: "Notes/future.md")]

        state.navigate(to: .workspaceNote(relativePath: "Projects/second.md"))

        XCTAssertEqual(state.backHistory, [.workspaceNote(relativePath: "Notes/first.md")])
        XCTAssertTrue(state.forwardHistory.isEmpty)
        XCTAssertEqual(state.historyCurrentItem, .workspaceNote(relativePath: "Projects/second.md"))
        XCTAssertEqual(state.selectedNotePath, "Projects/second.md")
        XCTAssertEqual(state.selectedFolderChain, ["Projects"])
        XCTAssertEqual(state.activeMillerItemPath, "Projects/second.md")
    }

    func testNavigateToCurrentDocumentDoesNotDuplicateHistory() {
        var state = WorkspaceTabState(document: .workspaceNote(relativePath: "Notes/current.md"))

        state.navigate(to: .workspaceNote(relativePath: "Notes/current.md"))

        XCTAssertTrue(state.backHistory.isEmpty)
        XCTAssertTrue(state.forwardHistory.isEmpty)
    }

    func testHistoryTraversalCanNavigateWithoutRecordingAnotherEntry() {
        var state = WorkspaceTabState(document: .workspaceNote(relativePath: "Notes/current.md"))
        state.backHistory = [.workspaceNote(relativePath: "Notes/previous.md")]

        let previous = state.backHistory.removeLast()
        state.forwardHistory.append(state.historyCurrentItem!)
        guard let previousDocument = previous.openedDocument else {
            return XCTFail("Expected document history item")
        }
        state.navigate(to: previousDocument, recordHistory: false)

        XCTAssertTrue(state.backHistory.isEmpty)
        XCTAssertEqual(state.forwardHistory, [.workspaceNote(relativePath: "Notes/current.md")])
        XCTAssertEqual(state.historyCurrentItem, .workspaceNote(relativePath: "Notes/previous.md"))
    }
}
