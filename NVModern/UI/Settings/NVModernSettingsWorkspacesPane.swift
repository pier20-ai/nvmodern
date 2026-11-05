import AppKit
import SwiftUI

struct WorkspacesPane: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft

    var body: some View {
        SettingsForm {
            Section {
                if draft.projects.isEmpty {
                    Text("No workspaces yet. Add a folder of notes to get started.")
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.projects, id: \._uiID) { project in
                    NavigationLink(value: project._uiID) {
                        HStack(spacing: 10) {
                            Image(systemName: project.icon ?? "folder")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayName)
                                Text((project.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if draft.defaultProjectID == project._uiID {
                                Text("Opens on Launch").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Show in Finder") { reveal(project.path) }
                        if draft.defaultProjectID != project._uiID {
                            Button("Open on Launch") { draft.setDefaultProject(id: project._uiID) }
                        }
                        Divider()
                        Button("Remove Workspace", role: .destructive) { model.removeWorkspace(project._uiID) }
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Workspace…") { addWorkspace() }
                }
            }
        }
        .navigationDestination(for: UUID.self) { id in
            WorkspaceDetailView(model: model, draft: $draft, id: id)
                .settingsPageToolbar(model)
        }
    }

    private func addWorkspace() {
        guard let url = chooseWorkspaceFolder(), !draft.projects.contains(where: { $0.path == url.path }) else { return }
        draft.addProject(NVModernProjectDraft(name: url.lastPathComponent, path: url.path))
    }
}

private struct WorkspaceDetailView: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let index = draft.projects.firstIndex(where: { $0._uiID == id }) {
            let project = draft.projects[index]
            SettingsForm {
                Section {
                    LabeledContent("Name") {
                        CommitTextField("Name", text: $draft.projects[index].name, prompt: URL(fileURLWithPath: project.path).lastPathComponent)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Icon") { SFSymbolPicker(symbol: $draft.projects[index].icon, placeholderSymbol: "folder") }
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text((project.path as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Change…") { changeFolder() }
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { draft.defaultProjectID == id },
                        set: { if $0 { draft.setDefaultProject(id: id) } }
                    )) {
                        SettingsLabel("Open on launch", summary: "New windows start in this workspace. Choose another workspace to change it.")
                    }
                    .disabled(draft.defaultProjectID == id)
                }

                Section {
                    HStack {
                        Button("Show in Finder") { reveal(project.path) }
                        Spacer()
                        Button("Remove Workspace…", role: .destructive) { model.removeWorkspace(id); dismiss() }
                    }
                } footer: {
                    Text("Removing a workspace only forgets it. The folder and its notes stay where they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(project.displayName)
        } else {
            ContentUnavailableView("Workspace Removed", systemImage: "folder.badge.minus")
        }
    }

    private func changeFolder() {
        guard let index = draft.projects.firstIndex(where: { $0._uiID == id }), let url = chooseWorkspaceFolder() else { return }
        let previous = draft.projects[index].path
        guard previous != url.path else { return }
        var next = model.draft
        next.projects[index].path = url.path
        guard model.updateDraft(next) else { return }
        model.offerUndo("Changed workspace folder.") { [weak model, id] in
            guard let model else { return }
            var next = model.draft
            guard let index = next.projects.firstIndex(where: { $0._uiID == id }), next.projects[index].path == url.path else { return }
            next.projects[index].path = previous
            model.updateDraft(next)
        }
    }
}

private func chooseWorkspaceFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
}

private func reveal(_ path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
