import Foundation

@MainActor
final class ActionInvocationDispatcher {
    static let shared = ActionInvocationDispatcher()

    private let executor: ActionExecutor

    init(executor: ActionExecutor? = nil) {
        self.executor = executor ?? ActionExecutor.shared
    }

    func execute(
        invocation: ActionInvocationReference,
        source: ActionSource,
        fallbackTarget: ActionTarget = .automatic
    ) async -> ActionResponse {
        switch invocation {
        case .method(let method, let args, let target):
            let request = ActionRequest(
                id: nil,
                method: method,
                args: args,
                target: target ?? fallbackTarget,
                source: source
            )
            return await executor.execute(request)
        }
    }
}
