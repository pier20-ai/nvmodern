import AppKit
import SwiftUI

@main
struct NVModernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            NVModernSettingsView()
        }
        .commands {
            CheckForUpdatesCommand()
            FileMenuCommands()
            EditMenuCommands()
            ViewMenuCommands()
            FormatMenuCommands()
            GoMenuCommands()
            WindowMenuCommands()
            SidebarCommands()
            CommandGroup(replacing: .help) {
                Button("Explore nvModern Help") {
                    WorkspaceMenuCommands.performAction("app.help.open")
                }
            }
        }
    }
}
