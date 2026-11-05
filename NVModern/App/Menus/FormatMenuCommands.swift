import SwiftUI

/// Format menu: Markdown formatting, grouped.
///
/// This was sixteen flat items — inline styles, headings, lists, and block
/// inserts in one undifferentiated column.
///
/// The items stay enabled and check the surface when invoked, rather than
/// greying out. Deriving enabled state here means calling
/// `currentEditorCommandTargetSnapshot()` from inside this `Commands` body, and
/// that call routes through `WorkspaceView.ensureWorkspaceTabController(...)`,
/// which mutates workspace state — doing it during a render pass made the
/// active tab resync from a stale snapshot and regress to `.launchpad`, so
/// Markdown documents stopped opening at all. Greying these out properly needs
/// the workspace to publish a small menu-state value on document change, which
/// nothing does yet. Invoking on a non-Markdown surface is now a silent no-op
/// instead of the old `NSSound.beep()`.
struct FormatMenuCommands: Commands {
    @ObservedObject private var routerState = WorkspaceActionRouterState.shared

    var body: some Commands {
        CommandMenu("Format") {
            let _ = routerState.revision

            Menu("Text") {
                actionButtons(for: [.bold, .italic, .strikethrough, .highlight, .inlineCode])
            }

            Menu("Heading") {
                actionButtons(for: [.heading1, .heading2, .heading3])
            }

            Menu("List") {
                actionButtons(for: [.bulletList, .numberedList, .taskList])
            }

            Divider()

            actionButtons(for: [.blockquote])

            Menu("Insert") {
                actionButtons(for: [.link, .wikilink, .table, .codeBlock])
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for actions: [MarkdownFormatMenuAction]) -> some View {
        ForEach(actions) { action in
            if let shortcut = action.keyboardShortcut {
                Button(action.title) { perform(action) }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            } else {
                Button(action.title) { perform(action) }
            }
        }
    }

    private func perform(_ action: MarkdownFormatMenuAction) {
        guard MenuCommandContext.isMarkdownEditingSurfaceNow(
            allowingArborOutline: action.supportsArborInlineFormatting
        ) else { return }

        let windowNumber = MenuCommandContext.targetWindowNumber
        switch action {
        case .table:
            _ = WorkspaceActionRouter.performInsertMarkdownTable(in: windowNumber)
        default:
            _ = WorkspaceActionRouter.performCurrentEditorBridgeCommand(action.command, in: windowNumber)
        }
    }
}

struct MarkdownFormatMenuShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
}

enum MarkdownFormatMenuAction: String, CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case highlight
    case inlineCode
    case link
    case wikilink
    case heading1
    case heading2
    case heading3
    case bulletList
    case numberedList
    case taskList
    case blockquote
    case table
    case codeBlock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .highlight: return "Highlight"
        case .inlineCode: return "Inline Code"
        case .link: return "Link"
        case .wikilink: return "Wikilink"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .taskList: return "Task List"
        case .blockquote: return "Blockquote"
        case .table: return "Table"
        case .codeBlock: return "Code Block"
        }
    }

    var command: String {
        switch self {
        case .bold: return "toggleMarkdownBold"
        case .italic: return "toggleMarkdownItalic"
        case .strikethrough: return "toggleMarkdownStrikethrough"
        case .highlight: return "toggleMarkdownHighlightSelection"
        case .inlineCode: return "toggleMarkdownInlineCode"
        case .link: return "insertMarkdownLink"
        case .wikilink: return "insertMarkdownWikilink"
        case .heading1: return "toggleMarkdownHeading1"
        case .heading2: return "toggleMarkdownHeading2"
        case .heading3: return "toggleMarkdownHeading3"
        case .bulletList: return "toggleMarkdownBulletList"
        case .numberedList: return "toggleMarkdownNumberedList"
        case .taskList: return "toggleMarkdownTaskList"
        case .blockquote: return "toggleMarkdownBlockquote"
        case .table: return ""
        case .codeBlock: return "insertMarkdownCodeBlock"
        }
    }

    var keyboardShortcut: MarkdownFormatMenuShortcut? {
        switch self {
        case .bold:
            return MarkdownFormatMenuShortcut(key: "b", modifiers: [.command])
        case .italic:
            return MarkdownFormatMenuShortcut(key: "i", modifiers: [.command])
        case .highlight:
            return MarkdownFormatMenuShortcut(key: "h", modifiers: [.command, .shift])
        case .table:
            return MarkdownFormatMenuShortcut(key: "t", modifiers: [.command, .option])
        default:
            return nil
        }
    }

    var supportsArborInlineFormatting: Bool {
        self == .bold || self == .italic
    }
}
