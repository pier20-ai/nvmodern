import Foundation

/// Side stack (ticket 0031): read-only reference cards in a column beside the
/// tab's content. Shift-clicking a wikilink pushes one; these actions expose
/// the same operations to the palette, menus, keybindings, the socket, and
/// MCP (`open_in_side_stack`).
@MainActor
enum WorkspaceSideStackBuiltinActions {
    static let pushMethod = "workspace.stack.push"
    static let toggleMethod = "workspace.stack.toggle"
    static let focusMethod = "workspace.stack.focus"
    static let closeMethod = "workspace.stack.close"
    static let clearMethod = "workspace.stack.clear"
    static let listMethod = "workspace.stack.list"

    /// Menu-owned shortcuts (View menu), also listed by the palette.
    static let toggleKeystroke = "cmd+opt+s"
    static let focusKeystroke = "cmd+opt+j"

    static func register(into registry: ActionRegistry) {
        registry.register(pushDescriptor) { request, context in
            struct PushArgs: Decodable {
                let path: String?
                let heading: String?
                let block: String?
            }
            let args = (try? request.decodeArgs(PushArgs.self)) ?? PushArgs(path: nil, heading: nil, block: nil)
            let (runtime, stack) = try resolve(context)

            var rawPath = args.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var focus = SideStackFocus(heading: args.heading, block: args.block)
            if rawPath.isEmpty {
                guard let current = runtime.currentDocumentSnapshot()?.relativePath, !current.isEmpty else {
                    throw ActionError.invalidArguments("No workspace note is open; pass path")
                }
                rawPath = current
            } else if focus == nil, rawPath.contains("#"), stack.resolveWorkspacePath(rawPath) == nil {
                // `Note#Heading` / `Note#^block`, as written in a wikilink.
                let parsed = parseObsidianWikilinkTarget(rawPath)
                focus = SideStackFocus(reference: parsed.reference)
                rawPath = parsed.noteTarget
            }

            guard let path = stack.resolveWorkspacePath(rawPath) else {
                throw ActionError.invalidArguments("No workspace note matches path", details: ["path": .string(rawPath)])
            }
            guard SideStackController.isStackable(path: path) else {
                throw ActionError.invalidArguments(
                    "The side stack shows Markdown, Org, and plain-text notes",
                    details: ["path": .string(path)]
                )
            }
            let outcome = stack.push(path: path, focus: focus)
            var result = snapshot(stack.state, runtime: runtime)
            result["id"] = .string(outcome.id)
            switch outcome {
            case .added:
                result["added"] = .bool(true)
            case .existing:
                result["added"] = .bool(false)
            }
            return .object(result)
        }

        registry.register(toggleDescriptor) { _, context in
            let (runtime, stack) = try resolve(context)
            stack.toggleVisibility()
            return .object(snapshot(stack.state, runtime: runtime))
        }

        registry.register(focusDescriptor) { _, context in
            let (runtime, stack) = try resolve(context)
            let area = stack.toggleFocus()
            var result = snapshot(stack.state, runtime: runtime)
            result["focused"] = .string(area)
            return .object(result)
        }

        registry.register(closeDescriptor) { request, context in
            struct CloseArgs: Decodable {
                let id: String?
            }
            let args = (try? request.decodeArgs(CloseArgs.self)) ?? CloseArgs(id: nil)
            let (runtime, stack) = try resolve(context)
            let requestedID = args.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = (requestedID?.isEmpty == false ? requestedID : nil) ?? stack.state.cards.first?.id else {
                throw ActionError.unavailable("The side stack has no cards")
            }
            guard stack.close(id: id) else {
                throw ActionError.invalidArguments("No side stack card with that id", details: ["id": .string(id)])
            }
            var result = snapshot(stack.state, runtime: runtime)
            result["closed"] = .string(id)
            return .object(result)
        }

        registry.register(clearDescriptor) { _, context in
            let (runtime, stack) = try resolve(context)
            stack.clear()
            return .object(snapshot(stack.state, runtime: runtime))
        }

        registry.register(listDescriptor) { _, context in
            let (runtime, stack) = try resolve(context)
            return .object(snapshot(stack.state, runtime: runtime))
        }
    }

    private static func resolve(
        _ context: ActionExecutionContext
    ) throws -> (any WorkspaceActionRuntime, SideStackController) {
        guard let runtime = WorkspaceActionRouter.runtime(for: context.resolvedTarget) else {
            throw ActionError.targetNotFound("Could not resolve a target workspace")
        }
        guard let stack = runtime.sideStackController() else {
            throw ActionError.unavailable("This window has no side stack")
        }
        return (runtime, stack)
    }

    /// JSON-like description of a stack for results and `workspace.stack.list`.
    static func snapshot(_ state: SideStackState, runtime: (any WorkspaceActionRuntime)? = nil) -> [String: ActionValue] {
        var result: [String: ActionValue] = [
            "isOpen": .bool(state.isOpen),
            "width": .double(state.resolvedWidth),
            "cards": .array(state.cards.map { card in
                var object: [String: ActionValue] = [
                    "id": .string(card.id),
                    "path": .string(card.path),
                    "title": .string(URL(fileURLWithPath: card.path).deletingPathExtension().lastPathComponent),
                    "collapsed": .bool(card.collapsed)
                ]
                if let heading = card.focus?.heading {
                    object["heading"] = .string(heading)
                }
                if let block = card.focus?.block {
                    object["block"] = .string(block)
                }
                return .object(object)
            })
        ]
        if let runtime {
            result["windowID"] = .string(runtime.windowID)
            result["tabID"] = ActionValue(runtime.selectedTabID)
        }
        return result
    }

    // MARK: - Descriptors

    static let pushDescriptor = ActionDescriptor(
        method: pushMethod,
        title: "Open in Side Stack",
        summary: "Show a note as a read-only card in the side stack beside the tab's document.",
        discussion: "The card goes on top of the stack; if the same note (and section) is already there, its card is revealed instead. With no path this pushes the current note. heading or block focuses the card on that section, like [[note#Heading]] / [[note#^block]].",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteRead],
        tags: ["workspace", "note", "stack", "reference", "sidebar"],
        arguments: [
            ActionArgumentDescriptor(
                name: "path",
                summary: "Workspace-relative note path (or note name); omit for the current note",
                kind: .string,
                isRequired: false
            ),
            ActionArgumentDescriptor(name: "heading", summary: "Focus the card on this heading", kind: .string, isRequired: false),
            ActionArgumentDescriptor(name: "block", summary: "Focus the card on this ^block id", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "The card id, whether it was added, and the stack", kind: .object),
        palette: ActionPalettePresentation(
            category: "Open",
            iconSystemName: "sidebar.right",
            when: "activeDocument.kind == \"workspaceNote\"",
            title: "Open in side stack",
            rank: 20,
            keywords: ["stack", "side", "reference", "beside", "card", "pin"],
            nounArguments: ["note": "path"]
        )
    )

    static let toggleDescriptor = ActionDescriptor(
        method: toggleMethod,
        title: "Toggle Side Stack",
        summary: "Show or hide the side stack column; its cards stay either way.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "stack", "sidebar", "layout"],
        arguments: [],
        result: ActionResultDescriptor(summary: "The stack", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "sidebar.right",
            title: "Toggle side stack",
            rank: 40,
            keywords: ["stack", "side", "references", "column", "show", "hide"]
        )
    )

    static let focusDescriptor = ActionDescriptor(
        method: focusMethod,
        title: "Focus Side Stack",
        summary: "Move keyboard focus between the main document and the side stack.",
        discussion: "Opens the column when it is hidden.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "stack", "focus"],
        arguments: [],
        result: ActionResultDescriptor(summary: "The focused area (stack or main) and the stack", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "arrow.left.arrow.right",
            title: "Focus side stack / document",
            rank: 41,
            keywords: ["stack", "side", "focus", "switch"]
        )
    )

    static let closeDescriptor = ActionDescriptor(
        method: closeMethod,
        title: "Close Side Stack Card",
        summary: "Remove a card from the side stack; closing the last card hides the column.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "stack"],
        arguments: [
            ActionArgumentDescriptor(name: "id", summary: "Card id from workspace.stack.list; omit for the top card", kind: .string, isRequired: false)
        ],
        result: ActionResultDescriptor(summary: "The closed id and the stack", kind: .object)
    )

    static let clearDescriptor = ActionDescriptor(
        method: clearMethod,
        title: "Clear Side Stack",
        summary: "Remove every card from the side stack and hide it.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite],
        tags: ["workspace", "stack"],
        arguments: [],
        result: ActionResultDescriptor(summary: "The empty stack", kind: .object),
        palette: ActionPalettePresentation(
            category: "Window",
            iconSystemName: "xmark.rectangle",
            when: nil,
            title: "Clear side stack",
            rank: 42,
            keywords: ["stack", "side", "close", "cards"]
        )
    )

    static let listDescriptor = ActionDescriptor(
        method: listMethod,
        title: "List Side Stack",
        summary: "Return the side stack's cards (top first), visibility, and width.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .workspace,
        capabilities: [.workspaceRead],
        tags: ["workspace", "stack"],
        arguments: [],
        result: ActionResultDescriptor(summary: "The stack", kind: .object)
    )
}
