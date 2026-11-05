import XCTest
@testable import nvModern

final class CommandCatalogTests: XCTestCase {

    // MARK: - Keystroke normalization

    func testKeystrokeNormalizeLowercases() {
        XCTAssertEqual(Keystroke.normalize("Cmd+Shift+D"), "cmd+shift+d")
        XCTAssertEqual(Keystroke.normalize("CMD+SHIFT+D"), "cmd+shift+d")
    }

    func testKeystrokeNormalizeSortsModifiers() {
        XCTAssertEqual(Keystroke.normalize("shift+cmd+d"), "cmd+shift+d")
        XCTAssertEqual(Keystroke.normalize("opt+ctrl+cmd+a"), "cmd+ctrl+opt+a")
    }

    func testKeystrokeNormalizeResolvesAliases() {
        XCTAssertEqual(Keystroke.normalize("command+option+a"), "cmd+opt+a")
        XCTAssertEqual(Keystroke.normalize("control+alt+x"), "ctrl+opt+x")
    }

    func testKeystrokeNormalizeSeparatedSymbolModifiers() {
        // Symbol modifiers separated by `+` work; concatenated symbols ("⌘⇧D") are
        // not parsed here — the recorder will emit canonical text.
        XCTAssertEqual(Keystroke.normalize("\u{2318}+\u{21E7}+d"), "cmd+shift+d")
    }

    func testKeystrokeNormalizeTolerantToWhitespace() {
        XCTAssertEqual(Keystroke.normalize("  cmd + shift + d  "), "cmd+shift+d")
    }

    func testKeystrokeNormalizeEmptyReturnsEmpty() {
        XCTAssertEqual(Keystroke.normalize(""), "")
        XCTAssertEqual(Keystroke.normalize("   "), "")
    }

    func testKeystrokeEqualIgnoresCaseAndOrder() {
        XCTAssertTrue(Keystroke.equal("Cmd+Shift+D", "shift+CMD+d"))
    }

    // MARK: - Lookup

    func testKeystrokeForReturnsDefaultWhenNoOverride() {
        let draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        let (keystroke, isOverride) = draft.keystroke(for: entry)
        XCTAssertEqual(keystroke, "cmd+d")
        XCTAssertFalse(isOverride)
    }

    func testKeystrokeForReturnsNilForSpecialWithoutDefault() {
        let draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        let (keystroke, isOverride) = draft.keystroke(for: entry)
        XCTAssertNil(keystroke)
        XCTAssertFalse(isOverride)
    }

    func testKeystrokeForReturnsOverride() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.setKeystroke("cmd+opt+d", for: entry)
        let (keystroke, isOverride) = draft.keystroke(for: entry)
        XCTAssertEqual(keystroke, "cmd+opt+d")
        XCTAssertTrue(isOverride)
    }

    // MARK: - Upsert / reset / unbind

    func testSetKeystrokeWritesRow() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)
        XCTAssertEqual(draft.keybindings.count, 1)
        XCTAssertEqual(draft.keybindings.first?.id, entry.id)
        XCTAssertEqual(draft.keybindings.first?.keystroke, "cmd+ctrl+d")
    }

    func testSetKeystrokeOverwritesExistingRow() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)
        draft.setKeystroke("cmd+ctrl+shift+d", for: entry)
        XCTAssertEqual(draft.keybindings.count, 1)
        XCTAssertEqual(draft.keybindings.first?.keystroke, "cmd+ctrl+shift+d")
    }

    func testSetKeystrokeMatchingDefaultWritesNoRow() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.setKeystroke("cmd+d", for: entry)
        XCTAssertTrue(draft.keybindings.isEmpty, "matching default should be a delete, not a write")
    }

    func testSetKeystrokeNilClearsOverride() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)
        draft.setKeystroke(nil, for: entry)
        XCTAssertTrue(draft.keybindings.isEmpty)
        let (current, isOverride) = draft.keystroke(for: entry)
        XCTAssertEqual(current, "cmd+d", "should revert to catalog default")
        XCTAssertFalse(isOverride)
    }

    func testResetKeystrokeClearsOverride() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)
        draft.resetKeystroke(for: entry)
        XCTAssertTrue(draft.keybindings.isEmpty)
    }

    func testUnbindWritesEmptyRow() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.unbindKeystroke(for: entry)
        XCTAssertEqual(draft.keybindings.count, 1, "unbind on a catalog entry with a default writes a no-keystroke row")
        let (current, isOverride) = draft.keystroke(for: entry)
        XCTAssertNil(current)
        XCTAssertTrue(isOverride)
    }

    func testUnbindOnNoDefaultIsNoop() {
        var draft = NVModernConfigDraft()
        let entry = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        draft.unbindKeystroke(for: entry)
        XCTAssertTrue(draft.keybindings.isEmpty)
    }

    // MARK: - Custom keybindings preservation

    func testCustomKeybindingsPreservedThroughCatalogMutations() {
        var draft = NVModernConfigDraft()
        let custom = NVModernActionKeybindingDraft(
            id: "user.custom.thing",
            keystroke: "cmd+opt+u",
            method: "user.custom.invoke"
        )
        draft.keybindings.append(custom)

        let entry = CommandCatalog.entry(id: "workspace.tab.split-right")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)
        draft.resetKeystroke(for: entry)

        XCTAssertEqual(draft.keybindings.count, 1, "custom row should survive catalog set+reset")
        XCTAssertEqual(draft.keybindings.first?.id, "user.custom.thing")
    }

    func testCustomKeybindingCountExcludesCatalog() {
        var draft = NVModernConfigDraft()
        draft.keybindings.append(NVModernActionKeybindingDraft(id: "user.one", keystroke: "cmd+1"))
        draft.keybindings.append(NVModernActionKeybindingDraft(id: "user.two", keystroke: "cmd+2"))
        let entry = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        draft.setKeystroke("cmd+ctrl+d", for: entry)

        XCTAssertEqual(draft.customKeybindingCount, 2)
    }

    // MARK: - Conflict detection

    func testReservedKeystrokeConflictDetected() {
        let draft = NVModernConfigDraft()
        let conflict = draft.keystrokeConflict(for: "cmd+b")
        if case .reserved(let purpose) = conflict {
            XCTAssertEqual(purpose, "Bold")
        } else {
            XCTFail("expected reserved conflict, got \(String(describing: conflict))")
        }
    }

    func testReservedConflictIsCaseInsensitive() {
        let draft = NVModernConfigDraft()
        let conflict = draft.keystrokeConflict(for: "CMD+SHIFT+H")
        if case .reserved = conflict {} else {
            XCTFail("expected reserved conflict")
        }
    }

    func testPaletteShortcutsAreReservedByTheirActualModes() {
        let purposes = Dictionary(
            uniqueKeysWithValues: CommandCatalog.reservedKeystrokes.map {
                ($0.keystroke, $0.purpose)
            }
        )

        XCTAssertEqual(purposes["cmd+k"], "Quick Find")
        XCTAssertEqual(purposes["cmd+shift+k"], "Actions")
        XCTAssertNil(purposes["cmd+o"])
    }

    func testCatalogConflictDetectedAgainstDefault() {
        let draft = NVModernConfigDraft()
        // Try to bind cmd+d to a different entry; it's the default for split-right.
        let conflict = draft.keystrokeConflict(
            for: "cmd+d",
            excluding: "workspace.tab.duplicate"
        )
        if case .catalogEntry(let id, _) = conflict {
            XCTAssertEqual(id, "workspace.tab.split-right")
        } else {
            XCTFail("expected catalog conflict, got \(String(describing: conflict))")
        }
    }

    func testCatalogConflictAgainstOverride() {
        var draft = NVModernConfigDraft()
        let dup = CommandCatalog.entry(id: "workspace.tab.duplicate")!
        draft.setKeystroke("cmd+ctrl+d", for: dup)

        let conflict = draft.keystrokeConflict(
            for: "cmd+ctrl+d",
            excluding: "workspace.note.create"
        )
        if case .catalogEntry(let id, _) = conflict {
            XCTAssertEqual(id, dup.id)
        } else {
            XCTFail("expected catalog conflict from override")
        }
    }

    func testCatalogConflictExcludesSelf() {
        let draft = NVModernConfigDraft()
        let conflict = draft.keystrokeConflict(
            for: "cmd+d",
            excluding: "workspace.tab.split-right"
        )
        XCTAssertNil(conflict, "an entry should be allowed to keep its own keystroke")
    }

    func testCustomConflictDetected() {
        var draft = NVModernConfigDraft()
        draft.keybindings.append(
            NVModernActionKeybindingDraft(id: "user.custom", keystroke: "cmd+opt+u")
        )
        let conflict = draft.keystrokeConflict(for: "cmd+opt+u")
        if case .customKeybinding(let id) = conflict {
            XCTAssertEqual(id, "user.custom")
        } else {
            XCTFail("expected custom conflict")
        }
    }

    func testNoConflictForNovelKeystroke() {
        let draft = NVModernConfigDraft()
        XCTAssertNil(draft.keystrokeConflict(for: "cmd+ctrl+opt+q"))
    }
}
