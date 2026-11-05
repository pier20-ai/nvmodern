import Foundation
import XCTest
@testable import nvModern

final class ActionMCPCatalogTests: XCTestCase {
    func testToolNamesAreUniqueAndAvoidChromeMutators() {
        let names = ActionMCPCatalog.tools.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)

        let methods = Set(ActionMCPCatalog.tools.map(\.method))
        XCTAssertFalse(methods.contains("workspace.tab.close"))
        XCTAssertFalse(methods.contains("workspace.split.right"))
        XCTAssertFalse(methods.contains("markdown.table.column.alignLeft"))
        XCTAssertFalse(methods.contains("automation.recipe.run"))
        XCTAssertTrue(methods.contains("workspace.search.query"))
        XCTAssertTrue(methods.contains("workspace.editor.selection.replace"))
        XCTAssertTrue(methods.contains("workspace.projects.list"))
        XCTAssertTrue(methods.contains("workspace.document.jump"))
    }

    func testAnnotateToolDescribesAnnotationItems() {
        guard let tool = ActionMCPCatalog.tool(named: "annotate") else {
            return XCTFail("missing annotate")
        }
        XCTAssertEqual(tool.method, "workspace.annotations.add")

        let annotations = tool.inputSchema().objectValue?["properties"]?.objectValue?["annotations"]?.objectValue
        XCTAssertEqual(annotations?["type"], .string("array"))
        XCTAssertEqual(annotations?["items"]?.objectValue?["required"], .array([.string("quote")]))

        XCTAssertEqual(ActionMCPCatalog.tool(named: "get_questions")?.method, "workspace.annotations.questions")
        XCTAssertEqual(ActionMCPCatalog.tool(named: "answer_question")?.method, "workspace.annotations.answer")
        XCTAssertEqual(ActionMCPCatalog.tool(named: "export_annotations")?.method, "workspace.annotations.export")

        let invocation = tool.invocation(from: [
            "path": .string("Reading/paper.md"),
            "annotations": .array([.object(["quote": .string("x")])])
        ])
        XCTAssertEqual(invocation.args["path"], .string("Reading/paper.md"))
    }

    func testPathAndProjectFlattening() {
        guard let tool = ActionMCPCatalog.tool(named: "get_note") else {
            return XCTFail("missing get_note")
        }

        let invocation = tool.invocation(from: [
            "path": .string("Inbox.md"),
            "maxBytes": .int(1024),
            "project": .string("Notes")
        ])

        XCTAssertEqual(invocation.method, "workspace.note.get")
        XCTAssertEqual(invocation.args["relativePath"], .string("Inbox.md"))
        XCTAssertNil(invocation.args["path"])
        XCTAssertNil(invocation.args["project"])
        XCTAssertEqual(invocation.args["maxBytes"], .int(1024))
        XCTAssertEqual(invocation.target.project, .named("Notes"))
    }

    func testProjectRootPathAndHeadingAliases() {
        guard let heading = ActionMCPCatalog.tool(named: "get_heading"),
              let backlinks = ActionMCPCatalog.tool(named: "get_backlinks")
        else {
            return XCTFail("missing tools")
        }

        let rooted = heading.invocation(from: [
            "path": .string("Projects/Plan.md"),
            "heading": .string("next-steps"),
            "project": .string("/tmp/notes")
        ])
        XCTAssertEqual(rooted.args["documentPath"], .string("Projects/Plan.md"))
        XCTAssertEqual(rooted.args["headingSlug"], .string("next-steps"))
        XCTAssertEqual(rooted.target.project, .rootPath("/tmp/notes"))

        let links = backlinks.invocation(from: ["path": .string("Inbox.md")])
        XCTAssertEqual(links.args["targetPath"], .string("Inbox.md"))
        XCTAssertEqual(links.target, .automatic)
    }

    func testGetHelpIsExposedWithoutProjectArgument() {
        guard let tool = ActionMCPCatalog.tool(named: "get_help") else {
            return XCTFail("missing get_help")
        }
        let properties = tool.inputSchema().objectValue?["properties"]?.objectValue
        XCTAssertEqual(tool.method, "app.help.get")
        XCTAssertNotNil(properties?["provider"])
        XCTAssertNotNil(properties?["topic"])
        XCTAssertNil(properties?["project"])
    }

    func testInputSchemaUsesFriendlyNames() {
        guard let tool = ActionMCPCatalog.tool(named: "search_notes") else {
            return XCTFail("missing search_notes")
        }
        let schema = tool.inputSchema().objectValue
        let properties = schema?["properties"]?.objectValue
        XCTAssertEqual(schema?["type"], .string("object"))
        XCTAssertNotNil(properties?["query"])
        XCTAssertNotNil(properties?["project"])
        XCTAssertEqual(schema?["required"], .array([.string("query")]))
    }
}

final class ActionMCPServerTests: XCTestCase {
    func testInitializeAndToolsList() throws {
        var server = ActionMCPServer(invoker: RecordingInvoker())
        let initialize = try decodeObject(server.handleMessage(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        """#))

        XCTAssertEqual(initialize["id"], ActionValue.int(1))
        let result = initialize["result"]?.objectValue
        XCTAssertEqual(result?["protocolVersion"], ActionValue.string("2025-06-18"))
        XCTAssertEqual(result?["serverInfo"]?.objectValue?["name"], ActionValue.string("nvmodern"))

        XCTAssertNil(server.handleMessage(#"""
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """#))

        let listed = try decodeObject(server.handleMessage(#"""
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        """#))
        let tools = listed["result"]?.objectValue?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, ActionMCPCatalog.tools.count)
        XCTAssertTrue(tools.contains { $0.objectValue?["name"] == ActionValue.string("search_notes") })
        XCTAssertTrue(tools.contains { $0.objectValue?["name"] == ActionValue.string("get_context") })
        XCTAssertTrue(tools.contains { $0.objectValue?["name"] == ActionValue.string("replace_selection") })
    }

    func testToolCallMapsToActionAndTagsSource() throws {
        let invoker = RecordingInvoker()
        invoker.response = .success(id: "req", result: ["count": .int(1)])
        var server = ActionMCPServer(invoker: invoker)

        _ = server.handleMessage(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        """#)

        let response = try decodeObject(server.handleMessage(#"""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"inbox","limit":5,"project":"Notes"}}}
        """#))
        XCTAssertEqual(response["id"], ActionValue.int(3))
        XCTAssertEqual(response["result"]?.objectValue?["isError"], ActionValue.bool(false))

        let request = try XCTUnwrap(invoker.requests.first)
        XCTAssertEqual(request.method, "workspace.search.query")
        XCTAssertEqual(request.args["query"], ActionValue.string("inbox"))
        XCTAssertEqual(request.args["limit"], ActionValue.int(5))
        XCTAssertNil(request.args["project"])
        XCTAssertEqual(request.target.project, .named("Notes"))
        XCTAssertEqual(request.source.kind, .socket)
        XCTAssertEqual(request.source.metadata["client"], ActionValue.string("mcp"))
    }

    func testUnknownToolAndAppNotRunningAreReported() throws {
        let invoker = RecordingInvoker()
        invoker.error = ActionSocketClient.Error.appNotRunning(socketPath: "/tmp/missing.sock")
        var server = ActionMCPServer(invoker: invoker)
        _ = server.handleMessage(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        """#)

        let unknown = try decodeObject(server.handleMessage(#"""
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"drop_table"}}
        """#))
        XCTAssertEqual(unknown["error"]?.objectValue?["code"], ActionValue.int(-32602))

        let missing = try decodeObject(server.handleMessage(#"""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping"}}
        """#))
        XCTAssertEqual(missing["result"]?.objectValue?["isError"], ActionValue.bool(true))
        let text = missing["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        XCTAssertTrue(text?.contains("not running") == true)
    }

    func testRejectsMissingOrWrongJSONRPCVersion() throws {
        var server = ActionMCPServer(invoker: RecordingInvoker())

        let missing = try decodeObject(server.handleMessage(#"{"id":1,"method":"ping"}"#))
        XCTAssertEqual(missing["error"]?.objectValue?["code"], ActionValue.int(-32600))

        let wrong = try decodeObject(server.handleMessage(#"{"jsonrpc":"1.0","method":"ping"}"#))
        XCTAssertEqual(wrong["id"], ActionValue.null)
        XCTAssertEqual(wrong["error"]?.objectValue?["code"], ActionValue.int(-32600))
    }

    private func decodeObject(_ line: String?) throws -> [String: ActionValue] {
        let payload = try XCTUnwrap(line)
        let value = try JSONDecoder().decode(ActionValue.self, from: Data(payload.utf8))
        return try XCTUnwrap(value.objectValue)
    }
}

private final class RecordingInvoker: ActionMCPInvoker, @unchecked Sendable {
    var requests: [ActionRequest] = []
    var response = ActionResponse.success(id: nil, result: .object([:]))
    var error: Error?

    func invoke(_ request: ActionRequest) throws -> ActionResponse {
        requests.append(request)
        if let error {
            throw error
        }
        return response
    }
}
