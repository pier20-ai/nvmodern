import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import nvModern

/// The launchpad browser answers arrow keys through a native key monitor rather
/// than SwiftUI focus. These pin the routing table and the responders that are
/// allowed to keep the keys.
final class MillerKeyboardRoutingTests: XCTestCase {
    private typealias Routing = MillerKeyboardRouting

    // Arrow keys arrive with `.function` and `.numericPad` set; those must not
    // count as modifiers.
    private let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    func testPlainArrowsMoveInEveryDirection() {
        XCTAssertEqual(Routing.action(keyCode: 123, flags: arrowFlags), .move(.left))
        XCTAssertEqual(Routing.action(keyCode: 124, flags: arrowFlags), .move(.right))
        XCTAssertEqual(Routing.action(keyCode: 125, flags: arrowFlags), .move(.down))
        XCTAssertEqual(Routing.action(keyCode: 126, flags: arrowFlags), .move(.up))
    }

    func testShiftArrowStillMoves() {
        XCTAssertEqual(
            Routing.action(keyCode: 125, flags: arrowFlags.union(.shift)),
            .move(.down)
        )
    }

    func testModifiedArrowsAreLeftForOtherHandlers() {
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control] {
            XCTAssertNil(
                Routing.action(keyCode: 124, flags: arrowFlags.union(modifier)),
                "\(modifier) + right arrow should not be consumed by the browser"
            )
        }
    }

    func testReturnAndTabRouting() {
        XCTAssertEqual(Routing.action(keyCode: 36, flags: []), .open)
        XCTAssertEqual(Routing.action(keyCode: 76, flags: []), .open)
        XCTAssertEqual(Routing.action(keyCode: 36, flags: [.command]), .openInBackgroundTab)
        XCTAssertNil(Routing.action(keyCode: 36, flags: [.option]))
        XCTAssertEqual(Routing.action(keyCode: 48, flags: []), .tab)
        XCTAssertNil(Routing.action(keyCode: 48, flags: [.shift]))
        XCTAssertNil(Routing.action(keyCode: 48, flags: [.control]))
    }

    func testUnrelatedKeysAreIgnored() {
        XCTAssertNil(Routing.action(keyCode: 0, flags: []))    // "a"
        XCTAssertNil(Routing.action(keyCode: 53, flags: []))   // Escape
        XCTAssertNil(Routing.action(keyCode: 49, flags: []))   // Space
    }

    func testRoutingReadsFlagsFromRealEvents() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: arrowFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ))
        XCTAssertEqual(Routing.action(for: event), .move(.right))
    }

    func testTextEntryRespondersKeepTheKeys() {
        XCTAssertTrue(Routing.responderNeedsKeys(NSTextView(frame: .zero)))
        XCTAssertTrue(Routing.responderNeedsKeys(NSTextField(frame: .zero)))
        XCTAssertTrue(Routing.responderNeedsKeys(NSSearchField(frame: .zero)))
    }

    func testEditorWebViewsKeepTheKeys() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertTrue(Routing.responderNeedsKeys(webView))

        // WebKit sometimes makes an internal subview first responder; walk up.
        let inner = NSView(frame: .zero)
        webView.addSubview(inner)
        XCTAssertTrue(Routing.responderNeedsKeys(inner))
    }

    func testBrowserPreviewWebViewDoesNotStealTheKeys() {
        let preview = MillerPreviewWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(Routing.responderNeedsKeys(preview))

        let inner = NSView(frame: .zero)
        preview.addSubview(inner)
        XCTAssertFalse(Routing.responderNeedsKeys(inner))
    }

    func testPlainViewsAndNoResponderLeaveTheBrowserInCharge() {
        XCTAssertFalse(Routing.responderNeedsKeys(nil))
        XCTAssertFalse(Routing.responderNeedsKeys(NSView(frame: .zero)))
        XCTAssertFalse(Routing.responderNeedsKeys(NSWindow()))
    }
}
