import XCTest
@testable import nvModern

final class ArborKernelProtocolTests: XCTestCase {
    func testWebBridgePreservesJSONNumberAndBooleanIdentity() throws {
        let value = WebEditorBridge.jsonSafeValue([
            "generation": NSNumber(value: 1),
            "ok": NSNumber(value: true)
        ])
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"generation":1,"ok":true}"#)
    }

    func testRequestEncodesVersionedJSONLineShape() throws {
        let request = ArborKernelRequest(
            id: "request-7",
            document: ArborKernelDocument(
                path: "Demo.outline",
                revision: 7,
                source: "#lang arbor/0\n- = (+ 40 2) ^answer\n"
            ),
            previousDerivedUIDs: ["old"]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "arbor-kernel/1")
        XCTAssertEqual(object["op"] as? String, "evaluate")
        XCTAssertEqual(object["id"] as? String, "request-7")
        XCTAssertEqual(object["previousDerivedUIDs"] as? [String], ["old"])
    }

    func testResponseDecodesDerivedPatchAndDiagnostics() throws {
        let json = #"{"protocol":"arbor-kernel/1","id":"request-7","ok":true,"revision":7,"document":{"path":"Demo.outline"},"blocks":[{"uid":"answer","depth":0,"body":"= (+ 40 2)","line":2,"parentUID":null}],"patches":[{"op":"set-derived","uid":"answer","revision":7,"value":42,"display":"42"}],"queries":[],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.blocks.first?.uid, "answer")
        XCTAssertEqual(response.patches.first?.operation, "set-derived")
        XCTAssertEqual(response.patches.first?.value, .number(42))
        XCTAssertEqual(response.patches.first?.display, "42")
    }

    func testDocumentReplaceEncodesOnlyReplacementFields() throws {
        let request = ArborKernelRequest.replaceDocument(
            id: "replace-7",
            document: ArborKernelDocument(
                id: "demo",
                path: "Demo.outline",
                revision: 7,
                source: "#lang arbor/0\n- Plain ^plain\n"
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let document = try XCTUnwrap(object["document"] as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "document/replace")
        XCTAssertEqual(document["id"] as? String, "demo")
        XCTAssertEqual(document["revision"] as? Int, 7)
        XCTAssertNil(object["previousDerivedUIDs"])
        XCTAssertNil(object["documentID"])
    }

    func testQueryRunEncodesEngineNeutralRequestAndDecodesRows() throws {
        let request = ArborKernelRequest.runQuery(
            id: "query-7",
            documentID: "demo",
            revision: 7,
            queryID: "projects",
            arguments: ["tag": .string("project")]
        )

        let requestData = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "query/run")
        XCTAssertEqual(object["documentID"] as? String, "demo")
        XCTAssertEqual(object["revision"] as? Int, 7)
        XCTAssertEqual(object["queryID"] as? String, "projects")
        XCTAssertNil(object["document"])

        let json = #"{"protocol":"arbor-kernel/1","id":"query-7","op":"query/run","ok":true,"revision":7,"worldRevision":3,"queryID":"projects","columns":["block"],"rows":[["tagged"]],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.operation, "query/run")
        XCTAssertEqual(response.worldRevision, 3)
        XCTAssertEqual(response.columns, ["block"])
        XCTAssertEqual(response.rows, [[.string("tagged")]])
        XCTAssertTrue(response.blocks.isEmpty)
        XCTAssertTrue(response.patches.isEmpty)
    }

    func testViewGetEncodesOptionalQueryAndDecodesKernelShapedRows() throws {
        let request = ArborKernelRequest.getView(
            id: "view-7",
            documentID: "demo",
            revision: 7,
            queryID: "projects",
            arguments: ["tag": .string("project")]
        )

        let requestData = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "view/get")
        XCTAssertEqual(object["documentID"] as? String, "demo")
        XCTAssertEqual(object["queryID"] as? String, "projects")
        XCTAssertNil(object["document"])

        let json = #"{"protocol":"arbor-kernel/1","id":"view-7","op":"view/get","ok":true,"revision":7,"worldRevision":3,"views":[{"id":"query:projects","producerID":"projects","kind":"query","presentation":"outline","status":"ok","inputs":["tag"],"columns":["block"],"rows":[{"id":"query:projects:row","cells":[{"kind":"block","value":"tagged","display":"Tagged #project","blockID":"tagged","documentID":"demo","path":"Demo.outline","markdown":"Tagged #project"}]}],"diagnostics":[]}],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))
        let view = try XCTUnwrap(response.views.first)
        XCTAssertEqual(view.producerID, "projects")
        XCTAssertEqual(view.presentation, "outline")
        XCTAssertEqual(view.rows.first?.cells.first?.blockID, "tagged")
        XCTAssertEqual(view.rows.first?.cells.first?.markdown, "Tagged #project")
    }

    func testProducerRunEncodesExplicitModeAndDecodesMaterializedBlocks() throws {
        let request = ArborKernelRequest.runProducer(
            id: "producer-7",
            documentID: "demo",
            revision: 7,
            producerID: "answer",
            mode: "append"
        )

        let requestData = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "producer/run")
        XCTAssertEqual(object["documentID"] as? String, "demo")
        XCTAssertEqual(object["producerID"] as? String, "answer")
        XCTAssertEqual(object["mode"] as? String, "append")
        XCTAssertNil(object["document"])

        let hash = String(repeating: "a", count: 40)
        let json = #"{"protocol":"arbor-kernel/1","id":"producer-7","op":"producer/run","ok":true,"revision":7,"worldRevision":3,"producerID":"answer","kind":"expression","mode":"append","generation":2,"inputHash":"\#(hash)","results":[{"key":"scalar","markdown":"42"}],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.operation, "producer/run")
        XCTAssertEqual(response.producerID, "answer")
        XCTAssertEqual(response.mode, "append")
        XCTAssertEqual(response.generation, 2)
        XCTAssertEqual(response.inputHash, hash)
        XCTAssertEqual(response.results, [ArborKernelProducerResult(key: "scalar", markdown: "42")])
    }

    func testIntentAndEffectRequestsKeepExecutionBehindTheNativeHost() throws {
        let intent = ArborKernelRequest.applyIntent(
            id: "intent-7",
            documentID: "demo",
            revision: 7,
            resultID: "result",
            intent: ArborKernelIntent(op: "set-text", text: "Renamed")
        )
        let intentData = try JSONEncoder().encode(intent)
        let intentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: intentData) as? [String: Any])
        XCTAssertEqual(intentObject["op"] as? String, "intent/apply")
        XCTAssertEqual(intentObject["resultID"] as? String, "result")
        XCTAssertEqual((intentObject["intent"] as? [String: Any])?["text"] as? String, "Renamed")

        let outcome = ArborKernelEffectOutcome(ok: true, value: .string("done"), message: nil)
        let completion = ArborKernelRequest.completeEffect(
            id: "complete-7",
            executionID: "effect-7",
            outcome: outcome
        )
        let completionData = try JSONEncoder().encode(completion)
        let completionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completionData) as? [String: Any]
        )
        XCTAssertEqual(completionObject["op"] as? String, "effect/complete")
        XCTAssertEqual(completionObject["executionID"] as? String, "effect-7")
        XCTAssertEqual((completionObject["outcome"] as? [String: Any])?["value"] as? String, "done")

        let mutation = ArborKernelRequest.completeMutation(
            id: "mutation-complete-7",
            executionID: "mutation-7",
            outcome: ArborKernelEffectOutcome(ok: true, value: nil, message: nil)
        )
        let mutationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as? [String: Any]
        )
        XCTAssertEqual(mutationObject["op"] as? String, "mutation/complete")
        XCTAssertEqual(mutationObject["executionID"] as? String, "mutation-7")
    }

    func testEffectRequestAndSourceOriginDecodeWithoutRendererSpecificTypes() throws {
        let json = #"{"protocol":"arbor-kernel/1","id":"effect-7","op":"producer/run","ok":true,"status":"effect-request","revision":7,"worldRevision":3,"producerID":"effect","kind":"effect","mode":"refresh","effect":{"executionID":"effect-7","handler":"fs/read","arguments":["Notes.md"],"capability":{"id":"grant","kind":"filesystem.read","resource":"Notes.md","summary":"Read Notes.md"},"limits":{"timeoutMs":3000,"maxOutputBytes":1048576}},"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "effect-request")
        XCTAssertEqual(response.effect?.handler, "fs/read")
        XCTAssertEqual(response.effect?.capability?.kind, "filesystem.read")

        let resultJSON = #"{"protocol":"arbor-kernel/1","id":"producer-7","op":"producer/run","ok":true,"revision":7,"producerID":"query","kind":"query","mode":"refresh","generation":1,"inputHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","results":[{"key":"row","markdown":"Alpha","origin":{"blockID":"alpha","documentID":"demo","path":"Demo.outline"},"updatePolicy":"source-text"}],"diagnostics":[]}"#
        let result = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(resultJSON.utf8))
        XCTAssertEqual(result.results.first?.origin?.blockID, "alpha")
        XCTAssertEqual(result.results.first?.updatePolicy, "source-text")
    }

    func testMutationRequestDecodesTrustedCandidateAndPreview() throws {
        let json = ##"{"protocol":"arbor-kernel/1","id":"mutation-7","op":"producer/run","ok":true,"status":"mutation-request","revision":7,"worldRevision":3,"producerID":"change","kind":"mutation","mode":"refresh","mutation":{"executionID":"mutation-7","summary":["Set text on alpha"],"operationCount":1,"destructive":true,"capability":{"id":"grant","kind":"outline.write","resource":"Demo.outline","summary":"Apply 1 outline change to Demo.outline"},"expectedSource":"#lang arbor/0\n- Alpha ^alpha\n","document":{"id":"demo","path":"Demo.outline","revision":8,"source":"#lang arbor/0\n- Beta ^alpha\n"}},"diagnostics":[]}"##
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.status, "mutation-request")
        XCTAssertEqual(response.mutation?.operationCount, 1)
        XCTAssertEqual(response.mutation?.destructive, true)
        XCTAssertEqual(response.mutation?.document.revision, 8)
        XCTAssertEqual(response.mutation?.summary, ["Set text on alpha"])
    }

    func testEffectBrokerRunsClockFileAndProcessHandlersWithinBounds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-arbor-effect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let limits = ArborKernelEffectLimits(timeoutMs: 5_000, maxOutputBytes: 1_048_576)

        let clock = ArborKernelEffect(
            executionID: "clock",
            handler: "clock/now",
            arguments: [],
            capability: nil,
            limits: limits
        )
        let clockOutput = try await ArborEffectBroker.execute(clock, workspaceRoot: root)
        guard case .string(let clockText) = clockOutput else { return XCTFail("Expected clock text") }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: clockText))

        let read = ArborKernelEffect(
            executionID: "read",
            handler: "fs/read",
            arguments: [.string("Note.md")],
            capability: nil,
            limits: limits
        )
        let readOutput = try await ArborEffectBroker.execute(read, workspaceRoot: root)
        XCTAssertEqual(readOutput, .string("hello"))

        let process = ArborKernelEffect(
            executionID: "process",
            handler: "process/run",
            arguments: [.string("printf"), .string("hello")],
            capability: nil,
            limits: limits
        )
        let processOutput = try await ArborEffectBroker.execute(process, workspaceRoot: root)
        XCTAssertEqual(processOutput, .string("hello"))

        let write = ArborKernelEffect(
            executionID: "write",
            handler: "fs/write",
            arguments: [.string("Output.txt"), .string("a")],
            capability: nil,
            limits: limits
        )
        let writeOutput = try await ArborEffectBroker.execute(write, workspaceRoot: root)
        XCTAssertEqual(
            writeOutput,
            .object(["path": .string("Output.txt"), "bytes": .number(1)])
        )
        let append = ArborKernelEffect(
            executionID: "append",
            handler: "fs/append",
            arguments: [.string("Output.txt"), .string("b")],
            capability: nil,
            limits: limits
        )
        _ = try await ArborEffectBroker.execute(append, workspaceRoot: root)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Output.txt"), encoding: .utf8),
            "ab"
        )

        let list = ArborKernelEffect(
            executionID: "list",
            handler: "fs/list",
            arguments: [],
            capability: nil,
            limits: limits
        )
        guard case .array(let entries) = try await ArborEffectBroker.execute(list, workspaceRoot: root)
        else { return XCTFail("Expected a directory listing") }
        XCTAssertTrue(entries.contains(.object(["name": .string("Note.md"), "kind": .string("file")])))

        let glob = ArborKernelEffect(
            executionID: "glob",
            handler: "fs/glob",
            arguments: [.string("."), .string("*.md")],
            capability: nil,
            limits: limits
        )
        let globOutput = try await ArborEffectBroker.execute(glob, workspaceRoot: root)
        XCTAssertEqual(
            globOutput,
            .array([.object(["name": .string("Note.md"), "kind": .string("file")])])
        )

        let model = ArborKernelEffect(
            executionID: "model",
            handler: "model/complete",
            arguments: [.string("Summarize this")],
            capability: nil,
            limits: limits
        )
        let modelOutput = try await ArborEffectBroker.execute(
            model,
            workspaceRoot: root,
            environment: ["NVMODERN_ARBOR_MODEL_COMMAND": "/bin/cat"]
        )
        XCTAssertEqual(
            modelOutput,
            .string("Summarize this")
        )

        let action = ArborKernelEffect(
            executionID: "action",
            handler: "action/run",
            arguments: [.string("app.health.ping")],
            capability: nil,
            limits: limits
        )
        guard case .object(let actionResult) = try await ArborEffectBroker.execute(
            action,
            workspaceRoot: root
        ) else { return XCTFail("Expected an action result") }
        XCTAssertEqual(actionResult["app"], .string("nvModern"))
        XCTAssertEqual(actionResult["method"], .string("app.health.ping"))
    }

    func testDocumentReplaceResponseDefaultsEvaluateOnlyCollections() throws {
        let json = #"{"protocol":"arbor-kernel/1","id":"replace-7","op":"document/replace","ok":true,"outcome":"replaced","revision":7,"worldRevision":2,"document":{"id":"demo","path":"Demo.outline"},"factCount":4,"queryIDs":["projects"],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.document?.id, "demo")
        XCTAssertEqual(response.factCount, 4)
        XCTAssertEqual(response.queryIDs, ["projects"])
        XCTAssertTrue(response.blocks.isEmpty)
        XCTAssertTrue(response.patches.isEmpty)
        XCTAssertTrue(response.rows.isEmpty)
    }

    func testRevisionMismatchDecodesAcceptedRevision() throws {
        let json = #"{"protocol":"arbor-kernel/1","id":"producer-stale","op":"producer/run","ok":false,"revision":7,"acceptedRevision":9,"worldRevision":3,"diagnostics":[{"severity":"error","code":"ARBOR3302","message":"stale"}]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.revision, 7)
        XCTAssertEqual(response.acceptedRevision, 9)
    }

    func testCompletionResponseDecodesDocumentIDAsAString() throws {
        let json = #"{"protocol":"arbor-kernel/1","id":"complete-7","op":"mutation/complete","ok":true,"revision":8,"documentID":"demo","producerID":"change","kind":"mutation","mode":"refresh","generation":1,"inputHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","results":[],"diagnostics":[]}"#
        let response = try JSONDecoder().decode(ArborKernelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.operation, "mutation/complete")
        XCTAssertEqual(response.documentID, "demo")
    }

    func testMissingRacketReturnsDiagnosticInsteadOfThrowing() async throws {
        let callbackQueue = DispatchQueue(label: "ArborKernelProtocolTests.callback")
        let supervisor = ArborKernelSupervisor(
            configuration: ArborKernelConfiguration(
                executableURL: nil,
                scriptURL: URL(fileURLWithPath: "/missing/arbor-kernel.rkt"),
                environment: [:],
                requestTimeout: 0.05,
                callbackQueue: callbackQueue
            )
        )

        let response = await supervisor.evaluate(
            document: ArborKernelDocument(
                path: "Demo.outline",
                revision: 3,
                source: "#lang arbor/0\n- Plain ^plain\n"
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.revision, 3)
        XCTAssertEqual(response.diagnostics.first?.code, "ARBOR9001")
        XCTAssertTrue(response.patches.isEmpty)
    }

    func testLocatorHonorsExplicitExecutableOverride() throws {
        let executableURL = try XCTUnwrap(
            ArborKernelLocator.racketExecutableURL(
                environment: ["NVMODERN_RACKET_PATH": "/bin/sh", "PATH": ""],
                fileManager: .default
            )
        )
        XCTAssertEqual(executableURL.path, "/bin/sh")
    }

    func testLocatorAcceptsAnInstallationDirectoryOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-racket-\(UUID().uuidString)", isDirectory: true)
        let executable = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("racket")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let located = try XCTUnwrap(
            ArborKernelLocator.racketExecutableURL(
                environment: ["NVMODERN_RACKET_PATH": root.path, "PATH": ""],
                fileManager: .default,
                applicationDirectories: []
            )
        )
        XCTAssertEqual(
            located.resolvingSymlinksInPath().path,
            executable.resolvingSymlinksInPath().path
        )
    }

    func testLocatorFindsAnyVersionedRacketApplicationDirectory() throws {
        let applications = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-applications-\(UUID().uuidString)", isDirectory: true)
        let executable = applications
            .appendingPathComponent("Racket v8.99", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("racket")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: applications) }

        let located = try XCTUnwrap(
            ArborKernelLocator.racketExecutableURL(
                environment: ["PATH": ""],
                fileManager: .default,
                applicationDirectories: [applications]
            )
        )
        XCTAssertEqual(
            located.resolvingSymlinksInPath().path,
            executable.resolvingSymlinksInPath().path
        )
    }

    func testBundledKernelScriptCanBeLocated() throws {
        let scriptURL = try XCTUnwrap(
            ArborKernelLocator.kernelScriptURL(bundle: .main, fileManager: .default)
        )
        XCTAssertEqual(scriptURL.lastPathComponent, "arbor-kernel.rkt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    func testInstalledRacketEvaluatesThroughNativeSupervisorWithoutShellPath() async throws {
        let configuration = ArborKernelConfiguration.bundled(
            environment: ["PATH": ""],
            fileManager: .default
        )
        guard configuration.executableURL != nil else {
            throw XCTSkip("Racket application bundle is not installed")
        }

        var integrationConfiguration = configuration
        integrationConfiguration.requestTimeout = 3
        integrationConfiguration.callbackQueue = DispatchQueue(
            label: "ArborKernelProtocolTests.integration-callback"
        )
        let supervisor = ArborKernelSupervisor(configuration: integrationConfiguration)
        defer { supervisor.shutdown() }

        let response = await supervisor.evaluate(
            document: ArborKernelDocument(
                path: "Live.outline",
                revision: 9,
                source: "#lang arbor/0\n- = (+ 40 2) ^answer\n"
            )
        )

        XCTAssertTrue(response.ok, response.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertEqual(response.revision, 9)
        XCTAssertEqual(response.patches.first?.display, "42")
    }

    func testInstalledRacketReplacesAndQueriesThroughOneSupervisor() async throws {
        let configuration = ArborKernelConfiguration.bundled(
            environment: ["PATH": ""],
            fileManager: .default
        )
        guard configuration.executableURL != nil else {
            throw XCTSkip("Racket application bundle is not installed")
        }

        var integrationConfiguration = configuration
        integrationConfiguration.requestTimeout = 3
        integrationConfiguration.callbackQueue = DispatchQueue(
            label: "ArborKernelProtocolTests.query-integration-callback"
        )
        let supervisor = ArborKernelSupervisor(configuration: integrationConfiguration)
        defer { supervisor.shutdown() }

        let source = """
        #lang arbor/0
        - Tagged #project ^tagged
        - {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^projects

        """
        let replaced = await supervisor.replaceDocument(
            ArborKernelDocument(id: "live", path: "Live.outline", revision: 1, source: source),
            requestID: "replace-live"
        )
        XCTAssertTrue(replaced.ok, replaced.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertEqual(replaced.id, "replace-live")
        XCTAssertEqual(replaced.outcome, "replaced")

        let queried = await supervisor.runQuery(
            documentID: "live",
            revision: 1,
            queryID: "projects",
            arguments: ["tag": .string("project")],
            requestID: "query-live"
        )
        XCTAssertTrue(queried.ok, queried.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertEqual(queried.id, "query-live")
        XCTAssertEqual(queried.columns, ["block"])
        XCTAssertEqual(queried.rows, [[.string("tagged")]])

        let viewed = await supervisor.getView(
            documentID: "live",
            revision: 1,
            queryID: "projects",
            arguments: ["tag": .string("project")],
            requestID: "view-live"
        )
        XCTAssertTrue(viewed.ok, viewed.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertEqual(viewed.id, "view-live")
        XCTAssertEqual(viewed.views.first?.presentation, "outline")
        XCTAssertEqual(viewed.views.first?.rows.first?.cells.first?.blockID, "tagged")

        let expressionSource = "#lang arbor/0\n- = (+ 40 2) ^answer\n"
        let expressionReplaced = await supervisor.replaceDocument(
            ArborKernelDocument(
                id: "expression-live",
                path: "Expression.outline",
                revision: 1,
                source: expressionSource
            ),
            requestID: "replace-expression-live"
        )
        XCTAssertTrue(
            expressionReplaced.ok,
            expressionReplaced.diagnostics.map(\.message).joined(separator: " | ")
        )
        let produced = await supervisor.runProducer(
            documentID: "expression-live",
            revision: 1,
            producerID: "answer",
            mode: "refresh",
            requestID: "producer-live"
        )
        XCTAssertTrue(produced.ok, produced.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertEqual(produced.results.first?.markdown, "42")
        XCTAssertEqual(produced.generation, 1)

        let effectReplaced = await supervisor.replaceDocument(
            ArborKernelDocument(
                id: "effect-live",
                path: "Effect.outline",
                revision: 1,
                source: "#lang arbor/0\n- ! (clock/now) ^now\n"
            ),
            requestID: "replace-effect-live"
        )
        XCTAssertTrue(effectReplaced.ok)
        let effectRequest = await supervisor.runProducer(
            documentID: "effect-live",
            revision: 1,
            producerID: "now",
            mode: "refresh",
            requestID: "effect-live"
        )
        XCTAssertEqual(effectRequest.status, "effect-request")
        let effectCompleted = await supervisor.completeEffect(
            executionID: "effect-live",
            outcome: ArborKernelEffectOutcome(
                ok: true,
                value: .string("2026-08-16T10:00:00Z"),
                message: nil
            ),
            requestID: "effect-live:complete"
        )
        XCTAssertTrue(effectCompleted.ok)
        XCTAssertEqual(effectCompleted.documentID, "effect-live")

        let mutationReplaced = await supervisor.replaceDocument(
            ArborKernelDocument(
                id: "mutation-live",
                path: "Mutation.outline",
                revision: 1,
                source: "#lang arbor/0\n- Root ^root\n- ! (outline/insert-child (block \"root\") \"Child\") ^maker\n"
            ),
            requestID: "replace-mutation-live"
        )
        XCTAssertTrue(mutationReplaced.ok)
        let mutationRequest = await supervisor.runProducer(
            documentID: "mutation-live",
            revision: 1,
            producerID: "maker",
            mode: "refresh",
            requestID: "mutation-live"
        )
        let mutationDocument = try XCTUnwrap(mutationRequest.mutation?.document)
        let mutationAccepted = await supervisor.replaceDocument(
            mutationDocument,
            requestID: "mutation-live:replace"
        )
        XCTAssertTrue(mutationAccepted.ok)
        let mutationCompleted = await supervisor.completeMutation(
            executionID: "mutation-live",
            outcome: ArborKernelEffectOutcome(ok: true, value: nil, message: nil),
            requestID: "mutation-live:complete"
        )
        XCTAssertTrue(mutationCompleted.ok)
        XCTAssertEqual(mutationCompleted.documentID, "mutation-live")
    }
}
