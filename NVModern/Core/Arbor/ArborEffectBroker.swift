import AppKit
import Foundation
import UserNotifications

enum ArborEffectBroker {
    static let maximumOutputBytes = 1024 * 1024
    static let maximumTimeoutMilliseconds = 60_000

    static func execute(
        _ effect: ArborKernelEffect,
        workspaceRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ArborKernelJSONValue {
        let value: ArborKernelJSONValue
        switch effect.handler {
        case "clock/now":
            value = .string(ISO8601DateFormatter().string(from: Date()))
        case "clock/today":
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            value = .string(formatter.string(from: Date()))
        case "fs/read":
            let file = try existingURL(stringArgument(effect, 0), inside: workspaceRoot)
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            try checkOutputSize(data.count, effect: effect)
            guard let text = String(data: data, encoding: .utf8) else { throw BrokerError.nonUTF8Output }
            value = .string(text)
        case "fs/list":
            let relativePath = effect.arguments.isEmpty ? "." : try stringArgument(effect, 0)
            let directory = try existingURL(relativePath, inside: workspaceRoot)
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            value = .array(try entries.map { url in
                let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                return .object([
                    "name": .string(url.lastPathComponent),
                    "kind": .string(properties.isDirectory == true
                        ? "directory"
                        : properties.isRegularFile == true ? "file" : "other")
                ])
            })
        case "fs/stat":
            let relativePath = try stringArgument(effect, 0)
            let file = try existingURL(relativePath, inside: workspaceRoot)
            let properties = try file.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            value = .object([
                "path": .string(relativePath),
                "kind": .string(properties.isDirectory == true
                    ? "directory"
                    : properties.isRegularFile == true ? "file" : "other"),
                "bytes": .number(Double(properties.fileSize ?? 0)),
                "modified": .string(ISO8601DateFormatter().string(
                    from: properties.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                ))
            ])
        case "fs/glob":
            let directory = try existingURL(stringArgument(effect, 0), inside: workspaceRoot)
            let expression = try wildcardExpression(stringArgument(effect, 1))
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                    let name = url.lastPathComponent
                    let range = NSRange(name.startIndex..<name.endIndex, in: name)
                    return expression.firstMatch(in: name, range: range) != nil
                }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
            value = .array(try entries.map { url in
                let properties = try url.resourceValues(forKeys: [.isDirectoryKey])
                return .object([
                    "name": .string(url.lastPathComponent),
                    "kind": .string(properties.isDirectory == true ? "directory" : "file")
                ])
            })
        case "fs/write", "fs/append":
            let relativePath = try stringArgument(effect, 0)
            let text = try stringArgument(effect, 1)
            let file = try writableURL(relativePath, inside: workspaceRoot)
            let data = Data(text.utf8)
            if effect.handler == "fs/write" {
                try data.write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
            value = .object(["path": .string(relativePath), "bytes": .number(Double(data.count))])
        case "fs/mkdir":
            let relativePath = try stringArgument(effect, 0)
            try FileManager.default.createDirectory(
                at: writableURL(relativePath, inside: workspaceRoot),
                withIntermediateDirectories: false
            )
            value = .object(["path": .string(relativePath), "created": .bool(true)])
        case "process/run":
            let command = try stringArgument(effect, 0)
            let arguments = try effect.arguments.dropFirst().enumerated().map {
                try stringArgument(effect, $0.offset + 1)
            }
            value = .string(try await Task.detached(priority: .userInitiated) {
                try runProcess(
                    command: command,
                    arguments: arguments,
                    input: nil,
                    cwd: workspaceRoot,
                    environment: environment,
                    limits: limits(effect)
                )
            }.value)
        case "http/request":
            value = try await executeHTTPRequest(effect)
        case "clipboard/read":
            value = try await MainActor.run {
                .string(NSPasteboard.general.string(forType: .string) ?? "")
            }
        case "clipboard/write":
            let text = try stringArgument(effect, 0)
            value = await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return .object([
                    "bytes": .number(Double(text.utf8.count)),
                    "written": .bool(pasteboard.setString(text, forType: .string))
                ])
            }
        case "notification/show":
            value = try await showNotification(effect)
        case "action/run":
            value = try await executeAction(effect)
        case "model/complete":
            guard let command = environment["NVMODERN_ARBOR_MODEL_COMMAND"], !command.isEmpty else {
                throw BrokerError.modelProviderUnavailable
            }
            let prompt = try stringArgument(effect, 0)
            var providerEnvironment = environment
            if effect.arguments.count == 2 {
                providerEnvironment["NVMODERN_ARBOR_MODEL"] = try stringArgument(effect, 1)
            }
            value = .string(try await Task.detached(priority: .userInitiated) {
                try runProcess(
                    command: command,
                    arguments: [],
                    input: prompt,
                    cwd: workspaceRoot,
                    environment: providerEnvironment,
                    limits: limits(effect)
                )
            }.value)
        default:
            throw BrokerError.unsupportedHandler(effect.handler)
        }

        try checkOutputSize(JSONEncoder().encode(value).count, effect: effect)
        return value
    }

    private static func stringArgument(_ effect: ArborKernelEffect, _ index: Int) throws -> String {
        guard effect.arguments.indices.contains(index),
              case .string(let value) = effect.arguments[index] else {
            throw BrokerError.invalidArguments
        }
        return value
    }

    private static func limits(_ effect: ArborKernelEffect) -> (timeout: TimeInterval, bytes: Int) {
        (
            TimeInterval(max(1, min(effect.limits.timeoutMs, maximumTimeoutMilliseconds))) / 1000,
            max(1, min(effect.limits.maxOutputBytes, maximumOutputBytes))
        )
    }

    private static func checkOutputSize(_ count: Int, effect: ArborKernelEffect) throws {
        if count > limits(effect).bytes { throw BrokerError.outputTooLarge }
    }

    private static func existingURL(_ relativePath: String, inside rootURL: URL) throws -> URL {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard file == root || file.path.hasPrefix(root.path + "/") else {
            throw BrokerError.outsideWorkspace
        }
        return file
    }

    private static func writableURL(_ relativePath: String, inside rootURL: URL) throws -> URL {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let lexical = root.appendingPathComponent(relativePath).standardizedFileURL
        guard lexical.path.hasPrefix(root.path + "/") else { throw BrokerError.outsideWorkspace }
        let parent = lexical.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent == root || parent.path.hasPrefix(root.path + "/") else {
            throw BrokerError.outsideWorkspace
        }
        return parent.appendingPathComponent(lexical.lastPathComponent).standardizedFileURL
    }

    private static func wildcardExpression(_ pattern: String) throws -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return try NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive])
    }

    private static func executeHTTPRequest(_ effect: ArborKernelEffect) async throws -> ArborKernelJSONValue {
        let method = try stringArgument(effect, 0)
        guard let url = URL(string: try stringArgument(effect, 1)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrokerError.invalidArguments
        }
        var request = URLRequest(url: url, timeoutInterval: limits(effect).timeout)
        request.httpMethod = method
        if effect.arguments.count >= 3, method != "GET" {
            request.httpBody = Data(try stringArgument(effect, 2).utf8)
        }
        if effect.arguments.count >= 4, case .object(let headers) = effect.arguments[3] {
            for (name, value) in headers {
                guard case .string(let text) = value else { throw BrokerError.invalidArguments }
                request.setValue(text, forHTTPHeaderField: name)
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOutputSize(data.count, effect: effect)
        guard let http = response as? HTTPURLResponse,
              let body = String(data: data, encoding: .utf8) else {
            throw BrokerError.nonUTF8Output
        }
        let headers: [String: ArborKernelJSONValue] = Dictionary(
            http.allHeaderFields.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key.lowercased(), ArborKernelJSONValue.string(String(describing: value)))
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return .object([
            "status": .number(Double(http.statusCode)),
            "headers": .object(headers),
            "body": .string(body)
        ])
    }

    private static func showNotification(_ effect: ArborKernelEffect) async throws -> ArborKernelJSONValue {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert]) else {
            throw BrokerError.permissionDenied
        }
        let content = UNMutableNotificationContent()
        content.title = try stringArgument(effect, 0)
        if effect.arguments.count == 2 { content.body = try stringArgument(effect, 1) }
        try await center.add(UNNotificationRequest(
            identifier: effect.executionID,
            content: content,
            trigger: nil
        ))
        return .object(["shown": .bool(true)])
    }

    @MainActor
    private static func executeAction(_ effect: ArborKernelEffect) async throws -> ArborKernelJSONValue {
        let method = try stringArgument(effect, 0)
        guard actionAllowed(method),
              ActionExecutor.shared.registry.descriptor(for: method) != nil else {
            throw BrokerError.actionUnavailable(method)
        }
        let arguments: [String: ActionValue]
        if effect.arguments.count == 2, case .object(let values) = effect.arguments[1] {
            arguments = values.mapValues(ActionValue.init)
        } else {
            arguments = [:]
        }
        let value = try await ActionExecutor.shared.invoke(ActionRequest(
            id: effect.executionID,
            method: method,
            args: arguments,
            target: .automatic,
            source: ActionSource(kind: .webBridge, identifier: "arbor")
        ))
        return ArborKernelJSONValue(value)
    }

    private static func actionAllowed(_ method: String) -> Bool {
        arborActionMethods.contains(method)
    }

    private static let arborActionMethods: Set<String> = [
        "app.health.ping",
        "content.backlinks.query",
        "content.heading.subtree",
        "content.node.get",
        "content.query",
        "content.query.exportCSV",
        "content.query.writeCSV",
        "content.surface.capabilities",
        "workspace.note.create",
        "workspace.note.createFromClipboard",
        "workspace.note.current",
        "workspace.note.duplicateCurrent",
        "workspace.note.open",
        "workspace.note.refile",
        "workspace.recent.list",
        "workspace.recent.open"
    ]

    private static func runProcess(
        command: String,
        arguments: [String],
        input: String?,
        cwd: URL,
        environment: [String: String],
        limits: (timeout: TimeInterval, bytes: Int)
    ) throws -> String {
        let process = Process()
        process.executableURL = command.contains("/")
            ? (command.hasPrefix("/")
                ? URL(fileURLWithPath: command)
                : cwd.appendingPathComponent(command).standardizedFileURL)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command.contains("/") ? arguments : [command] + arguments
        process.currentDirectoryURL = cwd
        process.environment = environment

        let outputPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        let collector = OutputCollector(limit: limits.bytes) {
            if process.isRunning { process.terminate() }
        }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let terminated = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        outputPipe.fileHandleForWriting.closeFile()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = outputPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                if data.isEmpty { break }
                collector.append(data)
            }
            drained.signal()
        }
        let timedOut = terminated.wait(timeout: .now() + limits.timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 1)
        }
        guard drained.wait(timeout: .now() + 1) == .success else { throw BrokerError.timedOut }
        if timedOut { throw BrokerError.timedOut }
        if collector.exceededLimit { throw BrokerError.outputTooLarge }
        let data = collector.data
        guard process.terminationStatus == 0 else { throw BrokerError.processFailed(process.terminationStatus) }
        guard let text = String(data: data, encoding: .utf8) else { throw BrokerError.nonUTF8Output }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private let onLimit: () -> Void
        private var storage = Data()
        private var didExceedLimit = false

        init(limit: Int, onLimit: @escaping () -> Void) {
            self.limit = limit
            self.onLimit = onLimit
        }

        var data: Data { lock.withLock { storage } }
        var exceededLimit: Bool { lock.withLock { didExceedLimit } }

        func append(_ data: Data) {
            let shouldStop = lock.withLock { () -> Bool in
                guard !didExceedLimit else { return false }
                guard storage.count + data.count <= limit else {
                    didExceedLimit = true
                    return true
                }
                storage.append(data)
                return false
            }
            if shouldStop { onLimit() }
        }
    }

    private enum BrokerError: LocalizedError {
        case invalidArguments
        case outsideWorkspace
        case outputTooLarge
        case nonUTF8Output
        case timedOut
        case processFailed(Int32)
        case unsupportedHandler(String)
        case permissionDenied
        case actionUnavailable(String)
        case modelProviderUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The effect has invalid arguments."
            case .outsideWorkspace: return "The effect path is outside the workspace."
            case .outputTooLarge: return "Effect output exceeds its byte limit."
            case .nonUTF8Output: return "Effect output is not UTF-8 text."
            case .timedOut: return "The effect exceeded its timeout."
            case .processFailed(let status): return "The process exited with status \(status)."
            case .unsupportedHandler(let handler): return "Unsupported effect handler: \(handler)"
            case .permissionDenied: return "Effect permission was denied."
            case .actionUnavailable(let method): return "Arbor action is not available: \(method)"
            case .modelProviderUnavailable:
                return "Set NVMODERN_ARBOR_MODEL_COMMAND to enable model/complete."
            }
        }
    }
}

private extension ActionValue {
    init(_ value: ArborKernelJSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let item): self = .bool(item)
        case .number(let item):
            self = item.rounded(.towardZero) == item ? .int(Int(item)) : .double(item)
        case .string(let item): self = .string(item)
        case .array(let items): self = .array(items.map(ActionValue.init))
        case .object(let items): self = .object(items.mapValues(ActionValue.init))
        }
    }
}

private extension ArborKernelJSONValue {
    init(_ value: ActionValue) {
        switch value {
        case .null: self = .null
        case .bool(let item): self = .bool(item)
        case .int(let item): self = .number(Double(item))
        case .double(let item): self = .number(item)
        case .string(let item): self = .string(item)
        case .array(let items): self = .array(items.map(ArborKernelJSONValue.init))
        case .object(let items): self = .object(items.mapValues(ArborKernelJSONValue.init))
        }
    }
}
