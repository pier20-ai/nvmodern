import Foundation

enum WorkspaceNoteFileReadError: Error, Equatable {
    case invalidPath
    case notFound
    case notAFile
    case unreadable
}

enum WorkspaceNoteFileRead {
    static let defaultMaxBytes = 48 * 1024
    static let absoluteMaxBytes = 256 * 1024

    struct Result: Equatable {
        var relativePath: String
        var title: String
        var body: String
        var byteCount: Int
        var truncated: Bool
    }

    static func clampMaxBytes(_ value: Int?) -> Int {
        let requested = value ?? defaultMaxBytes
        return min(max(requested, 1), absoluteMaxBytes)
    }

    static func fileURL(relativePath: String, projectRoot: URL) -> URL? {
        guard let normalized = normalizedRelativePath(relativePath) else {
            return nil
        }

        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(normalized).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isPath(resolved.path, withinRoot: root.path) else {
            return nil
        }
        return candidate
    }

    static func read(
        relativePath: String,
        projectRoot: URL,
        maxBytes: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> Result {
        guard let normalized = normalizedRelativePath(relativePath),
              let url = fileURL(relativePath: normalized, projectRoot: projectRoot) else {
            throw WorkspaceNoteFileReadError.invalidPath
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceNoteFileReadError.notFound
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceNoteFileReadError.notAFile
        }

        let limit = clampMaxBytes(maxBytes)
        let attributes: [FileAttributeKey: Any]
        let data: Data
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw WorkspaceNoteFileReadError.unreadable
        }

        let reportedByteCount = (attributes[.size] as? NSNumber)?.intValue ?? data.count
        let byteCount = max(reportedByteCount, data.count)
        let (body, prefixWasTruncated) = decodeUTF8(data, maxBytes: limit)
        let truncated = prefixWasTruncated || byteCount > limit
        let title = url.lastPathComponent
        return Result(
            relativePath: normalized,
            title: title,
            body: body,
            byteCount: byteCount,
            truncated: truncated
        )
    }

    static func normalizedRelativePath(_ path: String) -> String? {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        guard !normalized.isEmpty else { return nil }
        guard !normalized.hasPrefix("../"), !normalized.contains("/../") else { return nil }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") {
            return nil
        }

        return components.map(String.init).joined(separator: "/")
    }

    private static func isPath(_ path: String, withinRoot rootPath: String) -> Bool {
        if path == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    private static func decodeUTF8(_ data: Data, maxBytes: Int) -> (String, Bool) {
        let truncated = data.count > maxBytes
        let slice = truncated ? utf8Prefix(data, maxBytes: maxBytes) : data
        if let text = String(data: slice, encoding: .utf8) {
            return (text, truncated)
        }
        if let text = String(data: slice, encoding: .unicode) {
            return (text, truncated)
        }
        if let text = String(data: slice, encoding: .ascii) {
            return (text, truncated)
        }
        return (String(decoding: slice, as: UTF8.self), truncated)
    }

    private static func utf8Prefix(_ data: Data, maxBytes: Int) -> Data {
        var slice = data.prefix(maxBytes)
        while !slice.isEmpty, String(data: slice, encoding: .utf8) == nil {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}
