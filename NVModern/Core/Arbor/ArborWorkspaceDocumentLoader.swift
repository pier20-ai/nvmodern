import Foundation

enum ArborWorkspaceDocumentLoader {
    static func load(from rootURL: URL, fileManager: FileManager = .default) -> [ArborKernelDocument] {
        let root = rootURL.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let urls = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "outline",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url.standardizedFileURL
        }.sorted { $0.path < $1.path }

        return urls.compactMap { url in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let relativePath = String(url.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { return nil }
            return ArborKernelDocument(
                id: relativePath,
                path: relativePath,
                revision: 0,
                source: source
            )
        }
    }
}
