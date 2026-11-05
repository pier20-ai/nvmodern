import Foundation
import XCTest
@testable import nvModern

final class WorkspaceDiffDocumentTests: XCTestCase {
    func testDiffDocumentRoundTripsSourceReferencesWithoutBodies() throws {
        let original = WorkspaceOpenedDocument.diff(
            left: .workspace(relativePath: "Notes/Before.md"),
            right: .external(filePath: "/tmp/After.md")
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WorkspaceOpenedDocument.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.tabPresentation.title, "Before.md ↔ After.md")
        XCTAssertEqual(restored.tabPresentation.icon, "arrow.left.arrow.right")
        XCTAssertNil(restored.historyItem)
    }

    func testDiffSourcesResolveAgainstWorkspaceRoot() {
        let rootURL = URL(fileURLWithPath: "/tmp/Notes", isDirectory: true)

        XCTAssertEqual(
            WorkspaceDiffSource.workspace(relativePath: "Folder/Note.md").fileURL(rootURL: rootURL).path,
            "/tmp/Notes/Folder/Note.md"
        )
        XCTAssertEqual(
            WorkspaceDiffSource.external(filePath: "/tmp/External.md").fileURL(rootURL: rootURL).path,
            "/tmp/External.md"
        )
    }

    func testOnlyFileBackedMarkdownDocumentsCanBecomeDiffSources() {
        XCTAssertEqual(
            WorkspaceOpenedDocument.workspaceNote(relativePath: "Notes/Original.md").diffSource,
            .workspace(relativePath: "Notes/Original.md")
        )
        XCTAssertEqual(
            WorkspaceOpenedDocument.externalMarkdown(filePath: "/tmp/Selected.md").diffSource,
            .external(filePath: "/tmp/Selected.md")
        )
        XCTAssertNil(WorkspaceOpenedDocument.clipboardMarkdown(title: "Paste", body: "Text").diffSource)
    }

    @MainActor
    func testDiffWorkflowActionsAreRegisteredForReusableInvocation() {
        ActionRegistry.shared.ensureBuiltinsRegistered()

        XCTAssertEqual(
            ActionRegistry.shared.descriptor(for: "workspace.document.diff.selectOriginal")?.title,
            "Diff: Select as Original"
        )
        XCTAssertEqual(
            ActionRegistry.shared.descriptor(for: "workspace.document.diff.compareWithSelected")?.title,
            "Diff: Compare with Selected"
        )
    }
}
