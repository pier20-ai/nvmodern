import Foundation

/// Keeps repeated reloads and rapid hotkey presses from flooding notifications.
struct PluginFailureNotificationPolicy {
    private var previousLoadFailures: Set<String> = []
    private var lastRuntimeFailureAt: [String: TimeInterval] = [:]

    mutating func loadFailuresToNotify(_ failures: [String]) -> [String] {
        let current = Set(failures)
        defer { previousLoadFailures = current }
        return current.subtracting(previousLoadFailures).sorted()
    }

    mutating func shouldNotifyRuntimeFailure(method: String, uptime: TimeInterval) -> Bool {
        if let last = lastRuntimeFailureAt[method], uptime - last < 10 {
            return false
        }
        lastRuntimeFailureAt[method] = uptime
        return true
    }
}
