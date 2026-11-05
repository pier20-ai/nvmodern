import AppKit
import Foundation

/// A theme available to the editor: one self-contained CSS file that overrides
/// the public `--nv3-*` tokens documented in `NVModern/WebEditor/THEMING.md`.
///
/// Themes resolve across two roots: the user themes directory
/// (`themes_dir`, default `~/.config/nvmodern/themes`) and the bundled
/// `BuiltinThemes` resource folder. A user file with the same id shadows the
/// bundled one. The id `system` is reserved and always means "no theme".
struct UserEditorTheme: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let swatchHexes: [String]
    let isBundled: Bool
    let fileURL: URL
}

enum UserEditorThemeCatalog {
    static let fileExtension = "css"
    static let defaultDirectoryName = "themes"
    static let bundledThemesDirectoryName = "BuiltinThemes"
    static let reservedThemeID = "system"

    // Optional display metadata, declared inside the CSS as author-defined
    // custom properties so a theme stays a single file.
    static let nameProperty = "--nv3-theme-name"
    static let subtitleProperty = "--nv3-theme-subtitle"
    static let swatchProperty = "--nv3-theme-swatch"
    static let maxSwatches = 3

    /// The theme file copied into an empty themes directory on first use.
    static let templateThemeID = "example"

    /// `~/.config/nvmodern/themes`.
    static func defaultDirectoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("nvmodern", isDirectory: true)
            .appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    /// Resolves the configured `themes_dir`. Empty/nil uses the default
    /// location; relative paths resolve against the directory holding
    /// `config.toml`, matching `editor_theme_css` semantics.
    static func resolvedDirectoryURL(
        from configuredPath: String?,
        configURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let trimmed = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return defaultDirectoryURL(home: home)
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }

        let baseURL = configURL.deletingLastPathComponent()
        return baseURL.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    // MARK: Cached directory

    private static let directoryLock = NSLock()
    private static var cachedDirectory: URL?

    /// Refreshed by config resolution so Core-layer consumers (e.g.
    /// `DocumentInspectorAppearance`) can read theme CSS without reloading
    /// the whole config.
    static func setCachedDirectory(_ url: URL) {
        directoryLock.lock()
        cachedDirectory = url
        directoryLock.unlock()
    }

    static var currentDirectoryURL: URL {
        directoryLock.lock()
        defer { directoryLock.unlock() }
        return cachedDirectory ?? defaultDirectoryURL()
    }

    // MARK: Resolution

    /// Locates a theme across both roots. The user directory wins; `system`
    /// is reserved and resolves to nothing.
    static func themeFileURL(
        for themeID: String,
        in userDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmedID = sanitizedID(themeID)
        guard let trimmedID, trimmedID != reservedThemeID else { return nil }

        let userURL = userDirectory
            .appendingPathComponent(trimmedID, isDirectory: false)
            .appendingPathExtension(fileExtension)
        if fileManager.fileExists(atPath: userURL.path) {
            return userURL
        }

        // BuiltinThemes ships as a folder resource; fall back to the bundle
        // root in case packaging flattens it alongside the other resources.
        return Bundle.main.url(
            forResource: trimmedID,
            withExtension: fileExtension,
            subdirectory: bundledThemesDirectoryName
        ) ?? Bundle.main.url(forResource: trimmedID, withExtension: fileExtension)
    }

    static func cssText(
        for themeID: String,
        in userDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let fileURL = themeFileURL(for: themeID, in: userDirectory, fileManager: fileManager) else {
            return nil
        }
        return cssText(at: fileURL)
    }

    static func cssText(for themeID: String) -> String? {
        cssText(for: themeID, in: currentDirectoryURL)
    }

    // MARK: Discovery

    /// User themes from a themes directory, sorted by title.
    static func themes(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [UserEditorTheme] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )) ?? []

        return contents.compactMap { url in
            guard url.pathExtension.lowercased() == fileExtension,
                  !url.lastPathComponent.hasPrefix(".") else {
                return nil
            }

            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegularFile else { return nil }

            let id = url.deletingPathExtension().lastPathComponent
            guard id != reservedThemeID, let css = cssText(at: url) else { return nil }

            let metadata = Self.metadata(in: css)
            return UserEditorTheme(
                id: id,
                title: metadata.name ?? displayTitle(for: id),
                subtitle: metadata.subtitle,
                swatchHexes: metadata.swatches.isEmpty ? fallbackSwatches(in: css) : metadata.swatches,
                isBundled: false,
                fileURL: url
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Bundled themes from the app package, sorted by title.
    static func bundledThemes() -> [UserEditorTheme] {
        let urls = bundledThemeFileURLs()

        return urls.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard id != reservedThemeID, !id.hasPrefix("."), let css = cssText(at: url) else {
                return nil
            }

            let metadata = Self.metadata(in: css)
            return UserEditorTheme(
                id: id,
                title: metadata.name ?? displayTitle(for: id),
                subtitle: metadata.subtitle,
                swatchHexes: metadata.swatches.isEmpty ? fallbackSwatches(in: css) : metadata.swatches,
                isBundled: true,
                fileURL: url
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Matches a configured id against bundled theme ids case-insensitively,
    /// returning the canonical id. Used by the legacy `theme` config key.
    static func bundledThemeID(matching rawID: String) -> String? {
        let needle = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bundledThemeFileURLs()
            .map { $0.deletingPathExtension().lastPathComponent }
            .first { $0.lowercased() == needle }
    }

    private static func bundledThemeFileURLs() -> [URL] {
        // Enumerating only the BuiltinThemes folder keeps unrelated bundle CSS
        // (main.css, diff.css) out of the theme list; direct lookups via
        // themeFileURL(for:) additionally cover a flattened bundle root.
        (Bundle.main.urls(
            forResourcesWithExtension: fileExtension,
            subdirectory: bundledThemesDirectoryName
        ) ?? [])
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `true` when the directory did not exist or contained no themes; creates
    /// the directory and drops in the authoring template so the user starts
    /// from a working skeleton instead of a blank folder.
    @discardableResult
    static func installTemplateIfNeeded(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let hasThemes = !themes(in: directory, fileManager: fileManager).isEmpty
        guard !hasThemes else { return false }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let templateURL = directory
                .appendingPathComponent(templateThemeID, isDirectory: false)
                .appendingPathExtension(fileExtension)
            if !fileManager.fileExists(atPath: templateURL.path) {
                try makeTemplateCSS().write(to: templateURL, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }

    static func revealDirectory(_ directory: URL) {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    static func displayTitle(for id: String) -> String {
        id
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    struct Metadata: Equatable {
        var name: String?
        var subtitle: String?
        var swatches: [String]
    }

    static func metadata(in cssText: String) -> Metadata {
        Metadata(
            name: declaredValue(for: nameProperty, in: cssText).map(sanitizedName),
            subtitle: declaredValue(for: subtitleProperty, in: cssText).map(sanitizedName),
            swatches: declaredSwatches(in: cssText)
        )
    }

    // MARK: - Private

    private static func sanitizedID(_ rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            return nil
        }
        return trimmed
    }

    private static func cssText(at fileURL: URL) -> String? {
        guard let css = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return css.isEmpty ? nil : css
    }

    private static func declaredValue(for property: String, in cssText: String) -> String? {
        let pattern = "(?:^|[;{\\n])\\s*" + NSRegularExpression.escapedPattern(for: property) + "\\s*:\\s*([^;}]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(cssText.startIndex..., in: cssText)
        guard let match = regex.firstMatch(in: cssText, range: range),
              let valueRange = Range(match.range(at: 1), in: cssText) else {
            return nil
        }
        let value = String(cssText[valueRange])
        return value.isEmpty ? nil : value
    }

    private static func declaredSwatches(in cssText: String) -> [String] {
        let suffixes = ["", "-2", "-3"]
        var swatches: [String] = []
        for suffix in suffixes where swatches.count < maxSwatches {
            guard let raw = declaredValue(for: swatchProperty + suffix, in: cssText),
                  let swatch = sanitizedSwatch(raw) else {
                break
            }
            swatches.append(swatch)
        }
        return swatches
    }

    private static func sanitizedName(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = String(value.prefix(60))
        return value.isEmpty ? "" : value
    }

    private static func sanitizedSwatch(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        let hex = value.dropFirst()
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    /// When a theme declares no swatch, fall back to its accent color so the
    /// picker still shows something meaningful for minimal theme files.
    private static func fallbackSwatches(in cssText: String) -> [String] {
        guard let accent = declaredValue(for: "--nv3-color-accent", in: cssText),
              let swatch = sanitizedSwatch(accent) else {
            return []
        }
        return [swatch]
    }

    private static func makeTemplateCSS() -> String {
        """
        /*
         * nvModern editor theme — \(templateThemeID)
         *
         * Rename this file to name your theme; the filename (without .css) is
         * the theme id. Override any public --nv3-* token from WebEditor /
         * THEMING.md. Typography is set once on :root and applies to Markdown
         * and Org alike; colours are set per appearance. Only tokens a theme
         * sets change — everything else keeps the bundled default.
         *
         * Optional display metadata (shown in Settings > Appearance and the
         * Document Inspector):
        \(nameProperty): Example Theme;
        \(subtitleProperty): Describe the vibe;
        \(swatchProperty): #2383e2;
         */

        :root {
          --nv3-font-sans: "Iowan Old Style", Georgia, serif;
          --nv3-font-display: "Iowan Old Style", Georgia, serif;
          --nv3-font-label: "Seravek", -apple-system, sans-serif;
          /* The body face's x-height; code is scaled to match it. */
          --nv3-font-size-adjust: 0.479;
          --nv3-content-font-size: 1.06em;
          --nv3-md-h1-font-weight: 600;
        }

        [data-theme="light"] {
          --nv3-color-bg: #fbfaf8;
          --nv3-color-surface: #f2f0ec;
          --nv3-color-text: #242321;
          --nv3-color-text-muted: #77736b;
          --nv3-color-border: #ded9d1;
          --nv3-color-accent: #2f766f;
          --nv3-selection-bg: rgba(47, 118, 111, 0.18);

          --nv3-md-h1-color: #243f3b;
          --nv3-md-inline-code-color: #a3483f;
        }

        [data-theme="dark"] {
          --nv3-color-bg: #171615;
          --nv3-color-surface: #22201e;
          --nv3-color-text: #ece7df;
          --nv3-color-text-muted: #aaa199;
          --nv3-color-border: #34302d;
          --nv3-color-accent: #70bdb4;
          --nv3-selection-bg: rgba(112, 189, 184, 0.22);
        }
        """
    }
}
