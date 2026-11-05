import AppKit
import Foundation
import UserNotifications

@MainActor
enum URLSchemeRouter {
    static func open(_ url: URL) {
        open(NVModernURLScheme.rawString(from: url))
    }

    static func open(_ raw: String) {
        switch NVModernURLScheme.parse(raw) {
        case .success(let link):
            open(link)
        case .failure(let error):
            reject(raw, reason: rejectionMessage(error))
        }
    }

    private static func open(_ link: NVModernURLScheme.Link) {
        switch link {
        case .file(let path, let line, let heading):
            openFile(path: path, jump: PendingMarkdownJump(heading: heading, line: line))
        }
    }

    private static func openFile(path: String, jump: PendingMarkdownJump) {
        guard let standardized = resolveFilePath(path: path) else {
            reject(path, reason: "That file doesn’t exist in any workspace.")
            return
        }

        if let runtime = runtimeOwning(path: standardized) {
            let document = document(for: standardized, projectRoot: runtime.projectRootPath)
            if runtime.focusDocument(document) || performOpen(document, in: runtime) {
                runtime.jumpInCurrentDocument(heading: jump.heading, line: jump.line)
                return
            }
        }

        if let project = configuredProject(containing: standardized) {
            let document = document(for: standardized, projectRoot: project.id)
            if let runtime = WorkspaceActionRouter.runtime(forProjectRootPath: project.id) {
                _ = performOpen(document, in: runtime)
                runtime.jumpInCurrentDocument(heading: jump.heading, line: jump.line)
                return
            }
            enqueue(
                projectRootPath: project.id,
                documents: [document],
                pendingJump: jump
            )
            return
        }

        let document = WorkspaceOpenedDocument.externalMarkdown(filePath: standardized)
        if WorkspaceActionRouter.performExternalFileOpen(document) {
            WorkspaceActionRouter.runtime(for: nil)?.jumpInCurrentDocument(
                heading: jump.heading,
                line: jump.line
            )
            return
        }
        enqueue(projectRootPath: nil, documents: [document], pendingJump: jump)
    }

    @discardableResult
    private static func performOpen(
        _ document: WorkspaceOpenedDocument,
        in runtime: any WorkspaceActionRuntime
    ) -> Bool {
        if runtime.focusDocument(document) {
            return true
        }
        runtime.openDocument(document, disposition: .newTab)
        return true
    }

    /// Resolves a file link's path to an absolute path. `path` is usually
    /// workspace-relative and is tried against every known workspace root —
    /// open windows front to back, then configured projects — so links keep
    /// working across machines whose roots differ (shared iCloud Drive).
    /// A leading slash is also honored as a legacy absolute path, which is
    /// how Foundation URLs hand back relative links (`URL` prepends the
    /// slash), so both readings are covered.
    private static func resolveFilePath(path: String) -> String? {
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }

        var roots: [String?] = []
        roots.append(contentsOf: WorkspaceActionRouter.runtimesFrontToBack().map(\.projectRootPath))
        roots.append(contentsOf: NVModernConfigLoader.loadAppConfig().projects.map(\.rootURL.path))
        // Legacy absolute form, tried after the workspace-relative readings.
        if path.hasPrefix("/") {
            roots.append(nil)
        }

        var seen = Set<String>()
        for root in roots {
            let candidate: String
            if let root {
                candidate = NVModernURLScheme.normalizePath(root + "/" + relative)
            } else {
                candidate = NVModernURLScheme.normalizePath(path)
            }
            guard seen.insert(candidate).inserted else { continue }
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func document(for path: String, projectRoot: String) -> WorkspaceOpenedDocument {
        if let relative = NVModernURLScheme.relativePath(of: path, under: projectRoot), !relative.isEmpty {
            return .workspaceNote(relativePath: relative)
        }
        return .externalMarkdown(filePath: path)
    }

    private static func runtimeOwning(path: String) -> (any WorkspaceActionRuntime)? {
        WorkspaceActionRouter.runtimesFrontToBack().first { runtime in
            NVModernURLScheme.isAncestor(runtime.projectRootPath, of: path)
        }
    }

    private static func configuredProject(containing path: String) -> NVModernProject? {
        let appConfig = NVModernConfigLoader.loadAppConfig()
        let normalized = NVModernURLScheme.normalizePath(path)
        return appConfig.projects.first { NVModernURLScheme.isAncestor($0.id, of: normalized) }
    }

    private static func enqueue(
        projectRootPath: String?,
        documents: [WorkspaceOpenedDocument] = [],
        pendingJump: PendingMarkdownJump? = nil
    ) {
        WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(
            projectRootPath: projectRootPath,
            documents: documents,
            pendingJump: pendingJump
        )
        WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
    }

    private static func reject(_ raw: String, reason: String) {
        LocalDiagnosticsCenter.shared.log(
            level: .info,
            category: "workspace.urlScheme",
            event: "rejected",
            metadata: [
                "url": raw,
                "reason": reason
            ]
        )
        deliverQuietNotification(reason)
    }

    private static func rejectionMessage(_ error: NVModernURLScheme.ParseError) -> String {
        switch error {
        case .invalidScheme:
            return "That link isn’t a nvModern URL."
        case .unknownRoute:
            return "nvModern doesn’t recognize that link."
        case .relativeFilePath:
            return "That file link is empty."
        }
    }

    private static func deliverQuietNotification(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn’t open link"
        content.body = body
        let request = UNNotificationRequest(
            identifier: "nvmodern.url.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
