import Foundation

@MainActor
final class WorkspaceActivationTraceCenter {
    enum FinishMode: String {
        case webContextReceived
        case webAttachReady
        case pdfPageInfo
        case pdfAttachReady
        case csvDocumentApplied
        case csvAttachReady
    }

    static let shared = WorkspaceActivationTraceCenter()

    private struct Trace {
        let traceID: UUID
        let tabID: TabID
        let paneID: String
        let trigger: String
        let startedAtUptime: TimeInterval
        var lastMarkUptime: TimeInterval
        var initialPath: String?
        var targetPath: String?
        var targetKind: String?
        var tabTitle: String?
        var expectedFinishMode: FinishMode?
    }

    private struct PendingPointerInput {
        let paneID: String
        let title: String?
        var mouseDownAtUptime: TimeInterval?
        var mouseUpAtUptime: TimeInterval?
    }

    private var tracesByTabID: [TabID: Trace] = [:]
    private var pendingPointerInputsByTabID: [TabID: PendingPointerInput] = [:]

    private init() {}

    func begin(tabID: TabID, paneID: PaneID, trigger: String, title: String?, initialPath: String?) {
        #if DEBUG
        if let existing = tracesByTabID.removeValue(forKey: tabID) {
            let now = currentUptime()
            log(trace: existing, now: now, event: "trace.superseded", details: [:], isTerminal: true)
        }

        let paneDescription = String(describing: paneID)
        let now = currentUptime()
        let recentPointerInput = recentPointerInput(for: tabID, now: now, paneDescription: paneDescription)
        let startedAt = recentPointerInput?.mouseDownAtUptime ?? now
        var trace = Trace(
            traceID: UUID(),
            tabID: tabID,
            paneID: paneDescription,
            trigger: trigger,
            startedAtUptime: startedAt,
            lastMarkUptime: startedAt,
            initialPath: initialPath,
            targetPath: initialPath,
            targetKind: nil,
            tabTitle: title,
            expectedFinishMode: nil
        )

        var beginDetails = compacted([
            "trigger": trigger,
            "pane": paneDescription,
            "title": title,
            "path": initialPath
        ])
        if let recentPointerInput,
           let mouseDownAt = recentPointerInput.mouseDownAtUptime {
            beginDetails["sinceMouseDownMs"] = String(format: "%.2f", (now - mouseDownAt) * 1000)
        }
        if let recentPointerInput,
           let mouseUpAt = recentPointerInput.mouseUpAtUptime {
            beginDetails["sinceMouseUpMs"] = String(format: "%.2f", (now - mouseUpAt) * 1000)
        }

        log(trace: trace, now: now, event: "trace.begin", details: beginDetails, isTerminal: false)
        trace.lastMarkUptime = now
        tracesByTabID[tabID] = trace
        #endif
    }

    func mark(tabID: TabID, event: String, details: [String: String] = [:]) {
        #if DEBUG
        guard var trace = tracesByTabID[tabID] else { return }
        let now = currentUptime()
        log(trace: trace, now: now, event: event, details: details, isTerminal: false)
        trace.lastMarkUptime = now
        tracesByTabID[tabID] = trace
        #endif
    }

    func mark(path: String, event: String, details: [String: String] = [:]) {
        #if DEBUG
        for tabID in matchingTabIDs(forPath: path) {
            mark(tabID: tabID, event: event, details: details)
        }
        #endif
    }

    func updateTarget(tabID: TabID, path: String?, kind: String?) {
        #if DEBUG
        guard var trace = tracesByTabID[tabID] else { return }
        trace.targetPath = path ?? trace.targetPath
        trace.targetKind = kind ?? trace.targetKind
        let now = currentUptime()
        log(trace: trace, now: now, event: "trace.target", details: compacted([
            "path": trace.targetPath,
            "kind": trace.targetKind
        ]), isTerminal: false)
        trace.lastMarkUptime = now
        tracesByTabID[tabID] = trace
        #endif
    }

    func expect(tabID: TabID, finishMode: FinishMode) {
        #if DEBUG
        guard var trace = tracesByTabID[tabID] else { return }
        trace.expectedFinishMode = finishMode
        let now = currentUptime()
        log(trace: trace, now: now, event: "trace.expect", details: ["finishMode": finishMode.rawValue], isTerminal: false)
        trace.lastMarkUptime = now
        tracesByTabID[tabID] = trace
        #endif
    }

    func finishIfExpected(tabID: TabID, mode: FinishMode, event: String, details: [String: String] = [:]) {
        #if DEBUG
        guard let trace = tracesByTabID[tabID], trace.expectedFinishMode == mode else { return }
        finish(tabID: tabID, event: event, details: details)
        #endif
    }

    func finishIfExpected(path: String, mode: FinishMode, event: String, details: [String: String] = [:]) {
        #if DEBUG
        for tabID in matchingTabIDs(forPath: path) {
            finishIfExpected(tabID: tabID, mode: mode, event: event, details: details)
        }
        #endif
    }

    func finish(tabID: TabID, event: String, details: [String: String] = [:]) {
        #if DEBUG
        guard let trace = tracesByTabID.removeValue(forKey: tabID) else { return }
        let now = currentUptime()
        log(trace: trace, now: now, event: event, details: details, isTerminal: true)
        #endif
    }

    func abandon(tabID: TabID, reason: String) {
        #if DEBUG
        finish(tabID: tabID, event: "trace.abandon", details: ["reason": reason])
        #endif
    }

    private func matchingTabIDs(forPath path: String) -> [TabID] {
        tracesByTabID.compactMap { tabID, trace in
            if trace.targetPath == path || trace.initialPath == path {
                return tabID
            }
            return nil
        }
    }

    private func currentUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func recentPointerInput(for tabID: TabID, now: TimeInterval, paneDescription: String) -> PendingPointerInput? {
        guard let pending = pendingPointerInputsByTabID[tabID] else { return nil }
        guard pending.paneID == paneDescription else { return nil }
        guard let mouseDownAt = pending.mouseDownAtUptime else { return nil }
        guard now - mouseDownAt <= 3.0 else { return nil }
        return pending
    }

    private func log(trace: Trace, now: TimeInterval, event: String, details: [String: String], isTerminal: Bool) {
        let elapsedMs = (now - trace.startedAtUptime) * 1000
        let deltaMs = (now - trace.lastMarkUptime) * 1000
        var mergedDetails = details
        if mergedDetails["trigger"] == nil {
            mergedDetails["trigger"] = trace.trigger
        }
        if mergedDetails["title"] == nil, let title = trace.tabTitle, !title.isEmpty {
            mergedDetails["title"] = title
        }
        if mergedDetails["path"] == nil, let path = trace.targetPath ?? trace.initialPath, !path.isEmpty {
            mergedDetails["path"] = path
        }
        if mergedDetails["kind"] == nil, let kind = trace.targetKind, !kind.isEmpty {
            mergedDetails["kind"] = kind
        }
        if mergedDetails["finishMode"] == nil, let finishMode = trace.expectedFinishMode?.rawValue, !finishMode.isEmpty {
            mergedDetails["finishMode"] = finishMode
        }
        let detailsText = mergedDetails
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = detailsText.isEmpty ? "" : " \(detailsText)"
        let terminal = isTerminal ? " terminal=true" : ""
        print(
            String(
                format: "[NVModern][ActivationTrace] trace=%@ event=%@ elapsedMs=%.2f deltaMs=%.2f%@%@",
                trace.traceID.uuidString,
                event,
                elapsedMs,
                deltaMs,
                terminal,
                suffix
            )
        )
    }

    private func compacted(_ dictionary: [String: String?]) -> [String: String] {
        dictionary.reduce(into: [:]) { result, entry in
            if let value = entry.value, !value.isEmpty {
                result[entry.key] = value
            }
        }
    }
}
