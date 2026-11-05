import AppKit
import UserNotifications

/// The running app, as the plugin host sees it: the floating panels, the
/// workspace windows and the pasteboard.
@MainActor
final class PluginAppEnvironment: PluginHostEnvironment {
    private let panels: QuickCapturePanelController
    let documentWindows = ScratchpadWindowController()

    init(panels: QuickCapturePanelController) {
        self.panels = panels
    }

    var activeProjectRootPath: String? {
        WorkspaceActionRouter.runtimesFrontToBack().first?.projectRootPath
    }

    func input(_ request: PluginInputRequest) async -> String? {
        await withCheckedContinuation { continuation in
            panels.showInput(request, isPluginOwned: true) { text in
                continuation.resume(returning: text)
                return true
            }
        }
    }

    func panel(_ request: PluginPanelRequest) async {
        await withCheckedContinuation { continuation in
            panels.showEditor(request, isPluginOwned: true) {
                continuation.resume()
            }
        }
    }

    func window(_ request: PluginWindowRequest) async throws {
        try documentWindows.open(request)
    }

    func pick(_ request: PluginPickRequest) async throws -> ActionValue? {
        guard let windowNumber = MenuCommandContext.targetWindowNumber else {
            throw ActionError.unavailable("No workspace window is open to show a picker in")
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.windowNumber == windowNumber }?.makeKeyAndOrderFront(nil)
        return await PluginPickCenter.shared.choose(request) { pick in
            WorkspaceMenuCommands.openPalette(.pluginPick(pick), windowNumber: windowNumber)
        }
    }

    func confirm(_ request: PluginConfirmRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = request.message
        alert.informativeText = request.detail ?? ""
        alert.alertStyle = request.isDestructive ? .warning : .informational
        let confirmButton = alert.addButton(withTitle: request.confirmLabel ?? "OK")
        confirmButton.hasDestructiveAction = request.isDestructive
        alert.addButton(withTitle: request.cancelLabel ?? "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if let window = MenuCommandContext.sheetHostWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func notify(title: String?, message: String) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert]) else {
            throw ActionError.capabilityDenied("Notifications are turned off for nvModern")
        }
        let content = UNMutableNotificationContent()
        content.title = title ?? "nvModern"
        content.body = message
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A file inside an open project opens as that window's workspace note;
    /// anything else opens as an external document in the frontmost window.
    func open(fileURL: URL, inNewTab: Bool) -> Bool {
        let path = fileURL.standardizedFileURL.path
        let disposition: WorkspaceActionOpenDisposition = inNewTab ? .newTab : .currentTab

        for runtime in WorkspaceActionRouter.runtimesFrontToBack() {
            let rootPath = URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true).standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            runtime.openDocument(.workspaceNote(relativePath: String(path.dropFirst(prefix.count))), disposition: disposition)
            return true
        }

        guard WorkspaceActionRouter.performExternalFileOpen(.externalMarkdown(filePath: path)) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func readClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func dismissPluginSurfaces() {
        panels.closePluginSession()
        PluginPickCenter.shared.cancelAll()
    }
}
