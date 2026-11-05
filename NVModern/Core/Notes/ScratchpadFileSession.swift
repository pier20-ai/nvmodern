import Foundation

/// A scratchpad's disk baseline and local buffer. Checking the baseline before
/// every write also catches changes before the filesystem watcher delivers them.
final class ScratchpadFileSession {
    enum Failure: LocalizedError {
        case conflict
        var errorDescription: String? {
            "The scratchpad file changed externally while local edits were pending. Local edits have been retained."
        }
    }

    let fileURL: URL
    private(set) var body: String
    private var baseline: Data
    private(set) var hasConflict = false
    var isDirty: Bool { Data(body.utf8) != baseline }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            // Never truncate a file created concurrently with opening this window.
            try Data().write(to: fileURL, options: .withoutOverwriting)
        }
        baseline = try Data(contentsOf: fileURL)
        guard let text = String(data: baseline, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        body = text
    }

    func update(_ text: String) { body = text }

    /// Returns true only when a clean buffer was replaced by newer disk content.
    @discardableResult
    func refresh() throws -> Bool {
        guard !hasConflict else { throw Failure.conflict }
        let disk: Data
        do { disk = try Data(contentsOf: fileURL) }
        catch {
            if isDirty { hasConflict = true }
            throw error
        }
        guard disk != baseline else { return false }
        guard !isDirty else {
            hasConflict = true
            throw Failure.conflict
        }
        guard let text = String(data: disk, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        baseline = disk
        body = text
        return true
    }

    /// Explicitly discard local edits only after the user chooses the disk version.
    func reloadDiscardingLocalEdits() throws {
        let disk = try Data(contentsOf: fileURL)
        guard let text = String(data: disk, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        baseline = disk
        body = text
        hasConflict = false
    }

    /// Explicit user authorization to replace the disk version, including
    /// recreating a deleted file. A failed write keeps the local buffer blocked.
    func overwriteWithLocalEdits() throws {
        let data = Data(body.utf8)
        try data.write(to: fileURL, options: .atomic)
        baseline = data
        hasConflict = false
    }

    func save() throws {
        guard !hasConflict else { throw Failure.conflict }
        guard isDirty else { return }
        _ = try refresh()
        let data = Data(body.utf8)
        try data.write(to: fileURL, options: .atomic)
        baseline = data
    }
}
