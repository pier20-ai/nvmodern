import Foundation

/// Resolves the keyboard shortcut glyphs a palette row shows for an action.
///
/// Three sources, highest precedence first:
///
/// 1. user `[[keybindings]]` rows whose invocation targets the method,
/// 2. `CommandCatalog` entries invoking the method (their default keystroke;
///    a user override for a catalog entry is written back into config as a
///    `[[keybindings]]` row carrying the same method, so step 1 already covers
///    it — the one case this misses is an explicitly unbound catalog entry,
///    whose row is dropped at parse time),
/// 3. a static table of shortcuts the menu bar owns, which never appear in
///    config at all (`Cmd+T`, `Cmd+W`, `Cmd+F`, …).
///
/// Config parsing is not cheap, so the resolved method → keystroke map is
/// cached per project root and rebuilt only when `invalidate()` is called.
@MainActor
enum PaletteShortcutResolver {
    /// Display glyphs for the method's shortcut ("⌘⇧D"), or nil when it has none.
    static func shortcutLabel(forMethod method: String, projectRootPath: String?) -> String? {
        guard let keystroke = keystrokeMap(projectRootPath: projectRootPath)[method] else {
            return nil
        }
        let label = Keystroke.symbolize(keystroke)
        return label.isEmpty ? nil : label
    }

    /// Drops the cache. Call after the config file changes.
    static func invalidate() {
        cachedMaps.removeAll()
    }

    /// Shortcuts owned by the menu bar or the global key monitor rather than by
    /// config, so the palette can still show them.
    static let menuOwnedKeystrokes: [String: String] = [
        "workspace.tab.new": "cmd+t",
        "workspace.tab.close": "cmd+w",
        "workspace.tab.selectNext": "cmd+shift+]",
        "workspace.tab.selectPrevious": "cmd+shift+[",
        "workspace.tab.showAll": "cmd+shift+\\",
        "workspace.document.find": "cmd+f",
        "workspace.document.outline": "cmd+shift+o",
        "workspace.document.appearance": "cmd+opt+i",
        "workspace.split.right": "cmd+d",
        "workspace.split.down": "cmd+shift+d",
        "workspace.sidebar.toggle": "cmd+ctrl+s",
        WorkspaceSideStackBuiltinActions.toggleMethod: WorkspaceSideStackBuiltinActions.toggleKeystroke,
        WorkspaceSideStackBuiltinActions.focusMethod: WorkspaceSideStackBuiltinActions.focusKeystroke
    ]

    private static var cachedMaps: [String: [String: String]] = [:]

    private static func keystrokeMap(projectRootPath: String?) -> [String: String] {
        let cacheKey = projectRootPath ?? ""
        if let cached = cachedMaps[cacheKey] {
            return cached
        }
        let map = buildKeystrokeMap(projectRootPath: projectRootPath)
        cachedMaps[cacheKey] = map
        return map
    }

    private static func buildKeystrokeMap(projectRootPath: String?) -> [String: String] {
        // Lowest precedence first; later writes win.
        var map: [String: String] = menuOwnedKeystrokes.mapValues(Keystroke.normalize)

        for entry in CommandCatalog.entries {
            guard case .method(let method, _, _) = entry.invocation,
                  let defaultKeystroke = entry.defaultKeystroke else {
                continue
            }
            let normalized = Keystroke.normalize(defaultKeystroke)
            guard !normalized.isEmpty else { continue }
            map[method] = normalized
        }

        let config = NVModernConfigLoader.load(projectRootPath: projectRootPath)
        for binding in config.keybindings {
            guard let method = binding.invocation.methodName else { continue }
            let normalized = Keystroke.normalize(binding.keystroke)
            guard !normalized.isEmpty else { continue }
            map[method] = normalized
        }

        return map
    }
}
