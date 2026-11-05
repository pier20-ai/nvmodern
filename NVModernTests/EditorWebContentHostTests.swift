import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import nvModern

@MainActor
final class EditorWebContentHostTests: XCTestCase {
    func testLoadingPreviewSwitchDetachesInactiveSurfacesAndReusesEditor() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-editor-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let tabID = TabID()
        let editor = EditorWebContentController(ownerTabID: tabID, rootURL: rootURL)
        let preview = EditorWebContentController(ownerTabID: tabID, rootURL: rootURL)
        let hostingView = NSHostingView(rootView: AnyView(EditorWebContentHost(controller: editor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            editor.invalidate()
            preview.invalidate()
            window.close()
        }

        try await waitForAttachment(editor, hostingView: hostingView)
        let host = try XCTUnwrap(findHost(in: hostingView))
        let originalEditor = try XCTUnwrap(host.subviews.first as? WKWebView)

        // Renaming temporarily selects the loading preview while the index catches up.
        hostingView.rootView = AnyView(EditorWebContentHost(controller: preview))
        try await waitForAttachment(preview, hostingView: hostingView)
        XCTAssertTrue(findHost(in: hostingView) === host)
        XCTAssertFalse(editor.isAttached)
        XCTAssertNil(originalEditor.superview)
        XCTAssertEqual(host.subviews.count, 1)

        hostingView.rootView = AnyView(EditorWebContentHost(controller: editor))
        try await waitForAttachment(editor, hostingView: hostingView)
        XCTAssertFalse(preview.isAttached)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(host.subviews.first === originalEditor)

        // Teardown must detach the latest controller, even if it differs from the initial one.
        hostingView.rootView = AnyView(EditorWebContentHost(controller: preview))
        try await waitForAttachment(preview, hostingView: hostingView)
        hostingView.rootView = AnyView(EmptyView())
        for _ in 0..<100 {
            hostingView.layoutSubtreeIfNeeded()
            if !preview.isAttached { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(editor.isAttached)
        XCTAssertFalse(preview.isAttached)
        XCTAssertTrue(host.subviews.isEmpty)
    }

    private func waitForAttachment(
        _ controller: EditorWebContentController,
        hostingView: NSView
    ) async throws {
        for _ in 0..<100 {
            hostingView.layoutSubtreeIfNeeded()
            if controller.isAttached { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The selected editor surface did not attach")
        throw CocoaError(.coderInvalidValue)
    }

    private func findHost(in view: NSView) -> EditorWebContentHostView? {
        if let host = view as? EditorWebContentHostView { return host }
        return view.subviews.compactMap { findHost(in: $0) }.first
    }
}
