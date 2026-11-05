import AppKit
import SwiftUI

struct GeneralPane: View {
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        SettingsForm {
            Section {
                Picker(selection: syncMode) {
                    Text("Ask Before Reloading").tag(NVModernSyncMode.prompt.rawValue)
                    Text("Reload Automatically").tag(NVModernSyncMode.liveFile.rawValue)
                } label: {
                    SettingsLabel("When an open file changes on disk",
                                  summary: syncMode.wrappedValue == NVModernSyncMode.liveFile.rawValue
                                      ? "Open documents reload as soon as another app saves them."
                                      : "A banner offers to reload or keep your version.")
                }
            } header: {
                Text("Files")
            }

            Section {
                Toggle(isOn: socketEnabled) {
                    SettingsLabel("Allow command-line control",
                                  summary: "Lets the nv3 command and MCP clients run actions in nvModern.")
                }
                if socketEnabled.wrappedValue {
                    PathPickerRow(title: "Socket", prompt: defaultSocketPath, kind: .file, path: socketPath)
                }
            } header: {
                Text("Automation")
            } footer: {
                if socketEnabled.wrappedValue {
                    Text("Run `nv3 action <method>` from a shell, or add `nv3 mcp` as an MCP server.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if updater.isEnabled {
                Section {
                    Toggle(isOn: Binding(get: { updater.automaticallyChecks },
                                         set: { updater.setAutomaticallyChecks($0) })) {
                        SettingsLabel("Check for updates automatically",
                                      summary: "nvModern looks for new releases on GitHub once a day.")
                    }
                    LabeledContent("Version") {
                        Text(Self.versionString).textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                } header: {
                    Text("Updates")
                }
            }

            Section {
                LabeledContent("Location") {
                    Text((model.configURL.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { model.openConfigInFinder() }
                    Button("Open in Editor") { model.editConfig() }
                }
            } header: {
                Text("Configuration File")
            } footer: {
                Text("Every setting here is saved to this file as you change it. Edits made in another editor appear here right away.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var syncMode: Binding<String> {
        Binding(
            get: { draft.sync?.mode ?? NVModernSyncMode.prompt.rawValue },
            set: { value in
                draft.sync = value == NVModernSyncMode.prompt.rawValue ? nil : NVModernSyncDraft(mode: value)
            }
        )
    }

    private var socketEnabled: Binding<Bool> {
        Binding(
            get: { draft.socket?.enabled ?? true },
            set: { enabled in
                var socket = draft.socket ?? NVModernSocketDraft()
                socket.enabled = enabled ? nil : false
                draft.socket = socket.encodedIfMeaningful
            }
        )
    }

    private var socketPath: Binding<String?> {
        Binding(
            get: { draft.socket?.path },
            set: { path in
                var socket = draft.socket ?? NVModernSocketDraft()
                socket.path = path
                draft.socket = socket.encodedIfMeaningful
            }
        )
    }

    private var defaultSocketPath: String {
        (ActionSocketConfiguration.defaultSocketURL().path as NSString).abbreviatingWithTildeInPath
    }
}
