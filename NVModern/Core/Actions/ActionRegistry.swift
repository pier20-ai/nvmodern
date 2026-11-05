import Foundation

typealias ActionHandler = (_ request: ActionRequest, _ context: ActionExecutionContext) async throws -> ActionValue

@MainActor
final class ActionRegistry {
    static let shared = ActionRegistry()

    private struct Registration {
        let descriptor: ActionDescriptor
        let handler: ActionHandler
    }

    private var registrations: [String: Registration] = [:]
    private var didRegisterBuiltins = false

    func register(_ descriptor: ActionDescriptor, handler: @escaping ActionHandler) {
        registrations[descriptor.method] = Registration(descriptor: descriptor, handler: handler)
    }

    /// Remove a registration that came from outside the built-ins (a plugin).
    func unregister(method: String) {
        registrations.removeValue(forKey: method)
    }

    func ensureBuiltinsRegistered() {
        guard !didRegisterBuiltins else { return }
        didRegisterBuiltins = true
        BuiltinActions.register(into: self)
        ContentBuiltinActions.register(into: self)
        WorkspaceBuiltinActions.register(into: self)
        WorkspaceDocumentBuiltinActions.register(into: self)
        WorkspacePassageBuiltinActions.register(into: self)
        WorkspaceAnnotationBuiltinActions.register(into: self)
        WorkspaceSideStackBuiltinActions.register(into: self)
    }

    func descriptor(for method: String) -> ActionDescriptor? {
        registrations[method]?.descriptor
    }

    func handler(for method: String) -> ActionHandler? {
        registrations[method]?.handler
    }

    func allDescriptors() -> [ActionDescriptor] {
        registrations.values
            .map(\.descriptor)
            .sorted { $0.method.localizedCaseInsensitiveCompare($1.method) == .orderedAscending }
    }

    func descriptors(prefixedBy prefix: String?) -> [ActionDescriptor] {
        guard let prefix, !prefix.isEmpty else {
            return allDescriptors()
        }

        return allDescriptors().filter { $0.method.hasPrefix(prefix) }
    }
}
