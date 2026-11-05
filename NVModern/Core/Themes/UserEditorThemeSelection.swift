import Foundation

/// Persists the `editor_theme` selection into `config.toml`.
///
/// Shared by the `workspace.theme.*` actions so palette, keybindings, socket,
/// and CLI selections all land in the same place the Settings draft writes to.
enum UserEditorThemeSelection {
    /// Writes the selection and announces it through `.nvModernConfigDidChange`,
    /// which reloads runtime configs and re-pushes editor CSS to open tabs.
    /// Passing nil clears the selection (back to bundled defaults).
    ///
    /// Refuses to write when `config.toml` is missing or fails to decode:
    /// saving a fallback draft would replace a broken config with defaults.
    static func persist(_ themeID: String?) throws {
        let schema = NVModernConfigSchema.shared
        let configURL = NVModernConfigSchema.defaultConfigURL()

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ActionError.unavailable("config.toml does not exist; create it before selecting a theme")
        }

        let result = schema.loadDraft()
        if result.diagnostics.contains(where: { $0.severity == .error }) {
            throw ActionError.unavailable("config.toml has errors; fix them before selecting a theme")
        }

        let trimmed = themeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        guard result.draft.editor_theme?.trimmingCharacters(in: .whitespacesAndNewlines) != normalized else {
            return
        }

        var draft = result.draft
        draft.editor_theme = normalized
        try schema.saveDraft(draft, configURL: result.configURL)
        // Announce after a short delay: the config-change observers run a full
        // workspace reload on the main thread, and socket/CLI callers should
        // receive the action response before that work starts. sendResponse
        // re-enters the main actor right after the handler returns, so the
        // delayed enqueue is what lets the reply win the race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .nvModernConfigDidChange, object: configURL)
        }
    }

    /// The configured themes directory, resolved the same way the config
    /// loader resolves it.
    static func themesDirectory() -> URL {
        let result = NVModernConfigSchema.shared.loadDraft()
        return UserEditorThemeCatalog.resolvedDirectoryURL(
            from: result.draft.themes_dir,
            configURL: result.configURL
        )
    }

    /// The current selection id, if one is configured.
    static func selectedThemeID() -> String? {
        let result = NVModernConfigSchema.shared.loadDraft()
        let trimmed = result.draft.editor_theme?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
