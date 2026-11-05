import Foundation

struct ActionCLIInvocation: Equatable {
    var method: String
    var args: [String: ActionValue]
    var target: ActionTarget
    var socketURL: URL
    var prettyPrint: Bool
    var requestID: String?
}

enum ActionCLIParseResult: Equatable {
    case invoke(ActionCLIInvocation)
    case mcp(socketURL: URL)
    case help
    case usageError(String)
}

enum ActionCLIParser {
    static var usage: String {
        """
        nv3 <command>

        Commands:
          action <method> [options]  Invoke an action over the local socket
          mcp [options]              Run the MCP stdio server
          help                       Show this help

        \(actionUsage)

        \(mcpUsage)
        """
    }

    static let actionUsage = """
    nv3 action <method> [options]

    Invoke an nvModern action over the local Unix socket.

    Options:
      --arg NAME=VALUE   Set an argument (repeatable)
      --NAME VALUE       Same as --arg NAME=VALUE
      --json JSON        Merge a JSON object into args
      --target JSON      Action target selector JSON
      --socket PATH      Socket path
      --pretty           Pretty-print the JSON response
      --id ID            Request id
      -h, --help         Show this help

    Examples:
      nv3 action app.health.ping
      nv3 action workspace.search.query --query inbox
      nv3 action workspace.note.get --json '{"relativePath":"Inbox.md"}'

    The nvModern app must be running. Disable the socket with:

      [socket]
      enabled = false
    """

    static let mcpUsage = """
    nv3 mcp [options]

    Run a stdio MCP server that exposes a curated allowlist of nvModern
    actions. The nvModern app must be running.

    Options:
      --socket PATH      Socket path
      -h, --help         Show this help

    Claude Code:
      claude mcp add nvmodern -- /Applications/nvModern.app/Contents/MacOS/nv3 mcp

    Codex:
      [mcp_servers.nvmodern]
      command = "/Applications/nvModern.app/Contents/MacOS/nv3"
      args = ["mcp"]
    """

    static func parse(
        _ arguments: [String],
        defaultSocketURL: URL = ActionSocketConfiguration.defaultSocketURL()
    ) -> ActionCLIParseResult {
        let args = arguments
        if args.isEmpty {
            return .usageError("Missing command. Expected `nv3 action` or `nv3 mcp`.")
        }

        let first = args[0]
        if first == "-h" || first == "--help" || first == "help" {
            return .help
        }
        if first == "mcp" {
            return parseMCP(Array(args.dropFirst()), defaultSocketURL: defaultSocketURL)
        }
        if first != "action" {
            return .usageError("Unknown command '\(first)'. Expected `nv3 action` or `nv3 mcp`.")
        }

        let rest = Array(args.dropFirst())
        if rest.isEmpty || rest.contains("-h") || rest.contains("--help") {
            return rest.isEmpty ? .usageError("Missing action method.") : .help
        }

        let method = rest[0]
        guard !method.hasPrefix("-") else {
            return .usageError("Missing action method.")
        }

        var values: [String: ActionValue] = [:]
        var target = ActionTarget.automatic
        var socketURL = defaultSocketURL
        var prettyPrint = false
        var requestID: String?
        var index = 1

        while index < rest.count {
            let token = rest[index]
            if token == "--pretty" {
                prettyPrint = true
                index += 1
                continue
            }

            guard token.hasPrefix("--") else {
                return .usageError("Unexpected argument '\(token)'.")
            }

            let rawName = String(token.dropFirst(2))
            let name = rawName.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? rawName
            if name == "arg" {
                guard let raw = value(after: token, rest: rest, index: &index) else {
                    return .usageError("Missing value for --arg.")
                }
                guard let separator = raw.firstIndex(of: "=") else {
                    return .usageError("--arg requires NAME=VALUE.")
                }
                let key = String(raw[..<separator])
                let valueText = String(raw[raw.index(after: separator)...])
                guard !key.isEmpty else {
                    return .usageError("--arg requires NAME=VALUE.")
                }
                values[key] = parseScalar(valueText)
                continue
            }

            guard let raw = flagValue(name: name, token: token, rest: rest, index: &index) else {
                if name == "pretty" {
                    prettyPrint = true
                    continue
                }
                return .usageError("Missing value for --\(name).")
            }

            switch name {
            case "json":
                do {
                    values.merge(try parseObject(raw), uniquingKeysWith: { _, new in new })
                } catch {
                    return .usageError("Could not parse --json: \(error.localizedDescription)")
                }
            case "target":
                do {
                    target = try parseTarget(raw)
                } catch {
                    return .usageError("Could not parse --target: \(error.localizedDescription)")
                }
            case "socket":
                socketURL = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            case "id":
                requestID = raw
            case "pretty":
                prettyPrint = raw != "false"
            default:
                values[name] = parseScalar(raw)
            }
        }

        return .invoke(
            ActionCLIInvocation(
                method: method,
                args: values,
                target: target,
                socketURL: socketURL,
                prettyPrint: prettyPrint,
                requestID: requestID
            )
        )
    }

    private static func parseMCP(
        _ args: [String],
        defaultSocketURL: URL
    ) -> ActionCLIParseResult {
        if args.contains("-h") || args.contains("--help") {
            return .help
        }

        var socketURL = defaultSocketURL
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                return .usageError("Unexpected argument '\(token)'.")
            }
            let rawName = String(token.dropFirst(2))
            let name = rawName.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? rawName
            guard name == "socket" else {
                return .usageError("Unknown option --\(name).")
            }
            guard let raw = flagValue(name: name, token: token, rest: args, index: &index) else {
                return .usageError("Missing value for --socket.")
            }
            socketURL = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return .mcp(socketURL: socketURL)
    }

    private static func flagValue(
        name: String,
        token: String,
        rest: [String],
        index: inout Int
    ) -> String? {
        if let equals = token.firstIndex(of: "=") {
            let raw = String(token[token.index(after: equals)...])
            index += 1
            return raw
        }
        return value(after: token, rest: rest, index: &index)
    }

    private static func value(after token: String, rest: [String], index: inout Int) -> String? {
        let nextIndex = index + 1
        guard nextIndex < rest.count else { return nil }
        let next = rest[nextIndex]
        if next.hasPrefix("--") { return nil }
        index = nextIndex + 1
        return next
    }

    private static func parseScalar(_ raw: String) -> ActionValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw == "null" { return .null }
        if let int = Int(raw), String(int) == raw {
            return .int(int)
        }
        if raw.hasPrefix("{") || raw.hasPrefix("[") {
            if let data = raw.data(using: .utf8),
               let value = try? JSONDecoder().decode(ActionValue.self, from: data) {
                return value
            }
        }
        return .string(raw)
    }

    private static func parseObject(_ raw: String) throws -> [String: ActionValue] {
        guard let data = raw.data(using: .utf8) else {
            throw ActionError.decodeFailed("JSON was not UTF-8")
        }
        let value = try JSONDecoder().decode(ActionValue.self, from: data)
        guard let object = value.objectValue else {
            throw ActionError.invalidArguments("--json must be a JSON object")
        }
        return object
    }

    private static func parseTarget(_ raw: String) throws -> ActionTarget {
        guard let data = raw.data(using: .utf8) else {
            throw ActionError.decodeFailed("Target JSON was not UTF-8")
        }
        return try JSONDecoder().decode(ActionTarget.self, from: data)
    }
}
