import Foundation
import OSLog

private func NVModernHandleUncaughtException(_ exception: NSException) {
    LocalDiagnosticsCenter.shared.recordUncaughtException(exception)
}

enum LocalDiagnosticLevel: String, Codable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .warning:
            return .error
        case .error:
            return .error
        case .fault:
            return .fault
        }
    }
}

private struct LocalDiagnosticEntry: Codable {
    var id: UUID
    var timestamp: Date
    var runID: String
    var processIdentifier: Int32
    var level: LocalDiagnosticLevel
    var category: String
    var event: String
    var metadata: [String: String]
    var thread: String
    var uptimeMilliseconds: Double
}

private struct LocalDiagnosticRunState: Codable {
    var runID: String
    var processIdentifier: Int32
    var launchDate: Date
    var cleanExit: Bool
    var terminationDate: Date?
}

final class LocalDiagnosticsCenter {
    static let shared = LocalDiagnosticsCenter()

    private let logger = Logger(subsystem: "nvModern", category: "diagnostics")
    private let queue = DispatchQueue(label: "nvmodern.local-diagnostics", qos: .utility)
    private let watchdogQueue = DispatchQueue(label: "nvmodern.local-diagnostics.watchdog", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    // Arbor diagnostics include complete request and response payloads so one
    // failed run can be reconstructed without a second logging system.
    private let maxBreadcrumbBytes = 16 * 1024 * 1024
    private let maxBreadcrumbLines = 10_000
    private let mainThreadWatchdogInterval: TimeInterval = 2
    private let mainThreadWatchdogThreshold: TimeInterval = 8
    private let mainThreadWatchdogRepeatInterval: TimeInterval = 30

    private let diagnosticsDirectoryURL: URL
    private let breadcrumbsURL: URL
    private let runStateURL: URL
    private let lastExceptionURL: URL

    private var currentRunID = "unknown"
    private var installedExceptionHandler = false
    private var mainThreadWatchdogTimer: DispatchSourceTimer?
    private var mainThreadWatchdogPendingPingStartedAt: TimeInterval?
    private var mainThreadWatchdogLastHeartbeatAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var mainThreadWatchdogLastReportAt: TimeInterval?
    private var mainThreadWatchdogIsUnresponsive = false

    private init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        diagnosticsDirectoryURL = applicationSupportURL
            .appendingPathComponent("nvModern", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        breadcrumbsURL = diagnosticsDirectoryURL.appendingPathComponent("breadcrumbs.jsonl", isDirectory: false)
        runStateURL = diagnosticsDirectoryURL.appendingPathComponent("run-state.json", isDirectory: false)
        lastExceptionURL = diagnosticsDirectoryURL.appendingPathComponent("last-exception.json", isDirectory: false)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var diagnosticsPath: String {
        diagnosticsDirectoryURL.path
    }

    func install() {
        installExceptionHandlerIfNeeded()
        markLaunchStarted()
        startMainThreadWatchdogIfNeeded()
    }

    func markLaunchStarted() {
        queue.sync {
            ensureDiagnosticsDirectory()

            let previousRunState = loadRunState()
            let nextRunID = UUID().uuidString
            currentRunID = nextRunID

            if let previousRunState, previousRunState.cleanExit == false {
                appendBreadcrumbSync(
                    level: .fault,
                    category: "app",
                    event: "previousRunUncleanExit",
                    metadata: [
                        "previousRunID": previousRunState.runID,
                        "previousProcessIdentifier": String(previousRunState.processIdentifier),
                        "previousLaunchDate": iso8601String(previousRunState.launchDate)
                    ]
                )
            }

            saveRunState(
                LocalDiagnosticRunState(
                    runID: nextRunID,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    launchDate: Date(),
                    cleanExit: false,
                    terminationDate: nil
                )
            )

            appendBreadcrumbSync(
                level: .info,
                category: "app",
                event: "launchStarted",
                metadata: [
                    "diagnosticsPath": diagnosticsDirectoryURL.path,
                    "runID": nextRunID
                ]
            )
        }
    }

    func markLaunchEndedCleanly() {
        stopMainThreadWatchdog()
        queue.sync {
            ensureDiagnosticsDirectory()

            let runState = LocalDiagnosticRunState(
                runID: currentRunID,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                launchDate: loadRunState()?.launchDate ?? Date(),
                cleanExit: true,
                terminationDate: Date()
            )
            saveRunState(runState)

            appendBreadcrumbSync(
                level: .info,
                category: "app",
                event: "launchEndedCleanly",
                metadata: ["runID": currentRunID]
            )
        }
    }

    func log(
        level: LocalDiagnosticLevel = .info,
        category: String,
        event: String,
        metadata: [String: String] = [:]
    ) {
        let compactMetadata = metadata
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
        let metadataText = compactMetadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let message = metadataText.isEmpty ? "[\(category)] \(event)" : "[\(category)] \(event) \(metadataText)"
        logger.log(level: level.osLogType, "\(message, privacy: .public)")

        queue.async {
            self.ensureDiagnosticsDirectory()
            self.appendBreadcrumbSync(level: level, category: category, event: event, metadata: Dictionary(uniqueKeysWithValues: compactMetadata))
        }
    }

    func recordUncaughtException(_ exception: NSException) {
        let metadata: [String: String] = [
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
            "stack": exception.callStackSymbols.joined(separator: "\n")
        ]

        logger.fault("[app] uncaughtException name=\(exception.name.rawValue, privacy: .public) reason=\(exception.reason ?? "", privacy: .public)")

        queue.sync {
            ensureDiagnosticsDirectory()
            appendBreadcrumbSync(level: .fault, category: "app", event: "uncaughtException", metadata: metadata)
            if let data = try? encoder.encode(metadata) {
                try? data.write(to: lastExceptionURL, options: .atomic)
            }
        }
    }

    private func installExceptionHandlerIfNeeded() {
        guard !installedExceptionHandler else { return }
        installedExceptionHandler = true
        NSSetUncaughtExceptionHandler(NVModernHandleUncaughtException)
    }

    private func startMainThreadWatchdogIfNeeded() {
        watchdogQueue.async {
            guard self.mainThreadWatchdogTimer == nil else { return }

            self.mainThreadWatchdogLastHeartbeatAt = ProcessInfo.processInfo.systemUptime

            let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
            timer.schedule(
                deadline: .now() + self.mainThreadWatchdogInterval,
                repeating: self.mainThreadWatchdogInterval,
                leeway: .milliseconds(250)
            )
            timer.setEventHandler { [weak self] in
                self?.pollMainThreadWatchdog()
            }
            self.mainThreadWatchdogTimer = timer
            timer.resume()

            self.log(
                level: .info,
                category: "app.watchdog",
                event: "mainThreadWatchdogStarted",
                metadata: [
                    "intervalSeconds": String(format: "%.0f", self.mainThreadWatchdogInterval),
                    "thresholdSeconds": String(format: "%.0f", self.mainThreadWatchdogThreshold)
                ]
            )
        }
    }

    private func stopMainThreadWatchdog() {
        watchdogQueue.async {
            self.mainThreadWatchdogTimer?.cancel()
            self.mainThreadWatchdogTimer = nil
            self.mainThreadWatchdogPendingPingStartedAt = nil
            self.mainThreadWatchdogIsUnresponsive = false
        }
    }

    private func pollMainThreadWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime

        guard let pendingPingStartedAt = mainThreadWatchdogPendingPingStartedAt else {
            mainThreadWatchdogPendingPingStartedAt = now
            DispatchQueue.main.async { [weak self] in
                self?.recordMainThreadWatchdogHeartbeat()
            }
            return
        }

        let blockedSeconds = now - pendingPingStartedAt
        guard blockedSeconds >= mainThreadWatchdogThreshold else { return }

        let shouldReport = !mainThreadWatchdogIsUnresponsive
            || mainThreadWatchdogLastReportAt.map { now - $0 >= mainThreadWatchdogRepeatInterval } != false
        guard shouldReport else { return }

        mainThreadWatchdogIsUnresponsive = true
        mainThreadWatchdogLastReportAt = now
        log(
            level: .fault,
            category: "app.watchdog",
            event: "mainThreadUnresponsive",
            metadata: [
                "blockedSeconds": String(format: "%.1f", blockedSeconds),
                "lastHeartbeatAgeSeconds": String(format: "%.1f", now - mainThreadWatchdogLastHeartbeatAt)
            ]
        )
    }

    private func recordMainThreadWatchdogHeartbeat() {
        let heartbeatAt = ProcessInfo.processInfo.systemUptime
        watchdogQueue.async {
            let pendingPingStartedAt = self.mainThreadWatchdogPendingPingStartedAt
            self.mainThreadWatchdogPendingPingStartedAt = nil
            self.mainThreadWatchdogLastHeartbeatAt = heartbeatAt

            if self.mainThreadWatchdogIsUnresponsive {
                let blockedSeconds = pendingPingStartedAt.map { heartbeatAt - $0 } ?? 0
                self.mainThreadWatchdogIsUnresponsive = false
                self.log(
                    level: .notice,
                    category: "app.watchdog",
                    event: "mainThreadResponsiveAgain",
                    metadata: ["blockedSeconds": String(format: "%.1f", blockedSeconds)]
                )
            }
        }
    }

    private func appendBreadcrumbSync(
        level: LocalDiagnosticLevel,
        category: String,
        event: String,
        metadata: [String: String]
    ) {
        let entry = LocalDiagnosticEntry(
            id: UUID(),
            timestamp: Date(),
            runID: currentRunID,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            level: level,
            category: category,
            event: event,
            metadata: metadata,
            thread: Thread.isMainThread ? "main" : (Thread.current.name?.isEmpty == false ? Thread.current.name! : "background"),
            uptimeMilliseconds: ProcessInfo.processInfo.systemUptime * 1000
        )

        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: breadcrumbsURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: breadcrumbsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? data.write(to: breadcrumbsURL, options: .atomic)
            }
        } else {
            try? data.write(to: breadcrumbsURL, options: .atomic)
        }

        pruneBreadcrumbsIfNeeded()
    }

    private func pruneBreadcrumbsIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: breadcrumbsURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              fileSize > maxBreadcrumbBytes,
              let data = try? Data(contentsOf: breadcrumbsURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let trimmed = lines.suffix(maxBreadcrumbLines).joined(separator: "\n")
        guard let trimmedData = (trimmed + "\n").data(using: .utf8) else { return }
        try? trimmedData.write(to: breadcrumbsURL, options: .atomic)
    }

    private func ensureDiagnosticsDirectory() {
        try? FileManager.default.createDirectory(at: diagnosticsDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadRunState() -> LocalDiagnosticRunState? {
        guard let data = try? Data(contentsOf: runStateURL) else { return nil }
        return try? decoder.decode(LocalDiagnosticRunState.self, from: data)
    }

    private func saveRunState(_ state: LocalDiagnosticRunState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: runStateURL, options: .atomic)
    }

    private func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
