import Foundation

@MainActor
protocol ActionTargetResolving {
    func resolveTarget(for request: ActionRequest, descriptor: ActionDescriptor) throws -> ActionResolvedTarget
}

@MainActor
struct DefaultActionTargetResolver: ActionTargetResolving {
    func resolveTarget(for request: ActionRequest, descriptor: ActionDescriptor) throws -> ActionResolvedTarget {
        let runtime = WorkspaceActionRouter.resolveRuntime(target: request.target)
        let projectRootPath = resolveProjectRootPath(target: request.target, runtime: runtime)

        switch descriptor.targetRequirement {
        case .none:
            return .unresolved

        case .app:
            return ActionResolvedTarget(appID: "nvmodern")

        case .window:
            guard let runtime else {
                throw ActionError.targetNotFound("Could not resolve a target window for action \(request.method)")
            }
            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime.windowID,
                workspaceID: runtime.workspaceID,
                projectRootPath: runtime.projectRootPath
            )

        case .workspace:
            guard let runtime else {
                throw ActionError.targetNotFound("Could not resolve a target workspace for action \(request.method)")
            }
            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime.windowID,
                workspaceID: runtime.workspaceID,
                projectRootPath: runtime.projectRootPath
            )

        case .tab:
            guard let runtime else {
                throw ActionError.targetNotFound("Could not resolve a target workspace tab for action \(request.method)")
            }

            let tabID = try resolveTabID(from: request.target.tab, runtime: runtime)
            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime.windowID,
                workspaceID: runtime.workspaceID,
                tabID: tabID,
                projectRootPath: runtime.projectRootPath
            )

        case .project:
            guard let projectRootPath else {
                throw ActionError.targetNotFound("Could not resolve a target project for action \(request.method)")
            }
            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime?.windowID,
                workspaceID: runtime?.workspaceID,
                projectRootPath: projectRootPath
            )

        case .document:
            guard let runtime else {
                throw ActionError.targetNotFound("Could not resolve a target workspace document for action \(request.method)")
            }

            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime.windowID,
                workspaceID: runtime.workspaceID,
                tabID: try resolveTabID(from: request.target.tab, runtime: runtime),
                projectRootPath: runtime.projectRootPath,
                documentPath: resolveDocumentPath(from: request.target.document, runtime: runtime)
            )

        case .content:
            guard let runtime else {
                throw ActionError.targetNotFound("Could not resolve a target content surface for action \(request.method)")
            }

            return ActionResolvedTarget(
                appID: "nvmodern",
                windowID: runtime.windowID,
                workspaceID: runtime.workspaceID,
                tabID: try resolveTabID(from: request.target.tab, runtime: runtime),
                projectRootPath: runtime.projectRootPath,
                documentPath: resolveDocumentPath(from: request.target.document, runtime: runtime),
                contentAddress: resolveContentAddress(from: request.target.content, runtime: runtime)
            )
        }
    }

    private func resolveProjectRootPath(target: ActionTarget, runtime: (any WorkspaceActionRuntime)?) -> String? {
        if let projectSelector = target.project {
            switch projectSelector {
            case .active:
                return runtime?.projectRootPath ?? NVModernConfigLoader.load().rootURL.path
            case .rootPath(let path):
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            case .named(let name):
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return nil }
                return NVModernConfigLoader.loadAppConfig().projects.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
                })?.id
            }
        }

        return runtime?.projectRootPath ?? NVModernConfigLoader.load().rootURL.path
    }

    private func resolveTabID(from selector: ActionTarget.TabSelector?, runtime: any WorkspaceActionRuntime) throws -> String? {
        guard let selector else {
            return runtime.selectedTabID
        }

        switch selector {
        case .selected:
            return runtime.selectedTabID
        case .identifier(let identifier):
            guard runtime.containsTab(publicID: identifier) else {
                throw ActionError.targetNotFound(
                    "Could not find tab \(identifier) in workspace",
                    details: ["tabID": .string(identifier)]
                )
            }
            return identifier
        }
    }

    private func resolveDocumentPath(from selector: ActionTarget.DocumentSelector?, runtime: any WorkspaceActionRuntime) -> String? {
        guard let selector else {
            return runtime.currentDocumentSnapshot()?.relativePath ?? runtime.currentDocumentSnapshot()?.absolutePath
        }

        switch selector {
        case .current:
            return runtime.currentDocumentSnapshot()?.relativePath ?? runtime.currentDocumentSnapshot()?.absolutePath
        case .relativePath(let path):
            return path
        case .absolutePath(let path):
            return path
        }
    }

    private func resolveContentAddress(from selector: ActionTarget.ContentSelector?, runtime: any WorkspaceActionRuntime) -> ActionContentAddress? {
        guard let selector else { return nil }

        switch selector {
        case .currentDocument:
            guard let documentPath = runtime.currentDocumentSnapshot()?.relativePath else {
                return nil
            }
            return ActionContentAddress(documentPath: documentPath, nodeKind: .document)
        case .address(let address):
            return address
        case .selector:
            return nil
        }
    }
}
