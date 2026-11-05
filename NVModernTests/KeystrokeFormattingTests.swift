import XCTest
@testable import nvModern

final class KeystrokeFormattingTests: XCTestCase {

    // MARK: - symbolize

    func testSymbolizeBasicCmdShiftKey() {
        XCTAssertEqual(Keystroke.symbolize("cmd+shift+d"), "\u{2318}\u{21E7}D")
    }

    func testSymbolizeAllModifiers() {
        XCTAssertEqual(Keystroke.symbolize("cmd+ctrl+opt+shift+a"), "\u{2318}\u{2303}\u{2325}\u{21E7}A")
    }

    func testSymbolizePunctuationKey() {
        XCTAssertEqual(Keystroke.symbolize("cmd+/"), "\u{2318}/")
        XCTAssertEqual(Keystroke.symbolize("cmd+,"), "\u{2318},")
    }

    func testSymbolizeSpecialKeys() {
        XCTAssertEqual(Keystroke.symbolize("cmd+left"), "\u{2318}\u{2190}")
        XCTAssertEqual(Keystroke.symbolize("cmd+right"), "\u{2318}\u{2192}")
        XCTAssertEqual(Keystroke.symbolize("cmd+up"), "\u{2318}\u{2191}")
        XCTAssertEqual(Keystroke.symbolize("cmd+down"), "\u{2318}\u{2193}")
        XCTAssertEqual(Keystroke.symbolize("cmd+return"), "\u{2318}\u{21A9}")
        XCTAssertEqual(Keystroke.symbolize("cmd+tab"), "\u{2318}\u{21E5}")
        XCTAssertEqual(Keystroke.symbolize("cmd+space"), "\u{2318}\u{2423}")
        XCTAssertEqual(Keystroke.symbolize("cmd+delete"), "\u{2318}\u{232B}")
        XCTAssertEqual(Keystroke.symbolize("escape"), "\u{238B}")
    }

    func testSymbolizeFunctionKeys() {
        XCTAssertEqual(Keystroke.symbolize("cmd+f1"), "\u{2318}F1")
        XCTAssertEqual(Keystroke.symbolize("f12"), "F12")
    }

    func testSymbolizeNormalizesBeforeRendering() {
        // Input order should not matter.
        XCTAssertEqual(Keystroke.symbolize("Shift+CMD+D"), "\u{2318}\u{21E7}D")
    }

    func testSymbolizeEmptyReturnsEmpty() {
        XCTAssertEqual(Keystroke.symbolize(""), "")
        XCTAssertEqual(Keystroke.symbolize("   "), "")
    }

    // MARK: - fromComponents

    func testFromComponentsBasic() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: true, controlKey: false, optionKey: false, shiftKey: true, keyName: "d"),
            "cmd+shift+d"
        )
    }

    func testFromComponentsRejectsBareKey() {
        XCTAssertNil(
            Keystroke.fromComponents(commandKey: false, controlKey: false, optionKey: false, shiftKey: false, keyName: "d")
        )
    }

    func testFromComponentsRejectsShiftOnly() {
        XCTAssertNil(
            Keystroke.fromComponents(commandKey: false, controlKey: false, optionKey: false, shiftKey: true, keyName: "a")
        )
    }

    func testFromComponentsAcceptsControlOnly() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: false, controlKey: true, optionKey: false, shiftKey: false, keyName: "n"),
            "ctrl+n"
        )
    }

    func testFromComponentsAcceptsOptionOnly() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: false, controlKey: false, optionKey: true, shiftKey: false, keyName: "1"),
            "opt+1"
        )
    }

    func testFromComponentsLowercasesKey() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: true, controlKey: false, optionKey: false, shiftKey: false, keyName: "D"),
            "cmd+d"
        )
    }

    func testFromComponentsTrimsKey() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: true, controlKey: false, optionKey: false, shiftKey: false, keyName: "  d  "),
            "cmd+d"
        )
    }

    func testFromComponentsRejectsEmptyKey() {
        XCTAssertNil(
            Keystroke.fromComponents(commandKey: true, controlKey: false, optionKey: false, shiftKey: false, keyName: "")
        )
    }

    func testFromComponentsSpecialKeyName() {
        XCTAssertEqual(
            Keystroke.fromComponents(commandKey: true, controlKey: false, optionKey: false, shiftKey: false, keyName: "left"),
            "cmd+left"
        )
    }

    // MARK: - recorder output parses

    /// The Settings recorder writes Option as `opt`; the parser behind global
    /// hotkeys and `[[keybindings]]` must accept every spelling it records.
    @MainActor
    func testRecordedHyperShortcutParses() throws {
        let recorded = try XCTUnwrap(
            Keystroke.fromComponents(commandKey: true, controlKey: true, optionKey: true, shiftKey: true, keyName: "s")
        )
        XCTAssertEqual(recorded, "cmd+ctrl+opt+shift+s")

        let stroke = try ActionKeybindingManager().parseKeystroke(recorded)
        XCTAssertEqual(stroke.modifiers, [.command, .control, .option, .shift])
        XCTAssertEqual(stroke.key, .character("s"))
    }
}
