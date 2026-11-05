import SwiftUI

/// View menu: how the current window presents itself.
struct ViewMenuCommands: Commands {
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared
    @AppStorage(MillerDetailsPreference.key) private var isDetailsModeEnabled = false
    @AppStorage(CompactToolbarPreference.key) private var isCompactToolbarEnabled = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            let _ = routerState.revision

            // Reads the stored value so the checkmark follows it, writes
            // through the preference so the menu and
            // `workspace.toolbar.compact.toggle` share one path.
            Toggle(
                "Compact Toolbar",
                isOn: Binding(
                    get: { isCompactToolbarEnabled },
                    set: { CompactToolbarPreference.setEnabled($0) }
                )
            )

            Divider()

            Toggle("Details View", isOn: $isDetailsModeEnabled)
                .keyboardShortcut("2", modifiers: [.command, .option])

            Divider()

            Button("Toggle Inspector") {
                WorkspaceMenuCommands.openDocumentInspector()
            }
            .keyboardShortcut("\\", modifiers: [.command])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            // Side stack (ticket 0031). Keep the keys in sync with
            // `WorkspaceSideStackBuiltinActions.toggleKeystroke` / `focusKeystroke`.
            Button("Toggle Side Stack") {
                WorkspaceMenuCommands.performAction(WorkspaceSideStackBuiltinActions.toggleMethod)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("Focus Side Stack") {
                WorkspaceMenuCommands.performAction(WorkspaceSideStackBuiltinActions.focusMethod)
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)
        }
    }
}
