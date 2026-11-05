import AppKit
import XCTest
@testable import nvModern

@MainActor
final class WorkspaceWindowActivationGateTests: XCTestCase {
    func testActivationDeliversDocumentAndSidebarExactlyOnce() {
        let gate = WorkspaceWindowActivationGate(isActivated: false)
        let request = WorkspaceWindowLaunchStore.WindowRequest(
            projectRootPath: "/tmp/project",
            documents: [.workspaceNote(relativePath: "Draft.md")]
        )
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var delivered: WorkspaceWindowLaunchStore.WindowRequest?
        gate.onActivate = { resolved in
            XCTAssertTrue(resolved === window)
            XCTAssertTrue(gate.isActivated)
            delivered = gate.consumeRequest()
        }
        XCTAssertNil(gate.consumeRequest())
        gate.activate(sidebarVisible: false, request: request, window: window)
        XCTAssertEqual(delivered?.documents, request.documents)
        XCTAssertNil(gate.consumeRequest())
        XCTAssertEqual(gate.consumeSidebarVisibility(), false)
        XCTAssertNil(gate.consumeSidebarVisibility())
        XCTAssertNil(gate.onActivate)
    }

    func testSpareEligibilityKeepsProjectAndCopiedStateBoundaries() {
        var request = WorkspaceWindowLaunchStore.WindowRequest(
            projectRootPath: "/tmp/project",
            documents: [.workspaceNote(relativePath: "Draft.md")]
        )
        XCTAssertTrue(WorkspaceApplicationCoordinator.spareCanServe(request, rootKey: "/tmp/project"))
        XCTAssertFalse(WorkspaceApplicationCoordinator.spareCanServe(request, rootKey: "/tmp/other"))
        request.initialTabState = .initial
        XCTAssertFalse(WorkspaceApplicationCoordinator.spareCanServe(request, rootKey: "/tmp/project"))
        request.initialTabState = nil
        request.documents.append(.workspaceNote(relativePath: "Other.md"))
        XCTAssertFalse(WorkspaceApplicationCoordinator.spareCanServe(request, rootKey: "/tmp/project"))
    }
}
