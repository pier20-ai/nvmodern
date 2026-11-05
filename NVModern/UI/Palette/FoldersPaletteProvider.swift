import Foundation

/// Workspace folders. They serve two slots: the object of a `workspaceFolder`
/// picker (a refile destination), and the noun the `#` prefix denotes in root,
/// whose default verb is Browse.
@MainActor
final class FoldersPaletteProvider: PaletteSourceProvider {
    func sections(
        for source: PaletteSourceKind,
        query: PaletteQueryScope,
        frame: PaletteFrameSpec,
        context: PaletteContext
    ) async -> [PaletteSection] {
        guard case .folders = source else { return [] }

        // The note being refiled: an explicitly bound noun, else the document
        // in the tab. A batch subject binds no single path and needs none.
        let boundPath: String? = {
            guard case .string(let path)? = frame.pendingCommand?.args["path"] else { return nil }
            return path
        }()
        let hasBatchSubject: Bool = {
            if case .batch? = frame.subjectTarget { return true }
            return false
        }()

        // Refiling needs a workspace note to move; without one there is nothing
        // a destination could mean. The frame's empty state says so.
        if let pending = frame.pendingCommand,
           pending.method == "workspace.note.refile",
           boundPath == nil,
           !hasBatchSubject,
           context.currentDocumentRelativePath == nil {
            return []
        }

        // Only a destination picker excludes the folder the note already sits
        // in; browsing lists every folder, including the current one. A batch
        // spans several folders, so nothing is excluded.
        let excludedFolder: String? = {
            guard frame.pendingCommand != nil, !hasBatchSubject else { return nil }
            return (boundPath ?? context.currentDocumentRelativePath)
                .map { ($0 as NSString).deletingLastPathComponent }
        }()

        var folders = Set(context.notesModel.childrenByFolder.keys)
        for children in context.notesModel.childrenByFolder.values {
            for item in children where item.kind == .folder {
                folders.insert(item.relativePath)
            }
        }
        folders.insert("")

        let orderedFolders: [String]
        let browsableFolders = folders
            .filter { $0 != excludedFolder }
        if query.text.isEmpty {
            orderedFolders = browsableFolders.sorted {
                if $0.isEmpty { return true }
                if $1.isEmpty { return false }
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        } else {
            let candidates = browsableFolders.map { folder in
                let title = folder.isEmpty ? "Workspace Root" : (folder as NSString).lastPathComponent
                return PaletteSearchRanker.Candidate(
                    id: folder,
                    label: title,
                    items: folder.isEmpty ? [title] : PaletteSearchRanker.pathItems(folder)
                )
            }
            orderedFolders = PaletteSearchRanker.rank(query: query.text, candidates: candidates)
                .map(\.candidate.id)
        }

        let items = orderedFolders.map { folder in
            let title = folder.isEmpty ? "Workspace Root" : (folder as NSString).lastPathComponent
            let parent = folder.isEmpty ? "Workspace" : (folder as NSString).deletingLastPathComponent
                return PaletteItem(
                    id: "folder:\(folder)",
                    title: title,
                    subtitle: parent.isEmpty ? "Workspace" : parent,
                    iconSystemName: folder.isEmpty ? "externaldrive" : "folder",
                    // The refile handler normalises an empty path to the
                    // workspace root, so "" is a real destination here.
                    activation: frame.pendingCommand.map { $0.filled(with: .string(folder)) }
                        ?? .openFolder(relativePath: folder),
                    target: .folder(relativePath: folder)
                )
        }

        return [PaletteSection(id: "folders", title: "Folders", items: items)]
    }
}
