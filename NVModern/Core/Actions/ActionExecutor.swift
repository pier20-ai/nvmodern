import Foundation

struct ActionExecutionContext {
    let source: ActionSource
    let target: ActionTarget
    let resolvedTarget: ActionResolvedTarget
    let registry: ActionRegistry
    let contentSurface: (any ActionContentSurface)?
    let now: Date
}

@MainActor
final class ActionExecutor {
    static let shared = ActionExecutor()

    let registry: ActionRegistry
    var contentSurface: (any ActionContentSurface)?
    var targetResolver: any ActionTargetResolving

    init(
        registry: ActionRegistry? = nil,
        contentSurface: (any ActionContentSurface)? = nil,
        targetResolver: (any ActionTargetResolving)? = nil
    ) {
        self.registry = registry ?? ActionRegistry.shared
        self.contentSurface = contentSurface
        self.targetResolver = targetResolver ?? DefaultActionTargetResolver()
        self.registry.ensureBuiltinsRegistered()
    }

    func invoke(_ request: ActionRequest) async throws -> ActionValue {
        guard let descriptor = registry.descriptor(for: request.method),
              let handler = registry.handler(for: request.method) else {
            throw ActionError.unknownMethod(request.method)
        }

        let tracksEditor = request.method.hasPrefix("workspace.editor.selection.") ||
            request.method.hasPrefix("markdown.selection.")
        let diagnosticID = request.id ?? UUID().uuidString
        if tracksEditor {
            logEditorInvocation(request, id: diagnosticID, event: "editor.begin")
        }
        let resolvedTarget: ActionResolvedTarget
        do {
            resolvedTarget = try resolveTarget(for: request, descriptor: descriptor)
        } catch {
            if tracksEditor {
                logEditorInvocation(request, id: diagnosticID, event: "editor.failed", error: error)
            }
            throw error
        }
        let context = ActionExecutionContext(
            source: request.source,
            target: request.target,
            resolvedTarget: resolvedTarget,
            registry: registry,
            contentSurface: contentSurface,
            now: Date()
        )

        do {
            let result = try await handler(request, context)
            if tracksEditor {
                logEditorInvocation(request, id: diagnosticID, event: "editor.completed")
            }
            return result
        } catch let error as ActionError {
            if tracksEditor {
                logEditorInvocation(request, id: diagnosticID, event: "editor.failed", error: error)
            }
            throw error
        } catch {
            if tracksEditor {
                logEditorInvocation(request, id: diagnosticID, event: "editor.failed", error: error)
            }
            throw ActionError.executionFailed(
                error.localizedDescription,
                details: ["method": .string(request.method)]
            )
        }
    }

    func execute(_ request: ActionRequest) async -> ActionResponse {
        do {
            let result = try await invoke(request)
            return .success(id: request.id, result: result)
        } catch let error as ActionError {
            return .failure(id: request.id, error: error)
        } catch {
            return .failure(
                id: request.id,
                error: .executionFailed(error.localizedDescription, details: ["method": .string(request.method)])
            )
        }
    }

    private func logEditorInvocation(
        _ request: ActionRequest,
        id: String,
        event: String,
        error: Error? = nil
    ) {
        let runtime = WorkspaceActionRouter.resolveRuntime(target: request.target)
        let editor = runtime?.currentEditorCommandTargetSnapshot()
        var metadata = [
            "invocationID": id,
            "method": request.method,
            "source": request.source.kind.rawValue,
            "sourceIdentifier": request.source.identifier ?? "none",
            "windowID": runtime?.windowID ?? "none",
            "tabID": runtime?.selectedTabID ?? "none",
            "path": editor?.path ?? "none",
            "surface": editor?.surfaceKind.rawValue ?? "none",
            "editable": String(editor?.isEditable ?? false),
            "supportsReplacement": String(editor?.supportsSelectionReplacement ?? false),
        ]
        if let error {
            metadata["errorCode"] = (error as? ActionError)?.code.rawValue ?? "execution_failed"
            metadata["errorMessage"] = error.localizedDescription
        }
        LocalDiagnosticsCenter.shared.log(category: "action", event: event, metadata: metadata)
    }

    private func resolveTarget(for request: ActionRequest, descriptor: ActionDescriptor) throws -> ActionResolvedTarget {
        try targetResolver.resolveTarget(for: request, descriptor: descriptor)
    }
}
