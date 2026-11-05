import Foundation

/// A user-configurable command that can be assigned a keyboard shortcut from the
/// Shortcuts pane in Settings. The catalog is the source of truth for what's
/// configurable and what defaults exist; the user's TOML only stores *overrides*.
///
/// Note: built-in / inbuilt shortcuts (e.g. Cmd-B for Bold) are not represented as
/// catalog entries — they live in their respective subsystems (editor extensions,
/// menus, etc.). They appear here only as `CommandCatalog.reservedKeystrokes` so
/// the recorder can refuse to bind over them.
struct CommandCatalogEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String?
    let group: CommandCatalogGroup
    let kind: CommandKind
    let invocation: CommandInvocation
    let defaultKeystroke: String?
}

enum CommandCatalogGroup: String, CaseIterable, Codable, Sendable {
    case workspace
    case notes
    case tables

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .notes: return "Notes"
        case .tables: return "Tables"
        }
    }

    /// Stable ordering for grouped UI rendering.
    var sortOrder: Int {
        switch self {
        case .workspace: return 0
        case .notes: return 1
        case .tables: return 2
        }
    }
}

/// Whether the command is common enough to warrant a default keystroke
/// (which may also conflict with other defaults the user wants), or special enough
/// that we ship it without a default.
enum CommandKind: String, Codable, Sendable {
    case common
    case special
}

enum CommandInvocation: Equatable, Sendable {
    case method(String, args: [String: ActionValue] = [:], target: ActionTarget? = nil)
}

struct ReservedKeystroke: Equatable, Sendable {
    /// Canonical (normalized) keystroke string.
    let keystroke: String
    let purpose: String

    init(keystroke: String, purpose: String) {
        self.keystroke = Keystroke.normalize(keystroke)
        self.purpose = purpose
    }
}

/// Code-only registry. Add new commands by appending one entry below.
enum CommandCatalog {
    /// Curated starter set. New commands are appended here.
    static let entries: [CommandCatalogEntry] = [
        CommandCatalogEntry(
            id: "workspace.tab.split-right",
            title: "Split Tab Right",
            summary: "Open a new pane to the right of the current tab.",
            group: .workspace,
            kind: .common,
            invocation: .method("workspace.split.right"),
            defaultKeystroke: "cmd+d"
        ),
        CommandCatalogEntry(
            id: "workspace.tab.split-down",
            title: "Split Tab Down",
            summary: "Open a new pane below the current tab.",
            group: .workspace,
            kind: .common,
            invocation: .method("workspace.split.down"),
            defaultKeystroke: "cmd+shift+d"
        ),
        CommandCatalogEntry(
            id: "workspace.tab.duplicate",
            title: "Duplicate Tab",
            summary: "Duplicate the current tab in place.",
            group: .workspace,
            kind: .special,
            invocation: .method("workspace.tab.duplicate"),
            defaultKeystroke: nil
        ),
        CommandCatalogEntry(
            id: "workspace.note.create",
            title: "New Note",
            summary: "Create a new note in the active workspace.",
            group: .notes,
            kind: .common,
            invocation: .method("workspace.note.create"),
            defaultKeystroke: nil
        ),
        CommandCatalogEntry(
            id: "workspace.note.reveal-in-finder",
            title: "Reveal Note in Finder",
            summary: "Show the active document in Finder.",
            group: .notes,
            kind: .special,
            invocation: .method("workspace.document.reveal"),
            defaultKeystroke: nil
        ),
        CommandCatalogEntry(
            id: "markdown.table.row.insert-below",
            title: "Insert Row Below",
            summary: "Add a row below the current row in the active table.",
            group: .tables,
            kind: .special,
            invocation: .method("markdown.table.row.insertBelow"),
            defaultKeystroke: nil
        ),
        CommandCatalogEntry(
            id: "markdown.table.column.insert-right",
            title: "Insert Column Right",
            summary: "Add a column to the right of the current column in the active table.",
            group: .tables,
            kind: .special,
            invocation: .method("markdown.table.column.insertRight"),
            defaultKeystroke: nil
        )
    ]

    /// Inbuilt keystrokes the recorder must never let the user reassign.
    /// Update this list when a new editor extension or app menu claims a shortcut.
    static let reservedKeystrokes: [ReservedKeystroke] = [
        ReservedKeystroke(keystroke: "cmd+b", purpose: "Bold"),
        ReservedKeystroke(keystroke: "cmd+i", purpose: "Italic"),
        ReservedKeystroke(keystroke: "cmd+k", purpose: "Quick Find"),
        ReservedKeystroke(keystroke: "cmd+shift+k", purpose: "Actions"),
        ReservedKeystroke(keystroke: "cmd+shift+h", purpose: "Highlight Selection"),
        ReservedKeystroke(keystroke: "cmd+opt+left", purpose: "Date Previous"),
        ReservedKeystroke(keystroke: "cmd+opt+right", purpose: "Date Next"),
        ReservedKeystroke(keystroke: "cmd+w", purpose: "Close Tab"),
        ReservedKeystroke(keystroke: "cmd+t", purpose: "New Tab"),
        ReservedKeystroke(keystroke: "cmd+n", purpose: "Capture"),
        ReservedKeystroke(keystroke: "cmd+shift+n", purpose: "New Window"),
        ReservedKeystroke(keystroke: "cmd+r", purpose: "Refile"),
        ReservedKeystroke(keystroke: "cmd+f", purpose: "Find in Document"),
        ReservedKeystroke(keystroke: "cmd+shift+f", purpose: "Content Search"),
        ReservedKeystroke(keystroke: "cmd+,", purpose: "Settings"),
        ReservedKeystroke(keystroke: "cmd+s", purpose: "Save"),
        ReservedKeystroke(keystroke: "cmd+opt+s", purpose: "Toggle Side Stack"),
        ReservedKeystroke(keystroke: "cmd+opt+j", purpose: "Focus Side Stack")
    ]

    static func entry(id: String) -> CommandCatalogEntry? {
        entries.first { $0.id == id }
    }

    static func entriesGrouped() -> [(group: CommandCatalogGroup, entries: [CommandCatalogEntry])] {
        let grouped = Dictionary(grouping: entries, by: \.group)
        return CommandCatalogGroup.allCases
            .compactMap { group in
                guard let list = grouped[group], !list.isEmpty else { return nil }
                return (group, list)
            }
            .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }
}

/// Keystroke canonicalization. The catalog, conflict detection, and TOML all
/// compare keystrokes via the normalized form: lowercased, modifiers in fixed
/// order (`cmd+ctrl+opt+shift+<key>`), aliases collapsed.
enum Keystroke {
    private static let modifierOrder = ["cmd", "ctrl", "opt", "shift"]

    private static let modifierAliases: [String: String] = [
        "command": "cmd",
        "control": "ctrl",
        "alt": "opt",
        "option": "opt",
        "\u{2318}": "cmd",   // ⌘
        "\u{2303}": "ctrl",  // ⌃
        "\u{2325}": "opt",   // ⌥
        "\u{21E7}": "shift"  // ⇧
    ]

    /// Returns the canonical form of a keystroke string, or "" for empty input.
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = trimmed
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var modifiers = Set<String>()
        var keyParts: [String] = []

        for raw in tokens {
            let resolved = modifierAliases[raw] ?? raw
            if modifierOrder.contains(resolved) {
                modifiers.insert(resolved)
            } else {
                keyParts.append(resolved)
            }
        }

        let orderedModifiers = modifierOrder.filter { modifiers.contains($0) }
        return (orderedModifiers + keyParts).joined(separator: "+")
    }

    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    /// Returns the macOS-glyph display form (e.g. "cmd+shift+d" → "⌘⇧D").
    /// Empty input maps to "". Unknown multi-character tokens are uppercased verbatim.
    static func symbolize(_ keystroke: String) -> String {
        let normalized = normalize(keystroke)
        guard !normalized.isEmpty else { return "" }
        return normalized
            .split(separator: "+")
            .map { displaySymbols[String($0)] ?? $0.uppercased() }
            .joined()
    }

    /// Builds a normalized keystroke from raw modifier flags and a key name.
    /// Returns nil unless at least one of cmd/ctrl/opt is set (a bare key or shift-only
    /// combo is too easy to hit accidentally and is rejected by the recorder).
    static func fromComponents(
        commandKey: Bool,
        controlKey: Bool,
        optionKey: Bool,
        shiftKey: Bool,
        keyName: String
    ) -> String? {
        guard commandKey || controlKey || optionKey else { return nil }
        let key = keyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        var parts: [String] = []
        if commandKey { parts.append("cmd") }
        if controlKey { parts.append("ctrl") }
        if optionKey { parts.append("opt") }
        if shiftKey { parts.append("shift") }
        parts.append(key)
        return normalize(parts.joined(separator: "+"))
    }

    private static let displaySymbols: [String: String] = [
        "cmd": "\u{2318}",       // ⌘
        "ctrl": "\u{2303}",      // ⌃
        "opt": "\u{2325}",       // ⌥
        "shift": "\u{21E7}",     // ⇧
        "escape": "\u{238B}",    // ⎋
        "delete": "\u{232B}",    // ⌫
        "space": "\u{2423}",     // ␣
        "tab": "\u{21E5}",       // ⇥
        "return": "\u{21A9}",    // ↩
        "left": "\u{2190}",      // ←
        "right": "\u{2192}",     // →
        "up": "\u{2191}",        // ↑
        "down": "\u{2193}"       // ↓
    ]
}

/// The result of a keystroke-assignment conflict check.
enum KeystrokeConflict: Equatable {
    case reserved(purpose: String)
    case catalogEntry(id: String, title: String)
    case customKeybinding(id: String)
}

extension NVModernConfigDraft {
    /// Returns the active keystroke for a catalog entry and whether it's a user override.
    /// When the user hasn't overridden, returns the catalog default (or nil for `.special`
    /// commands with no default).
    func keystroke(for entry: CommandCatalogEntry) -> (keystroke: String?, isOverride: Bool) {
        if let binding = keybindings.first(where: { $0.id == entry.id }) {
            let raw = binding.keystroke ?? binding.key
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return (Keystroke.normalize(trimmed), true)
            }
            // An override row with no keystroke means the user explicitly unbound.
            return (nil, true)
        }
        return (entry.defaultKeystroke.map(Keystroke.normalize), false)
    }

    /// Sets the keystroke for a catalog entry. Passing nil clears any override (and
    /// the entry reverts to its catalog default, if any). The TOML stores deltas only:
    /// assigning the catalog default is recorded as "no override" (no row written).
    mutating func setKeystroke(_ keystroke: String?, for entry: CommandCatalogEntry) {
        keybindings.removeAll { $0.id == entry.id }
        guard let raw = keystroke?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return }
        let normalized = Keystroke.normalize(raw)
        if let def = entry.defaultKeystroke, Keystroke.normalize(def) == normalized {
            return  // matches default → no row needed
        }
        keybindings.append(makeKeybinding(for: entry, keystroke: normalized))
    }

    /// Explicitly unbind a catalog entry (clears default + any override). This writes
    /// a placeholder row with no keystroke so the runtime ignores the binding even
    /// though the catalog has a default.
    mutating func unbindKeystroke(for entry: CommandCatalogEntry) {
        keybindings.removeAll { $0.id == entry.id }
        guard entry.defaultKeystroke != nil else { return }
        var binding = makeKeybinding(for: entry, keystroke: "")
        binding.keystroke = nil
        binding.key = nil
        keybindings.append(binding)
    }

    /// Removes any user override, reverting to the catalog default.
    mutating func resetKeystroke(for entry: CommandCatalogEntry) {
        keybindings.removeAll { $0.id == entry.id }
    }

    /// Reports what already owns a candidate keystroke, if anything. Reserved + catalog
    /// + custom (non-catalog) keybindings are all considered. Pass `excluding:` to
    /// ignore the entry the user is currently editing.
    func keystrokeConflict(for keystroke: String, excluding excludedID: String? = nil)
        -> KeystrokeConflict?
    {
        let normalized = Keystroke.normalize(keystroke)
        guard !normalized.isEmpty else { return nil }

        if let reserved = CommandCatalog.reservedKeystrokes.first(where: { $0.keystroke == normalized }) {
            return .reserved(purpose: reserved.purpose)
        }

        for entry in CommandCatalog.entries where entry.id != excludedID {
            let (current, _) = self.keystroke(for: entry)
            if current == normalized {
                return .catalogEntry(id: entry.id, title: entry.title)
            }
        }

        for binding in keybindings where binding.id != excludedID {
            // Skip rows owned by catalog entries; those are reported as .catalogEntry above.
            if let id = binding.id, CommandCatalog.entry(id: id) != nil { continue }
            let raw = binding.keystroke ?? binding.key
            guard let raw, !raw.isEmpty else { continue }
            if Keystroke.normalize(raw) == normalized {
                return .customKeybinding(id: binding.id ?? "(unknown)")
            }
        }

        return nil
    }

    /// Number of `[[keybindings]]` rows whose id doesn't match any catalog entry.
    /// Surfaced in the UI as a "N custom shortcuts in config file" footer.
    var customKeybindingCount: Int {
        keybindings.reduce(into: 0) { count, binding in
            if let id = binding.id, CommandCatalog.entry(id: id) != nil { return }
            count += 1
        }
    }

    private func makeKeybinding(
        for entry: CommandCatalogEntry,
        keystroke: String
    ) -> NVModernActionKeybindingDraft {
        var binding = NVModernActionKeybindingDraft(id: entry.id)
        binding.title = entry.title
        binding.keystroke = keystroke.isEmpty ? nil : keystroke
        switch entry.invocation {
        case let .method(name, args, target):
            binding.method = name
            binding.args = args.isEmpty ? nil : args
            binding.target = target
        }
        return binding
    }
}
