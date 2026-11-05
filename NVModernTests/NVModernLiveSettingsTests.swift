import Foundation
import TOMLKit
import XCTest
@testable import nvModern

@MainActor
final class NVModernLiveSettingsTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvmodern-live-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.toml")
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }

    func testPluginTablesRoundTripIncludingAbsentPluginsAndUnknownSettings() throws {
        let source = """
        root = "\(directory.path)"
        [plugins]
        disabled = ["missing", "capture"]
        [plugins.settings.capture]
        folder = "Daily"
        enabled = true
        count = 3
        style = "org"
        future = ["retain", "these"]
        [plugins.settings.missing]
        still_here = "yes"
        """
        let first = try TOMLDecoder().decode(NVModernConfigDraft.self, from: source)
        let encoded = try NVModernConfigSchema.shared.encodedTOML(for: first)
        let second = try TOMLDecoder().decode(NVModernConfigDraft.self, from: encoded)
        XCTAssertEqual(first, second, "Row UUIDs must not make a disk reload look like an edit")
        XCTAssertEqual(second.plugins.settings["missing"]?["still_here"], "yes")
        XCTAssertEqual(second.plugins.settings["capture"]?["future"], ["retain", "these"])
    }

    func testLiveWriteMergesUnrelatedExternalEditAndPreservesUnknownPluginValues() throws {
        var base = NVModernConfigDraft(projects: [.init(name: "Notes", path: directory.path)])
        base.plugins.settings["capture"] = ["folder": "Daily", "unknown": "keep"]
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let monitor = NVModernConfigFileMonitor(configURL: configURL)
        var external = base; external.users = ["External"]
        try NVModernConfigSchema.shared.saveDraft(external, configURL: configURL)
        var edited = base; edited.plugins.settings["capture"]?["folder"] = "Inbox"
        let result = try monitor.write(edited, basedOn: base)
        XCTAssertEqual(result.users, ["External"])
        XCTAssertEqual(try monitor.readDraft().plugins.settings["capture"], ["folder": "Inbox", "unknown": "keep"])
    }

    func testConflictingExternalEditIsNotOverwritten() throws {
        let base = NVModernConfigDraft(users: ["Initial"], projects: [.init(name: "Notes", path: directory.path)])
        var edited = base; edited.users = ["UI edit"]
        var external = base; external.users = ["Disk edit"]
        XCTAssertThrowsError(try NVModernConfigFileMonitor.mergingEdits(base: base, edited: edited, latest: external))
    }

    func testPluginOnlyRefreshIsDeliveredOnceAndDiskEditsReachSettingsModel() async throws {
        let base = NVModernConfigDraft(projects: [.init(name: "Notes", path: directory.path)])
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let monitor = NVModernConfigFileMonitor(configURL: configURL)
        let model = NVModernSettingsModel(monitor: monitor)
        let observedURL = configURL!
        var targeted = 0, broad = 0
        let observer = NotificationCenter.default.addObserver(forName: .nvModernPluginsConfigDidChange, object: nil, queue: .main) { notification in
            if notification.object as? URL == observedURL { targeted += 1 }
        }
        let other = NotificationCenter.default.addObserver(forName: .nvModernConfigDidChange, object: nil, queue: .main) { notification in
            if notification.object as? URL == observedURL { broad += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer); NotificationCenter.default.removeObserver(other) }
        var edited = model.draft; edited.plugins.disabled = ["capture"]
        XCTAssertTrue(model.updateDraft(edited))
        XCTAssertEqual(model.draft.defaultProject?.path, directory.path)
        monitor.refresh()
        XCTAssertEqual(targeted, 1)
        XCTAssertEqual(broad, 0)
        var external = try monitor.readDraft(); external.users = ["Updated on disk"]
        try NVModernConfigSchema.shared.saveDraft(external, configURL: configURL)
        monitor.refresh()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(model.draft.users, ["Updated on disk"])
        XCTAssertEqual(model.draft.defaultProject?.path, directory.path)
        var followup = model.draft; followup.plugins.settings["capture"] = ["folder": "Daily"]
        XCTAssertTrue(model.updateDraft(followup))
        XCTAssertEqual(try monitor.readDraft().root, directory.path)
        XCTAssertEqual(broad, 1)
    }

    func testInvalidDiskContentCannotBeOverwrittenBySettings() throws {
        let base = NVModernConfigDraft(projects: [.init(name: "Notes", path: directory.path)])
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let model = NVModernSettingsModel(monitor: .init(configURL: configURL))
        try "root = [".write(to: configURL, atomically: true, encoding: .utf8)
        var edit = model.draft; edit.users = ["New person"]
        XCTAssertFalse(model.updateDraft(edit))
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "root = [")
    }

    func testRepairingInvalidTOMLRefreshesRuntimeEvenWhenValuesAreUnchanged() throws {
        let base = NVModernConfigDraft(projects: [.init(name: "Notes", path: directory.path)])
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let original = try Data(contentsOf: configURL)
        let monitor = NVModernConfigFileMonitor(configURL: configURL)
        let observedURL = configURL!
        var refreshes = 0
        let observer = NotificationCenter.default.addObserver(forName: .nvModernConfigDidChange, object: nil, queue: .main) { notification in
            if notification.object as? URL == observedURL { refreshes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try "root = [".write(to: configURL, atomically: true, encoding: .utf8)
        monitor.refresh()
        XCTAssertEqual(refreshes, 0)
        try original.write(to: configURL, options: .atomic)
        monitor.refresh()
        XCTAssertEqual(refreshes, 1)
        monitor.refresh()
        XCTAssertEqual(refreshes, 1)
    }

    func testWorkspaceRemovalUndoRestoresConfigWithoutDeletingFiles() throws {
        let file = directory.appendingPathComponent("keep.md")
        try "retain".write(to: file, atomically: true, encoding: .utf8)
        let base = NVModernConfigDraft(projects: [.init(name: "Notes", path: directory.path)])
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let model = NVModernSettingsModel(monitor: .init(configURL: configURL))
        let id = try XCTUnwrap(model.draft.defaultProjectID)
        model.removeWorkspace(id)
        XCTAssertTrue(model.draft.projects.isEmpty)
        XCTAssertNotNil(model.undoMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        model.undo()
        XCTAssertEqual(model.draft.projects.first?.name, "Notes")
        XCTAssertNil(model.undoMessage)
    }

    func testReloadKeepsNonFirstDefaultWorkspaceAndUndoKeepsOtherEdits() throws {
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var base = NVModernConfigDraft(substitutions: [.init(from: ";a", to: "A"), .init(from: ";a", to: "B")],
                                      projects: [.init(name: "First", path: first.path), .init(name: "Second", path: second.path)])
        base.setDefaultProject(id: base.projects[1]._uiID)
        try NVModernConfigSchema.shared.saveDraft(base, configURL: configURL)
        let model = NVModernSettingsModel(monitor: .init(configURL: configURL))
        model.removeSubstitution(model.draft.substitutions[0]._uiID)
        var next = model.draft; next.users = ["Later edit"]
        XCTAssertTrue(model.updateDraft(next))
        model.reloadFromDisk()
        XCTAssertEqual(model.draft.defaultProject?.path, second.path)
        model.undo()
        XCTAssertEqual(model.draft.substitutions.map(\.to), ["A", "B"])
        XCTAssertEqual(model.draft.users, ["Later edit"])
        XCTAssertEqual(try model.monitor.readDraft().root, second.path)
    }
}
