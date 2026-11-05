import AppKit
import SwiftUI

/// File menu: creating, opening, and acting on a document.
///
/// Search and navigation commands used to live here too — Quick Find, Actions,
/// Search Contents, and Find in Document were all File items, which is why the
/// menu had twelve entries and no dividers. Find now lives under Edit and the
/// palettes under Go.
struct FileMenuCommands: Commands {
    @ObservedObject private var sessionStore = WorkspaceSessionStore.shared
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            let _ = routerState.revision

            Button("Capture…") {
                WorkspaceMenuCommands.openPalette(.capture)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("New Note…") {
                _ = WorkspaceActionRouter.performPresentNewNotePanel(in: MenuCommandContext.targetWindowNumber)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("New Tab") {
                _ = WorkspaceActionRouter.performNewTab(
                    in: MenuCommandContext.targetWindowNumber,
                    trigger: "command-or-menu"
                )
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("Open Sibling…") {
                WorkspaceMenuCommands.openPalette(.siblings)
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(!MenuCommandContext.hasWorkspaceWindow)

            Button("New Window") {
                WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(projectRootPath: nil)
                WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open…") {
                openExternalFile()
            }

            Menu("Open Recent") {
                let _ = sessionStore.recentDocumentsRevision
                let recentItems = sessionStore.recentDocuments(limit: 12)
                if recentItems.isEmpty {
                    Text("No Recent Files")
                } else {
                    ForEach(recentItems) { item in
                        Button(recentMenuTitle(for: item)) {
                            openRecentDocument(item)
                        }
                    }
                }
            }

            Menu("Open Project") {
                let projects = NVModernConfigLoader.loadAppConfig().projects
                if projects.isEmpty {
                    Text("No Projects Configured")
                } else {
                    ForEach(projects) { project in
                        Button(project.name) {
                            WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(projectRootPath: project.id)
                            WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
                        }
                    }
                }
            }

            Button("Open Clipboard") {
                openClipboardContents()
            }
        }

        CommandGroup(after: .newItem) {
            let _ = routerState.revision

            Divider()

            Button("Duplicate Note") {
                _ = WorkspaceActionRouter.performDuplicateCurrentWorkspaceNote(
                    in: MenuCommandContext.targetWindowNumber
                )
            }

            Button("Reveal in Finder") {
                _ = WorkspaceActionRouter.performRevealCurrentDocumentInFinder(
                    in: MenuCommandContext.targetWindowNumber
                )
            }

            Button("Reload from Disk") {
                _ = WorkspaceActionRouter.performReloadCurrentDocumentFromDisk(
                    in: MenuCommandContext.targetWindowNumber
                )
            }

            Divider()

            Button("Compare Markdown Files…") {
                compareMarkdownFiles()
            }
        }
    }

    // MARK: - Open

    private func openExternalFile() {
        let sourceProjectRootPath = MenuCommandContext.projectRootPath

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Open"
        panel.title = "Open File"

        present(panel) { response in
            guard response == .OK,
                  let url = panel.url,
                  url.isFileURL else {
                return
            }

            let standardizedPath = url.standardizedFileURL.path
            WorkspaceWindowLaunchStore.shared.markInternallyHandledOpenFile(path: standardizedPath)

            WorkspaceMenuCommands.openDocument(
                .externalMarkdown(filePath: standardizedPath),
                projectRootPath: sourceProjectRootPath
            )
        }
    }

    private func openClipboardContents() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Clipboard Does Not Contain Text"
            alert.informativeText = "Copy some text to the clipboard, then choose File > Open Clipboard again."
            alert.runModal()
            return
        }

        WorkspaceMenuCommands.openDocument(
            .clipboardMarkdown(title: "Clipboard", body: text),
            projectRootPath: MenuCommandContext.projectRootPath
        )
    }

    private func compareMarkdownFiles() {
        let sourceProjectRootPath = MenuCommandContext.projectRootPath

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Compare"
        panel.title = "Compare Two Markdown Files"
        panel.message = "Select exactly two Markdown files."

        present(panel) { response in
            guard response == .OK else { return }

            let urls = panel.urls.map(\.standardizedFileURL)
            guard urls.count == 2,
                  urls.allSatisfy({ MenuCommandContext.markdownExtensions.contains($0.pathExtension.lowercased()) }),
                  urls[0] != urls[1] else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Choose Two Different Markdown Files"
                alert.informativeText = "The comparison viewer requires exactly two .md or Markdown files."
                alert.runModal()
                return
            }

            let rootURL = sourceProjectRootPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            WorkspaceMenuCommands.openDocument(
                .diff(
                    left: diffSource(for: urls[0], rootURL: rootURL),
                    right: diffSource(for: urls[1], rootURL: rootURL)
                ),
                projectRootPath: sourceProjectRootPath
            )
        }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let hostWindow = MenuCommandContext.sheetHostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func diffSource(for fileURL: URL, rootURL: URL?) -> WorkspaceDiffSource {
        let standardizedFileURL = fileURL.standardizedFileURL
        if let rootURL {
            let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            if standardizedFileURL.path.hasPrefix(rootPath) {
                return .workspace(relativePath: String(standardizedFileURL.path.dropFirst(rootPath.count)))
            }
        }
        return .external(filePath: standardizedFileURL.path)
    }

    // MARK: - Recents

    private func openRecentDocument(_ item: PersistedRecentDocument) {
        if WorkspaceActionRouter.performOpenDocument(
            item.document,
            disposition: .newTab,
            inProjectRootPath: item.rootPath
        ) {
            return
        }

        WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(
            projectRootPath: item.rootPath,
            documents: [item.document]
        )
        WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
    }

    private func recentMenuTitle(for item: PersistedRecentDocument) -> String {
        let rootName = URL(fileURLWithPath: item.rootPath).lastPathComponent
        switch item.document {
        case .workspaceNote(let relativePath):
            return "\(item.title) — \(rootName)/\(relativePath)"
        case .externalMarkdown(let filePath):
            return "\(item.title) — \(filePath)"
        case .clipboardMarkdown, .diff:
            return item.title
        }
    }
}
