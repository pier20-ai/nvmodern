import Foundation
import TOMLKit
import Yams

struct DocumentFrontmatterAppearance: Equatable {
    var theme: DocumentThemeID?
    var width: DocumentInspectorWidth?
    var fontFamily: String?

    var isEmpty: Bool {
        theme == nil && width == nil && fontFamily == nil
    }

    static func parse(from body: String) -> DocumentFrontmatterAppearance? {
        guard let frontmatter = splitFrontmatter(from: body) else { return nil }

        let fields = parseFields(body: frontmatter.body, style: frontmatter.style)
        let appearance = DocumentFrontmatterAppearance(
            theme: stringValue(for: ["theme"], in: fields).flatMap(parseTheme),
            width: stringValue(for: ["width"], in: fields).flatMap(DocumentInspectorWidth.init(configuredValue:)),
            fontFamily: stringValue(for: ["font-family", "font_family", "fontFamily"], in: fields)
                .flatMap(sanitizedFontFamily)
        )

        return appearance.isEmpty ? nil : appearance
    }

    /// Frontmatter `theme:` accepts the reserved `system` id, a bundled theme
    /// id, or a user theme id. Ids are sanitized; one that resolves to no
    /// file simply applies no palette.
    static func parseTheme(_ rawValue: String) -> DocumentThemeID? {
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == UserEditorThemeCatalog.reservedThemeID {
            return .system
        }
        guard let id = sanitizedThemeID(rawValue) else { return nil }
        return DocumentThemeID(rawValue: id)
    }

    static func sanitizedThemeID(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { return nil }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        guard !value.hasPrefix("."),
              !value.contains("/"),
              !value.contains("\\") else {
            return nil
        }
        return value
    }

    static func sanitizedFontFamily(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160 else { return nil }

        let disallowedSubstrings = ["/*", "*/", "url(", "expression("]
        let lowercasedValue = value.lowercased()
        guard !disallowedSubstrings.contains(where: { lowercasedValue.contains($0) }) else {
            return nil
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ,.-_\"'"
        )
        guard value.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return value
    }

    func applied(to fallback: DocumentInspectorSettings) -> DocumentInspectorAppearance {
        var settings = fallback
        if let theme {
            settings.theme = theme
        }
        if let width {
            settings.width = width
        }
        return DocumentInspectorAppearance(settings: settings, fontFamily: fontFamily)
    }

    private enum FrontmatterStyle {
        case yaml
        case toml
    }

    private static func splitFrontmatter(from source: String) -> (body: String, style: FrontmatterStyle)? {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let fence: String
        let style: FrontmatterStyle
        switch firstLine.replacingOccurrences(of: "\u{FEFF}", with: "") {
        case "---":
            fence = "---"
            style = .yaml
        case "+++":
            fence = "+++"
            style = .toml
        default:
            return nil
        }

        guard let endIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == fence
        }) else {
            return nil
        }

        return (Array(lines[1..<endIndex]).joined(separator: "\n"), style)
    }

    private static func parseFields(body: String, style: FrontmatterStyle) -> [String: Any] {
        switch style {
        case .yaml:
            return (try? Yams.load(yaml: body)) as? [String: Any] ?? [:]
        case .toml:
            guard let table = try? TOMLTable(string: body) else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: table.compactMap { key, value in
                stringValue(fromTOMLValue: value).map { (key, $0) }
            })
        }
    }

    private static func stringValue(for keys: [String], in fields: [String: Any]) -> String? {
        for key in keys {
            guard let value = fields[key] else { continue }
            if let string = value as? String {
                return string
            }
        }
        return nil
    }

    private static func stringValue(fromTOMLValue value: TOMLValueConvertible?) -> String? {
        guard let value else { return nil }
        if let string = value.string { return string }
        return nil
    }
}
