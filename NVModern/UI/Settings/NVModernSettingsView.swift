import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable {
    case general, workspaces, writing, appearance, shortcuts, plugins
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .workspaces: return "folder"
        case .writing: return "character.cursor.ibeam"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .plugins: return "puzzlepiece.extension"
        }
    }
    /// Sidebar tile color, following System Settings' colored icon squares.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .workspaces: return .blue
        case .writing: return .orange
        case .appearance: return .indigo
        case .shortcuts: return .gray
        case .plugins: return .green
        }
    }
    func includes(_ field: String) -> Bool {
        switch self {
        case .general: return field.hasPrefix("sync") || field.hasPrefix("socket") || field == "raw"
        case .workspaces: return field == "root" || field.hasPrefix("projects")
        case .writing: return field == "users" || field.hasPrefix("substitutions")
        case .appearance: return ["theme", "width", "filetypes", "window_tint", "editor_theme", "editor_theme_css", "themes_dir"].contains(field)
        case .shortcuts: return field.hasPrefix("keybindings")
        case .plugins: return field.hasPrefix("plugins")
        }
    }
}

@MainActor
final class NVModernSettingsModel: ObservableObject {
    let schema = NVModernConfigSchema.shared
    let monitor: NVModernConfigFileMonitor
    @Published private(set) var draft: NVModernConfigDraft
    @Published var selectedTab: SettingsTab = .general {
        didSet { if selectedTab != oldValue { path = NavigationPath() } }
    }
    /// Drill-down stack of the selected pane (a workspace or plugin page).
    @Published var path = NavigationPath()
    func goBack() { if !path.isEmpty { path.removeLast() } }
    @Published private(set) var diagnostics: [NVModernConfigDiagnostic] = []
    @Published private(set) var saveError: String?
    @Published private(set) var undoMessage: String?
    var configURL: URL { monitor.configURL }
    private var undoAction: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(monitor: NVModernConfigFileMonitor? = nil) {
        let monitor = monitor ?? .shared
        self.monitor = monitor
        do { draft = try monitor.readDraft() }
        catch { draft = NVModernConfigSchema.shared.defaultDraft(); saveError = error.localizedDescription }
        refreshDiagnostics()
        observer = NotificationCenter.default.addObserver(forName: .nvModernConfigFileDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self, url == self.configURL else { return }
                self.reloadFromDisk()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    @discardableResult
    func updateDraft(_ value: NVModernConfigDraft) -> Bool {
        guard value != draft else { return true }
        do {
            draft = try monitor.write(value, basedOn: draft)
            saveError = nil
            refreshDiagnostics()
            return true
        } catch {
            reloadFromDisk()
            saveError = error.localizedDescription
            return false
        }
    }

    func reloadFromDisk() {
        do {
            var loaded = try monitor.readDraft()
            let defaultPath = loaded.defaultProject?.path
            for index in loaded.projects.indices {
                if let row = draft.projects.first(where: { $0.path == loaded.projects[index].path }) { loaded.projects[index]._uiID = row._uiID }
            }
            loaded.defaultProjectID = loaded.projects.first { $0.path == defaultPath }?._uiID
            loaded.normalizeDefaultProject()
            for index in loaded.substitutions.indices {
                if let row = draft.substitutions.first(where: { $0 == loaded.substitutions[index] }) { loaded.substitutions[index]._uiID = row._uiID }
            }
            if loaded != draft { draft = loaded }
            saveError = nil
            refreshDiagnostics()
        } catch { saveError = "Could not read configuration: \(error.localizedDescription)" }
    }

    private func refreshDiagnostics() { diagnostics = schema.diagnostics(for: draft, configURL: configURL) }
    func openConfigInFinder() { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
    func editConfig() { NSWorkspace.shared.open(configURL) }

    func offerUndo(_ message: String, action: @escaping () -> Void) { undoMessage = message; undoAction = action }
    func undo() { let action = undoAction; undoMessage = nil; undoAction = nil; action?() }
    func dismissUndo() { undoMessage = nil; undoAction = nil }

    func removeWorkspace(_ id: UUID) {
        guard let index = draft.projects.firstIndex(where: { $0._uiID == id }) else { return }
        let row = draft.projects[index]
        let wasDefault = draft.defaultProjectID == id
        var next = draft; next.removeProject(id: id)
        guard updateDraft(next) else { return }
        offerUndo("Removed \(row.displayName). Files remain in place.") { [weak self] in
            guard let self, !self.draft.projects.contains(where: { $0.path == row.path }) else { return }
            var next = self.draft
            next.projects.insert(row, at: min(index, next.projects.count))
            if wasDefault { next.defaultProjectID = row._uiID }
            next.normalizeDefaultProject()
            self.updateDraft(next)
        }
    }

    func resetPluginSettings(_ name: String) {
        guard let values = draft.plugins.settings[name], !values.isEmpty else { return }
        var next = draft; next.plugins.settings.removeValue(forKey: name)
        guard updateDraft(next) else { return }
        offerUndo("Reset settings for \(name).") { [weak self] in
            guard let self else { return }
            var next = self.draft
            next.plugins.settings[name] = values.merging(next.plugins.settings[name] ?? [:]) { _, current in current }
            self.updateDraft(next)
        }
    }

    func removeSubstitution(_ id: UUID) {
        guard let index = draft.substitutions.firstIndex(where: { $0._uiID == id }) else { return }
        let row = draft.substitutions[index]
        var next = draft; next.substitutions.remove(at: index)
        guard updateDraft(next) else { return }
        offerUndo("Removed substitution \(row.from.isEmpty ? "without a trigger" : row.from).") { [weak self] in
            guard let self, !self.draft.substitutions.contains(where: { $0._uiID == row._uiID }) else { return }
            var next = self.draft
            next.substitutions.insert(row, at: min(index, next.substitutions.count))
            self.updateDraft(next)
        }
    }
}

struct NVModernSettingsView: View {
    @StateObject private var model: NVModernSettingsModel

    /// `model` is injectable for tests; the app passes nothing.
    @MainActor init(model: NVModernSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? NVModernSettingsModel())
    }
    private var draftBinding: Binding<NVModernConfigDraft> { Binding(get: { model.draft }, set: { model.updateDraft($0) }) }
    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.selectedTab }, set: { if let tab = $0 { model.selectedTab = tab } })
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: selection) { tab in
                Label { Text(tab.title) } icon: { SettingsTabIcon(tab: tab) }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            NavigationStack(path: $model.path) {
                pane
                    .settingsPageToolbar(model)
                    .navigationTitle(model.selectedTab.title)
                    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            }
            .id(model.selectedTab)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
        .background(WindowAccessor(onResolve: Self.configure, onAttaching: Self.configure))
    }

    /// SwiftUI gives `Settings` windows the preference toolbar style: a centered
    /// title with toolbar items on a second row that only exists while a pane has
    /// items (back button, search), so the sidebar jumps. The unified style keeps
    /// title, back button, and search on one fixed row, as System Settings does.
    private static func configure(_ window: NSWindow) {
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
    }

    @ViewBuilder private var pane: some View {
        switch model.selectedTab {
        case .general: GeneralPane(model: model, draft: draftBinding)
        case .workspaces: WorkspacesPane(model: model, draft: draftBinding)
        case .writing: WritingPane(model: model, draft: draftBinding)
        case .appearance: AppearancePane(draft: draftBinding)
        case .shortcuts: ShortcutsPane(model: model, draft: draftBinding)
        case .plugins: PluginsPane(model: model, draft: draftBinding)
        }
    }

    /// Errors show on every pane (a broken file blocks every edit); warnings
    /// show on the pane that owns the key, and unscoped ones on General.
    private var visibleIssues: [NVModernConfigDiagnostic] {
        model.diagnostics.filter { diagnostic in
            if diagnostic.severity == .error { return true }
            guard let field = diagnostic.fieldID else { return model.selectedTab == .general }
            return model.selectedTab.includes(field)
        }
    }

    @ViewBuilder private var footer: some View {
        let issues = visibleIssues
        if model.saveError != nil || !issues.isEmpty || model.undoMessage != nil {
            VStack(spacing: 0) {
                if model.saveError != nil || !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = model.saveError {
                            Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        }
                        ForEach(issues) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? Color.red : Color.secondary)
                        }
                        Button("Open Configuration File") { model.editConfig() }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
                if let message = model.undoMessage {
                    SettingsUndoBar(message: message, undo: model.undo, dismiss: model.dismissUndo)
                }
            }
        }
    }
}

/// White glyph on a rounded colored square, as in System Settings' sidebar.
private struct SettingsTabIcon: View {
    let tab: SettingsTab
    var body: some View {
        Image(systemName: tab.systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Every Settings page, root or pushed, carries the same back button: a pushed
/// page's toolbar replaces its parent's, so the button must come from the page.
/// It stays present (disabled at a pane's root), as in System Settings, so the
/// toolbar row never appears or disappears. It observes the model directly;
/// toolbar content does not reliably see environment updates.
private struct SettingsPageToolbar: ViewModifier {
    @ObservedObject var model: NVModernSettingsModel

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: model.goBack) { Image(systemName: "chevron.left") }
                        .disabled(model.path.isEmpty)
                        .help("Back")
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
    }
}

extension View {
    func settingsPageToolbar(_ model: NVModernSettingsModel) -> some View { modifier(SettingsPageToolbar(model: model)) }
}
