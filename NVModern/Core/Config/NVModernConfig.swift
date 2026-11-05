import Foundation

struct NVModernSearchFacetMap: Hashable {
    static let empty = NVModernSearchFacetMap(mappingsByFacetKey: [:])
    static let configurableFacetKeys: Set<String> = ["class", "workspace", "entity", "asset", "library", "root", "is"]
    static let supportedFacetKeys: [String] = ["class", "workspace", "entity", "asset", "library", "ext", "root", "is"]

    let mappingsByFacetKey: [String: [String: String]]

    var isEmpty: Bool {
        mappingsByFacetKey.values.allSatisfy(\.isEmpty)
    }

    func mappedValue(for facetKey: String, relativePath: String) -> String? {
        let normalizedFacetKey = facetKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mappings = mappingsByFacetKey[normalizedFacetKey], !mappings.isEmpty else {
            return nil
        }

        let normalizedPath = Self.normalizePathPrefix(relativePath)
        let candidates = mappings.keys.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }

        for candidate in candidates {
            if candidate.isEmpty {
                if let value = mappings[candidate], !value.isEmpty {
                    return value
                }
                continue
            }

            if normalizedPath == candidate || normalizedPath.hasPrefix(candidate + "/") {
                if let value = mappings[candidate], !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }

    static func normalizePathPrefix(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        return normalized
    }
}

struct NVModernProject: Identifiable, Hashable {
    let name: String
    let rootURL: URL
    let source: String
    let icon: String?
    let searchFacetMap: NVModernSearchFacetMap

    var id: String {
        rootURL.standardizedFileURL.path
    }
}

struct NVModernTextSubstitutionRule: Hashable {
    let from: String
    let to: String
}

enum NVModernSyncMode: String, Hashable {
    case prompt
    case liveFile = "live_file"

    var automaticallyReloadsFileChanges: Bool {
        switch self {
        case .prompt:
            return false
        case .liveFile:
            return true
        }
    }
}

struct NVModernSyncConfig: Hashable {
    static let `default` = NVModernSyncConfig(mode: .prompt)

    let mode: NVModernSyncMode
}

/// Appearance defaults for one file type, from `[filetypes.<ext>]`.
struct NVModernFiletypeAppearance: Hashable {
    /// Theme id for this file type. `system` means no theme even when a
    /// global `editor_theme` is set; nil inherits the global theme.
    let themeID: String?
    /// Replaces the theme's text and heading faces; the theme's sizes and
    /// x-height still apply.
    let fontFamily: String?
    /// The base theme CSS for documents of this type: the file type's theme
    /// (or the global one), `editor_theme_css`, then the font swap.
    let editorThemeCSS: String?
}

struct NVModernDocumentDefaultsConfig: Hashable {
    static let `default` = NVModernDocumentDefaultsConfig(width: .comfortable, filetypes: [:])

    let width: DocumentInspectorWidth
    /// Keyed by lowercased file extension without the dot (`org`, `md`).
    let filetypes: [String: NVModernFiletypeAppearance]
    /// Window chrome takes the visible document's page colour (`window_tint`).
    var tintsWindow = true

    var inspectorSettings: DocumentInspectorSettings {
        DocumentInspectorSettings(width: width)
    }

    func filetype(forPath path: String?) -> NVModernFiletypeAppearance? {
        guard let path else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return filetypes[ext]
    }
}

struct NVModernAppConfig {
    var plugins: NVModernPluginsDraft = .init()
    let defaultProject: NVModernProject
    let projects: [NVModernProject]
    let users: [String]
    let editorThemeCSS: String?
    let substitutions: [NVModernTextSubstitutionRule]
    let keybindings: [ActionKeybindingDefinition]
    let socket: ActionSocketConfiguration?
    let sync: NVModernSyncConfig
    let documentDefaults: NVModernDocumentDefaultsConfig
    let configURL: URL
    var warning: String?
}

struct NVModernRuntimeConfig {
    let activeProject: NVModernProject
    let availableProjects: [NVModernProject]
    let users: [String]
    let editorThemeCSS: String?
    let substitutions: [NVModernTextSubstitutionRule]
    let keybindings: [ActionKeybindingDefinition]
    let socket: ActionSocketConfiguration?
    let sync: NVModernSyncConfig
    let documentDefaults: NVModernDocumentDefaultsConfig
    let warning: String?
    let configURL: URL

    var rootURL: URL {
        activeProject.rootURL
    }

    var searchFacetMap: NVModernSearchFacetMap {
        activeProject.searchFacetMap
    }

    var supportedSearchFacetKeys: [String] {
        NVModernSearchFacetMap.supportedFacetKeys
    }

    var debugLabel: String {
        let usersLabel = users.isEmpty ? "users=0" : "users=\(users.count)"
        let projectsLabel = "projects=\(availableProjects.count)"
        let keybindingsLabel = "keybindings=\(keybindings.count)"
        let editorThemeLabel = editorThemeCSS.map { _ in "editorThemeCSS=loaded" } ?? "editorThemeCSS=nil"
        let syncLabel = "sync=\(sync.mode.rawValue)"
        let filetypesLabel = documentDefaults.filetypes.keys.sorted().joined(separator: ",")
        let documentDefaultsLabel = "documentDefaults=\(documentDefaults.width.rawValue)/filetypes=[\(filetypesLabel)]"
        let base = "Root: \(rootURL.path) [\(activeProject.name)] (\(activeProject.source), \(usersLabel), \(projectsLabel), \(keybindingsLabel), \(editorThemeLabel), \(syncLabel), \(documentDefaultsLabel))"
        if let warning {
            return "\(base) — \(warning)"
        }
        return base
    }

    var defaultDocumentInspectorSettings: DocumentInspectorSettings {
        documentDefaults.inspectorSettings
    }

    /// Base theme CSS for the document at `path`: its file type's theme and
    /// font when `[filetypes.<ext>]` sets them, otherwise the global theme,
    /// plus `@font-face` rules for any user-installed families it names.
    func editorThemeCSS(forPath path: String?) -> String? {
        let css = documentDefaults.filetype(forPath: path).map(\.editorThemeCSS) ?? editorThemeCSS
        guard let trimmed = css?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return UserFontFaceCatalog.appendingFontFaces(to: trimmed)
    }

}

enum NVModernConfigLoader {
    static func load(projectRootPath: String? = nil, fileManager: FileManager = .default) -> NVModernRuntimeConfig {
        NVModernConfigSchema.load(projectRootPath: projectRootPath, fileManager: fileManager)
    }

    static func loadAppConfig(fileManager: FileManager = .default) -> NVModernAppConfig {
        NVModernConfigSchema.shared.loadAppConfig(fileManager: fileManager)
    }
}
