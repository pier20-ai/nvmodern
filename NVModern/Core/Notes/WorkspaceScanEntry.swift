import Foundation

enum WorkspaceScanEntry {
    /// Classify symlinks by their targets while keeping callers' workspace-relative paths.
    /// The root must be canonical; links outside it remain outside the workspace.
    static func resourceValues(
        at url: URL,
        within rootURL: URL,
        forKeys keys: Set<URLResourceKey>
    ) -> URLResourceValues? {
        let entryKeys = keys.union([.isSymbolicLinkKey, .isHiddenKey])
        guard let values = try? url.resourceValues(forKeys: entryKeys),
              values.isHidden != true else { return nil }
        guard values.isSymbolicLink == true else { return values }

        let target = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.path == rootPath || target.path.hasPrefix(prefix) else { return nil }
        return try? target.resourceValues(forKeys: keys)
    }
}
