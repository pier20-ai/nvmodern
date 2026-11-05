import Foundation
import XCTest
@testable import nvModern

@MainActor
// Each test constructs its own host and registry; user plugins in the app's
// shared host must never influence these fixtures or the shared catalog tests.
final class PluginHostTests: XCTestCase {
    private var rootURL: URL!
    private var pluginsURL: URL!
    private var registry: ActionRegistry!
    private var executor: ActionExecutor!
    private var environment: StubEnvironment!
    private var host: PluginHost!

    func testXCTestAppHostDoesNotLoadPluginsOrTheirShortcuts() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertTrue(PluginHost.shared.loadedPluginNames.isEmpty)
        XCTAssertTrue(PluginHost.shared.loadErrors.isEmpty)
        XCTAssertTrue(PluginHost.shared.keybindings.isEmpty)
        XCTAssertTrue(PluginHost.shared.globalHotkeys.isEmpty)
        XCTAssertFalse(ActionRegistry.shared.allDescriptors().contains { $0.method.hasPrefix("plugin.") })
    }

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        rootURL = base.appendingPathComponent("notes", isDirectory: true)
        pluginsURL = base.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)

        registry = ActionRegistry()
        executor = ActionExecutor(registry: registry)
        environment = StubEnvironment()
        host = PluginHost(registry: registry, executor: executor)
        host.environment = environment
        let root = rootURL!
        host.projectsProvider = {
            ([PluginFileAccess.Project(name: "Notes", rootURL: root)], root)
        }
    }

    override func tearDown() async throws {
        host.unload()
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }

    func testRegisteredActionRunsAndReturnsItsValue() async throws {
        try load("""
        nv.actions.register({
          id: "sum",
          title: "Sum",
          run: ({ args }) => ({ total: args.a + args.b, plugin: nv.plugin.name }),
        });
        nv.actions.register({
          id: "later",
          title: "Later",
          run: async () => { await new Promise((done) => setTimeout(done, 5)); return "done"; },
        });
        """, as: "math")

        XCTAssertEqual(host.loadErrors, [])
        XCTAssertEqual(registry.descriptor(for: "plugin.math.sum")?.title, "Sum")

        let sum = try await executor.invoke(ActionRequest(method: "plugin.math.sum", args: ["a": 2, "b": 3]))
        XCTAssertEqual(sum, ["total": 5, "plugin": "math"])

        let later = try await executor.invoke(ActionRequest(method: "plugin.math.later"))
        XCTAssertEqual(later, "done")
    }

    func testSelectionFormattingExamplePreservesPrimitiveCallsAndEmptySelectionGuard() async throws {
        var calls: [[String: ActionValue]] = []
        var empty = false
        var replacement: String?
        func descriptor(_ method: String) -> ActionDescriptor {
            ActionDescriptor(method: method, title: method, summary: "Fixture", discussion: nil, domain: .workspace,
                             mutationKind: .mutating, targetRequirement: .none, capabilities: [], tags: [], arguments: [], result: nil)
        }
        registry.register(descriptor("markdown.selection.prefixLines")) { request, _ in
            calls.append(request.args)
            return .null
        }
        registry.register(descriptor("workspace.editor.selection.get")) { _, _ in
            ["text": "alpha\nbeta", "empty": .bool(empty)]
        }
        registry.register(descriptor("workspace.editor.selection.replace")) { request, _ in
            replacement = request.args["text"]?.stringValue
            return .null
        }
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NVModern/Plugins/examples/selection-formatting.js")
        host.reload(sources: [.init(url: example, isBuiltin: false)])
        XCTAssertEqual(host.loadErrors, [])
        for id in ["user-quote-selected", "important-callout-selected", "checklist-selected-lines"] {
            let method = "plugin.selection-formatting.\(id)"
            XCTAssertEqual(registry.descriptor(for: method)?.palette?.category, "Format")
            _ = try await executor.invoke(ActionRequest(method: method))
        }
        XCTAssertEqual(calls, [
            ["firstPrefix": "> [!user] ", "continuationPrefix": "> "],
            ["firstPrefix": "> [!important] ", "continuationPrefix": "> "],
            ["firstPrefix": "- [ ] ", "continuationPrefix": "- [ ] "]
        ])
        let reviewed = ActionRequest(method: "plugin.selection-formatting.mark-selected-reviewed")
        _ = try await executor.invoke(reviewed)
        XCTAssertTrue(replacement?.hasPrefix("**Reviewed ") == true)
        XCTAssertTrue(replacement?.hasSuffix(":** alpha\nbeta") == true)
        replacement = nil
        empty = true
        _ = try await executor.invoke(reviewed)
        XCTAssertNil(replacement)
    }

    func testSelectionReplacementFailureSurvivesNestedPluginInvocation() async throws {
        let descriptor = ActionDescriptor(
            method: "workspace.editor.selection.replace", title: "Replace selection", summary: "Fixture",
            discussion: nil, domain: .workspace, mutationKind: .mutating, targetRequirement: .none,
            capabilities: [], tags: [], arguments: [], result: nil
        )
        registry.register(descriptor) { _, _ in
            throw ActionError.unavailable("Could not replace the current editor selection")
        }
        try load("""
        nv.actions.register({
          id: "quote", title: "Quote",
          async run() { await nv.workspace.replaceSelection("> [!user] disposable text"); }
        });
        """, as: "selection-failure")

        let response = await executor.execute(ActionRequest(method: "plugin.selection-failure.quote"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertTrue(response.error?.message.contains("Could not replace the current editor selection") == true)
    }

    func testPalettePresentationAndShortcutsAreCollected() throws {
        try load("""
        nv.actions.register({
          id: "daily",
          title: "Daily note",
          palette: { category: "Capture", icon: "calendar", key: "n", keywords: ["org"] },
          globalHotkey: "cmd+ctrl+opt+shift+n",
          keybinding: "cmd+shift+d",
          run() {},
        });
        """, as: "org")

        let palette = try XCTUnwrap(registry.descriptor(for: "plugin.org.daily")?.palette)
        XCTAssertEqual(palette.category, "Capture")
        XCTAssertEqual(palette.iconSystemName, "calendar")
        XCTAssertEqual(palette.keywords, ["n", "org"])
        XCTAssertEqual(host.globalHotkeys, [.init(keystroke: "cmd+ctrl+opt+shift+n", method: "plugin.org.daily")])
        XCTAssertEqual(host.keybindings.map(\.keystroke), ["cmd+shift+d"])
        XCTAssertEqual(host.keybindings.first?.invocation.methodName, "plugin.org.daily")
    }

    func testDeclaredSettingsMergeDefaultsValidateOverridesAndRetainUnknownKeys() async throws {
        let file = pluginsURL.appendingPathComponent("settings.js")
        try """
        nv.settings.define([
          { key: "title", title: "Title", kind: "text", default: "Daily" },
          { key: "open", title: "Open", kind: "bool", default: false },
          { key: "count", title: "Count", kind: "number", default: 1 },
          { key: "zero", title: "Zero", kind: "number", default: 0 },
          { key: "style", title: "Style", kind: "choice", options: ["org", "iso"], default: "org" },
          { key: "folder", title: "Folder", kind: "folder", default: "Daily" }
        ]);
        nv.actions.register({ id: "read", title: "Read", run: () => nv.settings.get() });
        nv.actions.register({ id: "late", title: "Late", run: () => nv.settings.define([]) });
        """.write(to: file, atomically: true, encoding: .utf8)
        let configuration = NVModernPluginsDraft(settings: ["settings": [
            "title": "Inbox", "open": true, "count": "wrong type", "style": "unknown", "folder": "../escape", "future": 7
        ]])
        host.reload(sources: [.init(url: file, isBuiltin: false)], configuration: configuration)
        XCTAssertEqual(host.loadErrors, [])
        XCTAssertEqual(host.pluginInfos.first?.settingsSchema.map(\.kind), [.text, .bool, .number, .number, .choice, .folder])
        let values = try await executor.invoke(ActionRequest(method: "plugin.settings.read"))
        XCTAssertEqual(values, ["title": "Inbox", "open": true, "count": 1, "zero": 0, "style": "org", "folder": "Daily", "future": 7])
        do {
            _ = try await executor.invoke(ActionRequest(method: "plugin.settings.late"))
            XCTFail("Defining settings after load must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("during plugin load")) }
    }

    func testDisabledUserOverrideDoesNotExecuteOrActivateBuiltinAndReenablesCleanly() throws {
        let builtin = rootURL.appendingPathComponent("capture.js")
        let user = pluginsURL.appendingPathComponent("capture.js")
        try "throw new Error('builtin must not run');".write(to: builtin, atomically: true, encoding: .utf8)
        try """
        nv.settings.define([{key:"folder", title:"Folder", kind:"folder", default:"Daily"}]);
        nv.actions.register({id:"capture", title:"Capture", globalHotkey:"cmd+ctrl+opt+shift+n", keybinding:"cmd+shift+d", run(){}});
        """.write(to: user, atomically: true, encoding: .utf8)
        let sources: [PluginHost.Source] = [.init(url: builtin, isBuiltin: true), .init(url: user, isBuiltin: false)]
        host.reload(sources: sources, configuration: .init(disabled: ["capture"]))
        XCTAssertEqual(host.pluginInfos.count, 1)
        XCTAssertEqual(host.pluginInfos.first?.state, .disabled)
        XCTAssertEqual(host.pluginInfos.first?.path, user.path)
        XCTAssertTrue(host.pluginInfos.first?.settingsSchema.isEmpty == true)
        XCTAssertTrue(host.loadErrors.isEmpty)
        XCTAssertTrue(host.globalHotkeys.isEmpty)
        XCTAssertTrue(host.keybindings.isEmpty)
        XCTAssertNil(registry.descriptor(for: "plugin.capture.capture"))
        host.reload(sources: sources)
        XCTAssertEqual(host.pluginInfos.first?.state, .running)
        XCTAssertNotNil(registry.descriptor(for: "plugin.capture.capture"))
        XCTAssertEqual(host.globalHotkeys.count, 1)
        XCTAssertEqual(host.keybindings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.path))
    }

    func testInvalidSettingsSchemasFailWithStructuredInventoryAndNoPartialActions() throws {
        for fields in [
            "[{key:'x',title:'X',kind:'bool',default:'yes'}]",
            "[{key:'x',title:'X',kind:'choice',options:['a','a'],default:'a'}]",
            "[{key:'x',title:'X',kind:'folder',default:'/absolute'}]",
            "[{key:'x',title:'X',kind:'text',default:''},{key:'x',title:'Again',kind:'text',default:''}]"
        ] {
            try load("nv.actions.register({id:'partial', title:'Partial', run(){}}); nv.settings.define(\(fields));", as: "invalid")
            XCTAssertEqual(host.pluginInfos.first?.state, .failed)
            XCTAssertNotNil(host.pluginInfos.first?.loadError)
            XCTAssertTrue(host.pluginInfos.first?.settingsSchema.isEmpty == true)
            XCTAssertNil(registry.descriptor(for: "plugin.invalid.partial"))
        }
    }

    func testCapturePresetIsAStandaloneFrameOverTheCaptureCategory() {
        let frames = PalettePresetResolver.frames(for: .capture)
        XCTAssertEqual(frames.map(\.id), [PaletteFrameSpec.capture.id])
        XCTAssertEqual(frames.last?.sources, [.actions(category: "Capture")])
    }

    func testUIPickersConfirmAndNotifyCrossTheBridge() async throws {
        try load("""
        nv.actions.register({
          id: "ask",
          title: "Ask",
          async run() {
            const choice = await nv.ui.pick(
              [{ title: "Alpha", value: { n: 1 } }, { title: "Beta", subtitle: "second", key: "b", value: { n: 2 } }],
              { placeholder: "Which?" }
            );
            const name = await nv.ui.prompt({ placeholder: "Name", initialText: "draft" });
            const note = await nv.ui.pickNote();
            const folder = await nv.ui.pickFolder({ placeholder: "Where?" });
            const sure = await nv.ui.confirm("Really?", { detail: "No undo", destructive: true });
            await nv.ui.notify("Done", { title: "Ask" });
            return { choice, name, note, folder, sure };
          },
        });
        """, as: "ui")

        environment.pickReplies = [["n": 2], "typed", "Inbox/a.md", nil]
        let result = try await executor.invoke(ActionRequest(method: "plugin.ui.ask"))

        XCTAssertEqual(result, [
            "choice": ["n": 2], "name": "typed", "note": "Inbox/a.md", "folder": nil, "sure": true,
        ])
        XCTAssertEqual(environment.pickRequests.map(\.kind), [.items, .text, .note, .folder])
        XCTAssertEqual(environment.pickRequests[0].placeholder, "Which?")
        XCTAssertEqual(environment.pickRequests[0].items.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(environment.pickRequests[0].items[1].keywords, ["b"])
        XCTAssertEqual(environment.pickRequests[1].initialText, "draft")
        XCTAssertEqual(environment.notifications, ["Ask: Done"])
    }

    func testPickCenterRanksRowsAndAnswersExactlyOnce() async {
        let center = PluginPickCenter()
        let request = PluginPickRequest(kind: .items, items: [
            PluginPickItem(title: "Alpha", subtitle: nil, iconSystemName: nil, keywords: [], value: 1),
            PluginPickItem(title: "Beta", subtitle: nil, iconSystemName: nil, keywords: ["zz"], value: 2),
        ])

        let chosen = await center.choose(request) { pick in
            center.markPresented(pick.requestID)
            XCTAssertEqual(center.sections(for: pick, query: "").first?.items.map(\.title), ["Alpha", "Beta"])
            let ranked = center.sections(for: pick, query: "zz").first?.items ?? []
            XCTAssertEqual(ranked.first?.title, "Beta")
            guard case .pluginPick(let requestID, let value)? = ranked.first?.activation else {
                return XCTFail("Expected a plugin pick activation")
            }
            center.resolve(requestID, with: value)
            center.cancel(requestID)
        }
        XCTAssertEqual(chosen, 2)

        let dismissed = await center.choose(PluginPickRequest(kind: .text)) { pick in
            XCTAssertEqual(center.sections(for: pick, query: "").count, 0)
            XCTAssertEqual(center.sections(for: pick, query: "hi").first?.items.first?.title, "Use \u{201C}hi\u{201D}")
            center.cancel(pick.requestID)
        }
        XCTAssertNil(dismissed)
    }

    func testFilesReadWriteEditAndAppend() async throws {
        try load("""
        nv.actions.register({
          id: "files",
          title: "Files",
          async run() {
            const before = await nv.files.read("Inbox/a.md");
            await nv.files.write("Inbox/a.md", "one\\n");
            await nv.files.append({ project: "notes", path: "Inbox/a.md" }, "two\\n");
            const changed = await nv.files.edit("Inbox/a.md", (text) => text.toUpperCase());
            const unchanged = await nv.files.edit("Inbox/a.md", (text) => text);
            return {
              before,
              changed,
              unchanged,
              exists: await nv.files.exists("Inbox/a.md"),
              text: await nv.files.read("Inbox/a.md"),
              path: nv.files.resolve("Inbox/a.md"),
            };
          },
        });
        """, as: "io")

        let result = try await executor.invoke(ActionRequest(method: "plugin.io.files"))
        let fileURL = rootURL.appendingPathComponent("Inbox/a.md").standardizedFileURL
        XCTAssertEqual(result, [
            "before": nil,
            "changed": true,
            "unchanged": false,
            "exists": true,
            "text": "ONE\nTWO\n",
            "path": .string(fileURL.path),
        ])
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "ONE\nTWO\n")
    }

    func testRelativePathCannotLeaveTheProject() async throws {
        try load("""
        nv.actions.register({ id: "escape", title: "Escape", run: () => nv.files.read("../outside.md") });
        """, as: "io")

        do {
            _ = try await executor.invoke(ActionRequest(method: "plugin.io.escape"))
            XCTFail("Expected the action to fail")
        } catch let error as ActionError {
            XCTAssertEqual(error.code, .invalidArguments)
        }
    }

    func testDateFormatUsesStablePatterns() async throws {
        try load("""
        nv.actions.register({
          id: "stamp",
          title: "Stamp",
          run: () => nv.date.format("[yyyy-MM-dd EEE HH:mm]", new Date(2026, 9, 3, 14, 22)),
        });
        """, as: "dates")

        let stamp = try await executor.invoke(ActionRequest(method: "plugin.dates.stamp"))
        XCTAssertEqual(stamp, "[2026-10-03 Sat 14:22]")
    }

    func testThrownErrorFailsTheActionAndLoadErrorsAreReported() async throws {
        try load("""
        nv.actions.register({ id: "boom", title: "Boom", run() { throw new Error("nope"); } });
        nv.actions.register({ id: "reject", title: "Reject", run: async () => { throw new Error("later"); } });
        """, as: "errors")
        try write("nv.actions.register({ id: 'ok', title: 'OK', run() {} });\nthis is not javascript", as: "broken")
        reload()

        XCTAssertEqual(host.loadedPluginNames, ["errors"])
        XCTAssertEqual(host.loadErrors.count, 1)
        XCTAssertTrue(host.loadErrors[0].hasPrefix("broken.js:"), host.loadErrors[0])
        XCTAssertNil(registry.descriptor(for: "plugin.broken.ok"))

        for (method, message) in [("plugin.errors.boom", "nope"), ("plugin.errors.reject", "later")] {
            do {
                _ = try await executor.invoke(ActionRequest(method: method))
                XCTFail("Expected \(method) to fail")
            } catch let error as ActionError {
                XCTAssertEqual(error.code, .executionFailed)
                XCTAssertTrue(error.message.contains(message), error.message)
            }
        }
    }

    func testReloadDropsRemovedActionsAndUserPluginReplacesBuiltin() throws {
        let builtinURL = pluginsURL.appendingPathComponent("builtin", isDirectory: true)
        try FileManager.default.createDirectory(at: builtinURL, withIntermediateDirectories: true)
        try "nv.actions.register({ id: 'a', title: 'Builtin A', run() {} });"
            .write(to: builtinURL.appendingPathComponent("capture.js"), atomically: true, encoding: .utf8)
        try write("nv.actions.register({ id: 'a', title: 'User A', run() {} });", as: "capture")

        host.reload(
            sources: PluginHost.sources(inDirectory: builtinURL, isBuiltin: true)
                + PluginHost.sources(inDirectory: pluginsURL, isBuiltin: false)
        )
        XCTAssertEqual(host.loadErrors, [])
        XCTAssertEqual(registry.descriptor(for: "plugin.capture.a")?.title, "User A")

        try FileManager.default.removeItem(at: pluginsURL.appendingPathComponent("capture.js"))
        host.reload(sources: PluginHost.sources(inDirectory: builtinURL, isBuiltin: true))
        XCTAssertEqual(registry.descriptor(for: "plugin.capture.a")?.title, "Builtin A")

        host.reload(sources: [])
        XCTAssertNil(registry.descriptor(for: "plugin.capture.a"))
    }

    func testInvokeReachesOtherActionsAndSurfacesTheirErrors() async throws {
        try load("""
        nv.actions.register({ id: "inner", title: "Inner", run: ({ args }) => args.value * 2 });
        nv.actions.register({
          id: "outer",
          title: "Outer",
          async run() {
            const doubled = await nv.actions.invoke("plugin.chain.inner", { value: 21 });
            try {
              await nv.actions.invoke("no.such.method");
            } catch (error) {
              return { doubled, code: error.code };
            }
          },
        });
        """, as: "chain")

        let result = try await executor.invoke(ActionRequest(method: "plugin.chain.outer"))
        XCTAssertEqual(result, ["doubled": 42, "code": "unknown_method"])
    }

    /// The shipped example is the acceptance test for the API: `Cmd+N` `n`,
    /// type a note, and it lands in the org datetree.
    func testOrgCaptureExampleFilesIntoTheDatetree() async throws {
        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NVModern/Plugins/examples/org-capture.js")
        let root = rootURL!
        host.projectsProvider = {
            ([PluginFileAccess.Project(name: "Personal Notes", rootURL: root)], root)
        }
        host.reload(sources: [PluginHost.Source(url: exampleURL, isBuiltin: false)])
        XCTAssertEqual(host.loadErrors, [])

        environment.inputReplies = ["first thought", "second thought", nil]
        for _ in 0..<3 {
            _ = try await executor.invoke(ActionRequest(method: "plugin.org-capture.daily"))
        }

        XCTAssertEqual(environment.inputRequests.first?.placeholder, "Daily note…")
        XCTAssertEqual(environment.inputRequests.first?.submitKey, .plainReturn)

        let body = try String(contentsOf: rootURL.appendingPathComponent("org/general/daily.org"), encoding: .utf8)
        let lines = body.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, body)
        XCTAssertTrue(lines[0].hasPrefix("* 2"), body)
        XCTAssertTrue(lines[1].hasPrefix("** "), body)
        XCTAssertTrue(lines[2].hasPrefix("*** "), body)
        XCTAssertTrue(lines[3].hasPrefix("**** [") && lines[3].hasSuffix("] first thought"), body)
        XCTAssertTrue(lines[4].hasPrefix("**** [") && lines[4].hasSuffix("] second thought"), body)
    }

    func testWindowOptionsCrossBridgeAndInvocationCompletesOnOpen() async throws {
        try load("""
        nv.actions.register({ id: "open", title: "Open", async run() {
          await nv.ui.window({ project: "Notes", path: "scratch.md" }, {
            toggle: true, alwaysOnTop: true, allSpaces: true, position: { x: 12, y: 24 }, size: { width: 480, height: 300 }, cursor: "start"
          });
          return "opened";
        }});
        """, as: "window")
        let result = try await executor.invoke(ActionRequest(method: "plugin.window.open"))
        XCTAssertEqual(result, "opened")
        let request = try XCTUnwrap(environment.windowRequests.first)
        XCTAssertEqual(request.fileURL, rootURL.appendingPathComponent("scratch.md"))
        XCTAssertTrue(request.toggle)
        XCTAssertEqual(request.position, .coordinates(x: 12, y: 24))
        XCTAssertTrue(request.alwaysOnTop)
        XCTAssertTrue(request.allSpaces)
        XCTAssertEqual(request.width, 480)
        XCTAssertEqual(request.height, 300)
        XCTAssertEqual(request.cursor, .start)
    }

    func testWindowOpeningErrorsRejectPluginPromise() async throws {
        try load("""
        nv.actions.register({ id: "open", title: "Open", run: () => nv.ui.window("scratch.md") });
        """, as: "window")
        environment.windowError = CocoaError(.fileReadNoPermission)
        do {
            _ = try await executor.invoke(ActionRequest(method: "plugin.window.open"))
            XCTFail("An unreadable file must reject")
        } catch {}
        XCTAssertEqual(environment.windowRequests.count, 1)
    }

    func testInvalidWindowSizeRejectsBeforePresentation() async throws {
        try load("""
        nv.actions.register({ id: "open", title: "Open", run: () => nv.ui.window("scratch.md", { size: { width: -1, height: 300 } }) });
        """, as: "window")
        do {
            _ = try await executor.invoke(ActionRequest(method: "plugin.window.open"))
            XCTFail("Invalid size must reject")
        } catch {}
        XCTAssertTrue(environment.windowRequests.isEmpty)
    }

    // MARK: Helpers

    private func write(_ script: String, as name: String) throws {
        try script.write(to: pluginsURL.appendingPathComponent("\(name).js"), atomically: true, encoding: .utf8)
    }

    private func reload() {
        host.reload(sources: PluginHost.sources(inDirectory: pluginsURL, isBuiltin: false))
    }

    private func load(_ script: String, as name: String) throws {
        try write(script, as: name)
        reload()
    }
}

@MainActor
private final class StubEnvironment: PluginHostEnvironment {
    var activeProjectRootPath: String?
    var inputReplies: [String?] = []
    var inputRequests: [PluginInputRequest] = []
    var clipboard: String?

    func input(_ request: PluginInputRequest) async -> String? {
        inputRequests.append(request)
        return inputReplies.isEmpty ? nil : inputReplies.removeFirst()
    }

    func panel(_ request: PluginPanelRequest) async {}
    var windowRequests: [PluginWindowRequest] = []
    var windowError: Error?
    func window(_ request: PluginWindowRequest) async throws {
        windowRequests.append(request)
        if let windowError { throw windowError }
    }

    var pickRequests: [PluginPickRequest] = []
    var pickReplies: [ActionValue?] = []
    var confirmReply = true
    var notifications: [String] = []

    func pick(_ request: PluginPickRequest) async throws -> ActionValue? {
        pickRequests.append(request)
        return pickReplies.isEmpty ? nil : pickReplies.removeFirst()
    }

    func confirm(_ request: PluginConfirmRequest) async -> Bool { confirmReply }

    func notify(title: String?, message: String) async throws {
        notifications.append("\(title ?? "-"): \(message)")
    }

    func open(fileURL: URL, inNewTab: Bool) -> Bool { true }

    func readClipboard() -> String? { clipboard }

    func writeClipboard(_ text: String) { clipboard = text }

    func dismissPluginSurfaces() {}
}
