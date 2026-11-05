import XCTest
@testable import nvModern

final class WorkspaceTabSessionPersistenceTests: XCTestCase {
    func testV4SnapshotInfersNoteKindFromOpenedDocument() throws {
        let json = """
        {
          "selectedFolderChain": ["Notes"],
          "selectedNotePath": "Notes/Idea.md",
          "openedDocument": {
            "workspaceNote": {
              "relativePath": "Notes/Idea.md"
            }
          },
          "millerActiveDepth": 1
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .note)
        XCTAssertEqual(decoded.openedDocument, .workspaceNote(relativePath: "Notes/Idea.md"))
    }

    func testV4SnapshotWithoutDocumentInfersLaunchpad() throws {
        let json = """
        {
          "selectedFolderChain": [],
          "millerActiveDepth": 0
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .launchpad)
        XCTAssertEqual(decoded.millerHorizontalOrigin, 0)
    }

    func testUnknownKindFallsBackToLaunchpad() throws {
        let json = """
        {
          "kind": "spaceship",
          "selectedFolderChain": [],
          "millerActiveDepth": 0
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .launchpad)
    }

    /// Chat documents were retired. A saved chat tab restores as a launchpad,
    /// and chat entries drop out of its history without losing the notes.
    func testRetiredChatTabRestoresAsLaunchpad() throws {
        let json = """
        {
          "kind": "chat",
          "selectedFolderChain": [],
          "millerActiveDepth": 0,
          "chatSession": { "provider": "claude", "sessionID": "s1", "displayName": "Refactor" },
          "historyCurrentItem": { "chat": { "_0": { "provider": "claude", "sessionID": "s1" } } },
          "backHistory": [
            { "workspaceNote": { "relativePath": "Notes/A.md" } },
            { "chat": { "_0": { "provider": "codex", "sessionID": "s0" } } }
          ],
          "forwardHistory": ["Notes/B.md"]
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .launchpad)
        XCTAssertNil(decoded.openedDocument)
        XCTAssertNil(decoded.historyCurrentItem)
        XCTAssertEqual(decoded.backHistory, [.workspaceNote(relativePath: "Notes/A.md")])
        XCTAssertEqual(decoded.forwardHistory, [.workspaceNote(relativePath: "Notes/B.md")])

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNil(object["chatSession"])
    }

    /// Sessions saved while companions existed still restore their tab; the
    /// retired `childPane` / `companionPanes` fields are ignored.
    func testLegacyCompanionFieldsAreIgnored() throws {
        let json = """
        {
          "kind": "note",
          "selectedFolderChain": ["Notes"],
          "selectedNotePath": "Notes/Idea.md",
          "openedDocument": {
            "workspaceNote": { "relativePath": "Notes/Idea.md" }
          },
          "millerActiveDepth": 1,
          "companionPanes": {
            "workspace:Notes/Idea.md": {
              "content": { "type": "document", "path": "Docs/Spec.pdf" },
              "dock": "right"
            }
          },
          "childPane": {
            "content": { "type": "document", "path": "Docs/Spec.pdf" },
            "dock": "floating",
            "floatingFrame": { "x": 20, "y": 20, "width": 360, "height": 300 }
          }
        }
        """
        let decoded = try JSONDecoder().decode(PersistedWorkspaceTabState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .note)
        XCTAssertEqual(decoded.openedDocument, .workspaceNote(relativePath: "Notes/Idea.md"))

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNil(object["companionPanes"])
        XCTAssertNil(object["childPane"])
    }
}
