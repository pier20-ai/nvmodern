import Foundation
import TOMLKit
import Yams

@MainActor
final class MarkdownActionContentSurface: ActionContentSurface {
    let capabilities = ActionContentSurfaceCapabilities(
        supportsStructuralQueries: true,
        supportsSemanticQueries: false,
        supportsJoins: false,
        supportsWrites: false
    )

    func fetchNode(at address: ActionContentAddress, target: ActionTarget) async throws -> ActionContentNode {
        let rootURL = resolveRootURL(for: target)
        let nodes = try scanDocument(relativePath: address.documentPath, rootURL: rootURL)
        if let match = nodes.first(where: { nodeMatchesAddress($0, address: address) }) {
            return match
        }

        throw ActionError.targetNotFound(
            "Could not resolve content node in document",
            details: [
                "documentPath": .string(address.documentPath),
                "nodeKind": .string(address.nodeKind.rawValue)
            ]
        )
    }

    func headingSubtree(
        documentPath: String,
        headingSlug: String,
        projection: ActionContentProjection?,
        includeHeading: Bool,
        target: ActionTarget
    ) async throws -> ActionContentQueryResult {
        let rootURL = resolveRootURL(for: target)
        let nodes = try scanDocument(relativePath: documentPath, rootURL: rootURL)

        guard let headingNode = nodes.first(where: {
            $0.address.nodeKind == .heading && $0.address.headingSlug == headingSlug
        }) else {
            throw ActionError.targetNotFound(
                "Could not find heading subtree root",
                details: [
                    "documentPath": .string(documentPath),
                    "headingSlug": .string(headingSlug)
                ]
            )
        }

        let headingLevel = headingNode.attributes["level"]?.intValue ?? 1
        let headingStartLine = headingNode.address.range?.startLine ?? 0

        let nextBoundaryLine = nodes
            .filter { $0.address.nodeKind == .heading }
            .filter { ($0.address.range?.startLine ?? 0) > headingStartLine }
            .filter { ($0.attributes["level"]?.intValue ?? Int.max) <= headingLevel }
            .compactMap { $0.address.range?.startLine }
            .min()

        let subtreeNodes = nodes.filter { node in
            guard let startLine = node.address.range?.startLine else { return false }
            if startLine < headingStartLine { return false }
            if startLine == headingStartLine { return includeHeading && node.address == headingNode.address }
            if let boundary = nextBoundaryLine {
                return startLine < boundary
            }
            return true
        }

        let records = subtreeNodes.map { project(node: $0, projection: projection) }
        return ActionContentQueryResult(records: records, diagnostics: [])
    }

    func backlinks(
        to targetPath: String,
        projection: ActionContentProjection?,
        includeTransclusions: Bool,
        limit: Int?,
        target: ActionTarget
    ) async throws -> ActionContentQueryResult {
        let rootURL = resolveRootURL(for: target)
        let documents = try allTextDocumentPaths(rootURL: rootURL)
        let candidates = backlinkCandidates(for: targetPath)

        var records: [ActionContentRecord] = []
        for relativePath in documents {
            let nodes = try scanDocument(relativePath: relativePath, rootURL: rootURL)
            for node in nodes where node.address.nodeKind == .wikilink {
                guard let linkedTarget = node.attributes["target"]?.stringValue else { continue }
                guard candidates.contains(normalizeLinkTarget(linkedTarget)) else { continue }
                if !includeTransclusions, node.attributes["isTransclusion"]?.boolValue == true {
                    continue
                }
                records.append(project(node: node, projection: projection))
            }
        }

        if let limit, limit >= 0, records.count > limit {
            records = Array(records.prefix(limit))
        }

        return ActionContentQueryResult(records: records, diagnostics: [])
    }

    func runQuery(_ query: ActionContentQuery, target: ActionTarget) async throws -> ActionContentQueryResult {
        let rootURL = resolveRootURL(for: target)
        let documents = try resolveDocumentPaths(for: query.selector, rootURL: rootURL)

        var records: [ActionContentRecord] = []
        var diagnostics: [String] = []

        if query.semantic != nil {
            diagnostics.append("semantic queries are not implemented yet")
        }

        if query.join != nil {
            diagnostics.append("joins are not implemented yet")
        }

        for relativePath in documents {
            let nodes = try scanDocument(relativePath: relativePath, rootURL: rootURL)
            for node in nodes where matches(selector: query.selector, node: node) {
                records.append(project(node: node, projection: query.projection))
            }
        }

        if let limit = query.limit, limit >= 0, records.count > limit {
            records = Array(records.prefix(limit))
        }

        return ActionContentQueryResult(records: records, diagnostics: diagnostics)
    }

    private func resolveRootURL(for target: ActionTarget) -> URL {
        ActionProjectPathResolver.resolveRootURL(for: target)
    }

    private func resolveDocumentPaths(for selector: ActionContentSelector, rootURL: URL) throws -> [String] {
        if let documentPath = selector.documentPath?.trimmingCharacters(in: .whitespacesAndNewlines), !documentPath.isEmpty {
            return [normalizeRelativePath(documentPath)]
        }

        return try allTextDocumentPaths(rootURL: rootURL)
    }

    private func allTextDocumentPaths(rootURL: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        )

        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey])
            if values?.isHidden == true { continue }
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.textExtensions.contains(ext) || ext.isEmpty else { continue }
            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            paths.append(relative)
        }

        return paths.sorted()
    }

    private func scanDocument(relativePath: String, rootURL: URL) throws -> [ActionContentNode] {
        let normalizedPath = normalizeRelativePath(relativePath)
        let url = rootURL.appendingPathComponent(normalizedPath)
        guard let text = loadFullText(from: url) else {
            throw ActionError.targetNotFound(
                "Could not read document for content scan",
                details: ["documentPath": .string(normalizedPath)]
            )
        }

        var nodes: [ActionContentNode] = []
        let title = url.deletingPathExtension().lastPathComponent
        let fullLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        nodes.append(
            ActionContentNode(
                address: ActionContentAddress(documentPath: normalizedPath, nodeKind: .document, identifier: "document"),
                title: title,
                text: text,
                attributes: [
                    "documentPath": .string(normalizedPath),
                    "absolutePath": .string(url.path),
                    "title": .string(title)
                ]
            )
        )

        var startIndex = 0
        if let frontmatter = parseFrontmatter(lines: fullLines, documentPath: normalizedPath) {
            nodes.append(frontmatter.node)
            startIndex = frontmatter.endLineIndex + 1
        }

        var isInCodeFence = false
        var codeFenceStartLine: Int?
        var codeFenceLanguage: String?
        var codeFenceLines: [String] = []

        for lineIndex in startIndex..<fullLines.count {
            let line = fullLines[lineIndex]
            let lineNumber = lineIndex + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let fenceLanguage = parseCodeFence(line: line) {
                if isInCodeFence, let start = codeFenceStartLine {
                    nodes.append(
                        ActionContentNode(
                            address: ActionContentAddress(
                                documentPath: normalizedPath,
                                nodeKind: .codeFence,
                                identifier: "code-fence-\(start)",
                                range: ActionTextRange(startLine: start, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                            ),
                            title: codeFenceLanguage,
                            text: codeFenceLines.joined(separator: "\n"),
                            attributes: [
                                "language": ActionValue(codeFenceLanguage),
                                "startLine": .int(start),
                                "endLine": .int(lineNumber)
                            ]
                        )
                    )
                    codeFenceLines.removeAll()
                    codeFenceStartLine = nil
                    codeFenceLanguage = nil
                    isInCodeFence = false
                } else {
                    isInCodeFence = true
                    codeFenceStartLine = lineNumber
                    codeFenceLanguage = fenceLanguage
                    codeFenceLines.removeAll()
                }
                continue
            }

            if isInCodeFence {
                codeFenceLines.append(line)
                continue
            }

            if let heading = parseHeading(line: line) {
                let slug = slugify(heading.text)
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .heading,
                            identifier: "heading-\(lineNumber)",
                            headingSlug: slug,
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: heading.text,
                        text: heading.text,
                        attributes: [
                            "level": .int(heading.level),
                            "slug": .string(slug)
                        ]
                    )
                )
            }

            if let task = parseTaskItem(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .taskItem,
                            identifier: "task-\(lineNumber)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: task.text,
                        text: task.text,
                        attributes: [
                            "state": .string(task.state),
                            "marker": .string(task.marker)
                        ]
                    )
                )
            } else if let listItem = parseListItem(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .listItem,
                            identifier: "list-item-\(lineNumber)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: listItem,
                        text: listItem,
                        attributes: [:]
                    )
                )
            }

            for link in parseWikilinks(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .wikilink,
                            identifier: "wikilink-\(lineNumber)-\(link.target)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: link.target,
                        text: link.raw,
                        attributes: [
                            "target": .string(link.target),
                            "isTransclusion": .bool(link.isTransclusion)
                        ]
                    )
                )
            }

            for mention in parseMentions(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .mention,
                            identifier: "mention-\(lineNumber)-\(mention)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: mention,
                        text: "@\(mention)",
                        attributes: ["mention": .string(mention)]
                    )
                )
            }

            for tag in parseTags(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .tag,
                            identifier: "tag-\(lineNumber)-\(tag)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: tag,
                        text: "#\(tag)",
                        attributes: ["tag": .string(tag)]
                    )
                )
            }

            if let inlineLink = parseInlineLink(line: line) {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .inlineLink,
                            identifier: "inline-link-\(lineNumber)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: inlineLink.label,
                        text: inlineLink.href,
                        attributes: [
                            "label": .string(inlineLink.label),
                            "href": .string(inlineLink.href)
                        ]
                    )
                )
            }

            if !trimmed.isEmpty,
               !trimmed.hasPrefix("#"),
               parseTaskItem(line: line) == nil,
               parseListItem(line: line) == nil {
                nodes.append(
                    ActionContentNode(
                        address: ActionContentAddress(
                            documentPath: normalizedPath,
                            nodeKind: .paragraph,
                            identifier: "paragraph-\(lineNumber)",
                            range: ActionTextRange(startLine: lineNumber, startColumn: 1, endLine: lineNumber, endColumn: max(1, line.count))
                        ),
                        title: nil,
                        text: trimmed,
                        attributes: [:]
                    )
                )
            }
        }

        return nodes
    }

    private func nodeMatchesAddress(_ node: ActionContentNode, address: ActionContentAddress) -> Bool {
        guard node.address.documentPath == normalizeRelativePath(address.documentPath),
              node.address.nodeKind == address.nodeKind else {
            return false
        }

        if let identifier = address.identifier, node.address.identifier != identifier {
            return false
        }

        if let headingSlug = address.headingSlug, node.address.headingSlug != headingSlug {
            return false
        }

        if let range = address.range, node.address.range != range {
            return false
        }

        return true
    }

    private func matches(selector: ActionContentSelector, node: ActionContentNode) -> Bool {
        if let documentPath = selector.documentPath,
           normalizeRelativePath(documentPath) != node.address.documentPath {
            return false
        }

        if !selector.nodeKinds.isEmpty,
           !selector.nodeKinds.contains(node.address.nodeKind) {
            return false
        }

        if let headingSlug = selector.headingSlug,
           node.address.headingSlug != headingSlug,
           node.attributes["slug"]?.stringValue != headingSlug {
            return false
        }

        if let wikilinkTarget = selector.wikilinkTarget,
           node.attributes["target"]?.stringValue != wikilinkTarget {
            return false
        }

        if let tag = selector.tag,
           node.attributes["tag"]?.stringValue != tag {
            return false
        }

        if let mention = selector.mention,
           node.attributes["mention"]?.stringValue != mention {
            return false
        }

        if let taskState = selector.taskState,
           node.attributes["state"]?.stringValue != taskState {
            return false
        }

        if let frontmatterField = selector.frontmatterField {
            guard case .object(let fields)? = node.attributes["fields"],
                  fields[frontmatterField] != nil else {
                return false
            }
        }

        if let textContains = selector.textContains?.lowercased(), !textContains.isEmpty {
            let haystacks = [node.title, node.text] + node.attributes.values.map { $0.stringValue }
            let matchesText = haystacks
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(textContains) }
            if !matchesText {
                return false
            }
        }

        return true
    }

    private func project(node: ActionContentNode, projection: ActionContentProjection?) -> ActionContentRecord {
        let includeText = projection?.includeText ?? true
        let includeAttributes = projection?.includeAttributes ?? true
        let requestedFields = Set(projection?.fields ?? [])
        let useRequestedFields = !requestedFields.isEmpty

        var fields: [String: ActionValue] = [:]

        func include(_ key: String) -> Bool {
            !useRequestedFields || requestedFields.contains(key)
        }

        if include("documentPath") {
            fields["documentPath"] = .string(node.address.documentPath)
        }
        if include("nodeKind") {
            fields["nodeKind"] = .string(node.address.nodeKind.rawValue)
        }
        if let title = node.title, include("title") {
            fields["title"] = .string(title)
        }
        if includeText, let text = node.text, include("text") {
            fields["text"] = .string(text)
        }
        if let identifier = node.address.identifier, include("identifier") {
            fields["identifier"] = .string(identifier)
        }
        if let headingSlug = node.address.headingSlug, include("headingSlug") {
            fields["headingSlug"] = .string(headingSlug)
        }
        if let range = node.address.range {
            if include("startLine") { fields["startLine"] = .int(range.startLine) }
            if include("startColumn") { fields["startColumn"] = .int(range.startColumn) }
            if include("endLine") { fields["endLine"] = .int(range.endLine) }
            if include("endColumn") { fields["endColumn"] = .int(range.endColumn) }
        }

        if includeAttributes {
            for (key, value) in node.attributes where include(key) {
                fields[key] = value
            }
        }

        return ActionContentRecord(address: node.address, fields: fields)
    }

    private func parseFrontmatter(lines: [String], documentPath: String) -> (node: ActionContentNode, endLineIndex: Int)? {
        guard let firstLine = lines.first else { return nil }
        let fence: String
        let style: String
        if firstLine == "---" {
            fence = "---"
            style = "yaml"
        } else if firstLine == "+++" {
            fence = "+++"
            style = "toml"
        } else {
            return nil
        }

        guard let endIndex = lines.dropFirst().firstIndex(of: fence) else {
            return nil
        }

        let bodyLines = Array(lines[1..<endIndex])
        let body = bodyLines.joined(separator: "\n")
        let fields = parseFrontmatterFields(body: body, style: style)

        let node = ActionContentNode(
            address: ActionContentAddress(
                documentPath: documentPath,
                nodeKind: .frontmatter,
                identifier: "frontmatter",
                range: ActionTextRange(startLine: 1, startColumn: 1, endLine: endIndex + 1, endColumn: max(1, fence.count))
            ),
            title: "Frontmatter",
            text: body,
            attributes: [
                "style": .string(style),
                "fields": .object(fields)
            ]
        )
        return (node, endIndex)
    }

    private func parseFrontmatterFields(body: String, style: String) -> [String: ActionValue] {
        switch style {
        case "yaml":
            if let object = try? Yams.load(yaml: body) as? [String: Any] {
                return object.mapValues(ActionValue.init)
            }
        case "toml":
            if let decoded = try? TOMLDecoder().decode([String: ActionValue].self, from: body) {
                return decoded
            }
        default:
            break
        }
        return [:]
    }

    private func parseCodeFence(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let remainder = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "" : remainder
    }

    private func parseHeading(line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (hashes.count, remainder)
    }

    private func parseTaskItem(line: String) -> (state: String, marker: String, text: String)? {
        let pattern = #"^\s*([-*+])\s+\[([ xX])\]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
              let markerRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let marker = String(line[markerRange])
        let stateCharacter = String(line[stateRange]).lowercased()
        return (stateCharacter == "x" ? "checked" : "unchecked", marker, String(line[textRange]))
    }

    private func parseListItem(line: String) -> String? {
        let bulletPattern = #"^\s*[-*+]\s+(.+)$"#
        let orderedPattern = #"^\s*\d+\.\s+(.+)$"#
        for pattern in [bulletPattern, orderedPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
                  let textRange = Range(match.range(at: 1), in: line) else {
                continue
            }
            return String(line[textRange])
        }
        return nil
    }

    private func parseWikilinks(line: String) -> [(raw: String, target: String, isTransclusion: Bool)] {
        let pattern = #"(!?\[\[([^\]]+)\]\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, options: [], range: nsRange).compactMap { match in
            guard let rawRange = Range(match.range(at: 1), in: line),
                  let targetRange = Range(match.range(at: 2), in: line) else {
                return nil
            }
            let raw = String(line[rawRange])
            let target = String(line[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw, target, raw.hasPrefix("!"))
        }
    }

    private func parseMentions(line: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_])@([A-Za-z0-9._/-]+)"#
        return captureGroupValues(in: line, pattern: pattern)
    }

    private func parseTags(line: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_])#([A-Za-z0-9._/-]+)"#
        return captureGroupValues(in: line, pattern: pattern)
    }

    private func parseInlineLink(line: String) -> (label: String, href: String)? {
        let pattern = #"\[([^\]]+)\]\(([^\)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
              let labelRange = Range(match.range(at: 1), in: line),
              let hrefRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return (String(line[labelRange]), String(line[hrefRange]))
    }

    private func captureGroupValues(in line: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
    }

    private func slugify(_ text: String) -> String {
        let lowercased = text.lowercased()
        let components = lowercased
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return components.joined(separator: "-")
    }

    private func backlinkCandidates(for targetPath: String) -> Set<String> {
        let normalized = normalizeLinkTarget(targetPath)
        let url = URL(fileURLWithPath: normalized)
        let withoutExtension = url.deletingPathExtension().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basename = url.lastPathComponent
        let basenameWithoutExtension = url.deletingPathExtension().lastPathComponent

        return Set([
            normalized,
            withoutExtension,
            basename,
            basenameWithoutExtension
        ].filter { !$0.isEmpty })
    }

    private func normalizeLinkTarget(_ path: String) -> String {
        let cleaned = path
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? path
        return normalizeRelativePath(cleaned)
    }

    private func normalizeRelativePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }

    private func loadFullText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let unicode = String(data: data, encoding: .unicode) { return unicode }
        return String(data: data, encoding: .ascii)
    }

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline"
    ]
}
