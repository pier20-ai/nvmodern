import Foundation
import TOMLKit

extension Notification.Name {
    static let nvModernConfigDidChange = Notification.Name("NVModernConfigDidChange")
    static let nvModernPluginsConfigDidChange = Notification.Name("NVModernPluginsConfigDidChange")
    static let nvModernConfigFileDidChange = Notification.Name("NVModernConfigFileDidChange")
}

enum NVModernConfigDiagnosticSeverity: String, Hashable {
    case warning
    case error
}

struct NVModernConfigDiagnostic: Identifiable, Hashable {
    let id = UUID()
    let severity: NVModernConfigDiagnosticSeverity
    let message: String
    let fieldID: String?
}

struct NVModernConfigDraftLoadResult {
    let draft: NVModernConfigDraft
    let configURL: URL
    let diagnostics: [NVModernConfigDiagnostic]
}

enum NVModernConfigPathKind: Hashable {
    case directory
    case file
    case markdownFile
}

struct NVModernConfigOption: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String?
}

struct NVModernConfigSchemaSection: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let fields: [NVModernConfigField]
}

struct NVModernConfigField: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String?
    let kind: NVModernConfigFieldKind

    static func == (lhs: NVModernConfigField, rhs: NVModernConfigField) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum NVModernConfigFieldKind: Hashable {
    case optionalString(WritableKeyPath<NVModernConfigDraft, String?>, placeholder: String, pathKind: NVModernConfigPathKind?)
    case stringList(WritableKeyPath<NVModernConfigDraft, [String]>)
    case enumString(WritableKeyPath<NVModernConfigDraft, String?>, defaultValue: String, options: [NVModernConfigOption])
    case syncMode
    case projects
    case searchFacetMap(WritableKeyPath<NVModernConfigDraft, [String: [String: String]]?>)
    case substitutions
    case keybindings
    case socket
    case rawPreview
}

/// One `[filetypes.<ext>]` table: appearance defaults for a file extension.
struct NVModernFiletypeDraft: Codable, Equatable {
    var theme: String?
    var font_family: String?

    init(theme: String? = nil, font_family: String? = nil) {
        self.theme = theme
        self.font_family = font_family
    }

    var isEmpty: Bool {
        (theme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (font_family?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case font_family
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeTrimmedOptional(theme, forKey: .theme, into: &container)
        try encodeTrimmedOptional(font_family, forKey: .font_family, into: &container)
    }
}

struct NVModernConfigDraft: Codable, Equatable {
    var theme: String?
    var width: String?
    /// Appearance defaults by file extension (`[filetypes.org]`). The retired
    /// top-level `org_font_family` decodes into `filetypes.org.font_family`.
    var filetypes: [String: NVModernFiletypeDraft]
    /// Set when the retired `org_font_family` key was read; never encoded.
    var migratedOrgFontFamily = false
    /// Window chrome takes the visible document's page colour. Nil means on.
    var window_tint: Bool?
    var users: [String]
    var themes_dir: String?
    var editor_theme: String?
    var editor_theme_css: String?
    var substitutions: [NVModernTextSubstitutionDraft]
    var projects: [NVModernProjectDraft]
    var containsRetiredActionTables = false
    var keybindings: [NVModernActionKeybindingDraft]
    var socket: NVModernSocketDraft?
    var sync: NVModernSyncDraft?
    var search_facets: [String: [String: String]]?
    var plugins: NVModernPluginsDraft

    /// UI-only: identifies the default project among `projects`. Not encoded directly;
    /// the TOML top-level `root` key is derived from this on encode and resolves to
    /// this on decode (matching by normalized path).
    var defaultProjectID: UUID?

    init(
        theme: String? = nil,
        width: String? = nil,
        filetypes: [String: NVModernFiletypeDraft] = [:],
        users: [String] = [],
        themes_dir: String? = nil,
        editor_theme: String? = nil,
        editor_theme_css: String? = nil,
        substitutions: [NVModernTextSubstitutionDraft] = [],
        projects: [NVModernProjectDraft] = [],
        keybindings: [NVModernActionKeybindingDraft] = [],
        socket: NVModernSocketDraft? = nil,
        sync: NVModernSyncDraft? = nil,
        search_facets: [String: [String: String]]? = nil,
        defaultProjectID: UUID? = nil,
        plugins: NVModernPluginsDraft = .init()
    ) {
        self.theme = theme
        self.width = width
        self.filetypes = filetypes
        self.users = users
        self.themes_dir = themes_dir
        self.editor_theme = editor_theme
        self.editor_theme_css = editor_theme_css
        self.substitutions = substitutions
        self.projects = projects
        self.keybindings = keybindings
        self.socket = socket
        self.sync = sync
        self.search_facets = search_facets
        self.plugins = plugins
        self.defaultProjectID = defaultProjectID
        normalizeDefaultProject()
    }

    /// Compatibility accessor: the path of the current default project, as expressed in
    /// the top-level `root` TOML key. The setter finds a matching project by normalized
    /// path or synthesizes one and prepends it.
    var root: String? {
        get { defaultProject?.path }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                defaultProjectID = nil
                normalizeDefaultProject()
                return
            }
            if let match = projects.first(where: { normalizedProjectPath($0.path) == normalizedProjectPath(trimmed) }) {
                defaultProjectID = match._uiID
            } else {
                let synthesized = NVModernProjectDraft(
                    name: derivedProjectName(forPath: trimmed),
                    path: trimmed
                )
                projects.insert(synthesized, at: 0)
                defaultProjectID = synthesized._uiID
            }
        }
    }

    var defaultProject: NVModernProjectDraft? {
        guard let id = defaultProjectID else { return nil }
        return projects.first { $0._uiID == id }
    }

    /// Ensures `defaultProjectID` references a project that exists, falling back to the
    /// first project when not. After any mutation to `projects`, call this to maintain
    /// the invariant: `defaultProjectID == nil` only when `projects.isEmpty`.
    mutating func normalizeDefaultProject() {
        if let id = defaultProjectID, !projects.contains(where: { $0._uiID == id }) {
            defaultProjectID = nil
        }
        if defaultProjectID == nil {
            defaultProjectID = projects.first?._uiID
        }
    }

    mutating func addProject(_ project: NVModernProjectDraft) {
        projects.append(project)
        normalizeDefaultProject()
    }

    mutating func removeProject(id: UUID) {
        projects.removeAll { $0._uiID == id }
        normalizeDefaultProject()
    }

    mutating func setDefaultProject(id: UUID) {
        guard projects.contains(where: { $0._uiID == id }) else { return }
        defaultProjectID = id
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case theme
        case width
        case filetypes
        case org_font_family
        case window_tint
        case users
        case themes_dir
        case editor_theme
        case editor_theme_css
        case substitutions
        case projects
        case retiredActions = "actions"
        case keybindings
        case socket
        case sync
        case search_facets
        case plugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawRoot = try container.decodeIfPresent(String.self, forKey: .root)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        width = try container.decodeIfPresent(String.self, forKey: .width)
        filetypes = try container.decodeIfPresent([String: NVModernFiletypeDraft].self, forKey: .filetypes) ?? [:]
        window_tint = try container.decodeIfPresent(Bool.self, forKey: .window_tint)
        if let legacyOrgFont = try container.decodeIfPresent(String.self, forKey: .org_font_family) {
            migratedOrgFontFamily = true
            if filetypes["org"]?.font_family == nil {
                filetypes["org", default: .init()].font_family = legacyOrgFont
            }
        }
        users = try container.decodeIfPresent([String].self, forKey: .users) ?? []
        themes_dir = try container.decodeIfPresent(String.self, forKey: .themes_dir)
        editor_theme = try container.decodeIfPresent(String.self, forKey: .editor_theme)
        editor_theme_css = try container.decodeIfPresent(String.self, forKey: .editor_theme_css)
        substitutions = try container.decodeIfPresent([NVModernTextSubstitutionDraft].self, forKey: .substitutions) ?? []
        projects = try container.decodeIfPresent([NVModernProjectDraft].self, forKey: .projects) ?? []
        containsRetiredActionTables = container.contains(.retiredActions)
        keybindings = try container.decodeIfPresent([NVModernActionKeybindingDraft].self, forKey: .keybindings) ?? []
        socket = try container.decodeIfPresent(NVModernSocketDraft.self, forKey: .socket)
        sync = try container.decodeIfPresent(NVModernSyncDraft.self, forKey: .sync)
        search_facets = try container.decodeIfPresent([String: [String: String]].self, forKey: .search_facets)
        plugins = try container.decodeIfPresent(NVModernPluginsDraft.self, forKey: .plugins) ?? .init()
        defaultProjectID = nil

        // Resolve the default project from the legacy `root` TOML key.
        if let rawRoot {
            let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let match = projects.first(where: {
                    normalizedProjectPath($0.path) == normalizedProjectPath(trimmed)
                }) {
                    defaultProjectID = match._uiID
                } else {
                    // Legacy: `root` set without a matching project. Synthesize one so the
                    // unified workspace list contains every root we know about.
                    let synthesized = NVModernProjectDraft(
                        name: derivedProjectName(forPath: trimmed),
                        path: trimmed
                    )
                    projects.insert(synthesized, at: 0)
                    defaultProjectID = synthesized._uiID
                }
            }
        }
        normalizeDefaultProject()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeTrimmedOptional(defaultProject?.path, forKey: .root, into: &container)
        try encodeTrimmedOptional(theme, forKey: .theme, into: &container)
        try encodeTrimmedOptional(width, forKey: .width, into: &container)
        try container.encodeIfPresent(window_tint, forKey: .window_tint)
        let meaningfulFiletypes = filetypes.filter { !$0.value.isEmpty }
        if !meaningfulFiletypes.isEmpty { try container.encode(meaningfulFiletypes, forKey: .filetypes) }
        if !users.isEmpty { try container.encode(users, forKey: .users) }
        try encodeTrimmedOptional(themes_dir, forKey: .themes_dir, into: &container)
        try encodeTrimmedOptional(editor_theme, forKey: .editor_theme, into: &container)
        try encodeTrimmedOptional(editor_theme_css, forKey: .editor_theme_css, into: &container)
        if !substitutions.isEmpty { try container.encode(substitutions, forKey: .substitutions) }
        if !projects.isEmpty { try container.encode(projects, forKey: .projects) }
        let activeKeybindings = keybindings.filter { $0.action == nil }
        if !activeKeybindings.isEmpty { try container.encode(activeKeybindings, forKey: .keybindings) }
        try container.encodeIfPresent(socket?.encodedIfMeaningful, forKey: .socket)
        try container.encodeIfPresent(sync?.encodedIfMeaningful, forKey: .sync)
        if let search_facets, !search_facets.isEmpty {
            try container.encode(search_facets, forKey: .search_facets)
        }
        if !plugins.isEmpty { try container.encode(plugins, forKey: .plugins) }
    }

    // Decode generates fresh row UUIDs; preference equality is about values.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root && lhs.theme == rhs.theme && lhs.width == rhs.width
        && lhs.filetypes.filter({ !$0.value.isEmpty }) == rhs.filetypes.filter({ !$0.value.isEmpty })
        && (lhs.window_tint ?? true) == (rhs.window_tint ?? true)
        && lhs.users == rhs.users
        && lhs.themes_dir == rhs.themes_dir && lhs.editor_theme == rhs.editor_theme
        && lhs.editor_theme_css == rhs.editor_theme_css && lhs.substitutions == rhs.substitutions
        && lhs.projects == rhs.projects && lhs.keybindings == rhs.keybindings
        && lhs.socket == rhs.socket && lhs.sync == rhs.sync && lhs.search_facets == rhs.search_facets
        && lhs.plugins == rhs.plugins
    }
}

private func normalizedProjectPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded = NSString(string: trimmed).expandingTildeInPath
    var normalized = expanded
    while normalized.hasSuffix("/") && normalized.count > 1 {
        normalized.removeLast()
    }
    return normalized
}

private func derivedProjectName(forPath path: String) -> String {
    let normalized = normalizedProjectPath(path)
    let last = (normalized as NSString).lastPathComponent
    let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Workspace" : trimmed
}

struct NVModernProjectDraft: Codable, Equatable {
    var name: String
    var path: String
    var icon: String?
    var search_facets: [String: [String: String]]?
    var _uiID: UUID = UUID()

    init(name: String = "", path: String = "", icon: String? = nil, search_facets: [String: [String: String]]? = nil) {
        self.name = name
        self.path = path
        self.icon = icon
        self.search_facets = search_facets
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, icon, search_facets
    }

    static func == (lhs: NVModernProjectDraft, rhs: NVModernProjectDraft) -> Bool {
        lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.icon == rhs.icon
            && lhs.search_facets == rhs.search_facets
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Project" : trimmed
    }
}

struct NVModernTextSubstitutionDraft: Codable, Equatable {
    var from: String
    var to: String
    var _uiID: UUID = UUID()

    init(from: String = "", to: String = "") {
        self.from = from
        self.to = to
    }

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    static func == (lhs: NVModernTextSubstitutionDraft, rhs: NVModernTextSubstitutionDraft) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to
    }
}

struct NVModernSyncDraft: Codable, Equatable {
    var mode: String?

    init(mode: String? = nil) {
        self.mode = mode
    }

    var encodedIfMeaningful: NVModernSyncDraft? {
        mode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? self : nil
    }
}

struct NVModernSocketDraft: Codable, Equatable {
    var enabled: Bool?
    var path: String?

    init(enabled: Bool? = nil, path: String? = nil) {
        self.enabled = enabled
        self.path = path
    }

    var encodedIfMeaningful: NVModernSocketDraft? {
        if enabled != nil { return self }
        if path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return self }
        return nil
    }
}

struct NVModernActionKeybindingDraft: Codable, Equatable {
    var id: String?
    var title: String?
    var key: String?
    var keystroke: String?
    var action: String?
    var method: String?
    var args: [String: ActionValue]?
    var target: ActionTarget?
    var when: String?
    var _uiID: UUID = UUID()

    static func == (lhs: NVModernActionKeybindingDraft, rhs: NVModernActionKeybindingDraft) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.key == rhs.key
            && lhs.keystroke == rhs.keystroke
            && lhs.action == rhs.action
            && lhs.method == rhs.method
            && lhs.args == rhs.args
            && lhs.target == rhs.target
            && lhs.when == rhs.when
    }

    init(
        id: String? = nil,
        title: String? = nil,
        key: String? = nil,
        keystroke: String? = nil,
        action: String? = nil,
        method: String? = nil,
        args: [String: ActionValue]? = nil,
        target: ActionTarget? = nil,
        when: String? = nil
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.keystroke = keystroke
        self.action = action
        self.method = method
        self.args = args
        self.target = target
        self.when = when
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case key
        case keystroke
        case action
        case method
        case args
        case target
        case when
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeTrimmedOptional(id, forKey: .id, into: &container)
        try encodeTrimmedOptional(title, forKey: .title, into: &container)
        try encodeTrimmedOptional(key, forKey: .key, into: &container)
        try encodeTrimmedOptional(keystroke, forKey: .keystroke, into: &container)
        try encodeTrimmedOptional(action, forKey: .action, into: &container)
        try encodeTrimmedOptional(method, forKey: .method, into: &container)
        if let args, !args.isEmpty {
            try container.encode(args, forKey: .args)
        }
        try container.encodeIfPresent(target, forKey: .target)
        try encodeTrimmedOptional(when, forKey: .when, into: &container)
    }
}

struct NVModernConfigSchema {
    static let shared = NVModernConfigSchema()

    static let syncModeOptions: [NVModernConfigOption] = [
        NVModernConfigOption(id: "prompt", title: "Prompt", summary: "Show the reload or keep-local banner when open files change on disk."),
        NVModernConfigOption(id: "live_file", title: "Live File", summary: "Automatically reload open workspace files when they change on disk.")
    ]

    static let documentThemeOptions: [NVModernConfigOption] = [
        NVModernConfigOption(id: "system", title: "System", summary: "SF Pro with one blue accent"),
        NVModernConfigOption(id: "newsprint", title: "Newsprint", summary: "Adobe Caslon in black ink"),
        NVModernConfigOption(id: "laurenziana", title: "Laurenziana", summary: "Michelangelus on plaster and stone"),
        NVModernConfigOption(id: "riso", title: "Riso", summary: "Fluorescent pink and mint spot inks"),
        NVModernConfigOption(id: "cyanotype", title: "Cyanotype", summary: "Blueprint mono on a drafting grid"),
        NVModernConfigOption(id: "kunsthalle", title: "Kunsthalle", summary: "Swiss poster grotesk with signal orange"),
        NVModernConfigOption(id: "dispatch", title: "Dispatch", summary: "Newsreader and Anek, a modern newspaper"),
        NVModernConfigOption(id: "outliner", title: "Outliner", summary: "One monospace size, an ink per level"),
        NVModernConfigOption(id: "catppuccin", title: "Catppuccin", summary: "Soothing pastels, Latte and Mocha"),
        NVModernConfigOption(id: "nord", title: "Nord", summary: "Polar Night, Frost and Aurora"),
        NVModernConfigOption(id: "mayfair", title: "Mayfair", summary: "Nebula Sans on ivory, with brass")
    ]

    static let documentWidthOptions: [NVModernConfigOption] = DocumentInspectorWidth.allCases.map {
        NVModernConfigOption(id: $0.rawValue, title: $0.title, summary: $0.cssValue)
    }

    let sections: [NVModernConfigSchemaSection]

    private init() {
        sections = [
            NVModernConfigSchemaSection(
                id: "general",
                title: "General",
                systemImage: "gearshape",
                fields: [
                    NVModernConfigField(
                        id: "root",
                        title: "Default Root",
                        summary: "Default project root when no project override is provided.",
                        kind: .optionalString(\.root, placeholder: "~/Documents/Notes", pathKind: .directory)
                    ),
                    NVModernConfigField(
                        id: "editor_theme",
                        title: "Editor Theme",
                        summary: "Theme id applied to all documents: a bundled theme or a CSS file in themes_dir.",
                        kind: .enumString(\.editor_theme, defaultValue: "system", options: Self.documentThemeOptions)
                    ),
                    NVModernConfigField(
                        id: "width",
                        title: "Document Width",
                        summary: "Default text width for newly opened document inspectors.",
                        kind: .enumString(\.width, defaultValue: "comfortable", options: Self.documentWidthOptions)
                    ),
                    NVModernConfigField(
                        id: "sync.mode",
                        title: "File Sync",
                        summary: "How open workspace files react to external edits.",
                        kind: .syncMode
                    ),
                    NVModernConfigField(
                        id: "editor_theme_css",
                        title: "Editor Theme CSS",
                        summary: "Optional CSS file loaded from the config directory or an absolute path.",
                        kind: .optionalString(\.editor_theme_css, placeholder: "~/.config/nvmodern/editor.css", pathKind: .file)
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "projects",
                title: "Projects",
                systemImage: "folder",
                fields: [
                    NVModernConfigField(
                        id: "projects",
                        title: "Projects",
                        summary: "Named project roots shown in nvModern.",
                        kind: .projects
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "search",
                title: "Search Facets",
                systemImage: "tag",
                fields: [
                    NVModernConfigField(
                        id: "search_facets",
                        title: "Global Search Facets",
                        summary: "Prefix mappings used when a project does not override them.",
                        kind: .searchFacetMap(\.search_facets)
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "people",
                title: "People",
                systemImage: "person.2",
                fields: [
                    NVModernConfigField(
                        id: "users",
                        title: "Mention Names",
                        summary: "Known people offered by @mention autocomplete.",
                        kind: .stringList(\.users)
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "substitutions",
                title: "Substitutions",
                systemImage: "textformat",
                fields: [
                    NVModernConfigField(
                        id: "substitutions",
                        title: "Text Substitutions",
                        summary: "Short text triggers expanded by the editor.",
                        kind: .substitutions
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "automation",
                title: "Automation",
                systemImage: "wand.and.stars",
                fields: [
                    NVModernConfigField(
                        id: "keybindings",
                        title: "Keybindings",
                        summary: "Configured shortcuts for actions or raw methods.",
                        kind: .keybindings
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "socket",
                title: "Socket",
                systemImage: "point.3.connected.trianglepath.dotted",
                fields: [
                    NVModernConfigField(
                        id: "socket",
                        title: "Action Socket",
                        summary: "Local JSON action socket transport.",
                        kind: .socket
                    )
                ]
            ),
            NVModernConfigSchemaSection(
                id: "raw",
                title: "Raw TOML",
                systemImage: "curlybraces",
                fields: [
                    NVModernConfigField(
                        id: "raw",
                        title: "Generated TOML",
                        summary: "Canonical TOML generated from the schema-backed draft.",
                        kind: .rawPreview
                    )
                ]
            )
        ]
    }
}

extension NVModernConfigSchema {
    static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("nvmodern", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    func loadDraft(fileManager: FileManager = .default) -> NVModernConfigDraftLoadResult {
        let configURL = Self.defaultConfigURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: configURL.path) else {
            let draft = defaultDraft(fileManager: fileManager)
            return NVModernConfigDraftLoadResult(
                draft: draft,
                configURL: configURL,
                diagnostics: [
                    NVModernConfigDiagnostic(
                        severity: .warning,
                        message: "config.toml is missing; a default draft was created.",
                        fieldID: nil
                    )
                ] + diagnostics(for: draft, configURL: configURL, fileManager: fileManager)
            )
        }

        guard let configText = try? String(contentsOf: configURL, encoding: .utf8) else {
            let draft = defaultDraft(fileManager: fileManager)
            return NVModernConfigDraftLoadResult(
                draft: draft,
                configURL: configURL,
                diagnostics: [
                    NVModernConfigDiagnostic(
                        severity: .error,
                        message: "Could not read config.toml; a default draft was created.",
                        fieldID: nil
                    )
                ] + diagnostics(for: draft, configURL: configURL, fileManager: fileManager)
            )
        }

        do {
            let draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: configText)
            return NVModernConfigDraftLoadResult(
                draft: draft,
                configURL: configURL,
                diagnostics: diagnostics(for: draft, configURL: configURL, fileManager: fileManager)
            )
        } catch {
            let draft = defaultDraft(fileManager: fileManager)
            return NVModernConfigDraftLoadResult(
                draft: draft,
                configURL: configURL,
                diagnostics: [
                    NVModernConfigDiagnostic(
                        severity: .error,
                        message: "Invalid config.toml: \(error.localizedDescription)",
                        fieldID: nil
                    )
                ] + diagnostics(for: draft, configURL: configURL, fileManager: fileManager)
            )
        }
    }

    func defaultDraft(fileManager: FileManager = .default) -> NVModernConfigDraft {
        let path = firstFallbackDirectory(fileManager: fileManager).path
        let project = NVModernProjectDraft(
            name: derivedProjectName(forPath: path),
            path: path
        )
        return NVModernConfigDraft(projects: [project])
    }

    func encodedTOML(for draft: NVModernConfigDraft) throws -> String {
        var encoder = TOMLEncoder()
        encoder.options = [
            .allowLiteralStrings,
            .allowMultilineStrings,
            .indentations
        ]
        return try encoder.encode(draft)
    }

    func saveDraft(_ draft: NVModernConfigDraft, configURL: URL, fileManager: FileManager = .default) throws {
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: configURL.path) {
            let backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("\(configURL.lastPathComponent).bak", isDirectory: false)
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try? fileManager.copyItem(at: configURL, to: backupURL)
        }

        let toml = try encodedTOML(for: draft)
        try toml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func diagnostics(
        for draft: NVModernConfigDraft,
        configURL: URL,
        fileManager: FileManager = .default
    ) -> [NVModernConfigDiagnostic] {
        var diagnostics: [NVModernConfigDiagnostic] = []
        var warningMessages: [String] = []

        _ = buildAppConfig(
            from: draft,
            configURL: configURL,
            warningMessages: &warningMessages,
            fileManager: fileManager
        )

        for warning in mergedWarningList(from: warningMessages) {
            diagnostics.append(NVModernConfigDiagnostic(severity: .warning, message: warning, fieldID: nil))
        }

        let validRoot = draft.root.map {
            isDirectory(standardizedDirectoryURL(resolvedURL(from: $0, home: fileManager.homeDirectoryForCurrentUser)), fileManager: fileManager)
        } ?? false
        let hasValidProject = draft.projects.contains { project in
            isDirectory(standardizedDirectoryURL(resolvedURL(from: project.path, home: fileManager.homeDirectoryForCurrentUser)), fileManager: fileManager)
        }
        if !validRoot && !hasValidProject {
            diagnostics.append(
                NVModernConfigDiagnostic(
                    severity: .error,
                    message: "Configure at least one existing root or project directory.",
                    fieldID: "root"
                )
            )
        }

        return diagnostics
    }
}

extension NVModernConfigSchema {
    static func load(projectRootPath: String? = nil, fileManager: FileManager = .default) -> NVModernRuntimeConfig {
        let appConfig = shared.loadAppConfig(fileManager: fileManager)
        let home = fileManager.homeDirectoryForCurrentUser

        var warningMessages: [String] = []
        if let warning = appConfig.warning {
            warningMessages.append(warning)
        }

        let activeProject: NVModernProject
        if let projectRootPath,
           let overrideProject = resolveProjectOverride(
               from: projectRootPath,
               home: home,
               availableProjects: appConfig.projects,
               fileManager: fileManager
           )
        {
            activeProject = overrideProject
        } else {
            if projectRootPath != nil {
                warningMessages.append("invalid window root override")
            }
            activeProject = appConfig.defaultProject
        }

        return NVModernRuntimeConfig(
            activeProject: activeProject,
            availableProjects: appConfig.projects,
            users: appConfig.users,
            editorThemeCSS: appConfig.editorThemeCSS,
            substitutions: appConfig.substitutions,
            keybindings: appConfig.keybindings,
            socket: appConfig.socket,
            sync: appConfig.sync,
            documentDefaults: appConfig.documentDefaults,
            warning: mergedWarning(from: warningMessages),
            configURL: appConfig.configURL
        )
    }

    func loadAppConfig(fileManager: FileManager = .default) -> NVModernAppConfig {
        let configURL = Self.defaultConfigURL(fileManager: fileManager)

        guard fileManager.fileExists(atPath: configURL.path) else {
            return fallbackAppConfig(
                configURL: configURL,
                users: [],
                editorThemeCSS: nil,
                substitutions: [],
                keybindings: [],
                socket: defaultSocketConfiguration(home: fileManager.homeDirectoryForCurrentUser),
                sync: .default,
                documentDefaults: .default,
                warning: "config.toml missing",
                fileManager: fileManager
            )
        }

        guard let configText = try? String(contentsOf: configURL, encoding: .utf8) else {
            return fallbackAppConfig(
                configURL: configURL,
                users: [],
                editorThemeCSS: nil,
                substitutions: [],
                keybindings: [],
                socket: defaultSocketConfiguration(home: fileManager.homeDirectoryForCurrentUser),
                sync: .default,
                documentDefaults: .default,
                warning: "could not read config.toml",
                fileManager: fileManager
            )
        }

        let draft: NVModernConfigDraft
        do {
            draft = try TOMLDecoder().decode(NVModernConfigDraft.self, from: configText)
        } catch {
            return fallbackAppConfig(
                configURL: configURL,
                users: [],
                editorThemeCSS: nil,
                substitutions: [],
                keybindings: [],
                socket: defaultSocketConfiguration(home: fileManager.homeDirectoryForCurrentUser),
                sync: .default,
                documentDefaults: .default,
                warning: "invalid config.toml: \(error.localizedDescription)",
                fileManager: fileManager
            )
        }

        var warningMessages: [String] = []
        var config = buildAppConfig(
            from: draft,
            configURL: configURL,
            warningMessages: &warningMessages,
            fileManager: fileManager
        )
        config.plugins = draft.plugins
        if draft.containsRetiredActionTables && config.warning?.contains("[[actions]]") != true {
            config.warning = mergedWarning(from: [config.warning, "[[actions]] is no longer supported; migrate these actions to plugins"].compactMap { $0 })
        }
        return config
    }
}

private extension NVModernConfigSchema {
    func buildAppConfig(
        from draft: NVModernConfigDraft,
        configURL: URL,
        warningMessages: inout [String],
        fileManager: FileManager
    ) -> NVModernAppConfig {
        let home = fileManager.homeDirectoryForCurrentUser
        if draft.containsRetiredActionTables { warningMessages.append("[[actions]] is no longer supported; migrate these actions to plugins") }
        if draft.migratedOrgFontFamily {
            warningMessages.append("org_font_family is retired; it now applies as [filetypes.org] font_family")
        }
        let users = draft.users
        // Effective editor theme CSS, resolved across both roots (user themes
        // directory first, then bundled themes). `editor_theme` accepts any
        // theme id; the legacy top-level `theme` key aliases into it when
        // `editor_theme` is unset. `system`/nil means no theme CSS.
        let themesDirectory = UserEditorThemeCatalog.resolvedDirectoryURL(
            from: draft.themes_dir,
            configURL: configURL
        )
        UserEditorThemeCatalog.setCachedDirectory(themesDirectory)

        let editorThemeID = resolveEditorThemeID(
            configured: draft.editor_theme,
            legacy: draft.theme,
            themesDirectory: themesDirectory,
            fileManager: fileManager,
            warningMessages: &warningMessages
        )
        var selectedThemeCSS: String?
        if let editorThemeID {
            if let css = UserEditorThemeCatalog.cssText(for: editorThemeID, in: themesDirectory, fileManager: fileManager) {
                selectedThemeCSS = css
            } else {
                warningMessages.append("editor_theme not found: \(editorThemeID)")
            }
        }
        let overrideThemeCSS = decodeEditorThemeCSS(
            from: draft.editor_theme_css,
            configURL: configURL,
            warningMessages: &warningMessages
        )
        let editorThemeCSS = mergedEditorThemeCSS([selectedThemeCSS, overrideThemeCSS])
        let substitutions: [NVModernTextSubstitutionRule] = draft.substitutions.compactMap { substitution in
            let from = substitution.from
            guard !from.isEmpty else { return nil }
            return NVModernTextSubstitutionRule(from: from, to: substitution.to)
        }

        let defaultSearchFacetMap = decodeSearchFacetMap(draft.search_facets)

        var configuredProjects: [NVModernProject] = []
        var seenProjectPaths = Set<String>()

        func appendProject(name: String, path: String, icon: String?, searchFacetMap: NVModernSearchFacetMap, source: String) {
            let resolved = standardizedDirectoryURL(resolvedURL(from: path, home: home))
            guard isDirectory(resolved, fileManager: fileManager) else {
                warningMessages.append("project '\(name)' has invalid path: \(path)")
                return
            }

            let key = resolved.path
            guard !seenProjectPaths.contains(key) else { return }
            seenProjectPaths.insert(key)

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedIcon = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
            configuredProjects.append(
                NVModernProject(
                    name: trimmedName.isEmpty ? projectName(for: resolved) : trimmedName,
                    rootURL: resolved,
                    source: source,
                    icon: (trimmedIcon?.isEmpty == false) ? trimmedIcon : nil,
                    searchFacetMap: searchFacetMap.isEmpty ? defaultSearchFacetMap : searchFacetMap
                )
            )
        }

        for (index, project) in draft.projects.enumerated() {
            appendProject(
                name: project.name,
                path: project.path,
                icon: project.icon,
                searchFacetMap: decodeSearchFacetMap(project.search_facets),
                source: "config.toml projects[\(index)]"
            )
        }

        let defaultProject: NVModernProject
        if let configuredPath = draft.root {
            let configuredURL = standardizedDirectoryURL(resolvedURL(from: configuredPath, home: home))
            if isDirectory(configuredURL, fileManager: fileManager) {
                defaultProject = configuredProjects.first(where: { $0.id == configuredURL.path }) ?? NVModernProject(
                    name: projectName(for: configuredURL),
                    rootURL: configuredURL,
                    source: "config.toml",
                    icon: nil,
                    searchFacetMap: defaultSearchFacetMap
                )
            } else if let firstProject = configuredProjects.first {
                defaultProject = firstProject
                warningMessages.append("invalid root in config.toml; defaulting to first project")
            } else {
                return fallbackAppConfig(
                    configURL: configURL,
                    users: users,
                    editorThemeCSS: editorThemeCSS,
                    substitutions: substitutions,
                    keybindings: [],
                    socket: defaultSocketConfiguration(home: fileManager.homeDirectoryForCurrentUser),
                    sync: .default,
                    documentDefaults: .default,
                    warning: "invalid root in config.toml",
                    fileManager: fileManager
                )
            }
        } else if let firstProject = configuredProjects.first {
            defaultProject = firstProject
        } else {
            return fallbackAppConfig(
                configURL: configURL,
                users: users,
                editorThemeCSS: editorThemeCSS,
                substitutions: substitutions,
                keybindings: [],
                socket: defaultSocketConfiguration(home: fileManager.homeDirectoryForCurrentUser),
                sync: .default,
                documentDefaults: .default,
                warning: "missing root in config.toml",
                fileManager: fileManager
            )
        }

        var allProjects = [defaultProject]
        var seenAllProjects: Set<String> = [defaultProject.id]
        for project in configuredProjects where !seenAllProjects.contains(project.id) {
            seenAllProjects.insert(project.id)
            allProjects.append(project)
        }

        let keybindings = decodeKeybindings(draft.keybindings, warningMessages: &warningMessages)
        let socket = decodeSocket(draft.socket, home: home)
        let sync = decodeSync(draft.sync, warningMessages: &warningMessages)
        var documentDefaults = decodeDocumentDefaults(
            width: draft.width,
            filetypes: draft.filetypes,
            globalThemeCSS: selectedThemeCSS,
            overrideThemeCSS: overrideThemeCSS,
            themesDirectory: themesDirectory,
            fileManager: fileManager,
            warningMessages: &warningMessages
        )
        documentDefaults.tintsWindow = draft.window_tint ?? true

        return NVModernAppConfig(
            plugins: draft.plugins,
            defaultProject: defaultProject,
            projects: allProjects,
            users: users,
            editorThemeCSS: editorThemeCSS,
            substitutions: substitutions,
            keybindings: keybindings,
            socket: socket,
            sync: sync,
            documentDefaults: documentDefaults,
            configURL: configURL,
            warning: mergedWarning(from: warningMessages)
        )
    }

    func fallbackAppConfig(
        configURL: URL,
        users: [String],
        editorThemeCSS: String?,
        substitutions: [NVModernTextSubstitutionRule],
        keybindings: [ActionKeybindingDefinition],
        socket: ActionSocketConfiguration?,
        sync: NVModernSyncConfig,
        documentDefaults: NVModernDocumentDefaultsConfig,
        warning: String,
        fileManager: FileManager
    ) -> NVModernAppConfig {
        let fallbackURL = standardizedDirectoryURL(firstFallbackDirectory(fileManager: fileManager))
        let fallbackProject = NVModernProject(
            name: projectName(for: fallbackURL),
            rootURL: fallbackURL,
            source: "fallback",
            icon: nil,
            searchFacetMap: .empty
        )

        return NVModernAppConfig(
            defaultProject: fallbackProject,
            projects: [fallbackProject],
            users: users,
            editorThemeCSS: editorThemeCSS,
            substitutions: substitutions,
            keybindings: keybindings,
            socket: socket,
            sync: sync,
            documentDefaults: documentDefaults,
            configURL: configURL,
            warning: warning
        )
    }

    func decodeKeybindings(
        _ drafts: [NVModernActionKeybindingDraft],
        warningMessages: inout [String]
    ) -> [ActionKeybindingDefinition] {
        var bindings: [ActionKeybindingDefinition] = []
        var seenIDs = Set<String>()

        for (index, draft) in drafts.enumerated() {
            let id = draft.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? draft.id!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "keybinding-\(index + 1)"

            guard !seenIDs.contains(id) else {
                warningMessages.append("duplicate keybinding id '\(id)' ignored")
                continue
            }

            let keystroke = (draft.keystroke ?? draft.key ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keystroke.isEmpty else {
                if draft.method?.isEmpty != false {
                    warningMessages.append("keybinding '\(id)' is missing a keystroke and was ignored")
                }
                continue
            }

            let invocation: ActionInvocationReference
            if let retiredActionID = draft.action?.trimmingCharacters(in: .whitespacesAndNewlines), !retiredActionID.isEmpty {
                warningMessages.append("keybinding '\(id)' uses retired action '\(retiredActionID)' and was ignored; use a plugin method")
                continue
            } else if let method = draft.method?.trimmingCharacters(in: .whitespacesAndNewlines), !method.isEmpty {
                invocation = .method(method: method, args: draft.args ?? [:], target: draft.target)
            } else {
                warningMessages.append("keybinding '\(id)' is missing an action or method and was ignored")
                continue
            }

            bindings.append(
                ActionKeybindingDefinition(
                    id: id,
                    title: draft.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                    keystroke: keystroke,
                    invocation: invocation,
                    when: draft.when?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            seenIDs.insert(id)
        }

        return bindings
    }

    func decodeSocket(_ draft: NVModernSocketDraft?, home: URL) -> ActionSocketConfiguration? {
        ActionSocketConfiguration.make(
            enabled: draft?.enabled,
            path: draft?.path,
            home: home,
            resolvePath: { resolvedFileURL(from: $0, home: home) }
        )
    }

    func decodeSync(
        _ draft: NVModernSyncDraft?,
        warningMessages: inout [String]
    ) -> NVModernSyncConfig {
        guard let draft else {
            return .default
        }

        let normalizedMode = draft.mode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        guard let normalizedMode, !normalizedMode.isEmpty else {
            return .default
        }

        switch normalizedMode {
        case "prompt", "ask":
            return NVModernSyncConfig(mode: .prompt)
        case "live_file", "auto_reload", "autoreload":
            return NVModernSyncConfig(mode: .liveFile)
        default:
            warningMessages.append("unknown sync.mode '\(normalizedMode)'; defaulting to prompt")
            return .default
        }
    }

    func decodeDocumentDefaults(
        width configuredWidth: String?,
        filetypes configuredFiletypes: [String: NVModernFiletypeDraft],
        globalThemeCSS: String?,
        overrideThemeCSS: String?,
        themesDirectory: URL,
        fileManager: FileManager,
        warningMessages: inout [String]
    ) -> NVModernDocumentDefaultsConfig {
        let width = decodeDocumentInspectorWidth(configuredWidth, warningMessages: &warningMessages)
        var filetypes: [String: NVModernFiletypeAppearance] = [:]
        for (rawExtension, draft) in configuredFiletypes.sorted(by: { $0.key < $1.key }) where !draft.isEmpty {
            let ext = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !ext.isEmpty, !ext.contains("/") else {
                warningMessages.append("invalid filetypes key '\(rawExtension)'")
                continue
            }

            var themeID: String?
            var baseThemeCSS = globalThemeCSS
            if let rawTheme = draft.theme?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTheme.isEmpty {
                if let parsed = DocumentFrontmatterAppearance.parseTheme(rawTheme) {
                    themeID = parsed.rawValue
                    if parsed.rawValue == UserEditorThemeCatalog.reservedThemeID {
                        baseThemeCSS = nil
                    } else if let css = UserEditorThemeCatalog.cssText(for: parsed.rawValue, in: themesDirectory, fileManager: fileManager) {
                        baseThemeCSS = css
                    } else {
                        warningMessages.append("filetypes.\(ext) theme not found: \(parsed.rawValue)")
                    }
                } else {
                    warningMessages.append("invalid filetypes.\(ext) theme")
                }
            }

            var fontFamily: String?
            if let rawFont = draft.font_family, !rawFont.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fontFamily = DocumentFrontmatterAppearance.sanitizedFontFamily(rawFont)
                if fontFamily == nil {
                    warningMessages.append("invalid filetypes.\(ext) font_family")
                }
            }

            filetypes[ext] = NVModernFiletypeAppearance(
                themeID: themeID,
                fontFamily: fontFamily,
                editorThemeCSS: mergedEditorThemeCSS([
                    baseThemeCSS,
                    overrideThemeCSS,
                    fontFamily.map(DocumentInspectorAppearance.fontOverrideCSS(fontFamily:)),
                ])
            )
        }
        return NVModernDocumentDefaultsConfig(width: width, filetypes: filetypes)
    }

    func decodeDocumentInspectorWidth(
        _ configuredWidth: String?,
        warningMessages: inout [String]
    ) -> DocumentInspectorWidth {
        let normalizedWidth = normalizedDocumentInspectorValue(configuredWidth)
        guard let normalizedWidth, !normalizedWidth.isEmpty else {
            return DocumentInspectorSettings.default.width
        }

        if let width = DocumentInspectorWidth(configuredValue: configuredWidth) {
            return width
        }

        warningMessages.append("unknown width '\(normalizedWidth)'; defaulting to comfortable")
        return DocumentInspectorSettings.default.width
    }

    func normalizedDocumentInspectorValue(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    /// Resolves the effective global theme id from `editor_theme`, falling
    /// back to the legacy top-level `theme` key when unset. Legacy values are
    /// matched against bundled theme ids case-insensitively; unknown values
    /// warn and resolve to no theme, matching the old behavior.
    func resolveEditorThemeID(
        configured: String?,
        legacy: String?,
        themesDirectory: URL,
        fileManager: FileManager,
        warningMessages: inout [String]
    ) -> String? {
        let configuredID = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredID, !configuredID.isEmpty {
            if configuredID.lowercased() == UserEditorThemeCatalog.reservedThemeID {
                return nil
            }
            return configuredID
        }

        guard let legacyID = legacy?.trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyID.isEmpty else {
            return nil
        }
        if legacyID.lowercased() == UserEditorThemeCatalog.reservedThemeID || legacyID.lowercased() == "default" {
            return nil
        }
        if let bundledID = UserEditorThemeCatalog.bundledThemeID(matching: legacyID) {
            return bundledID
        }

        warningMessages.append("unknown theme '\(legacyID)'; defaulting to system")
        return nil
    }

    func mergedEditorThemeCSS(_ layers: [String?]) -> String? {
        let cssLayers = layers.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cssLayers.isEmpty else { return nil }
        return cssLayers.joined(separator: "\n\n")
    }

    func decodeEditorThemeCSS(
        from configuredPath: String?,
        configURL: URL,
        warningMessages: inout [String]
    ) -> String? {
        let trimmedPath = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPath, !trimmedPath.isEmpty else {
            return nil
        }

        let fileURL = resolvedConfigFileURL(from: trimmedPath, configURL: configURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            warningMessages.append("editor_theme_css file not found: \(trimmedPath)")
            return nil
        }

        do {
            let css = try String(contentsOf: fileURL, encoding: .utf8)
            return css.isEmpty ? nil : css
        } catch {
            warningMessages.append("could not read editor_theme_css: \(trimmedPath)")
            return nil
        }
    }

    func decodeSearchFacetMap(_ rawMappings: [String: [String: String]]?) -> NVModernSearchFacetMap {
        guard let rawMappings else { return .empty }

        var mappingsByFacetKey: [String: [String: String]] = [:]
        for (rawFacetKey, rawPrefixMap) in rawMappings {
            let facetKey = rawFacetKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard NVModernSearchFacetMap.configurableFacetKeys.contains(facetKey) else { continue }

            var normalizedPrefixMap: [String: String] = [:]
            for (rawPrefix, rawValue) in rawPrefixMap {
                let prefix = NVModernSearchFacetMap.normalizePathPrefix(rawPrefix)
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                normalizedPrefixMap[prefix] = value
            }

            if !normalizedPrefixMap.isEmpty {
                mappingsByFacetKey[facetKey] = normalizedPrefixMap
            }
        }

        return NVModernSearchFacetMap(mappingsByFacetKey: mappingsByFacetKey)
    }
}

private func encodeTrimmedOptional<K: CodingKey>(
    _ value: String?,
    forKey key: K,
    into container: inout KeyedEncodingContainer<K>
) throws {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    try container.encode(value, forKey: key)
}

private func defaultSocketConfiguration(home: URL) -> ActionSocketConfiguration {
    ActionSocketConfiguration(
        isEnabled: true,
        socketURL: ActionSocketConfiguration.defaultSocketURL(home: home)
    )
}

private func resolveProjectOverride(
    from path: String,
    home: URL,
    availableProjects: [NVModernProject],
    fileManager: FileManager
) -> NVModernProject? {
    let resolved = standardizedDirectoryURL(resolvedURL(from: path, home: home))
    guard isDirectory(resolved, fileManager: fileManager) else {
        return nil
    }

    if let matchedProject = availableProjects.first(where: { $0.id == resolved.path }) {
        return matchedProject
    }

    return NVModernProject(
        name: projectName(for: resolved),
        rootURL: resolved,
        source: "window override",
        icon: nil,
        searchFacetMap: .empty
    )
}

private func mergedWarning(from warnings: [String]) -> String? {
    let orderedWarnings = mergedWarningList(from: warnings)
    guard !orderedWarnings.isEmpty else { return nil }
    return orderedWarnings.joined(separator: "; ")
}

private func mergedWarningList(from warnings: [String]) -> [String] {
    let filteredWarnings = warnings.filter { !$0.isEmpty }
    var orderedWarnings: [String] = []
    var seenWarnings = Set<String>()
    for warning in filteredWarnings where !seenWarnings.contains(warning) {
        seenWarnings.insert(warning)
        orderedWarnings.append(warning)
    }
    return orderedWarnings
}

private func resolvedURL(from configuredPath: String, home: URL) -> URL {
    let expanded = NSString(string: configuredPath).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
    return home.appendingPathComponent(expanded, isDirectory: true)
}

private func resolvedFileURL(from configuredPath: String, home: URL) -> URL {
    let expanded = NSString(string: configuredPath).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded, isDirectory: false)
    }
    return home.appendingPathComponent(expanded, isDirectory: false)
}

private func resolvedConfigFileURL(from configuredPath: String, configURL: URL) -> URL {
    let expanded = NSString(string: configuredPath).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded, isDirectory: false)
    }

    let baseURL = configURL.deletingLastPathComponent()
    return baseURL.appendingPathComponent(expanded, isDirectory: false).standardizedFileURL
}

private func standardizedDirectoryURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
}

private func projectName(for url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
        return name
    }
    return url.path
}

private func firstFallbackDirectory(fileManager: FileManager) -> URL {
    let home = fileManager.homeDirectoryForCurrentUser
    let documents = home.appendingPathComponent("Documents", isDirectory: true)
    if isDirectory(documents, fileManager: fileManager) {
        return documents
    }

    if let repository = sourceRepositoryDirectory(fileManager: fileManager) {
        return repository
    }

    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    if isDirectory(cwd, fileManager: fileManager) {
        return cwd
    }

    return home
}

private func sourceRepositoryDirectory(fileManager: FileManager) -> URL? {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = sourceURL
        .deletingLastPathComponent() // Config
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // NVModern
        .deletingLastPathComponent() // repo root

    guard isDirectory(repositoryURL, fileManager: fileManager) else {
        return nil
    }

    return repositoryURL
}

private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}
