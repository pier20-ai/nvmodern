import AppKit
import Foundation

/// Document-level commands that used to exist only inside the omnibox palette's
/// private switch (copy path, rename, find, appearance) plus the two layout
/// toggles the palette exposed. They live in the registry so the palette, the
/// menus, configured keybindings, plugins, and the action socket all reach the
/// same implementation.
///
/// Every path-taking action here defaults to the current document when its
/// `path` argument is absent, which is what lets the palette bind a note noun
/// to them without changing plain invocation.
@MainActor
enum WorkspaceDocumentBuiltinActions {
    static func register(into registry: ActionRegistry) {
        registry.register(copyPathDescriptor) { request, context in
            let runtime = try resolvedRuntime(from: context)
            let resolved = try resolveDocument(request: request, runtime: runtime)
            guard let absolutePath = resolved.absolutePath else {
                throw ActionError.unavailable("The current document does not have a file path")
            }
            writeToPasteboard(absolutePath)
            return [
                "copied": .bool(true),
                "path": .string(absolutePath),
                "relativePath": ActionValue(resolved.relativePath),
                "projectRootPath": .string(runtime.projectRootPath)
            ]
        }

        registry.register(copyRelativePathDescriptor) { request, context in
            let runtime = try resolvedRuntime(from: context)
            let resolved = try resolveDocument(request: request, runtime: runtime)
            guard let relativePath = resolved.relativePath, !relativePath.isEmpty else {
                throw ActionError.unavailable("The current document is not a workspace note")
            }
            writeToPasteboard(relativePath)
            return [
                "copied": .bool(true),
                "relativePath": .string(relativePath),
                "projectRootPath": .string(runtime.projectRootPath)
            ]
        }

        registry.register(renameDescriptor) { request, context in
            struct RenameArgs: Decodable {
                let name: String
                let path: String?
            }

            let runtime = try resolvedRuntime(from: context)
            let args = try request.decodeArgs(RenameArgs.self)
            let newName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else {
                throw ActionError.invalidArguments("name must not be empty")
            }

            let resolved = try resolveDocument(request: request, runtime: runtime)
            guard let relativePath = resolved.relativePath, !relativePath.isEmpty else {
                throw ActionError.unavailable("Only workspace items can be renamed")
            }

            let newRelativePath = try runtime.renameWorkspaceItem(relativePath: relativePath, to: newName)
            return [
                "renamed": .bool(newRelativePath != relativePath),
                "oldRelativePath": .string(relativePath),
                "relativePath": .string(newRelativePath),
                "absolutePath": ActionValue(absolutePath(for: newRelativePath, runtime: runtime)),
                "projectRootPath": .string(runtime.projectRootPath),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(openParentFolderDescriptor) { request, context in
            try showInParentFolder(request: request, context: context, selectDocument: false)
        }

        registry.register(showInParentFolderDescriptor) { request, context in
            try showInParentFolder(request: request, context: context, selectDocument: true)
        }

        registry.register(findDescriptor) { _, context in
            let runtime = try resolvedRuntime(from: context)
            WorkspaceMenuCommands.openDocumentFind(windowNumber: runtime.windowNumber)
            return [
                "opened": .bool(true),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(documentThemeDescriptor) { request, context in
            struct Args: Decodable { let id: String }
            let args = try request.decodeArgs(Args.self)
            let runtime = try resolvedRuntime(from: context)
            guard var settings = runtime.currentDocumentInspectorSettings(),
                  let theme = EditorThemeRegistry.theme(withID: args.id, in: UserEditorThemeSelection.themesDirectory()) else {
                throw ActionError.invalidArguments("Unknown document theme '\(args.id)'")
            }
            settings.theme = DocumentThemeID(rawValue: theme.id)
            guard runtime.setCurrentDocumentInspectorSettings(settings) else {
                throw ActionError.unavailable("Open a text document to change its theme")
            }
            return ["id": .string(theme.id), "title": .string(theme.title)]
        }

        registry.register(documentWidthDescriptor) { request, context in
            struct Args: Decodable { let width: String }
            let args = try request.decodeArgs(Args.self)
            guard let width = DocumentInspectorWidth(configuredValue: args.width) else {
                throw ActionError.invalidArguments("Unknown page width '\(args.width)'")
            }
            let runtime = try resolvedRuntime(from: context)
            guard var settings = runtime.currentDocumentInspectorSettings() else {
                throw ActionError.unavailable("No document appearance settings available")
            }
            settings.width = width
            guard runtime.setCurrentDocumentInspectorSettings(settings) else {
                throw ActionError.unavailable("Open a text document to change its page width")
            }
            return ["width": .string(width.rawValue), "title": .string(width.title)]
        }

        registry.register(appearanceDescriptor) { _, context in
            let runtime = try resolvedRuntime(from: context)
            WorkspaceMenuCommands.openDocumentInspector(windowNumber: runtime.windowNumber)
            return [
                "opened": .bool(true),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(outlineDescriptor) { _, context in
            let runtime = try resolvedRuntime(from: context)
            WorkspaceMenuCommands.openPalette(.outline, windowNumber: runtime.windowNumber)
            return ["opened": .bool(true), "windowID": .string(runtime.windowID)]
        }

        registry.register(toggleCompactToolbarDescriptor) { _, _ in
            let enabled = CompactToolbarPreference.toggle()
            return ["enabled": .bool(enabled)]
        }

        registry.register(openPaletteDescriptor) { request, context in
            struct Args: Decodable {
                let preset: String?
                let query: String?
            }

            let runtime = try resolvedRuntime(from: context)
            let args = (try? request.decodeArgs(Args.self)) ?? Args(preset: nil, query: nil)
            let presetName = (args.preset ?? "root").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let preset: PalettePreset
            switch presetName {
            case "", "root", "search", "quickfind":
                preset = .root
            case "actions":
                preset = .actions
            case "content", "contentsearch":
                preset = .contentSearch(initialQuery: args.query ?? "")
            case "capture":
                preset = .capture
            case "outline":
                preset = .outline
            case "verbs", "documentverbs":
                preset = .documentVerbs
            default:
                throw ActionError.invalidArguments(
                    "Unknown palette preset",
                    details: ["preset": .string(presetName)]
                )
            }
            WorkspaceMenuCommands.openPalette(preset, windowNumber: runtime.windowNumber)
            return [
                "opened": .bool(true),
                "preset": .string(presetName),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID)
            ]
        }

        registry.register(toggleSidebarDescriptor) { _, context in
            let runtime = try resolvedRuntime(from: context)
            let visible = !runtime.isSidebarVisible
            runtime.setSidebarVisible(visible)
            return [
                "visible": .bool(visible),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID)
            ]
        }
    }

    // MARK: - Helpers

    private struct ResolvedDocument {
        let relativePath: String?
        let absolutePath: String?
    }

    private static func resolvedRuntime(
        from context: ActionExecutionContext
    ) throws -> any WorkspaceActionRuntime {
        guard let runtime = WorkspaceActionRouter.runtime(for: context.resolvedTarget) else {
            throw ActionError.targetNotFound("Could not resolve a target workspace")
        }
        return runtime
    }

    /// The document an action acts on: the explicit `path` argument, else the
    /// document open in the selected tab.
    private static func resolveDocument(
        request: ActionRequest,
        runtime: any WorkspaceActionRuntime
    ) throws -> ResolvedDocument {
        struct PathArgs: Decodable {
            let path: String?
        }

        let args = (try? request.decodeArgs(PathArgs.self)) ?? PathArgs(path: nil)
        if let requested = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard isSafeWorkspaceRelativePath(requested) else {
                throw ActionError.invalidArguments(
                    "path must be a workspace-relative path",
                    details: ["path": .string(requested)]
                )
            }
            return ResolvedDocument(
                relativePath: requested,
                absolutePath: absolutePath(for: requested, runtime: runtime)
            )
        }

        guard let snapshot = runtime.currentDocumentSnapshot() else {
            throw ActionError.unavailable("No document is currently open in the target workspace")
        }
        return ResolvedDocument(
            relativePath: snapshot.relativePath,
            absolutePath: snapshot.absolutePath
                ?? snapshot.relativePath.flatMap { absolutePath(for: $0, runtime: runtime) }
        )
    }

    private static func absolutePath(
        for relativePath: String,
        runtime: any WorkspaceActionRuntime
    ) -> String {
        URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .path
    }

    private static func showInParentFolder(
        request: ActionRequest,
        context: ActionExecutionContext,
        selectDocument: Bool
    ) throws -> ActionValue {
        let runtime = try resolvedRuntime(from: context)
        let resolved = try resolveDocument(request: request, runtime: runtime)
        guard let relativePath = resolved.relativePath, !relativePath.isEmpty else {
            throw ActionError.unavailable("The current document is not a workspace note")
        }
        guard runtime.showInParentFolder(
            relativePath: relativePath,
            selectDocument: selectDocument
        ) else {
            throw ActionError.unavailable("Could not show the document's parent folder")
        }
        return [
            "opened": .bool(true),
            "relativePath": .string(relativePath),
            "selectedDocument": .bool(selectDocument),
            "windowID": .string(runtime.windowID),
            "workspaceID": .string(runtime.workspaceID),
            "tabID": ActionValue(runtime.selectedTabID)
        ]
    }

    private static func isSafeWorkspaceRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func writeToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    // MARK: - Descriptors

    private static let pathArgument = ActionArgumentDescriptor(
        name: "path",
        summary: "Workspace-relative path; omit for the current document",
        kind: .string,
        isRequired: false
    )

    private static let copyPathDescriptor = ActionDescriptor(
        method: "workspace.document.copyPath",
        title: "Copy Path",
        summary: "Copy the document's absolute file path to the clipboard.",
        discussion: "With no path argument this copies the path of the document in the selected tab.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "document", "path", "clipboard"],
        arguments: [pathArgument],
        result: ActionResultDescriptor(summary: "Copied path metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "doc.on.clipboard",
            when: "activeDocument",
            title: "Copy Path",
            rank: 30,
            keywords: ["copy", "absolute", "clipboard"],
            nounArguments: ["note": "path"],
            acceptsBatch: true
        )
    )

    private static let copyRelativePathDescriptor = ActionDescriptor(
        method: "workspace.document.copyRelativePath",
        title: "Copy Relative Path",
        summary: "Copy the document's workspace-relative path to the clipboard.",
        discussion: "With no path argument this copies the path of the document in the selected tab.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "document", "path", "clipboard"],
        arguments: [pathArgument],
        result: ActionResultDescriptor(summary: "Copied path metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "doc.on.clipboard",
            when: "activeDocument",
            title: "Copy Relative Path",
            rank: 200,
            keywords: ["copy", "relative", "clipboard"],
            nounArguments: ["note": "path"],
            acceptsBatch: true
        )
    )

    private static let renameDescriptor = ActionDescriptor(
        method: "workspace.document.rename",
        title: "Rename Document",
        summary: "Rename a workspace note or folder, keeping open tabs and history pointed at it.",
        discussion: "The file extension is preserved when the new name omits one. With no path argument this renames the document in the selected tab.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "document", "rename"],
        arguments: [
            ActionArgumentDescriptor(
                name: "name",
                summary: "New file name",
                kind: .string,
                isRequired: true,
                picker: .text
            ),
            pathArgument
        ],
        result: ActionResultDescriptor(summary: "Renamed document metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "pencil",
            when: "activeDocument",
            title: "Rename…",
            rank: 12,
            keywords: ["rename", "move"],
            nounArguments: ["note": "path"]
        )
    )

    private static let openParentFolderDescriptor = ActionDescriptor(
        method: "workspace.document.openParentFolder",
        title: "Open Parent Folder",
        summary: "Open the document's parent folder in Miller columns and select its first item.",
        discussion: "The parent folder becomes the last visible column in the current tab.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "document", "folder", "miller", "browse"],
        arguments: [pathArgument],
        result: ActionResultDescriptor(summary: "Parent-folder browser metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Open",
            iconSystemName: "folder",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Open Parent Folder",
            rank: 18,
            keywords: ["parent", "folder", "miller", "browse"],
            nounArguments: ["note": "path"]
        )
    )

    private static let showInParentFolderDescriptor = ActionDescriptor(
        method: "workspace.document.showInParentFolder",
        title: "Show in Parent Folder",
        summary: "Show and select the document in its parent folder in Miller columns.",
        discussion: "The parent folder becomes the last visible column in the current tab.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "document", "folder", "miller", "reveal"],
        arguments: [pathArgument],
        result: ActionResultDescriptor(summary: "Parent-folder browser metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Open",
            iconSystemName: "folder.badge.questionmark",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Show in Parent Folder",
            rank: 19,
            keywords: ["show", "parent", "folder", "miller", "reveal"],
            nounArguments: ["note": "path"]
        )
    )

    private static let findDescriptor = ActionDescriptor(
        method: "workspace.document.find",
        title: "Find in Document",
        summary: "Open the in-document find bar for the selected tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "document", "find", "search"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Find bar request metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "magnifyingglass",
            when: editableTextSurfacePaletteCondition,
            title: "Find in document",
            rank: 10,
            keywords: ["find", "search", "replace"]
        )
    )

    private static let outlineDescriptor = ActionDescriptor(
        method: "workspace.document.outline",
        title: "Go to Heading…",
        summary: "Search and navigate headings in the active Markdown or Org document.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "document", "outline", "heading"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Outline palette request metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "list.bullet.indent",
            when: editableTextSurfacePaletteCondition,
            title: "Go to heading…",
            rank: 15,
            keywords: ["outline", "heading", "symbol", "navigate"]
        )
    )

    private static let documentThemeDescriptor = ActionDescriptor(
        method: "workspace.document.theme.select",
        title: "Document theme",
        summary: "Change the current document's theme through its appearance inspector settings.",
        discussion: "Frontmatter appearance overrides still take precedence, as in the inspector.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "document", "appearance"],
        arguments: [ActionArgumentDescriptor(name: "id", summary: "Document theme", kind: .string, isRequired: true, picker: .editorTheme)],
        result: ActionResultDescriptor(summary: "Selected document theme", kind: .object),
        palette: ActionPalettePresentation(
            category: "Appearance",
            iconSystemName: "paintpalette",
            when: "activeEditor.surface == \"text\"",
            title: "Document theme…",
            rank: 10,
            keywords: ["theme", "appearance", "color"],
            subject: .document
        )
    )

    private static let documentWidthDescriptor = ActionDescriptor(
        method: "workspace.document.width.select",
        title: "Page width",
        summary: "Change the current document's page width through its appearance inspector settings.",
        discussion: "Frontmatter appearance overrides still take precedence, as in the inspector.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "document", "appearance"],
        arguments: [ActionArgumentDescriptor(name: "width", summary: "Page width", kind: .string, isRequired: true, picker: .documentWidth)],
        result: ActionResultDescriptor(summary: "Selected page width", kind: .object),
        palette: ActionPalettePresentation(
            category: "Appearance",
            iconSystemName: "arrow.left.and.right",
            when: "activeEditor.surface == \"text\"",
            title: "Page width…",
            rank: 11,
            keywords: ["width", "page", "layout", "narrow", "wide"],
            subject: .document
        )
    )

    private static let appearanceDescriptor = ActionDescriptor(
        method: "workspace.document.appearance",
        title: "Document Appearance",
        summary: "Open the document appearance inspector for the selected tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "document", "appearance", "inspector"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Inspector request metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "textformat",
            when: "activeEditor.surface == \"text\"",
            title: "Document appearance",
            rank: 12,
            keywords: ["inspector", "width", "font"]
        )
    )

    private static let toggleCompactToolbarDescriptor = ActionDescriptor(
        method: "workspace.toolbar.compact.toggle",
        title: "Toggle Compact Toolbar",
        summary: "Switch every workspace window between the compact and the regular toolbar.",
        discussion: "The toolbar height is one app-wide preference, so this applies to open windows and to windows opened later.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .none,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "toolbar", "layout"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Compact toolbar state", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "menubar.rectangle",
            title: "Toggle Compact Toolbar",
            rank: 32,
            keywords: ["toolbar", "compact", "titlebar", "chrome"]
        )
    )

    private static let openPaletteDescriptor = ActionDescriptor(
        method: "workspace.palette.open",
        title: "Open Command Palette",
        summary: "Open the command palette on a preset frame in the target window.",
        discussion: "Presets: root (default), actions, content, capture, refile, outline, verbs (the current document's actions). `query` seeds the content preset. Not listed in the palette itself.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "palette", "omnibox"],
        arguments: [
            ActionArgumentDescriptor(name: "preset", summary: "root, actions, content, capture, refile, outline, or verbs", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "query", summary: "Initial query for the content preset", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Palette request metadata", kind: .object)
    )

    private static let toggleSidebarDescriptor = ActionDescriptor(
        method: "workspace.sidebar.toggle",
        title: "Toggle Sidebar",
        summary: "Show or hide the workspace sidebar for the target window.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "sidebar", "layout"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Sidebar visibility state", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "sidebar.left",
            title: "Toggle Sidebar",
            rank: 30,
            keywords: ["sidebar", "hide", "show"]
        )
    )
}
