import AppKit

/// Main-thread focus registry.
///
/// Phase 1 keeps this intentionally small:
/// - track registered app-owned windows/panels
/// - track per-window desired focus targets
/// - provide a target registration API for later phases
/// - offer reconciliation hooks without yet forcing broad behavioral changes
@MainActor
final class WindowFocusCoordinator {
    static let shared = WindowFocusCoordinator()

    enum WindowKind: String {
        case workspace
        case quickCapturePanel
        case scratchpad
        case auxiliary
    }

    enum TargetID: Hashable, CustomStringConvertible {
        case quickCaptureEditor

        var description: String {
            switch self {
            case .quickCaptureEditor:
                return "quick-capture.editor"
            }
        }
    }

    final class TargetRecord {
        weak var owner: AnyObject?
        let id: TargetID
        let debugName: String
        let requestFocus: () -> Void
        let ownsFirstResponder: (NSWindow) -> Bool
        let isAvailable: () -> Bool

        init(
            id: TargetID,
            debugName: String,
            owner: AnyObject,
            requestFocus: @escaping () -> Void,
            ownsFirstResponder: @escaping (NSWindow) -> Bool,
            isAvailable: @escaping () -> Bool
        ) {
            self.id = id
            self.debugName = debugName
            self.owner = owner
            self.requestFocus = requestFocus
            self.ownsFirstResponder = ownsFirstResponder
            self.isAvailable = isAvailable
        }
    }

    private struct WindowRecord {
        weak var window: NSWindow?
        var identifier: String
        var kind: WindowKind
        var desiredTargetID: TargetID?
        var lastResolvedTargetID: TargetID?
        var isKeyWindow: Bool
        var isMainWindow: Bool
        var lastBecameKeyDate: Date?
        var targets: [TargetID: TargetRecord]
    }

    private var windowsByNumber: [Int: WindowRecord] = [:]
    private(set) var activeWindowIdentifier: String?
    private var pendingReconcileWindowNumbers: Set<Int> = []

    private init() {}

    func registerWindow(_ window: NSWindow, kind: WindowKind, identifier: String) {
        cleanup()

        var record = windowsByNumber[window.windowNumber] ?? WindowRecord(
            window: window,
            identifier: identifier,
            kind: kind,
            desiredTargetID: nil,
            lastResolvedTargetID: nil,
            isKeyWindow: window.isKeyWindow,
            isMainWindow: window.isMainWindow,
            lastBecameKeyDate: window.isKeyWindow ? Date() : nil,
            targets: [:]
        )

        record.window = window
        record.identifier = identifier
        record.kind = kind
        record.isKeyWindow = window.isKeyWindow
        record.isMainWindow = window.isMainWindow
        windowsByNumber[window.windowNumber] = record

        if window.isKeyWindow {
            activeWindowIdentifier = identifier
        }
    }

    func kind(of window: NSWindow?) -> WindowKind? {
        guard let window else { return nil }
        return windowsByNumber[window.windowNumber]?.kind
    }

    func unregisterWindow(_ window: NSWindow) {
        cleanup()
        pendingReconcileWindowNumbers.remove(window.windowNumber)
        guard let removed = windowsByNumber.removeValue(forKey: window.windowNumber) else { return }
        if activeWindowIdentifier == removed.identifier {
            activeWindowIdentifier = nil
        }
    }

    func notifyWindowDidBecomeKey(_ window: NSWindow) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber] else { return }
        record.window = window
        record.isKeyWindow = true
        record.isMainWindow = window.isMainWindow
        record.lastBecameKeyDate = Date()
        windowsByNumber[window.windowNumber] = record
        activeWindowIdentifier = record.identifier
        requestReconcile(window: window, reason: "windowDidBecomeKey")
    }

    func notifyWindowDidResignKey(_ window: NSWindow) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber] else { return }
        record.window = window
        if let actualTargetID = resolvedActualTargetID(in: window, record: record) {
            record.desiredTargetID = actualTargetID
            debugLog("capturedActualTarget window=\(record.identifier) target=\(actualTargetID.description) reason=windowDidResignKey")
        }
        record.isKeyWindow = false
        record.isMainWindow = window.isMainWindow
        windowsByNumber[window.windowNumber] = record

        if activeWindowIdentifier == record.identifier {
            activeWindowIdentifier = nil
        }
    }

    func registerTarget(
        in window: NSWindow,
        targetID: TargetID,
        debugName: String,
        owner: AnyObject,
        requestFocus: @escaping () -> Void,
        ownsFirstResponder: @escaping (NSWindow) -> Bool,
        isAvailable: @escaping () -> Bool = { true }
    ) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber] else { return }

        let existingOwner = record.targets[targetID]?.owner
        record.targets[targetID] = TargetRecord(
            id: targetID,
            debugName: debugName,
            owner: owner,
            requestFocus: requestFocus,
            ownsFirstResponder: ownsFirstResponder,
            isAvailable: isAvailable
        )
        let isNewOrChangedTarget = existingOwner == nil || existingOwner !== owner
        let shouldReconcile = window.isKeyWindow && record.desiredTargetID == targetID && isNewOrChangedTarget
        windowsByNumber[window.windowNumber] = record

        if shouldReconcile {
            requestReconcile(window: window, reason: "targetRegistered.\(targetID.description)")
        }
    }

    func unregisterTarget(in window: NSWindow, targetID: TargetID) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber] else { return }
        record.targets.removeValue(forKey: targetID)
        if record.desiredTargetID == targetID {
            record.desiredTargetID = nil
        }
        if record.lastResolvedTargetID == targetID {
            record.lastResolvedTargetID = nil
        }
        windowsByNumber[window.windowNumber] = record
    }

    func setDesiredTarget(_ targetID: TargetID?, in window: NSWindow, reason: String) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber] else { return }
        record.desiredTargetID = targetID
        windowsByNumber[window.windowNumber] = record
        debugLog("setDesiredTarget window=\(record.identifier) target=\(targetID?.description ?? "nil") reason=\(reason)")
    }

    func desiredTargetID(for window: NSWindow) -> TargetID? {
        cleanup()
        return windowsByNumber[window.windowNumber]?.desiredTargetID
    }

    func requestReconcile(window: NSWindow, reason: String) {
        cleanup()
        let windowNumber = window.windowNumber
        guard windowsByNumber[windowNumber] != nil else { return }
        scheduleReconcile(window: window, reason: reason)
    }

    func reconcile(window: NSWindow, reason: String) {
        cleanup()
        guard var record = windowsByNumber[window.windowNumber],
              let targetID = record.desiredTargetID,
              let target = record.targets[targetID] else {
            return
        }

        guard target.owner != nil else {
            record.targets.removeValue(forKey: targetID)
            if record.lastResolvedTargetID == targetID {
                record.lastResolvedTargetID = nil
            }
            if record.desiredTargetID == targetID {
                record.desiredTargetID = nil
            }
            windowsByNumber[window.windowNumber] = record
            return
        }

        if target.ownsFirstResponder(window) {
            record.lastResolvedTargetID = targetID
            windowsByNumber[window.windowNumber] = record
            return
        }

        guard target.isAvailable() else {
            debugLog("reconcile skipped unavailable target window=\(record.identifier) target=\(target.debugName) reason=\(reason)")
            return
        }

        debugLog("reconcile requestFocus window=\(record.identifier) target=\(target.debugName) reason=\(reason)")
        target.requestFocus()
        record.lastResolvedTargetID = targetID
        windowsByNumber[window.windowNumber] = record
    }

    private func resolvedActualTargetID(in window: NSWindow, record: WindowRecord) -> TargetID? {
        for (targetID, target) in record.targets {
            guard target.owner != nil else { continue }
            if target.ownsFirstResponder(window) {
                return targetID
            }
        }
        return nil
    }

    private func scheduleReconcile(window: NSWindow, reason: String) {
        let windowNumber = window.windowNumber
        guard pendingReconcileWindowNumbers.insert(windowNumber).inserted else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.pendingReconcileWindowNumbers.remove(windowNumber)
            guard let window else { return }
            self.reconcile(window: window, reason: reason)
        }
    }

    private func cleanup() {
        windowsByNumber = windowsByNumber.compactMapValues { record in
            guard let window = record.window else { return nil }

            var cleaned = record
            cleaned.window = window
            cleaned.targets = cleaned.targets.compactMapValues { target in
                guard target.owner != nil else { return nil }
                return target
            }
            return cleaned
        }

        if let activeWindowIdentifier,
           !windowsByNumber.values.contains(where: { $0.identifier == activeWindowIdentifier }) {
            self.activeWindowIdentifier = nil
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[NVModern][Focus] \(message)")
        #endif
    }
}

/// Stateless event-routing checks shared by local monitors and app-level shortcut handling.
enum WindowEventRouting {
    /// Local event monitors created from a particular window subtree must only consume
    /// events that truly belong to that same host window.
    static func shouldHandleLocalEvent(_ event: NSEvent, in hostWindow: NSWindow?) -> Bool {
        guard let hostWindow,
              let eventWindow = event.window,
              eventWindow === hostWindow else {
            return false
        }

        if let modalWindow = NSApp.modalWindow,
           modalWindow !== hostWindow {
            return false
        }

        return hostWindow.isKeyWindow
    }

    /// App-wide shortcut interception should stand down while a modal system window like
    /// `NSOpenPanel` is active so navigation remains inside that modal surface.
    static func shouldHandleApplicationShortcutEvent(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil {
            return false
        }
        return true
    }
}
