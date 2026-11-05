import Foundation

func run(_ invocation: ActionCLIInvocation) {
    let request = ActionRequest(
        id: invocation.requestID ?? UUID().uuidString,
        method: invocation.method,
        args: invocation.args,
        target: invocation.target,
        source: .socket(client: "cli")
    )

    do {
        let response = try ActionSocketClient(socketURL: invocation.socketURL).invoke(request)
        printJSON(response, pretty: invocation.prettyPrint)
        exit(response.ok ? 0 : 1)
    } catch ActionSocketClient.Error.appNotRunning(let path) {
        fputs("nvModern is not running. Start the app, then retry.\nMissing socket: \(path)\n", stderr)
        exit(2)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
}

func printJSON(_ response: ActionResponse, pretty: Bool) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard let data = try? encoder.encode(response),
          let text = String(data: data, encoding: .utf8)
    else {
        fputs("Could not encode action response\n", stderr)
        exit(1)
    }
    fputs(text + "\n", stdout)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let envSocket = ProcessInfo.processInfo.environment["NVMODERN_ACTION_SOCKET"]
let defaultSocketURL = envSocket.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? ActionSocketConfiguration.defaultSocketURL()

switch ActionCLIParser.parse(arguments, defaultSocketURL: defaultSocketURL) {
case .help:
    fputs(ActionCLIParser.usage + "\n", stdout)
    exit(0)
case .usageError(let message):
    fputs(message + "\n\n" + ActionCLIParser.usage + "\n", stderr)
    exit(1)
case .mcp(let socketURL):
    var server = ActionMCPServer(socketURL: socketURL)
    server.run()
case .invoke(let invocation):
    run(invocation)
}
