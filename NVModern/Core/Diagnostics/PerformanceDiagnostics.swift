import AppKit
import Foundation

/// Low-overhead lifecycle timing for terminal-launched Debug builds.
///
/// Each line is written to stderr so a manual interaction session can be
/// captured without Instruments. Release builds compile these calls away.
@MainActor
enum PerformanceDiagnostics {
    private struct NewTabTrace {
        let id: UUID
        let trigger: String
        let startedAt: TimeInterval
        var lastMarkAt: TimeInterval
        var windowNumber: Int?
        var waitsForDocument: Bool = false
        var documentPath: String?
    }

    private static var pendingNewTabTrace: NewTabTrace?
    private static var windowNumbersByTabID: [TabID: Int] = [:]
    private static var newTabTracesByWindowNumber: [Int: NewTabTrace] = [:]

    static func beginNewTab(trigger: String, requestedWindowNumber: Int?) {
        #if DEBUG
        if let pendingNewTabTrace {
            emit(
                kind: "new-tab",
                event: "superseded",
                trace: pendingNewTabTrace,
                now: uptime(),
                metadata: [:]
            )
        }

        let now = uptime()
        let trace = NewTabTrace(
            id: UUID(),
            trigger: trigger,
            startedAt: now,
            lastMarkAt: now,
            windowNumber: nil
        )
        pendingNewTabTrace = trace
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard pendingNewTabTrace?.id == trace.id else { return }
            emit(kind: "new-tab", event: "unbound.timeout", trace: trace, now: uptime(), metadata: ["terminal": "true"])
            pendingNewTabTrace = nil
        }
        emit(
            kind: "new-tab",
            event: "begin",
            trace: trace,
            now: now,
            metadata: ["requestedWindow": requestedWindowNumber.map(String.init) ?? "none"]
        )
        #endif
    }

    static func ensureNewTab(trigger: String, requestedWindowNumber: Int?, waitsForDocument: Bool, documentPath: String? = nil) {
        #if DEBUG
        if pendingNewTabTrace == nil {
            beginNewTab(trigger: trigger, requestedWindowNumber: requestedWindowNumber)
        }
        pendingNewTabTrace?.waitsForDocument = waitsForDocument
        pendingNewTabTrace?.documentPath = documentPath
        #endif
    }

    static func associateNewTab(_ tabID: TabID, with window: NSWindow) {
        #if DEBUG
        guard newTabTracesByWindowNumber[window.windowNumber] != nil else { return }
        windowNumbersByTabID[tabID] = window.windowNumber
        #endif
    }

    static func markNewTab(tabID: TabID, event: String, metadata: [String: String] = [:]) {
        #if DEBUG
        guard let number = windowNumbersByTabID[tabID],
              var trace = newTabTracesByWindowNumber[number] else { return }
        let now = uptime()
        emit(kind: "new-tab", event: event, trace: trace, now: now, metadata: metadata)
        trace.lastMarkAt = now
        newTabTracesByWindowNumber[number] = trace
        let matchesDocument = trace.documentPath == nil || trace.documentPath == metadata["path"]
        if matchesDocument && (event == "web.editorFirstFrame"
            || (event == "web.contextReceived" && metadata["kind"] != "text" && metadata["kind"] != "unsupported")) {
            finishNewTab(windowNumber: number, event: event + ".complete")
        }
        #endif
    }

    static func markPendingNewTab(_ event: String, metadata: [String: String] = [:]) {
        #if DEBUG
        guard var trace = pendingNewTabTrace else { return }
        let now = uptime()
        emit(kind: "new-tab", event: event, trace: trace, now: now, metadata: metadata)
        trace.lastMarkAt = now
        pendingNewTabTrace = trace
        #endif
    }

    static func bindPendingNewTab(to window: NSWindow) {
        #if DEBUG
        guard var trace = pendingNewTabTrace else { return }
        pendingNewTabTrace = nil
        trace.windowNumber = window.windowNumber
        let now = uptime()
        emit(
            kind: "new-tab",
            event: "window.bound",
            trace: trace,
            now: now,
            metadata: ["window": String(window.windowNumber)]
        )
        trace.lastMarkAt = now
        newTabTracesByWindowNumber[window.windowNumber] = trace
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard newTabTracesByWindowNumber[window.windowNumber]?.id == trace.id else { return }
            finishNewTab(windowNumber: window.windowNumber, event: "timeout")
        }
        #endif
    }

    static func markNewTab(window: NSWindow, event: String, metadata: [String: String] = [:]) {
        #if DEBUG
        guard var trace = newTabTracesByWindowNumber[window.windowNumber] else { return }
        let now = uptime()
        emit(kind: "new-tab", event: event, trace: trace, now: now, metadata: metadata)
        trace.lastMarkAt = now
        newTabTracesByWindowNumber[window.windowNumber] = trace
        #endif
    }

    static func finishNewTab(window: NSWindow, event: String) {
        #if DEBUG
        if newTabTracesByWindowNumber[window.windowNumber]?.waitsForDocument == true {
            markNewTab(window: window, event: event)
            return
        }
        finishNewTab(windowNumber: window.windowNumber, event: event)
        #endif
    }

    private static func finishNewTab(windowNumber: Int, event: String) {
        #if DEBUG
        guard let trace = newTabTracesByWindowNumber.removeValue(forKey: windowNumber) else { return }
        windowNumbersByTabID = windowNumbersByTabID.filter { $0.value != windowNumber }
        emit(
            kind: "new-tab",
            event: event,
            trace: trace,
            now: uptime(),
            metadata: ["terminal": "true"]
        )
        #endif
    }

    static func appLifecycle(_ event: String, window: NSWindow? = nil) {
        #if DEBUG
        let keyWindow = NSApp.keyWindow
        write([
            "[NVModern][Perf]",
            "kind=app",
            "event=\(event)",
            String(format: "uptimeMs=%.2f", uptime() * 1_000),
            "main=\(Thread.isMainThread)",
            "active=\(NSApp.isActive)",
            "keyWindow=\(keyWindow?.windowNumber.description ?? "none")",
            "window=\(window?.windowNumber.description ?? "none")",
            "visible=\(window?.isVisible.description ?? "n/a")",
            "occlusion=\(window.map { String($0.occlusionState.rawValue) } ?? "n/a")"
        ])
        #endif
    }

    nonisolated static func background(
        kind: String,
        event: String,
        startedAt: TimeInterval? = nil,
        metadata: [String: String] = [:]
    ) {
        #if DEBUG
        let now = uptime()
        var fields = [
            "[NVModern][Perf]",
            "kind=\(kind)",
            "event=\(event)",
            String(format: "uptimeMs=%.2f", now * 1_000),
            "main=\(Thread.isMainThread)"
        ]
        if let startedAt {
            fields.append(String(format: "elapsedMs=%.2f", (now - startedAt) * 1_000))
        }
        fields.append(contentsOf: metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        write(fields)
        #endif
    }

    private static func emit(
        kind: String,
        event: String,
        trace: NewTabTrace,
        now: TimeInterval,
        metadata: [String: String]
    ) {
        var fields = [
            "[NVModern][Perf]",
            "kind=\(kind)",
            "trace=\(trace.id.uuidString)",
            "event=\(event)",
            String(format: "uptimeMs=%.2f", now * 1_000),
            String(format: "elapsedMs=%.2f", (now - trace.startedAt) * 1_000),
            String(format: "deltaMs=%.2f", (now - trace.lastMarkAt) * 1_000),
            "main=\(Thread.isMainThread)",
            "trigger=\(trace.trigger)",
            "window=\(trace.windowNumber.map(String.init) ?? "none")"
        ]
        fields.append(contentsOf: metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        LocalDiagnosticsCenter.shared.log(
            category: "workspace",
            event: "newTab.timing",
            metadata: metadata.merging([
                "trace": trace.id.uuidString,
                "phase": event,
                "trigger": trace.trigger,
                "window": trace.windowNumber.map(String.init) ?? "none",
                "elapsedMs": String(format: "%.2f", (now - trace.startedAt) * 1_000),
                "deltaMs": String(format: "%.2f", (now - trace.lastMarkAt) * 1_000)
            ]) { _, new in new }
        )
        write(fields)
    }

    nonisolated private static func write(_ fields: [String]) {
        guard let data = (fields.joined(separator: " ") + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    nonisolated private static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
