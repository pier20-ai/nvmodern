import Foundation

/// Identifies the theme applied to a document: the reserved `system` id, a
/// bundled theme id, or a user theme id (a CSS filename in the themes
/// directory without the extension). Encoded as a plain string so session
/// snapshots written before user themes existed decode unchanged.
struct DocumentThemeID: Hashable, Identifiable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let system = DocumentThemeID(rawValue: UserEditorThemeCatalog.reservedThemeID)

    var id: String { rawValue }

    var title: String {
        if rawValue == UserEditorThemeCatalog.reservedThemeID {
            return "System"
        }
        return EditorThemeRegistry.theme(withID: rawValue, in: UserEditorThemeCatalog.currentDirectoryURL)?.title
            ?? UserEditorThemeCatalog.displayTitle(for: rawValue)
    }
}

extension DocumentThemeID: Codable {
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DocumentInspectorWidth: String, Codable, CaseIterable, Identifiable, Hashable {
    case narrow
    case comfortable
    case wide
    case extraWide
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .comfortable: return "Comfort"
        case .wide: return "Wide"
        case .extraWide: return "XL"
        case .full: return "Full"
        }
    }

    var cssValue: String {
        switch self {
        case .narrow: return "620px"
        case .comfortable: return "740px"
        case .wide: return "920px"
        case .extraWide: return "1080px"
        case .full: return "100%"
        }
    }

    init?(configuredValue: String?) {
        guard let normalizedValue = Self.normalizedConfiguredValue(configuredValue),
              !normalizedValue.isEmpty else {
            return nil
        }

        switch normalizedValue {
        case "narrow":
            self = .narrow
        case "comfortable", "comfort", "default":
            self = .comfortable
        case "wide":
            self = .wide
        case "extra_wide", "extrawide", "xl":
            self = .extraWide
        case "full", "full_width", "fullwidth":
            self = .full
        default:
            return nil
        }
    }

    private static func normalizedConfiguredValue(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

struct DocumentInspectorScale: Codable, Hashable {
    static let range: ClosedRange<Double> = 75...125
    static let small = DocumentInspectorScale(percentage: 90)
    static let normal = DocumentInspectorScale(percentage: 100)
    static let large = DocumentInspectorScale(percentage: 110)
    static let extraLarge = DocumentInspectorScale(percentage: 125)

    let percentage: Double

    init(percentage: Double) {
        let rounded = percentage.rounded()
        self.percentage = min(Self.range.upperBound, max(Self.range.lowerBound, rounded))
    }

    var title: String {
        "\(Int(percentage.rounded()))%"
    }

    var cssValue: String {
        title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let percentage = try? container.decode(Double.self) {
            self.init(percentage: percentage)
            return
        }

        let legacyValue = try container.decode(String.self)
        switch legacyValue.lowercased() {
        case "small": self = .small
        case "normal": self = .normal
        case "large": self = .large
        case "extralarge": self = .extraLarge
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown document scale: \(legacyValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percentage)
    }
}

struct DocumentInspectorSettings: Codable, Equatable {
    var width: DocumentInspectorWidth
    var theme: DocumentThemeID
    var scale: DocumentInspectorScale
    var unwrapMarkdownLines: Bool

    static let `default` = DocumentInspectorSettings(
        width: .comfortable,
        theme: .system,
        scale: .normal,
        unwrapMarkdownLines: false
    )

    init(
        width: DocumentInspectorWidth,
        theme: DocumentThemeID = .system,
        scale: DocumentInspectorScale = .normal,
        unwrapMarkdownLines: Bool = false
    ) {
        self.width = width
        self.theme = theme
        self.scale = scale
        self.unwrapMarkdownLines = unwrapMarkdownLines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decodeIfPresent(DocumentInspectorWidth.self, forKey: .width) ?? Self.default.width
        theme = try container.decodeIfPresent(DocumentThemeID.self, forKey: .theme) ?? Self.default.theme
        scale = try container.decodeIfPresent(DocumentInspectorScale.self, forKey: .scale) ?? Self.default.scale
        unwrapMarkdownLines = try container.decodeIfPresent(Bool.self, forKey: .unwrapMarkdownLines)
            ?? Self.default.unwrapMarkdownLines
    }
}

extension DocumentInspectorSettings {
    var css: String {
        DocumentInspectorAppearance(settings: self).css
    }
}

struct DocumentInspectorAppearance: Equatable {
    var settings: DocumentInspectorSettings
    var fontFamily: String?

    init(settings: DocumentInspectorSettings, fontFamily: String? = nil) {
        self.settings = settings
        self.fontFamily = DocumentFrontmatterAppearance.sanitizedFontFamily(fontFamily)
    }

    /// CSS for the theme selected on this document, if any. The reserved
    /// `system` id means "no theme" and injects nothing.
    var selectedThemeCSS: String? {
        guard settings.theme.rawValue != UserEditorThemeCatalog.reservedThemeID else { return nil }
        return UserEditorThemeCatalog.cssText(for: settings.theme.rawValue)
    }

    /// Swaps the body and heading faces for `fontFamily` while keeping the
    /// theme's sizes. The swapped body face is scaled to the theme's x-height
    /// (`--nv3-font-size-adjust`), so a monospace or wide face lands at the
    /// theme's optical size. Shared by frontmatter `font-family` and
    /// `[filetypes.<ext>] font_family`.
    static func fontOverrideCSS(fontFamily: String) -> String {
        let stack = endsWithGenericFamily(fontFamily) ? fontFamily : "\(fontFamily), system-ui, sans-serif"
        return """
        :root,
        [data-theme="light"],
        [data-theme="dark"] {
          --nv3-font-sans: \(stack);
          --nv3-font-display: \(stack);
          --nv3-content-font-size-adjust: var(--nv3-font-size-adjust);
        }
        """
    }

    /// A stack the user already closed with a generic family keeps its own
    /// fallback; a bare family gets one, so a missing face never lands on the
    /// browser's default serif.
    private static func endsWithGenericFamily(_ stack: String) -> Bool {
        let last = stack.split(separator: ",").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return ["serif", "sans-serif", "monospace", "system-ui", "cursive", "fantasy"].contains(last)
            || last.hasPrefix("ui-")
    }

    var css: String {
        var layers = ["""
        :root,
        [data-theme="light"],
        [data-theme="dark"] {
          --nv3-editor-max-width: \(settings.width.cssValue);
          --nv3-document-scale: \(settings.scale.cssValue);
        }
        """]

        // The document's theme follows the width/scale rules so it wins over
        // the globally selected editor theme (same specificity, later in
        // source order inside one stylesheet).
        if let themeCSS = selectedThemeCSS?.trimmingCharacters(in: .whitespacesAndNewlines),
           !themeCSS.isEmpty {
            layers.append(themeCSS)
        }

        // A frontmatter font comes last so it also beats the document's theme.
        if let fontFamily {
            layers.append(Self.fontOverrideCSS(fontFamily: fontFamily))
        }
        let css = layers.joined(separator: "\n\n")
        return UserFontFaceCatalog.appendingFontFaces(to: css) ?? css
    }
}
