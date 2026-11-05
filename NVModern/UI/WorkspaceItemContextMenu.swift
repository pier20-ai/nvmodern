import SwiftUI

struct WorkspaceFolderActionTarget: Equatable {
    let relativePath: String?
    let displayName: String
}

struct WorkspaceFolderActionMenu: View {
    let target: WorkspaceFolderActionTarget
    let onCreateNote: () -> Void
    let onCreateFolder: () -> Void
    let onCreateNoteFromClipboard: () -> Void
    let onSearchInFolder: () -> Void
    let onOpenFolderInFinder: () -> Void
    let onCopyRelativePath: () -> Void
    let onCopyAbsolutePath: () -> Void
    let onEditFinderTags: () -> Void
    let onRenameFolder: (() -> Void)?
    let onMoveFolderToTrash: (() -> Void)?

    var body: some View {
        Group {
            Button("New File…") {
                onCreateNote()
            }

            Button("New Folder") {
                onCreateFolder()
            }

            Button("Note from Clipboard") {
                onCreateNoteFromClipboard()
            }

            Divider()

            Button("Search Here") {
                onSearchInFolder()
            }

            Button("Show in Finder") {
                onOpenFolderInFinder()
            }

            Divider()

            Button("Copy Relative Path") {
                onCopyRelativePath()
            }

            Button("Copy Path") {
                onCopyAbsolutePath()
            }

            Divider()

            Button("Tags…") {
                onEditFinderTags()
            }

            if onRenameFolder != nil || onMoveFolderToTrash != nil {
                Divider()
            }

            if let onRenameFolder {
                Button("Rename") {
                    onRenameFolder()
                }
            }

            if let onMoveFolderToTrash {
                Button("Move to Trash") {
                    onMoveFolderToTrash()
                }
            }
        }
    }
}

struct WorkspaceItemContextMenu: View {
    let kind: MillerItemKind
    let relativePath: String
    let displayName: String
    let onOpen: () -> Void
    let onOpenInNewTab: (() -> Void)?
    let onShowInFinder: () -> Void
    let onOpenFolderInFinder: (() -> Void)?
    let onCopyPath: () -> Void
    let onCopyAbsolutePath: () -> Void
    let onRename: () -> Void
    let onDuplicate: (() -> Void)?
    let onTrash: () -> Void
    let onCreateNoteInFolder: (() -> Void)?
    let onCreateFolderInFolder: (() -> Void)?
    let onCreateNoteFromClipboardInFolder: (() -> Void)?
    let onSearchInFolder: (() -> Void)?
    let onEditFinderTags: (() -> Void)?

    var body: some View {
        Group {
            Button("Open") {
                onOpen()
            }

            if let onOpenInNewTab, kind == .note {
                Button("Open in New Tab") {
                    onOpenInNewTab()
                }
            }

            if kind == .folder,
               let onCreateNoteInFolder,
               let onCreateFolderInFolder,
               let onCreateNoteFromClipboardInFolder,
               let onSearchInFolder,
               let onOpenFolderInFinder,
               let onEditFinderTags {
                Divider()
                WorkspaceFolderActionMenu(
                    target: WorkspaceFolderActionTarget(
                        relativePath: relativePath,
                        displayName: displayName
                    ),
                    onCreateNote: onCreateNoteInFolder,
                    onCreateFolder: onCreateFolderInFolder,
                    onCreateNoteFromClipboard: onCreateNoteFromClipboardInFolder,
                    onSearchInFolder: onSearchInFolder,
                    onOpenFolderInFinder: onOpenFolderInFinder,
                    onCopyRelativePath: onCopyPath,
                    onCopyAbsolutePath: onCopyAbsolutePath,
                    onEditFinderTags: onEditFinderTags,
                    onRenameFolder: onRename,
                    onMoveFolderToTrash: onTrash
                )
            } else {
                Divider()

                Button("Show in Finder") {
                    onShowInFinder()
                }

                Divider()

                Button("Copy Relative Path") {
                    onCopyPath()
                }

                Button("Copy Path") {
                    onCopyAbsolutePath()
                }

                Divider()

                if let onEditFinderTags {
                    Button("Tags…") {
                        onEditFinderTags()
                    }

                    Divider()
                }

                Button("Rename") {
                    onRename()
                }

                if let onDuplicate, kind == .note {
                    Button("Duplicate") {
                        onDuplicate()
                    }
                }

                Button("Move to Trash") {
                    onTrash()
                }
            }
        }
    }
}
