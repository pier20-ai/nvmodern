import Darwin
import Foundation

protocol ActionMCPInvoker: Sendable {
    func invoke(_ request: ActionRequest) throws -> ActionResponse
}

extension ActionSocketClient: ActionMCPInvoker {}

enum JSONRPCID: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case null
}

extension JSONRPCID: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON-RPC id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct JSONRPCRequest: Decodable, Equatable, Sendable {
    var jsonrpc: String?
    var id: JSONRPCID?
    var method: String?
    var params: ActionValue?

    var isNotification: Bool {
        id == nil
    }
}

struct JSONRPCErrorBody: Encodable, Equatable, Sendable {
    var code: Int
    var message: String
    var data: ActionValue?
}

struct JSONRPCResponse: Encodable, Equatable, Sendable {
    var jsonrpc: String = "2.0"
    var id: JSONRPCID
    var result: ActionValue?
    var error: JSONRPCErrorBody?

    static func success(id: JSONRPCID, result: ActionValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONRPCID, code: Int, message: String, data: ActionValue? = nil) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: JSONRPCErrorBody(code: code, message: message, data: data))
    }
}

struct ActionMCPServer {
    static let supportedProtocolVersions = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25"
    ]

    var invoker: any ActionMCPInvoker
    var serverName: String
    var serverVersion: String
    var didInitialize = false

    init(
        invoker: any ActionMCPInvoker,
        serverName: String = "nvmodern",
        serverVersion: String = ActionMCPServer.defaultVersion
    ) {
        self.invoker = invoker
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    init(
        socketURL: URL,
        serverName: String = "nvmodern",
        serverVersion: String = ActionMCPServer.defaultVersion
    ) {
        self.init(
            invoker: ActionSocketClient(socketURL: socketURL),
            serverName: serverName,
            serverVersion: serverVersion
        )
    }

    static var defaultVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.2"
    }

    mutating func run() {
        setbuf(stdout, nil)
        while let message = readLine(strippingNewline: true) {
            if let response = handleMessage(message) {
                fputs(response + "\n", stdout)
                fflush(stdout)
            }
        }
    }

    mutating func handleMessage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            return encode(JSONRPCResponse.failure(id: .null, code: -32700, message: "Parse error"))
        }

        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return encode(JSONRPCResponse.failure(id: .null, code: -32700, message: "Parse error"))
        }

        guard let response = handle(request) else {
            return nil
        }
        return encode(response)
    }

    mutating func handle(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        let id = request.id ?? .null
        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse.failure(id: id, code: -32600, message: "Invalid Request")
        }
        guard let method = request.method, !method.isEmpty else {
            return JSONRPCResponse.failure(id: id, code: -32600, message: "Invalid Request")
        }

        if method == "notifications/initialized" || method == "initialized" {
            didInitialize = true
            return nil
        }

        if request.isNotification {
            return nil
        }

        switch method {
        case "initialize":
            didInitialize = true
            return JSONRPCResponse.success(id: id, result: initializeResult(from: request.params))
        case "ping":
            return JSONRPCResponse.success(id: id, result: .object([:]))
        case "tools/list":
            guard didInitialize else {
                return JSONRPCResponse.failure(id: id, code: -32600, message: "Server not initialized")
            }
            return JSONRPCResponse.success(id: id, result: toolsListResult())
        case "tools/call":
            guard didInitialize else {
                return JSONRPCResponse.failure(id: id, code: -32600, message: "Server not initialized")
            }
            return callTool(id: id, params: request.params)
        default:
            return JSONRPCResponse.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(from params: ActionValue?) -> ActionValue {
        let requested = params?.objectValue?["protocolVersion"]?.stringValue
        let protocolVersion = requested.flatMap { version in
            Self.supportedProtocolVersions.contains(version) ? version : nil
        } ?? "2024-11-05"

        return [
            "protocolVersion": .string(protocolVersion),
            "capabilities": [
                "tools": ["listChanged": .bool(false)]
            ],
            "serverInfo": [
                "name": .string(serverName),
                "version": .string(serverVersion)
            ],
            "instructions": .string(
                "nvModern must be running. Paths are workspace-relative. Use get_context first to see the current project, tabs, viewport, and selection. Do not attempt table-alignment or chrome actions; this server exposes a curated allowlist."
            )
        ]
    }

    private func toolsListResult() -> ActionValue {
        let tools = ActionMCPCatalog.tools.map { tool -> ActionValue in
            [
                "name": .string(tool.name),
                "title": .string(tool.title),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema()
            ]
        }
        return ["tools": .array(tools)]
    }

    private func callTool(id: JSONRPCID, params: ActionValue?) -> JSONRPCResponse {
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue,
              !name.isEmpty
        else {
            return JSONRPCResponse.failure(id: id, code: -32602, message: "tools/call requires params.name")
        }

        guard let tool = ActionMCPCatalog.tool(named: name) else {
            return JSONRPCResponse.failure(
                id: id,
                code: -32602,
                message: "Unknown tool: \(name)",
                data: ["name": .string(name)]
            )
        }

        let arguments = object["arguments"]?.objectValue ?? [:]
        let invocation = tool.invocation(from: arguments)
        let request = ActionRequest(
            id: UUID().uuidString,
            method: invocation.method,
            args: invocation.args,
            target: invocation.target,
            source: .socket(client: "mcp")
        )

        do {
            let response = try invoker.invoke(request)
            return JSONRPCResponse.success(id: id, result: toolCallResult(from: response))
        } catch let error as ActionSocketClient.Error {
            return JSONRPCResponse.success(id: id, result: errorToolResult(error.localizedDescription))
        } catch {
            return JSONRPCResponse.success(id: id, result: errorToolResult(error.localizedDescription))
        }
    }

    private func toolCallResult(from response: ActionResponse) -> ActionValue {
        if response.ok {
            let payload = response.result ?? .object([:])
            return [
                "content": .array([
                    [
                        "type": .string("text"),
                        "text": .string(encodeValue(payload, pretty: true))
                    ]
                ]),
                "isError": .bool(false)
            ]
        }

        let payload: ActionValue
        if let error = response.error {
            payload = [
                "code": .string(error.code.rawValue),
                "message": .string(error.message),
                "details": .object(error.details)
            ]
        } else {
            payload = ["message": .string("Action failed")]
        }
        return [
            "content": .array([
                [
                    "type": .string("text"),
                    "text": .string(encodeValue(payload, pretty: true))
                ]
            ]),
            "isError": .bool(true)
        ]
    }

    private func errorToolResult(_ message: String) -> ActionValue {
        [
            "content": .array([
                [
                    "type": .string("text"),
                    "text": .string(message)
                ]
            ]),
            "isError": .bool(true)
        ]
    }

    private func encode(_ response: JSONRPCResponse) -> String {
        encodeValue(
            jsonObject(for: response),
            pretty: false
        )
    }

    private func jsonObject(for response: JSONRPCResponse) -> ActionValue {
        var object: [String: ActionValue] = [
            "jsonrpc": .string(response.jsonrpc),
            "id": idValue(response.id)
        ]
        if let error = response.error {
            var errorObject: [String: ActionValue] = [
                "code": .int(error.code),
                "message": .string(error.message)
            ]
            if let data = error.data {
                errorObject["data"] = data
            }
            object["error"] = .object(errorObject)
        } else {
            object["result"] = response.result ?? .object([:])
        }
        return .object(object)
    }

    private func idValue(_ id: JSONRPCID) -> ActionValue {
        switch id {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .null:
            return .null
        }
    }

    private func encodeValue(_ value: ActionValue, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return pretty ? text : text.replacingOccurrences(of: "\n", with: "")
    }
}
