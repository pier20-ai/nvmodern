import Foundation

enum BuiltinActions {
    @MainActor
    static func register(into registry: ActionRegistry) {
        registry.register(pingDescriptor) { request, context in
            [
                "app": "nvModern",
                "method": .string(request.method),
                "source": .string(context.source.kind.rawValue),
                "timestamp": .string(ISO8601DateFormatter().string(from: context.now))
            ]
        }

        registry.register(pluginsDescriptor) { _, _ in
            let host = PluginHost.shared
            return [
                "plugins": .array(host.loadedPluginNames.map(ActionValue.string)),
                "errors": .array(host.loadErrors.map(ActionValue.string)),
                "infos": .array(try host.pluginInfos.map { try ActionValue.fromEncodable($0) }),
                "globalHotkeys": .array(host.globalHotkeys.map {
                    ["keystroke": .string($0.keystroke), "method": .string($0.method)]
                })
            ]
        }

        registry.register(helpDescriptor) { request, _ in
            struct HelpArgs: Decodable {
                let provider: String?
                let topic: String?
            }
            let args = try request.decodeArgs(HelpArgs.self)
            let service = AppHelpService.shared
            guard let providerID = args.provider else {
                return ["providers": .array(service.providers.map {
                    ["id": .string($0.id), "title": .string($0.title), "topicCount": .int($0.topics.count)]
                })]
            }
            guard let provider = service.providers.first(where: { $0.id == providerID }) else {
                throw ActionError.invalidArguments("Unknown help provider '\(providerID)'. Call without arguments to list providers.")
            }
            if let topicID = args.topic {
                guard let topic = provider.topics.first(where: { $0.id == topicID }) else {
                    throw ActionError.invalidArguments("Unknown topic '\(topicID)' in provider '\(providerID)'.")
                }
                return try ActionValue.fromEncodable(topic)
            }
            return [
                "provider": .string(provider.id),
                "markdown": .string(AppHelpService.markdown(forProvider: provider.id) ?? ""),
                "topics": .array(provider.topics.map { ["id": .string($0.id), "title": .string($0.title), "category": .string($0.category)] })
            ]
        }

        registry.register(reloadPluginsDescriptor) { _, _ in
            NotificationCenter.default.post(name: .nvModernPluginsConfigDidChange, object: nil)
            return .null
        }

        registry.register(listDescriptor) { request, context in
            struct ListArgs: Decodable {
                let prefix: String?
            }

            let args = try? request.decodeArgs(ListArgs.self)
            let descriptors = context.registry.descriptors(prefixedBy: args?.prefix)
            let items = try descriptors.map { descriptor in
                try ActionValue.fromEncodable(descriptor)
            }
            return [
                "count": .int(items.count),
                "items": .array(items)
            ]
        }

        registry.register(describeDescriptor) { request, context in
            struct DescribeArgs: Decodable {
                let method: String
            }

            let args = try request.decodeArgs(DescribeArgs.self)
            guard let descriptor = context.registry.descriptor(for: args.method) else {
                throw ActionError.unknownMethod(args.method)
            }

            return try ActionValue.fromEncodable(descriptor)
        }

        registry.register(contentCapabilitiesDescriptor) { _, context in
            let capabilities = context.contentSurface?.capabilities ?? .unavailable
            return try ActionValue.fromEncodable(capabilities)
        }

        registry.register(contentNodeDescriptor) { request, context in
            struct NodeArgs: Decodable {
                let address: ActionContentAddress
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(NodeArgs.self)
            let node = try await contentSurface.fetchNode(at: args.address, target: request.target)
            return try ActionValue.fromEncodable(node)
        }

        registry.register(contentQueryDescriptor) { request, context in
            struct QueryArgs: Decodable {
                let query: ActionContentQuery
            }

            guard let contentSurface = context.contentSurface else {
                throw ActionError.unavailable("No content surface is registered")
            }

            let args = try request.decodeArgs(QueryArgs.self)
            let result = try await contentSurface.runQuery(args.query, target: request.target)
            return try ActionValue.fromEncodable(result)
        }
    }

    private static let pingDescriptor = ActionDescriptor(
        method: "app.health.ping",
        title: "Ping",
        summary: "Sanity-check the action runtime and return basic metadata.",
        discussion: "Useful for smoke testing socket and bridge transports before wiring app-specific actions.",
        domain: .introspection,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead],
        tags: ["health", "debug"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Basic runtime metadata", kind: .object)
    )

    private static let pluginsDescriptor = ActionDescriptor(
        method: "app.plugins.list",
        title: "List Plugins",
        summary: "Return loaded plugins, load errors, and plugin global hotkeys.",
        discussion: "Structured inventory includes running, disabled, and failed plugins, alongside compatibility fields.",
        domain: .introspection,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead],
        tags: ["plugins", "debug"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Plugin load state", kind: .object)
    )

    private static let helpDescriptor = ActionDescriptor(
        method: "app.help.get",
        title: "Get Help",
        summary: "Read nvModern's built-in help: list providers, read one provider as Markdown, or fetch one topic.",
        discussion: "The same content powers the F1 help drawer. With no arguments it lists providers; with `provider` it returns the Markdown reference and topic index; with `provider` and `topic` it returns that topic's structured content.",
        domain: .introspection,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead],
        tags: ["help", "docs"],
        arguments: [
            ActionArgumentDescriptor(name: "provider", summary: "Help provider id, e.g. calc", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "topic", summary: "Topic id within the provider", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Providers, provider Markdown, or one topic", kind: .object)
    )

    private static let reloadPluginsDescriptor = ActionDescriptor(
        method: "app.plugins.reload", title: "Reload Plugins", summary: "Reload plugin files and their shortcuts.",
        discussion: "Preserves the action socket and editor context.", domain: .app, mutationKind: .mutating,
        targetRequirement: .none, capabilities: [.appWrite], tags: ["plugins"], arguments: [], result: nil
    )

    private static let listDescriptor = ActionDescriptor(
        method: "app.actions.list",
        title: "List Actions",
        summary: "Return registered action descriptors, optionally filtered by method prefix.",
        discussion: "This is the discovery surface for sockets, command palettes, interactive markdown, and external automation.",
        domain: .introspection,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead],
        tags: ["introspection", "registry"],
        arguments: [
            ActionArgumentDescriptor(name: "prefix", summary: "Optional method prefix filter", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "Object containing action descriptors", kind: .object)
    )

    private static let describeDescriptor = ActionDescriptor(
        method: "app.actions.describe",
        title: "Describe Action",
        summary: "Return the descriptor for a single action method.",
        discussion: "External tooling can use this to inspect requirements, capabilities, and argument shapes before invocation.",
        domain: .introspection,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.appRead],
        tags: ["introspection", "registry"],
        arguments: [
            ActionArgumentDescriptor(name: "method", summary: "Method to describe", kind: .string, isRequired: true)
        ],
        result: ActionResultDescriptor(summary: "Action descriptor", kind: .object)
    )

    private static let contentCapabilitiesDescriptor = ActionDescriptor(
        method: "content.surface.capabilities",
        title: "Content Surface Capabilities",
        summary: "Report which structural, semantic, join, and write capabilities the content surface currently exposes.",
        discussion: "The action system is designed to expose note structure and meaning outside the app. This endpoint lets clients discover how deep that surface currently is.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.contentRead],
        tags: ["content", "semantic", "introspection"],
        arguments: [],
        result: ActionResultDescriptor(summary: "Content surface capability summary", kind: .object)
    )

    private static let contentNodeDescriptor = ActionDescriptor(
        method: "content.node.get",
        title: "Get Content Node",
        summary: "Return one content node addressed inside a note or document.",
        discussion: "Designed for heading-level, list-item-level, or link-level fetches once a structural content index is available.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .content,
        capabilities: [.contentRead, .contentSemanticRead],
        tags: ["content", "structure", "heading", "wikilink"],
        arguments: [
            ActionArgumentDescriptor(name: "address", summary: "Structured content address", kind: .object, isRequired: true)
        ],
        result: ActionResultDescriptor(summary: "Structured content node", kind: .object)
    )

    private static let contentQueryDescriptor = ActionDescriptor(
        method: "content.query",
        title: "Query Content Surface",
        summary: "Run a structural or semantic query across notes and return records that can later be joined or written elsewhere.",
        discussion: "This is the shape intended for features like 'all notes linking to X', 'all list items mentioning @tag', heading extraction, semantic note retrieval, and CSV/report generation.",
        domain: .content,
        mutationKind: .readOnly,
        targetRequirement: .project,
        capabilities: [.contentRead, .contentSemanticRead],
        tags: ["content", "query", "semantic", "join", "csv"],
        arguments: [
            ActionArgumentDescriptor(name: "query", summary: "Structured content query", kind: .object, isRequired: true)
        ],
        result: ActionResultDescriptor(summary: "Structured content records", kind: .object)
    )
}
