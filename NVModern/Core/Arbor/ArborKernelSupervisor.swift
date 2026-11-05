import Foundation
import CryptoKit

struct ArborKernelConfiguration {
    var executableURL: URL?
    var scriptURL: URL?
    var environment: [String: String]
    var requestTimeout: TimeInterval
    var callbackQueue: DispatchQueue

    static func bundled(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ArborKernelConfiguration {
        ArborKernelConfiguration(
            executableURL: ArborKernelLocator.racketExecutableURL(
                environment: environment,
                fileManager: fileManager
            ),
            scriptURL: ArborKernelLocator.kernelScriptURL(bundle: bundle, fileManager: fileManager),
            environment: environment,
            requestTimeout: 5.0,
            callbackQueue: .main
        )
    }
}

enum ArborKernelLocator {
    static func racketExecutableURL(
        environment: [String: String],
        fileManager: FileManager,
        applicationDirectories: [URL]? = nil
    ) -> URL? {
        var paths: [String] = []
        if let override = environment["NVMODERN_RACKET_PATH"], !override.isEmpty {
            paths.append(contentsOf: executablePaths(at: override))
        }
        if let path = environment["PATH"] {
            paths.append(
                contentsOf: path
                    .split(separator: ":")
                    .map {
                        URL(fileURLWithPath: String($0), isDirectory: true)
                            .appendingPathComponent("racket", isDirectory: false)
                            .path
                    }
            )
        }
        paths.append(contentsOf: versionedApplicationBundlePaths(
            fileManager: fileManager,
            directories: applicationDirectories ?? defaultApplicationDirectories(environment: environment)
        ))
        paths.append(contentsOf: [
            "/opt/homebrew/bin/racket",
            "/usr/local/bin/racket",
            "/opt/local/bin/racket"
        ])
        if let home = environment["HOME"], !home.isEmpty {
            paths.append(contentsOf: [
                "\(home)/.local/bin/racket",
                "\(home)/.nix-profile/bin/racket",
                "\(home)/.asdf/shims/racket",
                "\(home)/.local/share/mise/shims/racket"
            ])
        }

        var seen = Set<String>()
        return paths.first { path in
            var isDirectory = ObjCBool(false)
            return seen.insert(path).inserted
                && fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private static func executablePaths(at path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        return [
            url.path,
            url.appendingPathComponent("racket", isDirectory: false).path,
            url.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("racket", isDirectory: false).path
        ]
    }

    private static func defaultApplicationDirectories(environment: [String: String]) -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(
                URL(fileURLWithPath: home, isDirectory: true)
                    .appendingPathComponent("Applications", isDirectory: true)
            )
        }
        return directories
    }

    private static func versionedApplicationBundlePaths(
        fileManager: FileManager,
        directories: [URL]
    ) -> [String] {
        let candidates = directories.flatMap { directory in
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return candidates
            .filter { url in
                url.lastPathComponent.lowercased().hasPrefix("racket")
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
            }
            .map {
                $0.appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("racket", isDirectory: false)
                    .path
            }
    }

    static func kernelScriptURL(bundle: Bundle, fileManager: FileManager) -> URL? {
        let bundledCandidates = [
            bundle.url(
                forResource: "arbor-kernel",
                withExtension: "rkt",
                subdirectory: "ArborKernel"
            ),
            bundle.resourceURL?
                .appendingPathComponent("ArborKernel", isDirectory: true)
                .appendingPathComponent("arbor-kernel.rkt", isDirectory: false)
        ].compactMap { $0 }

        let sourceDirectory = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceTreeCandidate = sourceDirectory
            .appendingPathComponent("ArborKernel", isDirectory: true)
            .appendingPathComponent("arbor-kernel.rkt", isDirectory: false)

        return (bundledCandidates + [sourceTreeCandidate]).first { candidate in
            fileManager.fileExists(atPath: candidate.path)
        }
    }
}

final class ArborKernelSupervisor {
    typealias Completion = (ArborKernelResponse) -> Void

    private struct PendingRequest {
        var request: ArborKernelRequest
        var startedAt: TimeInterval
        var completion: Completion
    }

    private let configuration: ArborKernelConfiguration
    private let queue = DispatchQueue(label: "nvmodern.arbor-kernel", qos: .userInitiated)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var standardErrorBuffer = Data()
    private var recentStandardError = Data()
    private var pending: [String: PendingRequest] = [:]
    private var acceptedDocuments: [String: ArborKernelDocument] = [:]
    private let capabilityLock = NSLock()
    private var grantedCapabilities = Set<String>()

    init(configuration: ArborKernelConfiguration = .bundled()) {
        self.configuration = configuration
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func evaluate(
        document: ArborKernelDocument,
        previousDerivedUIDs: [String] = [],
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await withCheckedContinuation { continuation in
            evaluate(
                ArborKernelRequest(
                    id: requestID,
                    document: document,
                    previousDerivedUIDs: previousDerivedUIDs
                )
            ) { response in
                continuation.resume(returning: response)
            }
        }
    }

    func replaceDocument(
        _ document: ArborKernelDocument,
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(.replaceDocument(id: requestID, document: document))
    }

    func runQuery(
        documentID: String,
        revision: Int,
        queryID: String,
        arguments: [String: ArborKernelJSONValue] = [:],
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(
            .runQuery(
                id: requestID,
                documentID: documentID,
                revision: revision,
                queryID: queryID,
                arguments: arguments
            )
        )
    }

    func getView(
        documentID: String,
        revision: Int,
        queryID: String? = nil,
        arguments: [String: ArborKernelJSONValue] = [:],
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(
            .getView(
                id: requestID,
                documentID: documentID,
                revision: revision,
                queryID: queryID,
                arguments: arguments
            )
        )
    }

    func runProducer(
        documentID: String,
        revision: Int,
        producerID: String,
        mode: String,
        arguments: [String: ArborKernelJSONValue] = [:],
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(
            .runProducer(
                id: requestID,
                documentID: documentID,
                revision: revision,
                producerID: producerID,
                mode: mode,
                arguments: arguments
            )
        )
    }

    func applyIntent(
        documentID: String,
        revision: Int,
        resultID: String,
        intent: ArborKernelIntent,
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(
            .applyIntent(
                id: requestID,
                documentID: documentID,
                revision: revision,
                resultID: resultID,
                intent: intent
            )
        )
    }

    func completeEffect(
        executionID: String,
        outcome: ArborKernelEffectOutcome,
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(.completeEffect(id: requestID, executionID: executionID, outcome: outcome))
    }

    func cancelEffect(
        executionID: String,
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(.cancelEffect(id: requestID, executionID: executionID))
    }

    func completeMutation(
        executionID: String,
        outcome: ArborKernelEffectOutcome,
        requestID: String = UUID().uuidString
    ) async -> ArborKernelResponse {
        await send(.completeMutation(id: requestID, executionID: executionID, outcome: outcome))
    }

    func hasCapabilityGrant(_ id: String) -> Bool {
        capabilityLock.withLock { grantedCapabilities.contains(id) }
    }

    func rememberCapabilityGrant(_ id: String) {
        capabilityLock.withLock { _ = grantedCapabilities.insert(id) }
    }

    private func send(_ request: ArborKernelRequest) async -> ArborKernelResponse {
        await withCheckedContinuation { continuation in
            send(request) { response in
                continuation.resume(returning: response)
            }
        }
    }

    func evaluate(_ request: ArborKernelRequest, completion: @escaping Completion) {
        send(request, completion: completion)
    }

    private func send(_ request: ArborKernelRequest, completion: @escaping Completion) {
        queue.async { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            self.logSend(request)
            guard request.protocolVersion == ArborKernelProtocolVersion.current else {
                self.deliverImmediate(
                    response: .failure(
                        id: request.id,
                        operation: request.operation,
                        revision: request.document.revision,
                        path: request.document.path,
                        code: "ARBOR9006",
                        message: "Unsupported native Arbor kernel protocol: \(request.protocolVersion)"
                    ),
                    request: request,
                    startedAt: startedAt,
                    completion: completion
                )
                return
            }
            guard self.configuration.executableURL != nil else {
                self.deliverImmediate(
                    response: self.failureResponse(
                        for: request,
                        code: "ARBOR9001",
                        message: "Racket was not found in PATH, a standard package-manager location, or an installed Racket application. Set NVMODERN_RACKET_PATH only for a custom installation."
                    ),
                    request: request,
                    startedAt: startedAt,
                    completion: completion
                )
                return
            }
            guard self.configuration.scriptURL != nil else {
                self.deliverImmediate(
                    response: self.failureResponse(
                        for: request,
                        code: "ARBOR9002",
                        message: "The Arbor kernel resource is missing from this nvModern build."
                    ),
                    request: request,
                    startedAt: startedAt,
                    completion: completion
                )
                return
            }

            do {
                try self.startProcessIfNeeded()
                self.pending[request.id] = PendingRequest(
                    request: request,
                    startedAt: startedAt,
                    completion: completion
                )
                try self.write(request)
                self.scheduleTimeout(for: request.id)
            } catch {
                self.pending.removeValue(forKey: request.id)
                self.stopProcess()
                self.deliverImmediate(
                    response: self.failureResponse(
                        for: request,
                        code: "ARBOR9003",
                        message: "Could not start the Arbor kernel: \(error.localizedDescription)"
                    ),
                    request: request,
                    startedAt: startedAt,
                    completion: completion
                )
            }
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptedDocuments.removeAll()
            self.failAllPending(
                code: "ARBOR9008",
                message: "The Arbor kernel was stopped."
            )
            self.stopProcess()
        }
    }

    private func startProcessIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let executableURL = configuration.executableURL,
              let scriptURL = configuration.scriptURL else {
            return
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [scriptURL.path]
        process.environment = configuration.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        LocalDiagnosticsCenter.shared.log(
            category: "arbor.kernel.process",
            event: "starting",
            metadata: [
                "environmentKeys": configuration.environment.keys.sorted().joined(separator: ","),
                "executable": executableURL.path,
                "modelCommand": configuration.environment["NVMODERN_ARBOR_MODEL_COMMAND"] ?? "",
                "path": configuration.environment["PATH"] ?? "",
                "racketOverride": configuration.environment["NVMODERN_RACKET_PATH"] ?? "",
                "script": scriptURL.path
            ]
        )

        outputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        recentStandardError.removeAll(keepingCapacity: true)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consumeOutput(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consumeStandardError(data)
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            self?.queue.async { [weak self] in
                self?.processDidTerminate(process)
            }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        do {
            try process.run()
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.kernel.process",
                event: "started",
                metadata: [
                    "processIdentifier": String(process.processIdentifier),
                    "replayDocumentCount": String(acceptedDocuments.count)
                ]
            )
            try replayAcceptedDocuments()
        } catch {
            stopProcess()
            throw error
        }
    }

    private func write(_ request: ArborKernelRequest) throws {
        guard let inputPipe else {
            throw CocoaError(.fileWriteUnknown)
        }
        var data = try encoder.encode(request)
        LocalDiagnosticsCenter.shared.log(
            level: .debug,
            category: "arbor.kernel.transport",
            event: "stdin",
            metadata: [
                "bytes": String(data.count),
                "operation": request.operation,
                "payload": String(data: data, encoding: .utf8) ?? "<non-UTF8>",
                "requestID": request.id
            ]
        )
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func replayAcceptedDocuments() throws {
        for documentID in acceptedDocuments.keys.sorted() {
            guard let document = acceptedDocuments[documentID] else { continue }
            try write(
                .replaceDocument(
                    id: "replay-\(UUID().uuidString)",
                    document: document
                )
            )
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            let responseData = Data(line)
            LocalDiagnosticsCenter.shared.log(
                level: .debug,
                category: "arbor.kernel.transport",
                event: "stdout",
                metadata: [
                    "bytes": String(responseData.count),
                    "payload": String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
                ]
            )
            do {
                let response = try decoder.decode(ArborKernelResponse.self, from: responseData)
                guard response.protocolVersion == ArborKernelProtocolVersion.current else {
                    throw ArborKernelSupervisorError.protocolMismatch(response.protocolVersion)
                }
                guard let pendingRequest = pending.removeValue(forKey: response.id) else { continue }
                deliver(response: response, pending: pendingRequest)
            } catch {
                failAllPending(
                    code: "ARBOR9006",
                    message: "The Arbor kernel returned an invalid protocol response: \(error.localizedDescription)."
                )
                stopProcess()
                return
            }
        }
    }

    private func consumeStandardError(_ data: Data) {
        recentStandardError.append(data)
        let maximumBytes = 8 * 1024
        if recentStandardError.count > maximumBytes {
            recentStandardError.removeFirst(recentStandardError.count - maximumBytes)
        }

        standardErrorBuffer.append(data)
        while let newline = standardErrorBuffer.firstIndex(of: 0x0A) {
            let line = Data(standardErrorBuffer[..<newline])
            standardErrorBuffer.removeSubrange(...newline)
            logStandardError(line, event: "stderr")
        }
    }

    private func logStandardError(_ data: Data, event: String) {
        LocalDiagnosticsCenter.shared.log(
            level: .debug,
            category: "arbor.kernel.transport",
            event: event,
            metadata: [
                "bytes": String(data.count),
                "payload": String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            ]
        )
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let status = terminatedProcess.terminationStatus
        let detail = String(data: recentStandardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        LocalDiagnosticsCenter.shared.log(
            level: status == 0 ? .notice : .error,
            category: "arbor.kernel.process",
            event: "terminated",
            metadata: [
                "detail": detail ?? "",
                "status": String(status)
            ]
        )
        stopProcess()
        failAllPending(
            code: "ARBOR9004",
            message: detail?.isEmpty == false
                ? "The Arbor kernel exited with status \(status): \(detail!)"
                : "The Arbor kernel exited with status \(status)."
        )
    }

    private func scheduleTimeout(for requestID: String) {
        queue.asyncAfter(deadline: .now() + configuration.requestTimeout) { [weak self] in
            guard let self, let timedOut = self.pending.removeValue(forKey: requestID) else { return }
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "arbor.kernel.process",
                event: "timeout",
                metadata: [
                    "operation": timedOut.request.operation,
                    "request": self.diagnosticJSON(timedOut.request),
                    "requestID": requestID,
                    "timeoutSeconds": String(self.configuration.requestTimeout)
                ]
            )
            self.deliver(
                response: self.failureResponse(
                    for: timedOut.request,
                    code: "ARBOR9005",
                    message: "The Arbor kernel exceeded the \(self.configuration.requestTimeout)s evaluation limit."
                ),
                pending: timedOut
            )
            self.failAllPending(
                code: "ARBOR9005",
                message: "The Arbor kernel was restarted after another evaluation timed out."
            )
            self.stopProcess()
        }
    }

    private func failureResponse(
        for request: ArborKernelRequest,
        code: String,
        message: String
    ) -> ArborKernelResponse {
        .failure(
            id: request.id,
            operation: request.operation,
            revision: request.document.revision,
            path: request.document.path,
            code: code,
            message: message
        )
    }

    private func failAllPending(code: String, message: String) {
        let requests = pending.values
        pending.removeAll()
        for item in requests {
            deliver(
                response: failureResponse(for: item.request, code: code, message: message),
                pending: item
            )
        }
    }

    private func deliver(response: ArborKernelResponse, pending: PendingRequest) {
        if pending.request.operation == "document/replace",
           response.ok,
           let documentID = pending.request.document.id {
            acceptedDocuments[documentID] = pending.request.document
        }
        logReceive(response, pending: pending)
        deliver(response, completion: pending.completion)
    }

    private func deliverImmediate(
        response: ArborKernelResponse,
        request: ArborKernelRequest,
        startedAt: TimeInterval,
        completion: @escaping Completion
    ) {
        deliver(
            response: response,
            pending: PendingRequest(
                request: request,
                startedAt: startedAt,
                completion: completion
            )
        )
    }

    private func deliver(
        _ response: ArborKernelResponse,
        completion: @escaping Completion
    ) {
        configuration.callbackQueue.async {
            completion(response)
        }
    }

    private func logSend(_ request: ArborKernelRequest) {
        LocalDiagnosticsCenter.shared.log(
            level: .info,
            category: "arbor.kernel",
            event: "send",
            metadata: [
                "requestID": request.id,
                "operation": request.operation,
                "revision": String(request.document.revision),
                "documentID": request.documentID ?? request.document.id ?? "",
                "producerID": request.producerID ?? "",
                "queryID": request.queryID ?? "",
                "payload": diagnosticJSON(request)
            ]
        )
    }

    private func logReceive(_ response: ArborKernelResponse, pending: PendingRequest) {
        let durationMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - pending.startedAt) * 1_000
        )
        let output = response.results.map(\.markdown).joined(separator: "\n")
        let outputData = Data(output.utf8)
        let outputHash = outputData.isEmpty
            ? ""
            : Insecure.SHA1.hash(data: outputData).map { String(format: "%02x", $0) }.joined()
        LocalDiagnosticsCenter.shared.log(
            level: response.ok ? .info : .warning,
            category: "arbor.kernel",
            event: "receive",
            metadata: [
                "requestID": response.id,
                "operation": pending.request.operation,
                "revision": String(response.revision),
                "acceptedRevision": response.acceptedRevision.map(String.init) ?? "",
                "documentID": response.documentID ?? response.document?.id ?? "",
                "durationMs": String(format: "%.1f", durationMilliseconds),
                "factCount": String(response.factCount ?? 0),
                "patchCount": String(response.patches.count),
                "rowCount": String(response.rows.count),
                "viewCount": String(response.views.count),
                "resultCount": String(response.results.count),
                "effectHandler": response.effect?.handler ?? "",
                "capabilityID": response.effect?.capability?.id ?? "",
                "outputBytes": String(outputData.count),
                "outputHash": outputHash,
                "diagnosticCount": String(response.diagnostics.count),
                // The count alone cannot explain a rejection. effect/complete
                // was coming back as an error with one diagnostic and no patch,
                // which is why allowed effects produced no child node — the
                // reason was in text we were discarding.
                "diagnostics": response.diagnostics
                    .prefix(3)
                    .map { "\($0.severity)/\($0.code): \($0.message)" }
                    .joined(separator: " | "),
                "outcome": response.outcome ?? (response.ok ? "ok" : "error"),
                "payload": diagnosticJSON(response)
            ]
        )

        let outcome = response.outcome ?? (response.ok ? "ok" : "error")
        let diagnostics = response.diagnostics
        let operation = response.operation
        Task { @MainActor in
            ArborKernelStatusStore.shared.record(
                operation: operation,
                outcome: outcome,
                diagnostics: diagnostics
            )
        }
    }

    private func stopProcess() {
        let activeProcess = process
        if activeProcess != nil {
            LocalDiagnosticsCenter.shared.log(
                level: .notice,
                category: "arbor.kernel.process",
                event: "stopping",
                metadata: [
                    "pendingRequestCount": String(pending.count),
                    "processIdentifier": activeProcess.map { String($0.processIdentifier) } ?? ""
                ]
            )
        }
        process = nil
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
        if !standardErrorBuffer.isEmpty {
            logStandardError(standardErrorBuffer, event: "stderrPartial")
        }
        standardErrorBuffer.removeAll(keepingCapacity: true)
        recentStandardError.removeAll(keepingCapacity: true)
        activeProcess?.terminationHandler = nil
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
        }
    }

    private func diagnosticJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return text
    }
}

private enum ArborKernelSupervisorError: LocalizedError {
    case protocolMismatch(String)

    var errorDescription: String? {
        switch self {
        case .protocolMismatch(let received):
            return "Expected \(ArborKernelProtocolVersion.current), received \(received)"
        }
    }
}
