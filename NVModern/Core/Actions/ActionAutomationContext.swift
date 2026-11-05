import AppKit
import Foundation

struct ActionAutomationContext: Sendable {
    let now: Date
    let variables: [String: ActionValue]
}

@MainActor
enum ActionAutomationContextBuilder {
    static func build(source: ActionSource, fallbackTarget: ActionTarget = .automatic) -> ActionAutomationContext {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let runtime = WorkspaceActionRouter.resolveRuntime(target: fallbackTarget)
        let activeDocument = runtime?.currentDocumentSnapshot()
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let executionUUID = UUID().uuidString

        var variables: [String: ActionValue] = [
            "nowISO8601": .string(isoFormatter.string(from: now)),
            "nowDate": .string(dayFormatter.string(from: now)),
            "nowTime": .string(timeFormatter.string(from: now)),
            "nowUnix": .double(now.timeIntervalSince1970),
            "uuid": .string(executionUUID),
            "source": [
                "kind": .string(source.kind.rawValue),
                "identifier": ActionValue(source.identifier),
                "metadata": .object(source.metadata)
            ],
            "clipboard": [
                "text": .string(clipboardText)
            ],
            "app": [
                "name": .string("nvModern")
            ]
        ]

        if let runtime {
            let workspace: [String: ActionValue] = [
                "windowID": .string(runtime.windowID),
                "workspaceID": .string(runtime.workspaceID),
                "projectRootPath": .string(runtime.projectRootPath),
                "selectedTabID": ActionValue(runtime.selectedTabID),
                "hasDiffOriginal": .bool(runtime.currentDiffOriginalSource() != nil),
                "isSidebarVisible": .bool(runtime.isSidebarVisible)
            ]
            variables["activeWorkspace"] = .object(workspace)
        }

        if let activeDocument,
           let documentValue = try? ActionValue.fromEncodable(activeDocument) {
            variables["activeDocument"] = documentValue
        } else {
            variables["activeDocument"] = .null
        }

        // The focused editor surface, for `when` expressions that gate Markdown
        // formatting and other editor-only commands. `currentEditorCommandTargetSnapshot()`
        // reaches workspace state, so build this context from an event handler,
        // never from inside a SwiftUI render pass (see `MenuCommandContext`).
        if let editor = runtime?.currentEditorCommandTargetSnapshot() {
            variables["activeEditor"] = [
                "surface": .string(editor.surfaceKind.rawValue),
                "path": ActionValue(editor.path),
                "isEditable": .bool(editor.isEditable),
                "supportsSelectionReplacement": .bool(editor.supportsSelectionReplacement)
            ]
        } else {
            variables["activeEditor"] = .null
        }

        return ActionAutomationContext(now: now, variables: variables)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
