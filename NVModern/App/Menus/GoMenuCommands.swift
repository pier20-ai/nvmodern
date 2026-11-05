import AppKit
import SwiftUI

/// Go menu: moving around — the palettes and in-document navigation.
struct GoMenuCommands: Commands {
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared

    var body: some Commands {
        CommandMenu("Go") {
            let _ = routerState.revision

            Button("Quick Find…") {
                WorkspaceMenuCommands.openPalette(.root)
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("Actions…") {
                WorkspaceMenuCommands.openPalette(.actions)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Divider()

            Button("Go to Heading…") {
                WorkspaceMenuCommands.openPalette(.outline)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("Jump to Line…") {
                WorkspaceMenuCommands.openDocumentNavigator(.line)
            }
        }
    }
}
