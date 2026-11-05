import AppKit
import SwiftUI

/// Everything a menu item needs to know about "what am I acting on right now".
///
/// Each command group used to carry its own `currentTargetWindowNumber()` copy
/// while Capture/Refile/Inspector resolved through `WorkspaceActionRouter`
/// directly, so a File item and a Capture item could pick different windows in
/// the same multi-window session. One resolution point removes that class of
/// bug: `WorkspaceActionRouter.runtime(for: nil)` already walks key window ->
/// main window -> last active -> topmost, which is exactly what a menu wants.
@MainActor
enum MenuCommandContext {
    static var runtime: (any WorkspaceActionRuntime)? {
        WorkspaceActionRouter.runtime(for: nil)
    }

    static var targetWindowNumber: Int? {
        runtime?.windowNumber
    }

    static var hasWorkspaceWindow: Bool {
        runtime != nil
    }

    static var projectRootPath: String? {
        runtime?.projectRootPath
    }

    /// The window an `NSOpenPanel` sheet should hang off.
    static var sheetHostWindow: NSWindow? {
        if let windowNumber = targetWindowNumber,
           let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) {
            return window
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// Whether Markdown formatting applies to the current surface.
    ///
    /// Call this ONLY from inside a menu item's action, never from a `Commands`
    /// body. It reaches `WorkspaceView.currentEditorCommandTargetSnapshot()`,
    /// which goes through `ensureWorkspaceTabController(...)` and can therefore
    /// mutate workspace state. Evaluating it during a render pass made the
    /// active tab resync from a stale snapshot and regress to `.launchpad`,
    /// which broke opening Markdown documents entirely. Menu enabled state has
    /// to come from a value the workspace pushes out, not from a pull at render
    /// time — see the note in `FormatMenuCommands`.
    static func isMarkdownEditingSurfaceNow(allowingArborOutline: Bool = false) -> Bool {
        let document = WorkspaceActionRouter.currentDocumentSnapshot(in: nil)
        let commandTarget = WorkspaceActionRouter.currentEditorCommandTarget(in: nil)

        let isMarkdown = isMarkdownPath(
            document?.absolutePath ?? document?.relativePath,
            allowingArborOutline: allowingArborOutline
        ) || isMarkdownPath(
            commandTarget?.path,
            allowingArborOutline: allowingArborOutline
        )
        let isEditable = document?.isEditable == true || commandTarget?.isEditable == true

        return isMarkdown && isEditable && commandTarget?.surfaceKind == .text
    }

    private static func isMarkdownPath(_ path: String?, allowingArborOutline: Bool) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return markdownExtensions.contains(pathExtension)
            || (allowingArborOutline && pathExtension == "outline")
    }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
}

/// The one implementation of every command the menu bar can invoke.
///
/// `AppDelegate`'s key monitor and the menu items used to post the same
/// notifications through separate near-identical helpers, free to drift apart.
/// Both now call through here.
@MainActor
enum WorkspaceMenuCommands {
    /// Opens the one command palette on a preset. Every former surface —
    /// Quick Find, Actions, Content Search, Capture, Refile — is a
    /// preset, so menu items and the key monitor share one entry point.
    static func openPalette(_ preset: PalettePreset, windowNumber: Int? = nil) {
        guard WindowFocusCoordinator.shared.kind(of: NSApp.keyWindow) != .scratchpad else { return }
        let resolvedWindowNumber = windowNumber ?? MenuCommandContext.targetWindowNumber
        paletteDebugLog("menuCommand openPalette preset=\(preset.debugLabel) windowNumber=\(String(describing: resolvedWindowNumber))")

        var userInfo: [String: Any] = [PaletteOpenNotification.presetKey: preset]
        if let resolvedWindowNumber {
            userInfo[PaletteOpenNotification.windowNumberKey] = resolvedWindowNumber
        }
        NotificationCenter.default.post(
            name: .palettePresetOpenRequested,
            object: nil,
            userInfo: userInfo
        )
    }

    static func openDocumentFind(windowNumber: Int? = nil) {
        guard WindowFocusCoordinator.shared.kind(of: NSApp.keyWindow) != .scratchpad else { return }
        var userInfo: [String: Any] = [:]
        if let resolvedWindowNumber = windowNumber ?? MenuCommandContext.targetWindowNumber {
            userInfo[DocumentNavigatorNotification.windowNumberKey] = resolvedWindowNumber
        }
        NotificationCenter.default.post(
            name: .documentFindOpenRequested,
            object: nil,
            userInfo: userInfo
        )
    }

    static func openDocumentInspector(windowNumber: Int? = nil) {
        guard WindowFocusCoordinator.shared.kind(of: NSApp.keyWindow) != .scratchpad else { return }
        var userInfo: [String: Any] = [:]
        if let resolvedWindowNumber = windowNumber ?? MenuCommandContext.targetWindowNumber {
            userInfo[DocumentInspectorNotification.windowNumberKey] = resolvedWindowNumber
        }
        NotificationCenter.default.post(
            name: .documentInspectorOpenRequested,
            object: nil,
            userInfo: userInfo
        )
    }

    static func openDocumentNavigator(_ mode: DocumentNavigatorMode, windowNumber: Int? = nil) {
        guard WindowFocusCoordinator.shared.kind(of: NSApp.keyWindow) != .scratchpad else { return }
        var userInfo: [String: Any] = [DocumentNavigatorNotification.modeKey: mode]
        if let resolvedWindowNumber = windowNumber ?? MenuCommandContext.targetWindowNumber {
            userInfo[DocumentNavigatorNotification.windowNumberKey] = resolvedWindowNumber
        }
        NotificationCenter.default.post(
            name: .documentNavigatorOpenRequested,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Runs a registered action against the frontmost workspace, the way a
    /// keybinding would.
    static func performAction(_ method: String, args: [String: ActionValue] = [:]) {
        Task { @MainActor in
            let response = await ActionInvocationDispatcher.shared.execute(
                invocation: .method(method: method, args: args, target: nil),
                source: ActionSource(kind: .menu, identifier: method),
                fallbackTarget: .automatic
            )
            if !response.ok, let error = response.error {
                print("[NVModern][Actions][Menu] \(method) failed: \(error.message)")
            }
        }
    }

    /// Opens a document in the frontmost workspace, falling back to launching a
    /// new window when no workspace is available to receive it.
    static func openDocument(
        _ document: WorkspaceOpenedDocument,
        projectRootPath: String?
    ) {
        if WorkspaceActionRouter.performOpenDocumentInNewTab(document, in: MenuCommandContext.targetWindowNumber) {
            return
        }

        WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(
            projectRootPath: projectRootPath,
            documents: [document]
        )
        WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
    }
}
