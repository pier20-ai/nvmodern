import AppKit
import Foundation

@MainActor
enum WorkspaceBuiltinActions {
    static func register(into registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            method: "app.help.open", title: "Explore Help", summary: "Browse help, constructions, and examples.",
            discussion: nil, domain: .app, mutationKind: .readOnly, targetRequirement: .none,
            capabilities: [], tags: ["help", "learn", "reference"], arguments: [],
            result: ActionResultDescriptor(summary: "Help opened", kind: .object),
            palette: ActionPalettePresentation(category: "Help", iconSystemName: "questionmark.circle",
                                               title: "Explore help", rank: 10, keywords: ["help", "calc", "learn"])
        )) { _, _ in
            AppHelpService.shared.presentFromActiveWindow()
            return ["opened": .bool(true)]
        }

        registry.register(newTabDescriptor) { request, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.newTab()
            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(closeTabDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.closeCurrentTab()
            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(selectNextTabDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.selectNextTab()
            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(selectPreviousTabDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.selectPreviousTab()
            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(duplicateTabDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.duplicateCurrentTab()
            return workspaceMetadata(runtime)
        }

        registry.register(showAllTabsDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.showAllTabs()
            return workspaceMetadata(runtime)
        }

        registry.register(splitRightDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.splitHorizontally()
            return workspaceMetadata(runtime)
        }

        registry.register(splitDownDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            runtime.splitVertically()
            return workspaceMetadata(runtime)
        }

        registry.register(refileCurrentNoteDescriptor) { request, context in
            struct RefileArgs: Decodable {
                let folder: String?
                let path: String?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let args = try request.decodeArgs(RefileArgs.self)
            let requestedPath = args.path?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A `path` names the note to move — this is what lets the palette
            // refile a noun that is not the current document, one per member of
            // a multi-select batch.
            let result: WorkspaceActionNoteMoveResult?
            if let requestedPath, !requestedPath.isEmpty {
                result = try runtime.refileWorkspaceNote(
                    relativePath: requestedPath,
                    toFolderRelativePath: args.folder
                )
            } else {
                result = try runtime.refileCurrentWorkspaceNote(toFolderRelativePath: args.folder)
            }
            guard let result else {
                throw ActionError.unavailable("The requested document is not a workspace note")
            }
            return try ActionValue.fromEncodable(result)
        }

        registry.register(openNoteDescriptor) { request, context in
            struct OpenArgs: Decodable {
                let relativePath: String
                let openIn: WorkspaceActionOpenDisposition?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }

            let args = try request.decodeArgs(OpenArgs.self)
            let disposition = args.openIn ?? .currentTab
            runtime.openDocument(.workspaceNote(relativePath: args.relativePath), disposition: disposition)

            if let snapshot = runtime.currentDocumentSnapshot() {
                return try ActionValue.fromEncodable(snapshot)
            }

            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID),
                "relativePath": .string(args.relativePath)
            ]
        }

        registry.register(openNoteInNewTabDescriptor) { request, context in
            struct OpenArgs: Decodable {
                let path: String?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }

            let args = (try? request.decodeArgs(OpenArgs.self)) ?? OpenArgs(path: nil)
            let requestedPath = args.path?.trimmingCharacters(in: .whitespacesAndNewlines)
            let relativePath = (requestedPath?.isEmpty == false)
                ? requestedPath
                : runtime.currentDocumentSnapshot()?.relativePath
            guard let relativePath, !relativePath.isEmpty else {
                throw ActionError.invalidArguments("path is required when no workspace note is open")
            }

            runtime.openDocument(.workspaceNote(relativePath: relativePath), disposition: .newTab)
            if let snapshot = runtime.currentDocumentSnapshot() {
                return try ActionValue.fromEncodable(snapshot)
            }
            return [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID),
                "relativePath": .string(relativePath)
            ]
        }

        registry.register(currentNoteDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }

            guard let snapshot = runtime.currentDocumentSnapshot() else {
                throw ActionError.unavailable("No document is currently open in the target workspace")
            }

            return try ActionValue.fromEncodable(snapshot)
        }

        registry.register(getNoteDescriptor) { request, context in
            struct GetNoteArgs: Decodable {
                let relativePath: String
                let maxBytes: Int?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let args = try request.decodeArgs(GetNoteArgs.self)
            let projectRoot = URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true)
            do {
                let result = try WorkspaceNoteFileRead.read(
                    relativePath: args.relativePath,
                    projectRoot: projectRoot,
                    maxBytes: args.maxBytes
                )
                return [
                    "relativePath": .string(result.relativePath),
                    "title": .string(result.title),
                    "body": .string(result.body),
                    "byteCount": .int(result.byteCount),
                    "truncated": .bool(result.truncated)
                ]
            } catch WorkspaceNoteFileReadError.invalidPath {
                throw ActionError.invalidArguments(
                    "relativePath must be a workspace-relative file path",
                    details: ["relativePath": .string(args.relativePath)]
                )
            } catch WorkspaceNoteFileReadError.notFound {
                throw ActionError.targetNotFound(
                    "Note not found: \(args.relativePath)",
                    details: ["relativePath": .string(args.relativePath)]
                )
            } catch WorkspaceNoteFileReadError.notAFile {
                throw ActionError.invalidArguments(
                    "relativePath must point to a file",
                    details: ["relativePath": .string(args.relativePath)]
                )
            } catch WorkspaceNoteFileReadError.unreadable {
                throw ActionError.executionFailed(
                    "Could not read \(args.relativePath)",
                    details: ["relativePath": .string(args.relativePath)]
                )
            }
        }

        registry.register(searchQueryDescriptor) { request, context in
            struct SearchArgs: Decodable {
                let query: String
                let limit: Int?
            }

            let args = try request.decodeArgs(SearchArgs.self)
            let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw ActionError.invalidArguments("query must not be empty")
            }
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }

            let config = NVModernConfigLoader.load(projectRootPath: runtime.projectRootPath)
            let engine = NoteSearchEngineRegistry.shared.engine(for: config.activeProject)
            let response = await engine.search(
                query: query,
                rootURL: config.rootURL,
                supportedFacetKeys: config.supportedSearchFacetKeys
            )
            let limit = min(max(args.limit ?? 20, 1), 80)
            let items = Array(response.results.prefix(limit)).map { hit in
                WorkspaceActionSearchHit(
                    title: hit.title,
                    relativePath: hit.relativePath,
                    snippet: hit.snippet,
                    score: hit.score
                )
            }
            return [
                "query": .string(query),
                "count": .int(items.count),
                "indexPhase": .string(response.indexStatus.phase.rawValue),
                "indexStale": .bool(response.indexStatus.isStale),
                "items": .array(try items.map { try ActionValue.fromEncodable($0) })
            ]
        }

        registry.register(currentProjectDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            return try ActionValue.fromEncodable(runtime.currentProjectSnapshot())
        }

        registry.register(listProjectsDescriptor) { _, context in
            let runtime = resolvedRuntime(from: context)
            let config = NVModernConfigLoader.load(
                projectRootPath: context.resolvedTarget.projectRootPath ?? runtime?.projectRootPath
            )
            let items = config.availableProjects.map { project in
                WorkspaceActionProjectSnapshot(name: project.name, rootPath: project.rootURL.path)
            }
            var result: [String: ActionValue] = [
                "count": .int(items.count),
                "items": .array(try items.map { try ActionValue.fromEncodable($0) })
            ]
            if let runtime {
                result["current"] = try ActionValue.fromEncodable(runtime.currentProjectSnapshot())
            }
            return .object(result)
        }

        registry.register(listTabsDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let items = runtime.listTabs()
            return [
                "count": .int(items.count),
                "selectedTabID": ActionValue(runtime.selectedTabID),
                "items": .array(try items.map { try ActionValue.fromEncodable($0) })
            ]
        }

        registry.register(editorSelectionGetDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let editor = await runtime.queryEditorContext(.selection),
                  let selection = editor.selection
            else {
                throw ActionError.unavailable("No text editor is currently focused")
            }
            return [
                "path": ActionValue(editor.path),
                "title": ActionValue(editor.title),
                "surface": .string(editor.surface),
                "text": .string(selection.text),
                "startLine": ActionValue(selection.startLine),
                "endLine": ActionValue(selection.endLine),
                "startPage": ActionValue(selection.startPage),
                "endPage": ActionValue(selection.endPage),
                "empty": .bool(selection.empty)
            ]
        }

        registry.register(editorSelectionReplaceDescriptor) { request, context in
            struct ReplaceArgs: Decodable {
                let text: String
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let args = try request.decodeArgs(ReplaceArgs.self)
            guard runtime.replaceCurrentEditorSelection(with: args.text) else {
                throw ActionError.unavailable("Could not replace the current editor selection")
            }
            return [
                "replaced": .bool(true),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(prefixMarkdownSelectionLinesDescriptor) { request, context in
            struct PrefixArgs: Decodable {
                let firstPrefix: String
                let continuationPrefix: String?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard canEditMarkdownSelection(runtime.currentEditorCommandTargetSnapshot()) else {
                throw ActionError.unavailable("Available only for a selection in the active editable Markdown editor")
            }

            let args = try request.decodeArgs(PrefixArgs.self)
            let continuationPrefix = args.continuationPrefix ?? args.firstPrefix
            guard !args.firstPrefix.isEmpty || !continuationPrefix.isEmpty else {
                throw ActionError.invalidArguments("At least one selection prefix must be non-empty")
            }
            guard runtime.performCurrentEditorBridgeCommand(
                "prefixMarkdownSelectionLines",
                payload: [
                    "firstPrefix": .string(args.firstPrefix),
                    "continuationPrefix": .string(continuationPrefix)
                ]
            ) else {
                throw ActionError.unavailable("Select one or more Markdown lines before running this action")
            }

            return [
                "performed": .bool(true),
                "operation": .string(prefixMarkdownSelectionLinesDescriptor.method),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(editorCursorContextGetDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let editor = await runtime.queryEditorContext(.cursorNeighborhood),
                  let cursor = editor.cursor
            else {
                throw ActionError.unavailable("No text editor is currently focused")
            }
            return [
                "path": ActionValue(editor.path),
                "title": ActionValue(editor.title),
                "surface": .string(editor.surface),
                "cursorLine": .int(cursor.line),
                "cursorColumn": .int(cursor.column),
                "startLine": .int(cursor.startLine),
                "endLine": .int(cursor.endLine),
                "text": .string(cursor.text),
                "truncated": .bool(cursor.truncated),
                "selectionText": ActionValue(editor.selection?.text)
            ]
        }

        registry.register(currentContextDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let editor = await runtime.queryEditorContext(.currentContext)
            let snapshot = WorkspaceActionContextSnapshot(
                project: runtime.currentProjectSnapshot(),
                document: runtime.currentDocumentSnapshot(),
                surface: editor?.surface ?? "none",
                tabs: runtime.listTabs(),
                viewport: editor?.viewport,
                selection: editor?.selection,
                cursor: editor?.cursor.map {
                    WorkspaceEditorCursorPosition(line: $0.line, column: $0.column)
                }
            )
            return try ActionValue.fromEncodable(snapshot)
        }

        registry.register(jumpInDocumentDescriptor) { request, context in
            struct JumpArgs: Decodable {
                let heading: String?
                let line: Int?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let args = try request.decodeArgs(JumpArgs.self)
            let heading = args.heading?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedHeading = (heading?.isEmpty == false) ? heading : nil
            guard resolvedHeading != nil || args.line != nil else {
                throw ActionError.invalidArguments("heading or line is required")
            }
            guard runtime.currentDocumentSnapshot() != nil else {
                throw ActionError.unavailable("No document is open in the selected tab")
            }
            runtime.jumpInCurrentDocument(heading: resolvedHeading, line: args.line)
            return [
                "jumped": .bool(true),
                "heading": ActionValue(resolvedHeading),
                "line": ActionValue(args.line),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(revealCurrentDocumentDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            return [
                "revealed": .bool(runtime.revealCurrentDocumentInFinder()),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(openCurrentDocumentInZedDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let snapshot = runtime.currentDocumentSnapshot(),
                  let absolutePath = snapshot.absolutePath,
                  !absolutePath.isEmpty else {
                throw ActionError.unavailable("The current document does not have a file path")
            }
            guard FileManager.default.fileExists(atPath: absolutePath) else {
                throw ActionError.unavailable(
                    "The current document no longer exists on disk",
                    details: ["path": .string(absolutePath)]
                )
            }
            guard let executableURL = zedExecutableURL() else {
                throw ActionError.unavailable(
                    "The Zed command-line tool was not found",
                    details: ["command": .string("zed")]
                )
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = [absolutePath]

            do {
                try process.run()
            } catch {
                throw ActionError.executionFailed(
                    "Could not open the current document in Zed",
                    details: [
                        "path": .string(absolutePath),
                        "error": .string(error.localizedDescription)
                    ]
                )
            }

            return [
                "opened": .bool(true),
                "path": .string(absolutePath),
                "command": .string(executableURL.path),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(duplicateCurrentNoteDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let result = try runtime.duplicateCurrentWorkspaceNote() else {
                throw ActionError.unavailable("The current document is not a workspace note")
            }
            return try ActionValue.fromEncodable(result)
        }

        registry.register(reloadCurrentDocumentDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            return [
                "reloaded": .bool(runtime.reloadCurrentDocumentFromDisk()),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(selectDiffOriginalDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let snapshot = runtime.currentDocumentSnapshot(),
                  let source = diffSource(for: snapshot) else {
                throw ActionError.unavailable("Select a workspace or external Markdown document first")
            }

            runtime.setCurrentDiffOriginalSource(source)
            return [
                "selected": .bool(true),
                "role": .string("original"),
                "path": .string(source.path),
                "title": .string(snapshot.title),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(compareWithSelectedDescriptor) { _, context in
            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let original = runtime.currentDiffOriginalSource() else {
                throw ActionError.unavailable("Choose Diff: Select as Original before comparing")
            }
            guard let snapshot = runtime.currentDocumentSnapshot(),
                  let selected = diffSource(for: snapshot) else {
                throw ActionError.unavailable("Select a workspace or external Markdown document to compare")
            }
            guard original != selected else {
                throw ActionError.unavailable("Select a different Markdown document to compare with the original")
            }

            let rootURL = URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true)
            let originalURL = original.fileURL(rootURL: rootURL)
            let selectedURL = selected.fileURL(rootURL: rootURL)
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                throw ActionError.unavailable(
                    "The selected original no longer exists on disk",
                    details: ["path": .string(originalURL.path)]
                )
            }
            guard FileManager.default.fileExists(atPath: selectedURL.path) else {
                throw ActionError.unavailable(
                    "The selected comparison document no longer exists on disk",
                    details: ["path": .string(selectedURL.path)]
                )
            }

            runtime.openDocument(.diff(left: original, right: selected), disposition: .newTab)
            return [
                "opened": .bool(true),
                "originalPath": .string(original.path),
                "selectedPath": .string(selected.path),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        registry.register(insertMarkdownTableDescriptor) { request, context in
            struct TableArgs: Decodable {
                let rows: Int?
                let columns: Int?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard MarkdownTableFactory.canInsertTable(in: runtime.currentEditorCommandTargetSnapshot()) else {
                throw ActionError.unavailable("Available only in the active editable Markdown editor")
            }

            let args = (try? request.decodeArgs(TableArgs.self)) ?? TableArgs(rows: nil, columns: nil)
            let rows = MarkdownTableFactory.normalizedCount(args.rows)
            let columns = MarkdownTableFactory.normalizedCount(args.columns)
            let table = MarkdownTableFactory.makeMarkdownTable(rows: rows, columns: columns)
            guard runtime.replaceCurrentEditorSelection(with: table) else {
                throw ActionError.unavailable("The current editor is no longer available for insertion")
            }

            return [
                "inserted": .bool(true),
                "rows": .int(rows),
                "columns": .int(columns),
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "tabID": ActionValue(runtime.selectedTabID)
            ]
        }

        for definition in markdownSelectionActionDefinitions {
            registry.register(definition.descriptor) { _, context in
                guard let runtime = resolvedRuntime(from: context) else {
                    throw ActionError.targetNotFound("Could not resolve a target workspace")
                }
                guard canEditMarkdownSelection(runtime.currentEditorCommandTargetSnapshot()) else {
                    throw ActionError.unavailable("Available only for a selection in the active editable Markdown editor")
                }
                guard runtime.performCurrentEditorBridgeCommand(definition.bridgeCommand) else {
                    throw ActionError.unavailable("Select one or more Markdown lines before running this action")
                }

                return [
                    "performed": .bool(true),
                    "operation": .string(definition.method),
                    "windowID": .string(runtime.windowID),
                    "workspaceID": .string(runtime.workspaceID),
                    "tabID": ActionValue(runtime.selectedTabID)
                ]
            }
        }

        for definition in markdownTableStructuralActionDefinitions {
            registry.register(definition.descriptor) { _, context in
                guard let runtime = resolvedRuntime(from: context) else {
                    throw ActionError.targetNotFound("Could not resolve a target workspace")
                }
                guard MarkdownTableFactory.canEditTable(in: runtime.currentEditorCommandTargetSnapshot()) else {
                    throw ActionError.unavailable("Available only in the active editable Markdown editor")
                }
                guard runtime.performCurrentEditorBridgeCommand(definition.bridgeCommand) else {
                    throw ActionError.unavailable("No active Markdown table cell is available for this table operation")
                }

                return [
                    "performed": .bool(true),
                    "operation": .string(definition.method),
                    "windowID": .string(runtime.windowID),
                    "workspaceID": .string(runtime.workspaceID),
                    "tabID": ActionValue(runtime.selectedTabID)
                ]
            }
        }

        registry.register(createNoteDescriptor) { request, context in
            struct CreateArgs: Decodable {
                let folder: String?
                let fileName: String
                let body: String?
                let open: Bool?
                let openIn: WorkspaceActionOpenDisposition?
            }

            let args = try request.decodeArgs(CreateArgs.self)
            let shouldOpen = args.open ?? true
            let disposition = args.openIn ?? .newTab
            let runtime = resolvedRuntime(from: context)

            if let runtime,
               runtime.projectRootPath == context.resolvedTarget.projectRootPath {
                let result = try runtime.createNote(
                    inFolderRelativePath: args.folder,
                    fileName: args.fileName,
                    body: args.body,
                    open: shouldOpen,
                    disposition: disposition
                )
                return try ActionValue.fromEncodable(result)
            }

            guard let projectRootPath = context.resolvedTarget.projectRootPath else {
                throw ActionError.targetNotFound("Could not resolve a project root for note creation")
            }

            if shouldOpen {
                throw ActionError.unavailable(
                    "Opening a newly created note requires a live workspace runtime for the target project",
                    details: ["projectRootPath": .string(projectRootPath)]
                )
            }

            let notesModel = NotesWorkspaceModel(projectRootPath: projectRootPath)
            let relativePath = try notesModel.createNote(inFolderRelativePath: args.folder, fileName: args.fileName)
            if let body = args.body, !body.isEmpty {
                try notesModel.saveTextNote(relativePath: relativePath, body: body)
            }

            let absolutePath = notesModel.workspaceURL(for: relativePath)?.path ?? URL(fileURLWithPath: projectRootPath).appendingPathComponent(relativePath).path
            let result = WorkspaceActionNoteCreateResult(
                relativePath: relativePath,
                absolutePath: absolutePath,
                projectRootPath: projectRootPath,
                wasOpened: false,
                windowID: nil,
                workspaceID: nil,
                tabID: nil
            )
            return try ActionValue.fromEncodable(result)
        }

        registry.register(createClipboardNoteDescriptor) { request, context in
            struct ClipboardArgs: Decodable {
                let folder: String?
                let openIn: WorkspaceActionOpenDisposition?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionError.unavailable("Clipboard does not contain text")
            }

            let args = (try? request.decodeArgs(ClipboardArgs.self)) ?? ClipboardArgs(folder: nil, openIn: nil)
            let fileName = clipboardFileName(from: text, now: context.now)
            let result = try runtime.createNote(
                inFolderRelativePath: args.folder,
                fileName: fileName,
                body: text,
                open: true,
                disposition: args.openIn ?? .currentTab
            )
            return try ActionValue.fromEncodable(result)
        }

        registry.register(listRecentDocumentsDescriptor) { request, context in
            struct RecentArgs: Decodable {
                let limit: Int?
            }

            let args = (try? request.decodeArgs(RecentArgs.self)) ?? RecentArgs(limit: nil)
            let rootURL = context.resolvedTarget.projectRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let recent = WorkspaceSessionStore.shared.recentDocuments(rootURL: rootURL, limit: args.limit ?? 12)
            return [
                "count": .int(recent.count),
                "items": .array(try recent.map { try ActionValue.fromEncodable($0) })
            ]
        }

        registry.register(openRecentDocumentDescriptor) { request, context in
            struct OpenRecentArgs: Decodable {
                let id: String?
                let relativePath: String?
                let openIn: WorkspaceActionOpenDisposition?
            }

            guard let runtime = resolvedRuntime(from: context) else {
                throw ActionError.targetNotFound("Could not resolve a target workspace")
            }
            let args = try request.decodeArgs(OpenRecentArgs.self)
            let recent = WorkspaceSessionStore.shared.recentDocuments(
                rootURL: URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true),
                limit: 50
            )
            let match = recent.first { item in
                if let id = args.id, item.id == id { return true }
                if let relativePath = args.relativePath,
                   case .workspaceNote(let path) = item.document {
                    return path == relativePath
                }
                return false
            }
            guard let match else {
                throw ActionError.targetNotFound("Recent document not found")
            }
            runtime.openDocument(match.document, disposition: args.openIn ?? .currentTab)
            return try ActionValue.fromEncodable(match)
        }

        registry.register(listThemesDescriptor) { _, _ in
            let directory = UserEditorThemeSelection.themesDirectory()
            let themes = EditorThemeRegistry.availableThemes(in: directory)
            let selectedID = UserEditorThemeSelection.selectedThemeID()?.lowercased()
                ?? EditorThemeRegistry.systemThemeID
            let items = themes.map { theme in
                themeValue(theme, isSelected: theme.id.lowercased() == selectedID)
            }
            let selected = themes.first(where: { $0.id.lowercased() == selectedID })
            return [
                "directory": .string(directory.path),
                "selected": selected.map { .string($0.id) } ?? .null,
                "items": .array(items)
            ]
        }

        registry.register(selectThemeDescriptor) { request, _ in
            struct Args: Decodable {
                let id: String
            }

            let args = try request.decodeArgs(Args.self)
            let requestedID = args.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if requestedID.isEmpty
                || requestedID.lowercased() == "none"
                || requestedID.lowercased() == EditorThemeRegistry.systemThemeID {
                try UserEditorThemeSelection.persist(nil)
                return [
                    "id": .string(EditorThemeRegistry.systemThemeID),
                    "title": .string("System"),
                    "selected": .bool(true)
                ]
            }

            let directory = UserEditorThemeSelection.themesDirectory()
            guard let theme = EditorThemeRegistry.theme(withID: requestedID, in: directory) else {
                throw ActionError.invalidArguments(
                    "Unknown editor theme '\(requestedID)' in \(directory.path)"
                )
            }
            try UserEditorThemeSelection.persist(theme.id)
            return themeValue(theme, isSelected: true)
        }

        registry.register(cycleThemeDescriptor) { request, _ in
            struct Args: Decodable {
                let reverse: Bool?
            }

            let args = (try? request.decodeArgs(Args.self)) ?? Args(reverse: nil)
            let step = (args.reverse == true) ? -1 : 1
            let directory = UserEditorThemeSelection.themesDirectory()
            let themes = EditorThemeRegistry.availableThemes(in: directory)
            guard themes.count > 1 else {
                throw ActionError.unavailable("No editor themes found in \(directory.path)")
            }

            let selectedID = UserEditorThemeSelection.selectedThemeID()?.lowercased()
                ?? EditorThemeRegistry.systemThemeID
            let currentIndex = themes.firstIndex(where: { $0.id.lowercased() == selectedID })
                ?? 0
            let offset = currentIndex + step
            let next = themes[((offset % themes.count) + themes.count) % themes.count]
            try UserEditorThemeSelection.persist(next.id)
            return themeValue(next, isSelected: true)
        }
    }

    private static func themeValue(_ theme: AvailableEditorTheme, isSelected: Bool) -> ActionValue {
        .object([
            "id": .string(theme.id),
            "title": .string(theme.title),
            "swatch": theme.swatchHexes.first.map(ActionValue.string) ?? .null,
            "isBundled": .bool(theme.isBundled),
            "selected": .bool(isSelected)
        ])
    }

    private static func resolvedRuntime(from context: ActionExecutionContext) -> (any WorkspaceActionRuntime)? {
        WorkspaceActionRouter.runtime(for: context.resolvedTarget)
    }

    private static func workspaceMetadata(_ runtime: any WorkspaceActionRuntime) -> ActionValue {
        [
            "windowID": .string(runtime.windowID),
            "workspaceID": .string(runtime.workspaceID),
            "tabID": ActionValue(runtime.selectedTabID)
        ]
    }

    private static func zedExecutableURL() -> URL? {
        var candidatePaths = [
            "/usr/local/bin/zed",
            "/opt/homebrew/bin/zed"
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidatePaths.append(
                contentsOf: path
                    .split(separator: ":")
                    .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("zed").path }
            )
        }

        var seenPaths = Set<String>()
        return candidatePaths.first { path in
            seenPaths.insert(path).inserted
                && FileManager.default.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private static func clipboardFileName(from text: String, now: Date) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = firstLine.isEmpty ? "clipboard" : firstLine
        let sanitized = base
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = sanitized.isEmpty ? "clipboard" : String(sanitized.prefix(48))
        return "\(prefix)-\(formatter.string(from: now)).md"
    }

    private static let newTabDescriptor = ActionDescriptor(
        method: "workspace.tab.new",
        title: "New Workspace Tab",
        summary: "Create and select a new workspace tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "tab"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Selected tab metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "plus.rectangle.on.rectangle",
            title: "New tab",
            rank: 20,
            keywords: ["tab"]
        )
    )

    private static let closeTabDescriptor = ActionDescriptor(
        method: "workspace.tab.close",
        title: "Close Workspace Tab",
        summary: "Close the currently selected workspace tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "tab"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Workspace metadata after closing the tab", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "xmark.rectangle",
            title: "Close tab",
            rank: 22,
            keywords: ["tab"]
        )
    )

    private static let selectNextTabDescriptor = ActionDescriptor(
        method: "workspace.tab.selectNext",
        title: "Select Next Tab",
        summary: "Move selection to the next tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "tab"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Selected tab metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "chevron.right.square",
            title: "Show next tab",
            rank: 210,
            keywords: ["tab", "next"]
        )
    )

    private static let selectPreviousTabDescriptor = ActionDescriptor(
        method: "workspace.tab.selectPrevious",
        title: "Select Previous Tab",
        summary: "Move selection to the previous tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "tab"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Selected tab metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "chevron.left.square",
            title: "Show previous tab",
            rank: 212,
            keywords: ["tab", "previous"]
        )
    )

    /// AppKit's tab overview grid, the same one Safari shows for Show All Tabs.
    /// It toggles, so running it again while the grid is up dismisses it.
    private static let showAllTabsDescriptor = ActionDescriptor(
        method: "workspace.tab.showAll",
        title: "Show All Tabs",
        summary: "Toggle the overview grid of every tab in the window.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "tab", "overview"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Workspace metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "square.grid.2x2",
            title: "Show all tabs",
            rank: 214,
            keywords: ["tab", "overview", "grid", "all"]
        )
    )

    private static let duplicateTabDescriptor = ActionDescriptor(
        method: "workspace.tab.duplicate",
        title: "Duplicate Current Tab",
        summary: "Duplicate the selected tab into the same pane.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "tab", "duplicate"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Workspace metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "plus.square.on.square",
            title: "Duplicate tab",
            rank: 200,
            keywords: ["tab", "copy"]
        )
    )

    private static let splitRightDescriptor = ActionDescriptor(
        method: "workspace.split.right",
        title: "Split Right",
        summary: "Create a right-hand split with a duplicate of the current tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "split", "layout"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Workspace metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "rectangle.split.2x1",
            title: "Split right",
            rank: 10,
            keywords: ["split", "pane"]
        )
    )

    private static let splitDownDescriptor = ActionDescriptor(
        method: "workspace.split.down",
        title: "Split Down",
        summary: "Create a lower split with a duplicate of the current tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "split", "layout"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Workspace metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "rectangle.split.1x2",
            title: "Split down",
            rank: 12,
            keywords: ["split", "pane"]
        )
    )

    private static let refileCurrentNoteDescriptor = ActionDescriptor(
        method: "workspace.note.refile",
        title: "Refile Note",
        summary: "Move a workspace note into another workspace folder.",
        discussion: "With no path argument this moves the note open in the selected tab. The open tab, history, session state, and search model follow the moved note.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "note", "refile", "move"],
        arguments: [
            ActionArgumentDescriptor(
                name: "folder",
                summary: "Destination folder relative path; omit for workspace root",
                kind: .string,
                isRequired: false,
                picker: .workspaceFolder
            ),
            ActionArgumentDescriptor(
                name: "path",
                summary: "Relative note path to move; omit for the current document",
                kind: .string,
                isRequired: false
            )
        ],
        result: ActionResultDescriptor(summary: "Moved note metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "arrow.right.doc.on.clipboard",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Refile to…",
            rank: 10,
            keywords: ["move", "folder"],
            nounArguments: ["note": "path"],
            acceptsBatch: true
        )
    )

    private static let openNoteDescriptor = ActionDescriptor(
        method: "workspace.note.open",
        title: "Open Workspace Note",
        summary: "Open a workspace note in the current tab or a new tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "note"],
        arguments: [
            ActionArgumentDescriptor(name: "relativePath", summary: "Relative note path within the project", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "openIn", summary: "currentTab or newTab", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Current document snapshot", kind: .object)
    )

    /// The palette's "open" verb. `workspace.note.open` defaults to the current
    /// tab and stays that way for scripted callers, so the noun → verb frame
    /// binds this thin wrapper instead of changing that default.
    private static let openNoteInNewTabDescriptor = ActionDescriptor(
        method: "workspace.note.openInNewTab",
        title: "Open Workspace Note in a New Tab",
        summary: "Open a workspace note in a new tab.",
        discussion: "With no path this opens the current document in a new tab.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "note", "open", "tab"],
        arguments: [
            ActionArgumentDescriptor(
                name: "path",
                summary: "Relative note path; omit for the current document",
                kind: .string,
                isRequired: false
            )
        ],
        result: ActionResultDescriptor(summary: "Current document snapshot", kind: .object),
        palette: ActionPalettePresentation(
            category: "Open",
            iconSystemName: "plus.rectangle.on.rectangle",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Open in new tab",
            rank: 10,
            keywords: ["open", "tab"],
            nounArguments: ["note": "path"]
        )
    )

    private static let currentNoteDescriptor = ActionDescriptor(
        method: "workspace.note.current",
        title: "Current Workspace Note",
        summary: "Return a snapshot of the document currently open in the selected workspace tab.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "note", "current"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Current document snapshot", kind: .object)
    )

    private static let getNoteDescriptor = ActionDescriptor(
        method: "workspace.note.get",
        title: "Get Workspace Note",
        summary: "Read a workspace note by relative path without opening a tab.",
        discussion: "Returns UTF-8 body truncated at maxBytes (default 48KiB, cap 256KiB). Does not change the selected tab.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "note", "get", "read"],
        arguments: [
            ActionArgumentDescriptor(name: "relativePath", summary: "Relative note path within the project", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "maxBytes", summary: "Maximum body size in bytes", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Note body and truncation metadata", kind: .object)
    )

    private static let searchQueryDescriptor = ActionDescriptor(
        method: "workspace.search.query",
        title: "Search Workspace Notes",
        summary: "Run a full-text search against the current project's note index.",
        discussion: "Uses the same FTS query language as the omnibox content search, including facet prefixes.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "search", "notes"],
        arguments: [
            ActionArgumentDescriptor(name: "query", summary: "Full-text search query", kind: .string, isRequired: true),
            ActionArgumentDescriptor(name: "limit", summary: "Maximum hits to return (default 20, cap 80)", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Search hits with snippets and index status", kind: .object)
    )

    private static let currentProjectDescriptor = ActionDescriptor(
        method: "workspace.project.current",
        title: "Current Project",
        summary: "Return the active project name and root path.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "project"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Project name and root path", kind: .object)
    )

    private static let listProjectsDescriptor = ActionDescriptor(
        method: "workspace.projects.list",
        title: "List Projects",
        summary: "Return configured projects and the current project when a workspace is available.",
        discussion: "Does not require a live window. Current is included only when a workspace can be resolved.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead, .workspaceRead],
        tags: ["workspace", "project", "list"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Configured projects and optional current project", kind: .object)
    )

    private static let listTabsDescriptor = ActionDescriptor(
        method: "workspace.tabs.list",
        title: "List Workspace Tabs",
        summary: "List open tabs in the target workspace window.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "tabs"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Open tab snapshots", kind: .object)
    )

    private static let editorSelectionGetDescriptor = ActionDescriptor(
        method: "workspace.editor.selection.get",
        title: "Get Editor Selection",
        summary: "Return the current text selection and its line range (page range in a PDF).",
        discussion: "Queries the selected tab's text surface or PDF.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "editor", "selection"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Selection text and line range", kind: .object)
    )

    private static let editorSelectionReplaceDescriptor = ActionDescriptor(
        method: "workspace.editor.selection.replace",
        title: "Replace Editor Selection",
        summary: "Replace the current text selection, or insert at the caret when the selection is empty.",
        discussion: "Targets the selected tab's text surface.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "editor", "selection", "replace"],
        arguments: [
            ActionArgumentDescriptor(name: "text", summary: "Replacement text", kind: .string, isRequired: true)
        ],
        result: ActionResultDescriptor(summary: "Replacement result", kind: .object)
    )

    private static let prefixMarkdownSelectionLinesDescriptor = ActionDescriptor(
        method: "markdown.selection.prefixLines",
        title: "Prefix Selected Markdown Lines",
        summary: "Prefix the first and continuation lines of each Markdown selection.",
        discussion: "Applies all prefixes in one editor transaction so the transformation is atomic and undoable as one edit.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "markdown", "selection", "prefix", "format"],
        arguments: [
            ActionArgumentDescriptor(
                name: "firstPrefix",
                summary: "Prefix for the first line of each selection range",
                kind: .string,
                isRequired: true
            ),
            ActionArgumentDescriptor(
                name: "continuationPrefix",
                summary: "Prefix for following lines; defaults to firstPrefix",
                kind: .string,
                isRequired: false
            )
        ],
        result: ActionResultDescriptor(summary: "Performed selection prefix metadata", kind: .object)
    )

    private static let editorCursorContextGetDescriptor = ActionDescriptor(
        method: "workspace.editor.cursorContext.get",
        title: "Get Cursor Context",
        summary: "Return note text around the current cursor.",
        discussion: "Defaults to 12 lines of neighborhood, truncated at 2000 characters.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "editor", "cursor", "context"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Cursor neighborhood text and coordinates", kind: .object)
    )

    private static let currentContextDescriptor = ActionDescriptor(
        method: "workspace.context.current",
        title: "Current Workspace Context",
        summary: "Return what the user is currently seeing: project, tabs, viewport text, and selection.",
        discussion: "Viewport text comes from the focused Markdown/org editor. Does not fail if no note is open.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "context", "viewport", "tabs"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Visible workspace context snapshot", kind: .object)
    )

    private static let jumpInDocumentDescriptor = ActionDescriptor(
        method: "workspace.document.jump",
        title: "Jump in Current Document",
        summary: "Jump to a Markdown heading or line in the current document.",
        discussion: "Provide heading, line, or both. Heading matches the in-document navigator.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "document", "jump", "heading"],
        arguments: [
            ActionArgumentDescriptor(name: "heading", summary: "Heading text or slug to jump to", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "line", summary: "1-based line number", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Jump result", kind: .object)
    )

    private static let revealCurrentDocumentDescriptor = ActionDescriptor(
        method: "workspace.document.reveal",
        title: "Reveal Current Document",
        summary: "Reveal the current workspace or external document in Finder.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "document", "finder"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Reveal result", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "folder",
            when: "activeDocument",
            title: "Show in Finder",
            rank: 20,
            keywords: ["finder", "reveal"]
        )
    )

    private static let openCurrentDocumentInZedDescriptor = ActionDescriptor(
        method: "workspace.document.openInZed",
        title: "Open in Zed",
        summary: "Open the current workspace or external document in Zed.",
        discussion: "Runs the Zed command-line tool with the document's full path.",
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "document", "zed", "editor"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Zed launch result", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "arrow.up.forward.app",
            when: "activeDocument",
            title: "Open in Zed",
            rank: 220,
            keywords: ["editor", "external"]
        )
    )

    private static let duplicateCurrentNoteDescriptor = ActionDescriptor(
        method: "workspace.note.duplicateCurrent",
        title: "Duplicate Current Note",
        summary: "Duplicate the current workspace note and open the duplicate.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "note", "duplicate"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Created duplicate note metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "doc.on.doc",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Duplicate current note",
            rank: 14,
            keywords: ["copy"]
        )
    )

    private static let reloadCurrentDocumentDescriptor = ActionDescriptor(
        method: "workspace.document.reload",
        title: "Reload Current Document",
        summary: "Reload the current document from disk.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "document", "reload"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Reload result", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "arrow.clockwise",
            when: "activeDocument",
            title: "Reload current document",
            rank: 210,
            keywords: ["refresh", "disk"]
        )
    )

    private static let selectDiffOriginalDescriptor = ActionDescriptor(
        method: "workspace.document.diff.selectOriginal",
        title: "Diff: Select as Original",
        summary: "Remember the current Markdown document as the original side of a comparison.",
        discussion: "The selection belongs to the target workspace window and remains active until another original is selected or the window closes.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead, .noteRead],
        tags: ["workspace", "document", "markdown", "diff", "compare", "original"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Selected original document metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "doc.text",
            when: "activeDocument",
            title: "Diff: Select as Original",
            rank: 230,
            keywords: ["diff", "compare"]
        )
    )

    private static let compareWithSelectedDescriptor = ActionDescriptor(
        method: "workspace.document.diff.compareWithSelected",
        title: "Diff: Compare with Selected",
        summary: "Open a read-only diff between the remembered original and the current Markdown document.",
        discussion: "Run Diff: Select as Original first, navigate to another workspace or external Markdown document, then invoke this action.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "document", "markdown", "diff", "compare", "selected"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Opened diff tab metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "File",
            iconSystemName: "arrow.left.arrow.right",
            when: "activeWorkspace.hasDiffOriginal",
            title: "Diff: Compare with Selected",
            rank: 232,
            keywords: ["diff", "compare"]
        )
    )

    private static let insertMarkdownTableDescriptor = ActionDescriptor(
        method: "markdown.table.insert",
        title: "Add Table",
        summary: "Insert a Markdown table at the current cursor or selection.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "markdown", "table", "insert"],
        arguments: [
            ActionArgumentDescriptor(name: "rows", summary: "Number of body rows", kind: .int, isRequired: false),
            ActionArgumentDescriptor(name: "columns", summary: "Number of columns", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Inserted table metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Format",
            iconSystemName: "tablecells",
            when: editableTextSurfacePaletteCondition,
            title: "Add table",
            rank: 30,
            keywords: ["table", "grid"]
        )
    )

    private static let markdownSelectionActionDefinitions: [MarkdownSelectionActionDefinition] = [
        MarkdownSelectionActionDefinition(
            method: "markdown.selection.quote",
            title: "Quote Selected",
            summary: "Prefix each selected Markdown line with a blockquote marker.",
            bridgeCommand: "quoteMarkdownSelection",
            tags: ["workspace", "markdown", "selection", "quote", "format"],
            paletteTitle: "Quote Selected",
            iconSystemName: "text.quote"
        ),
        MarkdownSelectionActionDefinition(
            method: "markdown.selection.unquote",
            title: "Unquote Selected",
            summary: "Remove one blockquote marker from each selected Markdown line.",
            bridgeCommand: "unquoteMarkdownSelection",
            tags: ["workspace", "markdown", "selection", "unquote", "format"],
            paletteTitle: "Unquote Selected",
            iconSystemName: "text.quote"
        )
    ]

    private static let markdownTableStructuralActionDefinitions: [MarkdownTableStructuralActionDefinition] = [
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.row.insertAbove",
            title: "Insert Table Row Above",
            summary: "Insert a Markdown table row above the focused table row.",
            bridgeCommand: "markdownTableActiveInsertRowAbove",
            tags: ["workspace", "markdown", "table", "row", "insert"],
            paletteTitle: "Insert table row above",
            iconSystemName: "plus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.row.insertBelow",
            title: "Insert Table Row Below",
            summary: "Insert a Markdown table row below the focused table row.",
            bridgeCommand: "markdownTableActiveInsertRowBelow",
            tags: ["workspace", "markdown", "table", "row", "insert"],
            paletteTitle: "Insert table row below",
            iconSystemName: "plus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.row.delete",
            title: "Delete Table Row",
            summary: "Delete the focused Markdown table body row.",
            bridgeCommand: "markdownTableActiveDeleteRow",
            tags: ["workspace", "markdown", "table", "row", "delete"],
            paletteTitle: "Delete table row",
            iconSystemName: "minus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.row.moveUp",
            title: "Move Table Row Up",
            summary: "Move the focused Markdown table body row up.",
            bridgeCommand: "markdownTableActiveMoveRowUp",
            tags: ["workspace", "markdown", "table", "row", "move"],
            paletteTitle: "Move table row up",
            iconSystemName: "arrow.up"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.row.moveDown",
            title: "Move Table Row Down",
            summary: "Move the focused Markdown table body row down.",
            bridgeCommand: "markdownTableActiveMoveRowDown",
            tags: ["workspace", "markdown", "table", "row", "move"],
            paletteTitle: "Move table row down",
            iconSystemName: "arrow.down"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.insertLeft",
            title: "Insert Table Column Left",
            summary: "Insert a Markdown table column to the left of the focused column.",
            bridgeCommand: "markdownTableActiveInsertColumnLeft",
            tags: ["workspace", "markdown", "table", "column", "insert"],
            paletteTitle: "Insert table column left",
            iconSystemName: "plus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.insertRight",
            title: "Insert Table Column Right",
            summary: "Insert a Markdown table column to the right of the focused column.",
            bridgeCommand: "markdownTableActiveInsertColumnRight",
            tags: ["workspace", "markdown", "table", "column", "insert"],
            paletteTitle: "Insert table column right",
            iconSystemName: "plus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.delete",
            title: "Delete Table Column",
            summary: "Delete the focused Markdown table column.",
            bridgeCommand: "markdownTableActiveDeleteColumn",
            tags: ["workspace", "markdown", "table", "column", "delete"],
            paletteTitle: "Delete table column",
            iconSystemName: "minus.rectangle"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.moveLeft",
            title: "Move Table Column Left",
            summary: "Move the focused Markdown table column left.",
            bridgeCommand: "markdownTableActiveMoveColumnLeft",
            tags: ["workspace", "markdown", "table", "column", "move"],
            paletteTitle: "Move table column left",
            iconSystemName: "arrow.left"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.moveRight",
            title: "Move Table Column Right",
            summary: "Move the focused Markdown table column right.",
            bridgeCommand: "markdownTableActiveMoveColumnRight",
            tags: ["workspace", "markdown", "table", "column", "move"],
            paletteTitle: "Move table column right",
            iconSystemName: "arrow.right"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.alignLeft",
            title: "Align Table Column Left",
            summary: "Set the focused Markdown table column alignment to left.",
            bridgeCommand: "markdownTableActiveAlignColumnLeft",
            tags: ["workspace", "markdown", "table", "column", "align"],
            paletteTitle: "Align table column left",
            iconSystemName: "text.alignleft"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.alignCenter",
            title: "Align Table Column Center",
            summary: "Set the focused Markdown table column alignment to center.",
            bridgeCommand: "markdownTableActiveAlignColumnCenter",
            tags: ["workspace", "markdown", "table", "column", "align"],
            paletteTitle: "Align table column center",
            iconSystemName: "text.aligncenter"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.column.alignRight",
            title: "Align Table Column Right",
            summary: "Set the focused Markdown table column alignment to right.",
            bridgeCommand: "markdownTableActiveAlignColumnRight",
            tags: ["workspace", "markdown", "table", "column", "align"],
            paletteTitle: "Align table column right",
            iconSystemName: "text.alignright"
        ),
        MarkdownTableStructuralActionDefinition(
            method: "markdown.table.cell.clear",
            title: "Clear Table Cell",
            summary: "Clear the focused Markdown table cell.",
            bridgeCommand: "markdownTableActiveClearCell",
            tags: ["workspace", "markdown", "table", "cell", "clear"],
            paletteTitle: "Clear table cell",
            iconSystemName: "eraser"
        )
    ]

    private static let createNoteDescriptor = ActionDescriptor(
        method: "workspace.note.create",
        title: "Create Workspace Note",
        summary: "Create a workspace note in the target project, optionally opening it in the UI.",
        discussion: "If no live workspace is available for the target project, creation can still happen headlessly as long as open=false.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .project,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "note", "create"],
        arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Optional parent folder relative path", kind: .string, isRequired: false),
            ActionArgumentDescriptor(
                name: "fileName",
                summary: "File name to create",
                kind: .string,
                isRequired: true,
                picker: .text
            ),
            ActionArgumentDescriptor(name: "body", summary: "Optional initial note body", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "open", summary: "Whether to open the note in the UI", kind: .bool, isRequired: false),
            ActionArgumentDescriptor(name: "openIn", summary: "currentTab or newTab", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Created note metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Create",
            iconSystemName: "doc.badge.plus",
            title: "New note…",
            rank: 10,
            keywords: ["new", "note", "create"],
            nounArguments: ["folder": "folder"],
            boundTitle: "New note here…"
        )
    )

    private static let createClipboardNoteDescriptor = ActionDescriptor(
        method: "workspace.note.createFromClipboard",
        title: "Create Note from Clipboard",
        summary: "Create a Markdown note from the current text clipboard and open it.",
        discussion: "The filename is generated from the first clipboard line plus a timestamp.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "note", "create", "clipboard"],
        arguments: [
            ActionArgumentDescriptor(name: "folder", summary: "Optional parent folder relative path", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "openIn", summary: "currentTab or newTab", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Created note metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Create",
            iconSystemName: "doc.on.clipboard",
            title: "Note from clipboard",
            rank: 22,
            keywords: ["paste", "clipboard"],
            nounArguments: ["folder": "folder"]
        )
    )

    private static let listThemesDescriptor = ActionDescriptor(
        method: "workspace.theme.list",
        title: "List Editor Themes",
        summary: "List user editor themes from the configured themes directory.",
        discussion: nil,
        domain: .app,
        mutationKind: .readOnly,
        targetRequirement: .app,
        capabilities: [.appRead],
        tags: ["workspace", "theme", "appearance"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Theme list with the current selection", kind: .object)
    )

    private static let selectThemeDescriptor = ActionDescriptor(
        method: "workspace.theme.select",
        title: "Select Editor Theme",
        summary: "Select a user editor theme by id and persist it in config.toml.",
        discussion: "Theme ids are CSS filenames in the themes directory without the .css extension. Pass the id \"\" or \"none\" to clear the selection and return to bundled defaults.",
        domain: .app,
        mutationKind: .mutating,
        targetRequirement: .app,
        capabilities: [.appWrite],
        tags: ["workspace", "theme", "appearance"],
        arguments: [
            ActionArgumentDescriptor(
                name: "id",
                summary: "Theme id (CSS filename without extension)",
                kind: .string,
                isRequired: true,
                picker: .editorTheme
            )
        ],
        result: ActionResultDescriptor(summary: "The selected theme", kind: .object),
        palette: ActionPalettePresentation(
            category: "Appearance",
            iconSystemName: "paintpalette",
            title: "Default editor theme…",
            rank: 10,
            keywords: ["theme", "css", "appearance"]
        )
    )

    private static let cycleThemeDescriptor = ActionDescriptor(
        method: "workspace.theme.cycle",
        title: "Cycle Editor Theme",
        summary: "Switch to the next (or previous) user editor theme.",
        discussion: "Themes are ordered by display title. With no theme selected this starts from the first theme.",
        domain: .app,
        mutationKind: .mutating,
        targetRequirement: .app,
        capabilities: [.appWrite],
        tags: ["workspace", "theme", "appearance"],
        arguments: [
            ActionArgumentDescriptor(name: "reverse", summary: "Cycle backwards when true", kind: .bool, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "The newly selected theme", kind: .object),
        palette: ActionPalettePresentation(
            category: "Appearance",
            iconSystemName: "arrow.triangle.2.circlepath",
            title: "Cycle editor theme",
            rank: 200,
            keywords: ["theme", "next"]
        )
    )

    private static let listRecentDocumentsDescriptor = ActionDescriptor(
        method: "workspace.recent.list",
        title: "List Recent Files",
        summary: "List recently opened workspace and external files.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .project,
        capabilities: [.workspaceRead],
        tags: ["workspace", "recent", "file"],
        arguments: [
            ActionArgumentDescriptor(name: "limit", summary: "Maximum number of recent entries", kind: .int, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Recent file list", kind: .object)
    )

    private static let openRecentDocumentDescriptor = ActionDescriptor(
        method: "workspace.recent.open",
        title: "Open Recent File",
        summary: "Open a recent file by id or workspace-relative path.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "recent", "file", "open"],
        arguments: [
            ActionArgumentDescriptor(name: "id", summary: "Recent item id", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "relativePath", summary: "Workspace-relative path", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "openIn", summary: "currentTab or newTab", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Opened recent item", kind: .object)
    )

    private static func diffSource(for snapshot: WorkspaceActionDocumentSnapshot) -> WorkspaceDiffSource? {
        switch snapshot.kind {
        case .workspaceNote:
            guard let relativePath = snapshot.relativePath, !relativePath.isEmpty else { return nil }
            return .workspace(relativePath: relativePath)
        case .externalMarkdown:
            guard let absolutePath = snapshot.absolutePath, !absolutePath.isEmpty else { return nil }
            return .external(filePath: absolutePath)
        case .clipboardMarkdown, .diff:
            return nil
        }
    }

    private static func canEditMarkdownSelection(
        _ commandTarget: WorkspaceEditorCommandTargetSnapshot?
    ) -> Bool {
        guard let commandTarget else { return false }
        let path = commandTarget.path ?? ""
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return commandTarget.surfaceKind == .text &&
            commandTarget.isEditable &&
            commandTarget.supportsSelectionReplacement &&
            ["md", "markdown", "mdown", "mkd"].contains(ext)
    }
}

/// Editor commands (Markdown formatting, table operations, in-document find)
/// all need the same availability rule: an active, editable text surface. The
/// palette hides them everywhere else.
let editableTextSurfacePaletteCondition = "activeEditor.surface == \"text\" && activeEditor.isEditable"

private struct MarkdownSelectionActionDefinition {
    let method: String
    let title: String
    let summary: String
    let bridgeCommand: String
    let tags: [String]
    let paletteTitle: String
    let iconSystemName: String

    var descriptor: ActionDescriptor {
        ActionDescriptor(
            method: method,
            title: title,
            summary: summary,
            discussion: "Operates on the selected lines in the active editable Markdown editor.",
            domain: .workspace,
            mutationKind: .mutating,
            targetRequirement: .workspace,
            capabilities: [.workspaceWrite, .noteWrite],
            tags: tags,
            arguments: [],
            result: ActionResultDescriptor(summary: "Performed selection formatting metadata", kind: .object),
            palette: ActionPalettePresentation(
                category: "Format",
                iconSystemName: iconSystemName,
                when: editableTextSurfacePaletteCondition,
                title: paletteTitle,
                rank: 10,
                keywords: ["markdown", "selection"]
            )
        )
    }
}

private struct MarkdownTableStructuralActionDefinition {
    let method: String
    let title: String
    let summary: String
    let bridgeCommand: String
    let tags: [String]
    let paletteTitle: String
    let iconSystemName: String

    var descriptor: ActionDescriptor {
        ActionDescriptor(
            method: method,
            title: title,
            summary: summary,
            discussion: "Operates on the currently focused Markdown table cell in the active editor.",
            domain: .workspace,
            mutationKind: .mutating,
            targetRequirement: .workspace,
            capabilities: [.workspaceWrite, .noteWrite],
            tags: tags,
            arguments: [],
            result: ActionResultDescriptor(summary: "Performed table operation metadata", kind: .object),
            palette: ActionPalettePresentation(
                category: "Format",
                iconSystemName: iconSystemName,
                when: editableTextSurfacePaletteCondition,
                title: paletteTitle,
                // Sixteen row/column/cell operations: searchable, never the menu.
                rank: ActionPalettePresentation.longTailRank,
                keywords: ["markdown", "table"]
            )
        )
    }
}

enum MarkdownTableFactory {
    static func normalizedCount(_ value: Int?) -> Int {
        max(1, value ?? 2)
    }

    static func canInsertTable(in commandTarget: WorkspaceEditorCommandTargetSnapshot?) -> Bool {
        guard let commandTarget else { return false }
        return commandTarget.surfaceKind == .text &&
            commandTarget.isEditable &&
            commandTarget.supportsSelectionReplacement &&
            isMarkdownPath(commandTarget.path)
    }

    static func canEditTable(in commandTarget: WorkspaceEditorCommandTargetSnapshot?) -> Bool {
        guard let commandTarget else { return false }
        return commandTarget.surfaceKind == .text &&
            commandTarget.isEditable &&
            commandTarget.supportsSelectionReplacement &&
            isMarkdownPath(commandTarget.path)
    }

    static func makeMarkdownTable(rows: Int = 2, columns: Int = 2) -> String {
        let normalizedRows = normalizedCount(rows)
        let normalizedColumns = normalizedCount(columns)

        let header = (1...normalizedColumns).map { "Header \($0)" }.joined(separator: " | ")
        let separator = Array(repeating: "---", count: normalizedColumns).joined(separator: " | ")
        let bodyRows = (1...normalizedRows).map { _ in
            let cells = Array(repeating: "", count: normalizedColumns).joined(separator: " | ")
            return "| \(cells) |"
        }

        return ([
            "| \(header) |",
            "| \(separator) |"
        ] + bodyRows).joined(separator: "\n")
    }

    private static func isMarkdownPath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }
}
