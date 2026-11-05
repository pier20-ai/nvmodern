import AppKit
import Foundation

/// Verbs for the passage noun — a full-text match the palette found with `/`.
///
/// A passage is the one noun the palette carries more than a path for: it also
/// knows the matched text and the term that found it, and the verbs here are
/// the ones that need that text. They are `listedOnlyWhenBound`, so they never
/// clutter the root menu; they appear only in a passage's verbs frame.
@MainActor
enum WorkspacePassageBuiltinActions {
    static func register(into registry: ActionRegistry) {
        registry.register(quoteDescriptor) { request, context in
            let runtime = try resolvedRuntime(from: context)
            let args = try request.decodeArgs(PassageArgs.self)
            let snippet = args.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !snippet.isEmpty else {
                throw ActionError.invalidArguments("snippet must not be empty")
            }
            let text = quotationBlock(snippet: snippet, sourcePath: args.path)
            guard runtime.replaceCurrentEditorSelection(with: text) else {
                throw ActionError.unavailable("The current editor cannot accept text")
            }
            return [
                "inserted": .bool(true),
                "characters": .int(text.count),
                "sourceRelativePath": ActionValue(args.path)
            ]
        }

        registry.register(transcludeDescriptor) { request, context in
            let runtime = try resolvedRuntime(from: context)
            let args = try request.decodeArgs(PassageArgs.self)
            guard let path = args.path, !path.isEmpty else {
                throw ActionError.invalidArguments("path must not be empty")
            }
            let text = "\n![[\(noteName(for: path))]]\n"
            guard runtime.replaceCurrentEditorSelection(with: text) else {
                throw ActionError.unavailable("The current editor cannot accept text")
            }
            return [
                "inserted": .bool(true),
                "sourceRelativePath": .string(path)
            ]
        }

        registry.register(copyTextDescriptor) { request, _ in
            let args = try request.decodeArgs(PassageArgs.self)
            let snippet = args.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !snippet.isEmpty else {
                throw ActionError.invalidArguments("snippet must not be empty")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(snippet, forType: .string)
            return [
                "copied": .bool(true),
                "characters": .int(snippet.count)
            ]
        }
    }

    // MARK: - Helpers

    private struct PassageArgs: Decodable {
        let path: String?
        let snippet: String?
        let term: String?
    }

    private static func resolvedRuntime(
        from context: ActionExecutionContext
    ) throws -> any WorkspaceActionRuntime {
        guard let runtime = WorkspaceActionRouter.runtime(for: context.resolvedTarget) else {
            throw ActionError.targetNotFound("Could not resolve a target workspace")
        }
        return runtime
    }

    /// A Markdown blockquote of the passage, attributed with a wikilink back
    /// to the note it came from.
    static func quotationBlock(snippet: String, sourcePath: String?) -> String {
        let quoted = snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        guard let sourcePath, !sourcePath.isEmpty else {
            return "\n\(quoted)\n"
        }
        return "\n\(quoted)\n\u{2014} [[\(noteName(for: sourcePath))]]\n"
    }

    /// The wikilink target for a note: its file name without the extension.
    static func noteName(for relativePath: String) -> String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Descriptors

    private static let pathArgument = ActionArgumentDescriptor(
        name: "path",
        summary: "Workspace-relative path of the note the passage came from",
        kind: .string,
        isRequired: false
    )

    private static let snippetArgument = ActionArgumentDescriptor(
        name: "snippet",
        summary: "The matched text",
        kind: .string,
        isRequired: true
    )

    private static let termArgument = ActionArgumentDescriptor(
        name: "term",
        summary: "The search term that found the passage",
        kind: .string,
        isRequired: false
    )

    private static let quoteDescriptor = ActionDescriptor(
        method: "workspace.passage.quote",
        title: "Quote Passage",
        summary: "Insert a passage as a Markdown blockquote, attributed to its note.",
        discussion: "Inserts at the cursor in the current editor. The palette binds these arguments from a passage noun.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "passage", "quote", "search"],
        arguments: [pathArgument, snippetArgument, termArgument],
        result: ActionResultDescriptor(summary: "Insertion metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "text.quote",
            title: "Quote into current note",
            keywords: ["quote", "blockquote", "cite"],
            nounArguments: ["passage": "path"],
            subject: .document,
            listedOnlyWhenBound: true
        )
    )

    private static let transcludeDescriptor = ActionDescriptor(
        method: "workspace.passage.transclude",
        title: "Transclude Passage Source",
        summary: "Insert a whole-note embed (![[note]]) for the note a passage came from.",
        discussion: "Inserts on its own line at the cursor, which is what the editor's transclusion plugin renders.",
        domain: .workspace,
        mutationKind: .mutating,
        targetRequirement: .workspace,
        capabilities: [.workspaceWrite, .noteWrite],
        tags: ["workspace", "passage", "transclusion", "embed"],
        arguments: [pathArgument, snippetArgument, termArgument],
        result: ActionResultDescriptor(summary: "Insertion metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "rectangle.stack",
            title: "Transclude its note",
            keywords: ["transclude", "embed", "include"],
            nounArguments: ["passage": "path"],
            subject: .document,
            listedOnlyWhenBound: true
        )
    )

    private static let copyTextDescriptor = ActionDescriptor(
        method: "workspace.passage.copy",
        title: "Copy Passage Text",
        summary: "Copy a passage's matched text to the clipboard.",
        discussion: nil,
        domain: .workspace,
        mutationKind: .readOnly,
        targetRequirement: .none,
        capabilities: [.noteRead],
        tags: ["workspace", "passage", "copy", "clipboard"],
        arguments: [pathArgument, snippetArgument, termArgument],
        result: ActionResultDescriptor(summary: "Copy metadata", kind: .object),
        palette: ActionPalettePresentation(
            category: "Document",
            iconSystemName: "doc.on.clipboard",
            title: "Copy text",
            keywords: ["copy", "clipboard", "snippet"],
            nounArguments: ["passage": "path"],
            subject: .document,
            listedOnlyWhenBound: true
        )
    )
}
