import SwiftUI

/// Edit menu: the Find submenu macOS expects.
///
/// `Cmd+F` and `Shift+Cmd+F` used to be File items, which is the clearest HIG
/// violation the menu bar had — every other Mac app puts find under
/// Edit > Find.
struct EditMenuCommands: Commands {
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            let _ = routerState.revision

            Menu("Find") {
                Button("Find in Document…") {
                    WorkspaceMenuCommands.openDocumentFind()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Search Contents…") {
                    WorkspaceMenuCommands.openPalette(.contentSearch(initialQuery: ""))
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!MenuCommandContext.hasWorkspaceWindow)
            }
        }
    }
}
