import XCTest
@testable import nvModern

final class QuickCaptureAppendSupportTests: XCTestCase {
    func testMarkdownListContinuation() {
        XCTAssertEqual(
            QuickCaptureMarkdownContinuation.continuation(for: "  - item"),
            QuickCaptureListContinuation(indent: "  ", prefix: "  - ", endsList: false)
        )
        XCTAssertEqual(
            QuickCaptureMarkdownContinuation.continuation(for: "9. item"),
            QuickCaptureListContinuation(indent: "", prefix: "10. ", endsList: false)
        )
        XCTAssertEqual(
            QuickCaptureMarkdownContinuation.continuation(for: "- "),
            QuickCaptureListContinuation(indent: "", prefix: "- ", endsList: true)
        )
        XCTAssertNil(QuickCaptureMarkdownContinuation.continuation(for: "plain text"))
    }
}
