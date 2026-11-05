import AppKit
import WebKit
import XCTest
@testable import nvModern

@MainActor
final class AppHelpServiceTests: XCTestCase {
    private func provider() -> HelpProvider {
        HelpProvider(id: "test", title: "Test Help", topics: [HelpTopic(
            id: "sum", title: "Sum", category: "Numbers", summary: "Add values safely <script>example</script>.",
            keywords: ["total", "addition"], signatures: ["sum(values)"], aliases: ["stats.sum"],
            examples: [.init(code: "sum([1, 2])", result: "3")],
            insertions: [.init(id: "example-0", label: "Insert example", template: "sum([1, 2]) -> ")]
        )])
    }

    func testBundledProvidersDecodeAndSupportIntentSearch() throws {
        let service = AppHelpService()
        let calc = try XCTUnwrap(service.providers.first(where: { $0.id == "calc" }))
        XCTAssertGreaterThan(calc.topics.count, 100)
        XCTAssertTrue(calc.topics.contains { $0.matches("filter list") })
        XCTAssertTrue(calc.topics.contains { $0.matches("percentage") })
        XCTAssertFalse(calc.topics.contains { $0.matches("no-such-help-entry") })
        let topic = try XCTUnwrap(calc.topics.first)
        XCTAssertEqual(try JSONDecoder().decode(HelpTopic.self, from: JSONEncoder().encode(topic)), topic)
    }

    func testProviderRegistrationReplacesAndRejectsDuplicateTopicIDs() {
        let service = AppHelpService()
        let original = provider()
        service.register(original)
        var changed = original
        changed.title = "Updated"
        service.register(changed)
        XCTAssertEqual(service.providers.filter { $0.id == "test" }.count, 1)
        XCTAssertEqual(service.providers.first { $0.id == "test" }?.title, "Updated")
        changed.topics.append(changed.topics[0])
        service.register(changed)
        XCTAssertEqual(service.providers.first { $0.id == "test" }?.topics.count, 1)
    }

    func testNativeDetailRendersReactAndValidatesInsertionActions() async throws {
        let controller = HelpDrawerController(providers: [provider()], selectedProviderID: "test", canInsert: true, allowsMultiline: true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 880, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { controller.invalidate(); window.close() }
        window.makeKeyAndOrderFront(nil)
        let web = try XCTUnwrap(findWeb(in: controller.view))
        try await waitForTitle("Sum", web: web)
        let summary = try await web.evaluateJavaScript("document.querySelector('.summary').textContent") as? String
        XCTAssertEqual(summary, provider().topics[0].summary)
        let scripts = try await web.evaluateJavaScript("document.querySelector('.summary script') !== null") as? Bool
        XCTAssertEqual(scripts, false)
        let result = try await web.evaluateJavaScript("document.querySelector('.result code').textContent") as? String
        XCTAssertEqual(result, "3")
        var inserted: [String] = []
        controller.onInsert = { inserted.append($0) }
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.nvmodern.postMessage({kind:'event',event:'help.insert',payload:{topicID:'other',actionID:'example-0'}});true")
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.nvmodern.postMessage({kind:'event',event:'help.insert',payload:{topicID:'sum',actionID:'unknown'}});true")
        XCTAssertTrue(inserted.isEmpty)
        _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
        for _ in 0..<100 {
            if !inserted.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(inserted, ["sum([1, 2]) -> "])
        let search = try XCTUnwrap(findSearch(in: controller.view))
        search.stringValue = "nothing matches"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        for _ in 0..<100 {
            let empty = try await web.evaluateJavaScript("document.querySelector('.empty') !== null") as? Bool
            if empty == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let empty = try await web.evaluateJavaScript("document.querySelector('.empty') !== null") as? Bool
        XCTAssertEqual(empty, true)
    }

    func testDrawerDismissalIsBoundToSourceAndClosesOnce() async throws {
        let service = AppHelpService()
        service.register(provider())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = NSView(frame: window.contentLayoutRect)
        window.contentView = source
        window.makeKeyAndOrderFront(nil)
        defer { service.dismiss(); window.close() }
        var closed = 0
        let originalSubviews = source.subviews.count
        service.present(providerID: "test", in: source, onClose: { closed += 1 })
        XCTAssertTrue(service.isPresented)
        XCTAssertEqual(source.subviews.count, originalSubviews, "Help must not insert views into the host's view tree")
        let panel = try XCTUnwrap(window.childWindows?.first as? HelpPanel, "Help must attach to the workspace window")
        XCTAssertNotNil(findSearch(in: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(window.convertToScreen(window.contentLayoutRect).contains(AppHelpService.drawerFrame(in: window)))
        window.setContentSize(NSSize(width: 900, height: 700))
        XCTAssertEqual(panel.frame, AppHelpService.drawerFrame(in: window))
        service.dismiss(ownedBy: NSView())
        XCTAssertTrue(service.isPresented)
        service.dismiss(ownedBy: source)
        XCTAssertFalse(service.isPresented)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        service.dismiss()
        XCTAssertEqual(closed, 1)
    }

    func testDrawerDismissesOnEscapeAndWhenAnotherWindowBecomesKey() throws {
        let service = AppHelpService()
        service.register(provider())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = NSView(frame: window.contentLayoutRect)
        window.contentView = source
        window.makeKeyAndOrderFront(nil)
        defer { service.dismiss(animated: false); window.close() }
        service.present(providerID: "test", in: source)
        let panel = try XCTUnwrap(window.childWindows?.first as? HelpPanel)
        panel.cancelOperation(nil)
        XCTAssertFalse(service.isPresented)
        service.present(providerID: "test", in: source)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(service.isPresented)
    }

    private func findWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
    private func findSearch(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearch(in: $0) }.first
    }
    private func waitForTitle(_ title: String, web: WKWebView) async throws {
        for _ in 0..<300 {
            if let text = try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent"), text as? String == title { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let html = try? await web.evaluateJavaScript("document.body.innerHTML") as? String
        XCTFail("Bundled React help did not render its selected topic: \(html ?? "nil")")
    }
}
