import AppKit
import SwiftUI

struct PluginsPane: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    @ObservedObject private var host = PluginHost.shared
    @State private var folderError: String?

    var body: some View {
        SettingsForm {
            Section {
                if host.pluginInfos.isEmpty {
                    Text("No plugins installed.").foregroundStyle(.secondary)
                }
                ForEach(host.pluginInfos) { info in
                    NavigationLink(value: info.path) {
                        HStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundStyle(info.state == .running ? Color.accentColor : Color.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name.settingsDisplayName)
                                Text(subtitle(info)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if info.state == .failed {
                                Label("Error", systemImage: "exclamationmark.triangle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.red)
                                    .help("Could not load")
                            }
                            Toggle("Enabled", isOn: enabledBinding(info.name))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack {
                        Text("Plugins are JavaScript files in your plugins folder. Saving one reloads it.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Plugins Folder") { openFolder() }
                        Button("Reload") {
                            Task { _ = try? await ActionExecutor.shared.invoke(ActionRequest(method: "app.plugins.reload")) }
                        }
                    }
                    if let folderError { Text(folderError).font(.callout).foregroundStyle(.red) }
                }
            }
        }
        .navigationDestination(for: String.self) { path in
            PluginDetailView(model: model, draft: $draft, host: host, path: path)
                .settingsPageToolbar(model)
        }
    }

    private func subtitle(_ info: PluginInfo) -> String {
        let count = info.actionMethods.count
        let actions = count == 1 ? "1 action" : "\(count) actions"
        switch info.state {
        case .running: return "\(info.isBuiltin ? "Built-in" : "User plugin") · \(actions)"
        case .disabled: return "Off"
        case .failed: return "Could not load"
        }
    }

    private func enabledBinding(_ name: String) -> Binding<Bool> { pluginEnabledBinding(name, draft: $draft) }

    private func openFolder() {
        let folder = model.configURL.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { folderError = error.localizedDescription }
    }
}

private func pluginEnabledBinding(_ name: String, draft: Binding<NVModernConfigDraft>) -> Binding<Bool> {
    Binding(
        get: { !draft.wrappedValue.plugins.disabled.contains(name) },
        set: { enabled in
            draft.wrappedValue.plugins.disabled.removeAll { $0 == name }
            if !enabled { draft.wrappedValue.plugins.disabled.append(name) }
        }
    )
}

private struct PluginDetailView: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    @ObservedObject var host: PluginHost
    let path: String
    @State private var pickerError: String?

    var body: some View {
        if let info = host.pluginInfos.first(where: { $0.path == path }) {
            SettingsForm {
                Section {
                    Toggle(isOn: pluginEnabledBinding(info.name, draft: $draft)) {
                        SettingsLabel("Enabled", summary: info.isDisabled
                                      ? "Turning a plugin off removes its actions and shortcuts. Its settings are kept."
                                      : nil)
                    }
                    LabeledContent("Source") {
                        HStack(spacing: 8) {
                            Text(info.isBuiltin ? "Built-in" : URL(fileURLWithPath: info.path).lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.path)])
                            }
                        }
                    }
                }

                if let error = info.loadError {
                    Section {
                        Label {
                            Text(error).font(.body.monospaced()).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    } header: {
                        Text("Could Not Load")
                    } footer: {
                        Text("Fix the source file and save it to reload.").font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !info.settingsSchema.isEmpty {
                    Section {
                        ForEach(info.settingsSchema) { field in
                            PluginSettingRow(field: field, value: settingBinding(info.name, field),
                                             referenceWorkspace: draft.defaultProject, pickerError: $pickerError)
                        }
                    } header: {
                        Text("Settings")
                    } footer: {
                        HStack(alignment: .top) {
                            if let pickerError { Text(pickerError).font(.callout).foregroundStyle(.red) }
                            Spacer()
                            Button("Restore Defaults") { model.resetPluginSettings(info.name) }
                                .disabled(draft.plugins.settings[info.name]?.isEmpty != false)
                        }
                    }
                }

                if !info.actionMethods.isEmpty {
                    Section {
                        ForEach(info.actionMethods, id: \.self) { method in
                            LabeledContent(ActionRegistry.shared.descriptor(for: method)?.title ?? method) {
                                KeystrokeText(keystroke: shortcut(for: method))
                            }
                        }
                    } header: {
                        Text("Actions")
                    } footer: {
                        HStack {
                            Spacer()
                            Button("Edit Shortcuts…") { model.selectedTab = .shortcuts }
                        }
                    }
                }
            }
            .navigationTitle(info.name.settingsDisplayName)
        } else {
            ContentUnavailableView("Plugin Removed", systemImage: "puzzlepiece.extension")
        }
    }

    private func shortcut(for method: String) -> String? {
        if let row = draft.keybindings.first(where: { $0.method == method }) { return row.keystroke ?? row.key }
        return host.keybindings.first { $0.invocation.methodName == method }?.keystroke
    }

    private func settingBinding(_ name: String, _ field: PluginSettingsField) -> Binding<ActionValue> {
        Binding(get: { draft.plugins.settings[name]?[field.key] ?? field.defaultValue },
                set: { draft.plugins.settings[name, default: [:]][field.key] = $0 })
    }
}

private struct PluginSettingRow: View {
    let field: PluginSettingsField
    @Binding var value: ActionValue
    let referenceWorkspace: NVModernProjectDraft?
    @Binding var pickerError: String?

    var body: some View {
        control
        if !field.accepts(value) {
            Label("The value in config.toml is invalid, so the plugin uses its default.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text:
            LabeledContent(field.title) {
                CommitTextField(field.title, text: Binding(get: { value.stringValue ?? field.defaultValue.stringValue ?? "" },
                                                           set: { value = .string($0) }))
                    .labelsHidden()
            }
        case .bool:
            Toggle(field.title, isOn: Binding(get: { value.boolValue ?? field.defaultValue.boolValue ?? false },
                                              set: { value = .bool($0) }))
        case .number:
            LabeledContent(field.title) {
                TextField(field.title, value: Binding(get: { value.doubleValue ?? field.defaultValue.doubleValue ?? 0 },
                                                      set: { value = .double($0) }), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        case .choice:
            Picker(field.title, selection: Binding(get: { value.stringValue ?? "" }, set: { value = .string($0) })) {
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
        case .folder:
            LabeledContent {
                HStack(spacing: 8) {
                    Text(value.stringValue.map { $0 == "." ? "Workspace root" : $0 } ?? "Not set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }.disabled(referenceWorkspace == nil)
                }
            } label: {
                SettingsLabel(field.title, summary: "Inside whichever workspace the action runs in.")
            }
        }
    }

    private func chooseFolder() {
        guard let project = referenceWorkspace else { return }
        let root = URL(fileURLWithPath: NSString(string: project.path).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = root
        panel.message = "Choose a folder inside \(project.displayName)."
        guard panel.runModal() == .OK, let chosen = panel.url?.resolvingSymlinksInPath().standardizedFileURL else { return }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard chosen.path == root.path || chosen.path.hasPrefix(prefix) else {
            pickerError = "Choose a folder inside \(project.displayName)."; return
        }
        value = .string(chosen.path == root.path ? "." : String(chosen.path.dropFirst(prefix.count)))
        pickerError = nil
    }
}
