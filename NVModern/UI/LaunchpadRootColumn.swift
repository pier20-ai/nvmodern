import Foundation

/// What the launchpad's first column selects between.
enum LaunchpadRootSource: Hashable {
    case workspace
    case recent
}

/// The synthetic first column of the launchpad browser.
///
/// Its rows are real `MillerItem`s carrying reserved paths, so the browser
/// treats column 0 exactly like any other column — arrow keys and Tab flow
/// through it, and the selected row highlights the same way. The reserved path
/// also becomes element 0 of `WorkspaceTabState.selectedFolderChain`, which
/// keeps the browser's existing invariant intact: chain index `i` still
/// produces column `i + 1`. That is what lets a whole extra column exist
/// without shifting any depth arithmetic.
///
/// The prefix uses U+0001, which cannot occur in an APFS path component, so a
/// synthetic path can never collide with a real relative path.
enum LaunchpadRootColumn {
    static let pathPrefix = "\u{1}launchpad/"
    static let workspacePath = pathPrefix + "workspace"
    static let recentPath = pathPrefix + "recent"

    static func isSynthetic(_ path: String) -> Bool {
        path.hasPrefix(pathPrefix)
    }

    static func source(for path: String?) -> LaunchpadRootSource {
        guard let path, isSynthetic(path) else { return .workspace }
        // Anything else, including a capture row persisted by an older
        // session, reads as Workspace.
        return path == recentPath ? .recent : .workspace
    }

    /// The synthetic path for a source, i.e. what chain element 0 should be.
    static func path(for source: LaunchpadRootSource) -> String {
        switch source {
        case .workspace: return workspacePath
        case .recent: return recentPath
        }
    }

    /// The real workspace folder whose children fill column 1. `""` is the
    /// workspace root; `nil` means the source has no backing folder (Recent).
    static func rootFolderPath(for source: LaunchpadRootSource) -> String? {
        switch source {
        case .workspace: return ""
        case .recent: return nil
        }
    }

    static func title(for source: LaunchpadRootSource) -> String {
        switch source {
        case .workspace: return "Workspace"
        case .recent: return "Recent"
        }
    }

    /// Column 0: Workspace and Recent.
    static func items() -> [MillerItem] {
        [
            MillerItem(relativePath: workspacePath, name: "Workspace", kind: .folder, modifiedDate: nil),
            MillerItem(relativePath: recentPath, name: "Recent", kind: .folder, modifiedDate: nil),
        ]
    }

    /// Guarantees element 0 is a synthetic root path.
    ///
    /// Sessions persisted before the root column existed hold plain folder
    /// chains; those decode as Workspace, which is what they meant.
    static func normalized(_ chain: [String]) -> [String] {
        guard let first = chain.first else { return [workspacePath] }
        return isSynthetic(first) ? chain : [workspacePath] + chain
    }
}
