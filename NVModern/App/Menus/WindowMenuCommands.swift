import SwiftUI

/// Window menu: native window tabs.
///
/// The native-shell experiment replaced Bonsplit tabs and splits with AppKit
/// window tabbing, so tab traversal routes to `NSWindow` tab navigation and
/// the split/pane commands are gone. `Cmd+W` stays in the monitor because
/// AppKit provides its own File > Close item on that key and two menu items
/// cannot share it.
struct WindowMenuCommands: Commands {
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared

    var body: some Commands {
        CommandGroup(before: .windowList) {
            let _ = routerState.revision
            let isAvailable = MenuCommandContext.hasWorkspaceWindow

            Button("Show Next Tab") {
                _ = WorkspaceActionRouter.performSelectNextTab(in: MenuCommandContext.targetWindowNumber)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!isAvailable)

            Button("Show Previous Tab") {
                _ = WorkspaceActionRouter.performSelectPreviousTab(in: MenuCommandContext.targetWindowNumber)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!isAvailable)

            Button("Show All Tabs") {
                _ = WorkspaceActionRouter.performShowAllTabs(in: MenuCommandContext.targetWindowNumber)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .disabled(!isAvailable)

            Button("Duplicate Tab") {
                _ = WorkspaceActionRouter.performDuplicateCurrentTab(in: MenuCommandContext.targetWindowNumber)
            }
            .disabled(!isAvailable)

            Button("Copy Link") {
                _ = WorkspaceActionRouter.performCopyCurrentDocumentLink(in: MenuCommandContext.targetWindowNumber)
            }
            .disabled(!isAvailable)

            Divider()
        }
    }
}
