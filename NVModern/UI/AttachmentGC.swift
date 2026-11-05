import Foundation

// MARK: - Attachment GC

/// Garbage-collects orphaned images in `<root>/.attachments/`.
enum AttachmentGC {
    private static let interval: UInt64 = 30 * 60 * 1_000_000_000 // 30 min
    private static let gracePeriod: TimeInterval = 30 * 60 // 30 min

    /// Run an initial GC pass, then repeat every 30 minutes until cancelled.
    static func runLoop(rootURL: URL) async {
        let initialPassStartedAt = ProcessInfo.processInfo.systemUptime
        PerformanceDiagnostics.background(
            kind: "attachment-gc",
            event: "initialPass.begin",
            metadata: ["root": rootURL.path]
        )
        collect(rootURL: rootURL)
        PerformanceDiagnostics.background(
            kind: "attachment-gc",
            event: "initialPass.end",
            startedAt: initialPassStartedAt,
            metadata: ["root": rootURL.path]
        )
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { break }
            collect(rootURL: rootURL)
        }
    }

    private static func collect(rootURL: URL) {
        let fm = FileManager.default
        let attachmentsDir = rootURL.appendingPathComponent(".attachments", isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: attachmentsDir.path, isDirectory: &isDir), isDir.boolValue else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: attachmentsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ), !files.isEmpty else { return }

        let referenced = referencedFilenames(rootURL: rootURL)
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        var deleted = 0

        for fileURL in files {
            let name = fileURL.lastPathComponent
            if referenced.contains(name) { continue }

            guard let attrs = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                  let created = attrs.creationDate,
                  created < cutoff else { continue }

            do {
                try fm.removeItem(at: fileURL)
                deleted += 1
            } catch {
                print("[NVModern][AttachmentGC] Failed to delete \(name): \(error)")
            }
        }

        if deleted > 0 {
            print("[NVModern][AttachmentGC] Deleted \(deleted) orphaned attachment(s)")
        }
    }

    private static func referencedFilenames(rootURL: URL) -> Set<String> {
        var result = Set<String>()
        let fm = FileManager.default
        let exts: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text", "org", "outline"]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        let pattern = try? NSRegularExpression(pattern: #"\.attachments/([^\s)\]"']+)"#)

        while let url = enumerator.nextObject() as? URL {
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let pattern else { continue }

            let range = NSRange(content.startIndex..., in: content)
            for match in pattern.matches(in: content, range: range) {
                if let r = Range(match.range(at: 1), in: content) {
                    result.insert(String(content[r]))
                }
            }
        }

        return result
    }
}
