import Foundation

struct PendingMarkdownJump: Equatable, Sendable {
    var heading: String?
    var line: Int?
}

enum NVModernURLScheme {
    static let scheme = "nvmodern"

    enum Link: Equatable, Sendable {
        /// `path` is workspace-relative (the portable, shared-link form) or
        /// absolute for legacy links and files outside any project. Relative
        /// paths resolve against each known workspace root, first match wins.
        case file(path: String, line: Int?, heading: String?)
    }

    enum ParseError: Error, Equatable, Sendable {
        case invalidScheme
        case unknownRoute(String)
        case relativeFilePath
    }

    static func parse(_ raw: String) -> Result<Link, ParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stripped = stripScheme(trimmed) else {
            return .failure(.invalidScheme)
        }

        let parts = splitQuery(stripped)
        let routeSplit = splitRoute(parts.route)
        let route = routeSplit.route.lowercased()
        let query = parseQuery(parts.query)

        switch route {
        case "file":
            let decoded = collapseLeadingSlashes(percentDecode(routeSplit.remainder))
            guard !decoded.isEmpty, decoded != "/" else {
                return .failure(.relativeFilePath)
            }
            // Both shapes are accepted: a leading slash is a legacy absolute
            // path; anything else is workspace-relative and resolved against
            // each known workspace root by the router. Unknown query keys
            // (such as the retired `workspace`) are ignored.
            let line = query["line"].flatMap { Int($0) }
            let heading = query["heading"].flatMap(trimmedNonEmpty)
            return .success(.file(path: decoded, line: line, heading: heading))

        default:
            return .failure(.unknownRoute(route.isEmpty ? stripped : route))
        }
    }

    /// Rebuild a parseable string from a Foundation `URL`. Host/path accessors
    /// turn `file` into the host, so callers must not parse those directly.
    static func rawString(from url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host == "file" {
            let path = url.path.isEmpty ? "/" : url.path
            var raw = "\(scheme)://file/\(path)"
            if let query = url.query, !query.isEmpty {
                raw += "?\(query)"
            }
            return raw
        }
        return url.absoluteString
    }

    static func fileLinkURL(path: String, line: Int? = nil, heading: String? = nil) -> String {
        let encodedPath = percentEncodePath(path)
        var url = "\(scheme)://file/\(encodedPath)"
        var query: [String] = []
        if let line {
            query.append("line=\(line)")
        }
        if let heading, let encoded = percentEncodeQueryValue(heading) {
            query.append("heading=\(encoded)")
        }
        if !query.isEmpty {
            url += "?" + query.joined(separator: "&")
        }
        return url
    }

    /// Workspace-relative link — the form Copy Link emits for workspace
    /// notes. The path resolves against each known workspace root when the
    /// link is opened, so it survives workspace moves and keeps working on
    /// other machines whose roots differ (shared iCloud Drive setups). Use
    /// `fileLinkURL(path:)` for files outside any project.
    static func fileLinkURL(relativePath: String, line: Int? = nil, heading: String? = nil) -> String {
        // Keep slashes literal so the link stays readable; each segment is
        // percent-encoded individually.
        let encodedSegments = relativePath
            .split(separator: "/")
            .map { percentEncodePath(String($0)) }
            .joined(separator: "/")
        var url = "\(scheme)://file/\(encodedSegments)"
        var query: [String] = []
        if let line {
            query.append("line=\(line)")
        }
        if let heading, let encoded = percentEncodeQueryValue(heading) {
            query.append("heading=\(encoded)")
        }
        if !query.isEmpty {
            url += "?" + query.joined(separator: "&")
        }
        return url
    }

    static func isAncestor(_ root: String, of path: String) -> Bool {
        let normalizedRoot = normalizePath(root)
        let normalizedPath = normalizePath(path)
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    static func relativePath(of path: String, under root: String) -> String? {
        guard isAncestor(root, of: path) else { return nil }
        let normalizedRoot = normalizePath(root)
        let normalizedPath = normalizePath(path)
        if normalizedPath == normalizedRoot { return "" }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }

    static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func stripScheme(_ raw: String) -> String? {
        let prefix = "\(scheme)://"
        guard raw.lowercased().hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }

    private static func splitQuery(_ raw: String) -> (route: String, query: String?) {
        guard let index = raw.firstIndex(of: "?") else {
            return (raw, nil)
        }
        return (String(raw[..<index]), String(raw[raw.index(after: index)...]))
    }

    private static func splitRoute(_ raw: String) -> (route: String, remainder: String) {
        guard let index = raw.firstIndex(of: "/") else {
            return (raw, "")
        }
        return (String(raw[..<index]), String(raw[raw.index(after: index)...]))
    }

    private static func parseQuery(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var values: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecode(String(parts[0]))
            guard !key.isEmpty else { continue }
            let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
            values[key] = value
        }
        return values
    }

    private static func percentDecode(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }

    private static func collapseLeadingSlashes(_ path: String) -> String {
        var collapsed = path
        while collapsed.hasPrefix("//") {
            collapsed = String(collapsed.dropFirst())
        }
        return collapsed
    }

    private static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static func percentEncodeQueryValue(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
