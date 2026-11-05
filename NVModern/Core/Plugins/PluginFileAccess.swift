import Foundation

/// Resolves `nv.files` references and performs the reads and writes.
///
/// Writes deliberately bypass `NotesWorkspaceModel.saveTextNote`: that path
/// marks the write as the app's own, which tells live sync the open editor
/// already has the content. A plugin write is the opposite case — the editor
/// has not seen it — so it lands as an external change and live sync reloads
/// or flags the open tab, the same as an append quick capture always has.
struct PluginFileAccess {
    struct Project: Equatable {
        let name: String
        let rootURL: URL
    }

    enum Reference: Equatable {
        case path(String)
        case project(name: String, path: String)
    }

    var projects: [Project]
    /// The frontmost workspace window's root, else the configured default.
    var activeRootURL: URL
    var fileManager: FileManager = .default

    func resolve(_ reference: Reference) throws -> URL {
        switch reference {
        case .path(let rawPath):
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw ActionError.invalidArguments("File path is empty")
            }
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            if path == "~" || path.hasPrefix("~/") {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            }
            return try url(forRelativePath: path, under: activeRootURL)

        case .project(let name, let path):
            guard let project = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ActionError.invalidArguments(
                    "Unknown project '\(name)'",
                    details: ["project": .string(name)]
                )
            }
            return try url(forRelativePath: path, under: project.rootURL)
        }
    }

    func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func read(_ url: URL) throws -> String? {
        guard exists(url) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String, to url: URL) throws {
        try createParentDirectory(of: url)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read, transform, write. Returns whether the file changed.
    func edit(_ url: URL, transform: (String) throws -> String?) throws -> Bool {
        let current = try read(url) ?? ""
        guard let updated = try transform(current), updated != current else { return false }
        try write(updated, to: url)
        return true
    }

    /// In-place append, so the file keeps its identity for sync clients.
    func append(_ text: String, to url: URL) throws {
        try createParentDirectory(of: url)
        if !exists(url) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    private func url(forRelativePath path: String, under rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        let url = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else {
            throw ActionError.invalidArguments(
                "Path '\(path)' leaves its project root",
                details: ["path": .string(path)]
            )
        }
        return url
    }

    private func createParentDirectory(of url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
