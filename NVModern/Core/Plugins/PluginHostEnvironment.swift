import Foundation

/// Options for `nv.ui.input`.
struct PluginInputRequest: Equatable {
    enum SubmitKey: String {
        case commandReturn = "cmd+return"
        case plainReturn = "return"
    }

    enum DismissBehavior: String {
        case submit
        case cancel
    }

    var placeholder: String?
    var initialText: String?
    var submitKey: SubmitKey = .commandReturn
    var onDismiss: DismissBehavior = .cancel
    /// Toggle identity. Nil never toggles.
    var id: String?
}

/// Options for `nv.ui.panel`.
struct PluginPanelRequest: Equatable {
    enum CursorPlacement: String {
        case start
        case end
    }

    var fileURL: URL
    var cursor: CursorPlacement = .end
    var id: String
}

/// Options for a persistent single-document window.
struct PluginWindowRequest: Equatable {
    enum Position: Equatable {
        case right
        case coordinates(x: Double, y: Double)
    }
    var fileURL: URL
    var toggle = false
    var alwaysOnTop = false
    var allSpaces = false
    var position: Position?
    var width: Double = 420
    var height: Double = 340
    var cursor: PluginPanelRequest.CursorPlacement = .end
}

/// One row of `nv.ui.pick`.
struct PluginPickItem: Equatable {
    var title: String
    var subtitle: String?
    var iconSystemName: String?
    var keywords: [String]
    var value: ActionValue
}

/// A palette picker: `nv.ui.pick`, `prompt`, `pickNote` and `pickFolder`.
struct PluginPickRequest: Equatable {
    var kind: PalettePluginPick.Kind
    /// Rows for the `items` kind; unused otherwise.
    var items: [PluginPickItem] = []
    var placeholder: String?
    var initialText: String?
}

/// Options for `nv.ui.confirm`.
struct PluginConfirmRequest: Equatable {
    var message: String
    var detail: String?
    var confirmLabel: String?
    var cancelLabel: String?
    var isDestructive = false
}

/// Everything the plugin host needs from the running app. The host itself
/// stays free of AppKit and of window state, so tests drive it with a stub.
@MainActor
protocol PluginHostEnvironment: AnyObject {
    /// Root of the frontmost workspace window's project, if a window exists.
    var activeProjectRootPath: String? { get }

    /// Show the floating text panel. Nil means cancelled or left empty.
    func input(_ request: PluginInputRequest) async -> String?

    /// Show the floating editor panel on a file; returns when it closes.
    func panel(_ request: PluginPanelRequest) async

    /// Open or focus a document window; returns when presented, not on close.
    func window(_ request: PluginWindowRequest) async throws

    /// Show a palette picker in the frontmost workspace window. Nil means
    /// dismissed; throws when there is no window to show it in.
    func pick(_ request: PluginPickRequest) async throws -> ActionValue?

    /// Ask a yes/no question in an alert.
    func confirm(_ request: PluginConfirmRequest) async -> Bool

    /// Post a system notification banner.
    func notify(title: String?, message: String) async throws

    /// Open a file in a workspace tab. False when no window could take it.
    func open(fileURL: URL, inNewTab: Bool) -> Bool

    func readClipboard() -> String?
    func writeClipboard(_ text: String)

    /// Close every plugin-owned surface; called when plugins reload.
    func dismissPluginSurfaces()
}
