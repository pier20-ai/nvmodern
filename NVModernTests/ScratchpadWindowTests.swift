import AppKit
import XCTest
import WebKit
@testable import nvModern

@MainActor
final class ScratchpadWindowTests: XCTestCase {
    func testFileIdentityReuseWindowOptionsAndFrameMemory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratchpad-window-\(UUID().uuidString).md")
        let frameName = "nvModern.scratchpad.\(url.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            NSWindow.removeFrame(usingName: frameName)
        }
        let controller = ScratchpadWindowController()
        try controller.open(PluginWindowRequest(fileURL: url, alwaysOnTop: true, allSpaces: true))
        let window = try XCTUnwrap(NSApp.windows.first { $0.representedURL == url })
        XCTAssertEqual(window.title, url.lastPathComponent)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(WindowFocusCoordinator.shared.kind(of: window), .scratchpad)

        window.setContentSize(NSSize(width: 500, height: 400))
        let resizedFrame = window.frame
        try controller.open(PluginWindowRequest(fileURL: url, alwaysOnTop: false, allSpaces: false, width: 600))
        XCTAssertEqual(NSApp.windows.filter { $0.representedURL == url }.count, 1)
        XCTAssertEqual(window.frame, resizedFrame)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        try controller.open(PluginWindowRequest(fileURL: url, position: .right))
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        XCTAssertEqual(window.frame.maxX, screen.visibleFrame.maxX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, screen.visibleFrame.maxY, accuracy: 1)
        try controller.open(PluginWindowRequest(fileURL: url, position: .coordinates(x: 12, y: 24)))
        XCTAssertEqual(window.frame.minX, screen.visibleFrame.minX + 12, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, screen.visibleFrame.maxY - 24, accuracy: 1)
        XCTAssertTrue(controller.prepareForTermination())
        window.performClose(nil)
        XCTAssertNil(WindowFocusCoordinator.shared.kind(of: window))

        try controller.open(PluginWindowRequest(fileURL: url))
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.representedURL == url && $0.isVisible })
        XCTAssertEqual(reopened.frame.size, resizedFrame.size)
        reopened.performClose(nil)
    }

    func testRapidEditToggleCloseFlushesTheWebBufferAndCanReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratchpad-bridge-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: url)
            NSWindow.removeFrame(usingName: "nvModern.scratchpad.\(url.path)")
        }
        let controller = ScratchpadWindowController()
        try controller.open(PluginWindowRequest(fileURL: url, toggle: true))
        let window = try XCTUnwrap(NSApp.windows.first { $0.representedURL == url })
        let webView = try await waitForWebView(window)
        try await waitForEditor(webView)
        _ = try await runScript(webView, """
            const content = document.querySelector('.cm-content');
            content.focus();
            document.execCommand('insertText', false, 'rapid edit');
            await new Promise(resolve => requestAnimationFrame(resolve));
            """)
        try controller.open(PluginWindowRequest(fileURL: url, toggle: true))
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(WindowFocusCoordinator.shared.kind(of: window))
        XCTAssertEqual(try String(contentsOf: url), "rapid edit")
        try controller.open(PluginWindowRequest(fileURL: url, toggle: true))
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.representedURL == url && $0.isVisible })
        XCTAssertFalse(reopened === window)
        reopened.performClose(nil)
    }

    func testCleanReloadKeepsEditorAndThemeObserverIsInstalled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratchpad-theme-\(UUID().uuidString).md")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url)
            NSWindow.removeFrame(usingName: "nvModern.scratchpad.\(url.path)")
        }
        let controller = ScratchpadWindowController()
        try controller.open(PluginWindowRequest(fileURL: url))
        let window = try XCTUnwrap(NSApp.windows.first { $0.representedURL == url })
        let webView = try await waitForWebView(window)
        try await waitForEditor(webView)
        _ = try await webView.evaluateJavaScript("window.scratchpadOriginalEditor = document.querySelector('.cm-content'); document.documentElement.style.setProperty('--bg', '#123456')")
        let themeChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let color = window.backgroundColor.usingColorSpace(.sRGB) else { return false }
            return abs(color.redComponent - 18.0 / 255) < 0.005
                && abs(color.greenComponent - 52.0 / 255) < 0.005
                && abs(color.blueComponent - 86.0 / 255) < 0.005
        }, object: nil)
        await fulfillment(of: [themeChanged], timeout: 5)
        try "external update".write(to: url, atomically: true, encoding: .utf8)
        try controller.open(PluginWindowRequest(fileURL: url))
        _ = try await runScript(webView, "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
        let sameEditor = try await webView.evaluateJavaScript("window.scratchpadOriginalEditor === document.querySelector('.cm-content')")
        XCTAssertEqual(sameEditor as? Bool, true)
        let text = try await webView.evaluateJavaScript("document.querySelector('.cm-content').textContent")
        XCTAssertEqual(text as? String, "external update")
        window.performClose(nil)
    }

    private func findWebView(in view: NSView?) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view?.subviews.compactMap { findWebView(in: $0) }.first
    }

    private func waitForWebView(_ window: NSWindow) async throws -> WKWebView {
        for _ in 0..<100 {
            if let webView = findWebView(in: window.contentView) { return webView }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The hosting view did not attach the editor")
        throw CocoaError(.coderInvalidValue)
    }

    private func runScript(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func waitForEditor(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            if !webView.isLoading,
               let mounted = try? await webView.evaluateJavaScript("!!document.querySelector('.cm-content')"),
               mounted as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The bundled editor did not mount")
        throw CocoaError(.coderInvalidValue)
    }

}
