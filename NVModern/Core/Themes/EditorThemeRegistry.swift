import Foundation

/// One entry in the unified theme set shown by the Document Inspector and the
/// Settings appearance pane. Every theme is a CSS file — bundled in the app
/// package or authored in the user themes directory — except the `system`
/// entry, which means "no theme, bundled defaults only".
struct AvailableEditorTheme: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let swatchHexes: [String]
    let isBundled: Bool
    let fileURL: URL?
}

enum EditorThemeRegistry {
    static let systemThemeID = UserEditorThemeCatalog.reservedThemeID

    /// The unified theme set: System first, then bundled themes, then user
    /// themes. A user file sharing a bundled id shadows it in place, so
    /// customizing a built-in is a matter of dropping in a same-named file.
    static func availableThemes(
        in userDirectory: URL,
        fileManager: FileManager = .default
    ) -> [AvailableEditorTheme] {
        var result: [AvailableEditorTheme] = [
            AvailableEditorTheme(
                id: systemThemeID,
                title: "System",
                subtitle: "Default editor palette",
                swatchHexes: [],
                isBundled: true,
                fileURL: nil
            )
        ]

        func append(_ theme: UserEditorTheme, shadowing: Bool) {
            if let index = result.firstIndex(where: { $0.id.lowercased() == theme.id.lowercased() }) {
                guard shadowing else { return }
                result[index] = AvailableEditorTheme(
                    id: theme.id,
                    title: theme.title,
                    subtitle: theme.subtitle ?? "Custom theme",
                    swatchHexes: theme.swatchHexes,
                    isBundled: false,
                    fileURL: theme.fileURL
                )
                return
            }
            result.append(
                AvailableEditorTheme(
                    id: theme.id,
                    title: theme.title,
                    subtitle: theme.subtitle ?? (theme.isBundled ? "Built-in theme" : "Custom theme"),
                    swatchHexes: theme.swatchHexes,
                    isBundled: theme.isBundled,
                    fileURL: theme.fileURL
                )
            )
        }

        for theme in UserEditorThemeCatalog.bundledThemes() {
            append(theme, shadowing: false)
        }
        for theme in UserEditorThemeCatalog.themes(in: userDirectory, fileManager: fileManager) {
            append(theme, shadowing: true)
        }

        return result
    }

    /// The registry entry for a theme id, if it exists in either root.
    static func theme(
        withID id: String,
        in userDirectory: URL,
        fileManager: FileManager = .default
    ) -> AvailableEditorTheme? {
        availableThemes(in: userDirectory, fileManager: fileManager)
            .first { $0.id.lowercased() == id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    /// True when `id` refers to System or a theme file in either root.
    static func isKnownThemeID(
        _ id: String,
        in userDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        theme(withID: id, in: userDirectory, fileManager: fileManager) != nil
    }
}
