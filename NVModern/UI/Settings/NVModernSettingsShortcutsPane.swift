import AppKit
import SwiftUI

/// One bindable action as Settings lists it.
private struct ShortcutItem: Identifiable {
    let method: String
    let title: String
    let summary: String?
    /// Catalog commands keep their catalog ids and defaults in `config.toml`.
    let catalogEntry: CommandCatalogEntry?
    var id: String { method }
}

private struct ShortcutGroup: Identifiable {
    let title: String
    var items: [ShortcutItem]
    var id: String { title }
}

struct ShortcutsPane: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    @ObservedObject private var host = PluginHost.shared
    @State private var query = ""

    /// Palette verb order from the palette spec, then anything else alphabetically.
    private static let categoryOrder = ["Open", "File", "Document", "Format", "Window", "Create", "Appearance"]

    var body: some View {
        let groups = filteredGroups
        SettingsForm {
            if groups.isEmpty {
                Text("No actions match “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        ShortcutRow(draft: $draft, host: host, item: item)
                    }
                }
            }
            if query.isEmpty, !host.globalHotkeys.isEmpty {
                Section {
                    ForEach(host.globalHotkeys, id: \.keystroke) { hotkey in
                        LabeledContent(ActionRegistry.shared.descriptor(for: hotkey.method)?.title ?? hotkey.method) {
                            KeystrokeText(keystroke: hotkey.keystroke)
                        }
                    }
                } header: {
                    Text("Global")
                } footer: {
                    Text("Global shortcuts work while other apps are active. Plugins declare them in their source.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if query.isEmpty, !orphanedBindings.isEmpty {
                Section {
                    ForEach(orphanedBindings, id: \._uiID) { binding in
                        LabeledContent {
                            HStack {
                                KeystrokeText(keystroke: binding.keystroke ?? binding.key)
                                RemoveRowButton(help: "Remove shortcut") {
                                    draft.keybindings.removeAll { $0._uiID == binding._uiID }
                                }
                            }
                        } label: {
                            SettingsLabel(binding.title ?? binding.id ?? "Shortcut", summary: binding.method ?? binding.action ?? "No action")
                        }
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("These shortcuts in config.toml point at actions that aren't loaded, such as a disabled plugin's.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Actions")
    }

    private var allGroups: [ShortcutGroup] {
        var byCategory: [String: [ShortcutItem]] = [:]
        var seen = Set<String>()
        let catalogByMethod = Dictionary(CommandCatalog.entries.compactMap { entry -> (String, CommandCatalogEntry)? in
            guard case .method(let method, _, _) = entry.invocation else { return nil }
            return (method, entry)
        }, uniquingKeysWith: { first, _ in first })

        func add(_ item: ShortcutItem, to category: String) {
            guard seen.insert(item.method).inserted else { return }
            byCategory[category, default: []].append(item)
        }

        for descriptor in ActionRegistry.shared.allDescriptors() {
            guard let palette = descriptor.palette, !descriptor.method.hasPrefix("plugin.") else { continue }
            add(ShortcutItem(method: descriptor.method, title: descriptor.title,
                             summary: descriptor.summary, catalogEntry: catalogByMethod[descriptor.method]),
                to: palette.category)
        }
        for entry in CommandCatalog.entries {
            guard case .method(let method, _, _) = entry.invocation else { continue }
            add(ShortcutItem(method: method, title: entry.title, summary: entry.summary, catalogEntry: entry),
                to: entry.group.title)
        }

        var groups = byCategory.map { ShortcutGroup(title: $0.key, items: $0.value.sorted { $0.title < $1.title }) }
        groups.sort { lhs, rhs in
            let l = Self.categoryOrder.firstIndex(of: lhs.title) ?? Int.max
            let r = Self.categoryOrder.firstIndex(of: rhs.title) ?? Int.max
            return l == r ? lhs.title < rhs.title : l < r
        }

        for plugin in host.pluginInfos where !plugin.actionMethods.isEmpty {
            let items = plugin.actionMethods.filter { seen.insert($0).inserted }.map { method in
                let descriptor = ActionRegistry.shared.descriptor(for: method)
                return ShortcutItem(method: method, title: descriptor?.title ?? method,
                                    summary: descriptor?.summary, catalogEntry: nil)
            }
            if !items.isEmpty { groups.append(ShortcutGroup(title: plugin.name.settingsDisplayName, items: items)) }
        }
        return groups
    }

    private var filteredGroups: [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return allGroups }
        return allGroups.compactMap { group in
            var group = group
            if !group.title.localizedCaseInsensitiveContains(needle) {
                group.items = group.items.filter {
                    $0.title.localizedCaseInsensitiveContains(needle) || $0.method.localizedCaseInsensitiveContains(needle)
                }
            }
            return group.items.isEmpty ? nil : group
        }
    }

    /// Rows that no listed action owns, so they would otherwise be invisible.
    private var orphanedBindings: [NVModernActionKeybindingDraft] {
        let listed = Set(allGroups.flatMap(\.items).map(\.method))
        return draft.keybindings.filter { binding in
            if let id = binding.id, CommandCatalog.entry(id: id) != nil { return false }
            guard let method = binding.method else { return true }
            return !listed.contains(method)
        }
    }
}

private struct ShortcutRow: View {
    @Binding var draft: NVModernConfigDraft
    @ObservedObject var host: PluginHost
    let item: ShortcutItem

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(conflict)
                        .accessibilityLabel(conflict)
                }
                if isOverridden {
                    Button("Reset") { reset() }
                        .buttonStyle(.link)
                        .help("Restore the default shortcut")
                }
                if let menuShortcut {
                    KeystrokeText(keystroke: menuShortcut)
                        .help("Set by the menu bar")
                } else {
                    HotkeyRecorder(keystroke: keystrokeBinding)
                }
            }
        } label: {
            Text(item.title)
        }
        .help(item.summary ?? "")
    }

    private var menuShortcut: String? { PaletteShortcutResolver.menuOwnedKeystrokes[item.method] }

    /// The shortcut the plugin declares in its source, if any.
    private var declared: String? {
        host.keybindings.first { $0.invocation.methodName == item.method }?.keystroke
    }

    private var configured: NVModernActionKeybindingDraft? {
        draft.keybindings.first { $0.method == item.method && ($0.id.flatMap(CommandCatalog.entry(id:)) == nil) }
    }

    private var current: String? {
        if let entry = item.catalogEntry { return draft.keystroke(for: entry).keystroke }
        if let configured { return configured.keystroke ?? configured.key }
        return declared
    }

    private var isOverridden: Bool {
        if let entry = item.catalogEntry { return draft.keystroke(for: entry).isOverride && entry.defaultKeystroke != nil }
        return configured != nil && declared != nil
    }

    private var keystrokeBinding: Binding<String?> {
        Binding(get: { current }, set: { value in
            let value = value.flatMap { $0.isEmpty ? nil : Keystroke.normalize($0) }
            if let entry = item.catalogEntry {
                if let value { draft.setKeystroke(value, for: entry) } else { draft.unbindKeystroke(for: entry) }
                return
            }
            draft.keybindings.removeAll { $0.method == item.method }
            if value == declared.map(Keystroke.normalize) { return }
            // A row without a keystroke unbinds the plugin's declared default.
            if value == nil && declared == nil { return }
            let id = item.method.hasPrefix("plugin.") ? "plugin:\(item.method)" : item.method
            draft.keybindings.append(.init(id: id, keystroke: value, method: item.method))
        })
    }

    private func reset() {
        if let entry = item.catalogEntry { draft.resetKeystroke(for: entry) } else { draft.keybindings.removeAll { $0.method == item.method } }
    }

    private var conflict: String? {
        guard menuShortcut == nil, let current, !current.isEmpty else { return nil }
        let normalized = Keystroke.normalize(current)
        if let owner = PaletteShortcutResolver.menuOwnedKeystrokes.first(where: { $0.key != item.method && Keystroke.normalize($0.value) == normalized }) {
            return "Also used by \(ActionRegistry.shared.descriptor(for: owner.key)?.title ?? owner.key)."
        }
        let ownID = item.catalogEntry?.id ?? configured?.id
        switch draft.keystrokeConflict(for: current, excluding: ownID) {
        case .reserved(let purpose): return "\(purpose) already uses this shortcut."
        case .catalogEntry(_, let title): return "Also used by \(title)."
        case .customKeybinding(let id):
            let method = id.hasPrefix("plugin:") ? String(id.dropFirst("plugin:".count)) : id
            return "Also used by \(ActionRegistry.shared.descriptor(for: method)?.title ?? id)."
        case nil: return nil
        }
    }
}

/// Read-only shortcut glyphs, styled like the recorder's resting state.
struct KeystrokeText: View {
    let keystroke: String?
    var body: some View {
        Text(keystroke.map(Keystroke.symbolize) ?? "None")
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
