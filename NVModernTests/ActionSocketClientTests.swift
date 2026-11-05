import XCTest
@testable import nvModern

final class ActionSocketConfigurationTests: XCTestCase {
    func testSocketDefaultsOnWhenSectionIsOmitted() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let config = ActionSocketConfiguration.make(
            enabled: nil,
            path: nil,
            home: home,
            resolvePath: { URL(fileURLWithPath: $0) }
        )
        XCTAssertEqual(config?.isEnabled, true)
        XCTAssertEqual(config?.socketURL, ActionSocketConfiguration.defaultSocketURL(home: home))
    }

    func testSocketCanBeDisabled() {
        XCTAssertNil(
            ActionSocketConfiguration.make(
                enabled: false,
                path: "/tmp/custom.sock",
                home: URL(fileURLWithPath: "/Users/test"),
                resolvePath: { URL(fileURLWithPath: $0) }
            )
        )
    }

    func testCustomSocketPathIsResolved() {
        let config = ActionSocketConfiguration.make(
            enabled: true,
            path: "/tmp/custom.sock",
            home: URL(fileURLWithPath: "/Users/test"),
            resolvePath: { URL(fileURLWithPath: $0) }
        )
        XCTAssertEqual(config?.socketURL.path, "/tmp/custom.sock")
    }
}

final class ActionSocketSourceTests: XCTestCase {
    func testMissingSourceDefaultsToInternalThenTagsSocket() throws {
        let request = try JSONDecoder().decode(
            ActionRequest.self,
            from: Data(#"{"method":"app.health.ping"}"#.utf8)
        )
        XCTAssertEqual(request.source.kind, .internalCall)
        XCTAssertEqual(request.withSocketSource().source.kind, .socket)
        XCTAssertTrue(request.withSocketSource().source.metadata.isEmpty)
    }

    func testClientMetadataSurvivesSocketTagging() throws {
        let request = ActionRequest(
            method: "app.health.ping",
            source: .socket(client: "cli")
        )
        let tagged = request.withSocketSource()
        XCTAssertEqual(tagged.source.kind, .socket)
        XCTAssertEqual(tagged.source.metadata["client"], .string("cli"))
    }

    func testInternalKindCannotSurviveTheSocket() {
        let request = ActionRequest(method: "app.health.ping", source: .internalCall)
        XCTAssertEqual(request.withSocketSource().source.kind, .socket)
    }
}

final class ActionCLIParserTests: XCTestCase {
    func testParsesFlagArgsAndTypes() {
        let socket = URL(fileURLWithPath: "/tmp/action.sock")
        guard case .invoke(let invocation) = ActionCLIParser.parse(
            ["action", "workspace.search.query", "--query", "inbox", "--limit", "10", "--pretty"],
            defaultSocketURL: socket
        ) else {
            return XCTFail("expected invoke")
        }

        XCTAssertEqual(invocation.method, "workspace.search.query")
        XCTAssertEqual(invocation.args["query"], .string("inbox"))
        XCTAssertEqual(invocation.args["limit"], .int(10))
        XCTAssertTrue(invocation.prettyPrint)
        XCTAssertEqual(invocation.socketURL, socket)
    }

    func testParsesJSONArgsAndCustomSocket() {
        guard case .invoke(let invocation) = ActionCLIParser.parse(
            [
                "action",
                "workspace.note.get",
                "--json",
                #"{"relativePath":"Inbox.md","maxBytes":1024}"#,
                "--socket",
                "/tmp/custom.sock"
            ],
            defaultSocketURL: URL(fileURLWithPath: "/tmp/default.sock")
        ) else {
            return XCTFail("expected invoke")
        }

        XCTAssertEqual(invocation.args["relativePath"], .string("Inbox.md"))
        XCTAssertEqual(invocation.args["maxBytes"], .int(1024))
        XCTAssertEqual(invocation.socketURL.path, "/tmp/custom.sock")
    }

    func testHelpAndUnknownCommand() {
        guard case .help = ActionCLIParser.parse(["--help"]) else {
            return XCTFail("expected help")
        }
        guard case .mcp(let url) = ActionCLIParser.parse(
            ["mcp"],
            defaultSocketURL: URL(fileURLWithPath: "/tmp/action.sock")
        ) else {
            return XCTFail("expected mcp")
        }
        XCTAssertEqual(url.path, "/tmp/action.sock")
        guard case .mcp(let custom) = ActionCLIParser.parse(
            ["mcp", "--socket", "/tmp/custom.sock"],
            defaultSocketURL: URL(fileURLWithPath: "/tmp/action.sock")
        ) else {
            return XCTFail("expected mcp with socket")
        }
        XCTAssertEqual(custom.path, "/tmp/custom.sock")
        guard case .usageError = ActionCLIParser.parse(["nope"]) else {
            return XCTFail("expected usage error")
        }
        guard case .usageError = ActionCLIParser.parse(["action"]) else {
            return XCTFail("expected missing method")
        }
    }
}

@MainActor
final class ActionSocketClientTests: XCTestCase {
    func testClientPingRoundTrip() async throws {
        let url = URL(fileURLWithPath: "/tmp/nvm-\(UUID().uuidString.prefix(8)).sock")
        let server = ActionSocketServer()
        server.configure(socketURL: url)
        server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: url)
        }

        guard case .running = server.state else {
            return XCTFail("server failed to start: \(String(describing: server.state))")
        }

        let response = try await Task.detached {
            try ActionSocketClient(socketURL: url).invoke(
                ActionRequest(method: "app.health.ping", source: .socket(client: "cli"))
            )
        }.value

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.objectValue?["app"]?.stringValue, "nvModern")
    }

    func testClientReportsAppNotRunning() {
        let url = URL(fileURLWithPath: "/tmp/nvm-missing-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(
            try ActionSocketClient(socketURL: url).invoke(ActionRequest(method: "app.health.ping"))
        ) { error in
            guard let clientError = error as? ActionSocketClient.Error,
                  case .appNotRunning(let path) = clientError else {
                XCTFail("expected appNotRunning, got \(error)")
                return
            }
            XCTAssertEqual(path, url.path)
        }
    }
}
