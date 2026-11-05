import AppKit

extension Notification.Name {
    /// Posted when `CompactToolbarPreference` changes, so open workspace
    /// windows can restyle without waiting to be recreated.
    static let workspaceToolbarStyleDidChange = Notification.Name("nvmodern.workspaceToolbarStyleDidChange")
}

/// Toolbar height preference, shared by the View menu item and the
/// `workspace.toolbar.compact.toggle` action. Both write through `setEnabled`,
/// which is the only place the value changes and the only thing that tells
/// attached windows to restyle.
enum CompactToolbarPreference {
    static let key = "toolbar.compact"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static var windowStyle: NSWindow.ToolbarStyle {
        isEnabled ? .unifiedCompact : .unified
    }

    static func setEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: key)
        NotificationCenter.default.post(name: .workspaceToolbarStyleDidChange, object: nil)
    }

    static func toggle() -> Bool {
        let enabled = !isEnabled
        setEnabled(enabled)
        return enabled
    }
}

/// AppKit toolbar for native-shell workspace windows.
///
/// The SwiftUI `.toolbar` bridge (`NSHostingView.sceneBridgingOptions`
/// containing `.toolbars`) rebuilds every item on each toolbar-preference
/// change: it discards the item viewers, creates a fresh hosting view per
/// item, re-renders each symbol image, and re-tiles. Preferences change on
/// every key-window transition, and every tab is a window, so a Cmd-Tab paid
/// that rebuild once per tab. Time Profiler samples put the bridge at roughly
/// 60% of all main-thread work during new-tab and activation.
///
/// A plain `NSToolbar` validates its items in place and never rebuilds views
/// on activation. The window view installs closures here for the actions it
/// owns; item enablement is read through those closures at validation time.
@MainActor
final class NativeWorkspaceToolbarController: NSObject {
    struct Handlers {
        var toggleSidebar: () -> Void = {}
        var goBack: () -> Void = {}
        var goForward: () -> Void = {}
        var canGoBack: () -> Bool = { false }
        var canGoForward: () -> Bool = { false }
        var newNote: () -> Void = {}
        var toggleInspector: () -> Void = {}
        var search: () -> Void = {}
    }

    private enum ItemID {
        static let toggleSidebar = NSToolbarItem.Identifier("nvmodern.toolbar.toggleSidebar")
        static let back = NSToolbarItem.Identifier("nvmodern.toolbar.back")
        static let forward = NSToolbarItem.Identifier("nvmodern.toolbar.forward")
        static let newNote = NSToolbarItem.Identifier("nvmodern.toolbar.newNote")
        static let inspector = NSToolbarItem.Identifier("nvmodern.toolbar.inspector")
        static let search = NSToolbarItem.Identifier("nvmodern.toolbar.search")
    }

    var handlers = Handlers()

    private let toolbar: NSToolbar
    private weak var attachedWindow: NSWindow?

    override init() {
        toolbar = NSToolbar(identifier: "nvmodern.workspace.toolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyToolbarStyle),
            name: .workspaceToolbarStyleDidChange,
            object: nil
        )
    }

    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        attachedWindow = window
        applyToolbarStyle()
    }

    /// Windows created later read the preference on `attach`; open ones follow
    /// it from here.
    @objc private func applyToolbarStyle() {
        attachedWindow?.toolbarStyle = CompactToolbarPreference.windowStyle
    }

    /// Re-runs item validation now instead of waiting for the next window
    /// update, so back/forward enablement follows history changes promptly.
    func revalidate() {
        toolbar.validateVisibleItems()
    }

    // MARK: - Actions

    @objc private func toggleSidebar(_ sender: Any?) {
        handlers.toggleSidebar()
    }

    @objc private func goBack(_ sender: Any?) {
        handlers.goBack()
    }

    @objc private func goForward(_ sender: Any?) {
        handlers.goForward()
    }

    @objc private func newNote(_ sender: Any?) {
        handlers.newNote()
    }

    @objc private func toggleInspector(_ sender: Any?) {
        handlers.toggleInspector()
    }

    @objc private func search(_ sender: Any?) {
        handlers.search()
    }

    // MARK: - Items

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        toolTip: String,
        action: Selector,
        isNavigational: Bool = false
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.isBordered = true
        item.isNavigational = isNavigational
        item.target = self
        item.action = action
        return item
    }
}

extension NativeWorkspaceToolbarController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.toggleSidebar,
            .sidebarTrackingSeparator,
            ItemID.back,
            ItemID.forward,
            .flexibleSpace,
            ItemID.newNote,
            ItemID.inspector,
            ItemID.search
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.toggleSidebar:
            return makeItem(
                itemIdentifier,
                label: "Sidebar",
                symbolName: "sidebar.leading",
                toolTip: "Show or hide the sidebar",
                action: #selector(toggleSidebar(_:))
            )
        case ItemID.back:
            return makeItem(
                itemIdentifier,
                label: "Back",
                symbolName: "chevron.backward",
                toolTip: "Go back",
                action: #selector(goBack(_:)),
                isNavigational: true
            )
        case ItemID.forward:
            return makeItem(
                itemIdentifier,
                label: "Forward",
                symbolName: "chevron.forward",
                toolTip: "Go forward",
                action: #selector(goForward(_:)),
                isNavigational: true
            )
        case ItemID.newNote:
            return makeItem(
                itemIdentifier,
                label: "New Note",
                symbolName: "square.and.pencil",
                toolTip: "New note (⌥⌘N)",
                action: #selector(newNote(_:))
            )
        case ItemID.inspector:
            return makeItem(
                itemIdentifier,
                label: "Inspector",
                symbolName: "sidebar.right",
                toolTip: "Show or hide the inspector",
                action: #selector(toggleInspector(_:))
            )
        case ItemID.search:
            return makeItem(
                itemIdentifier,
                label: "Search",
                symbolName: "magnifyingglass",
                toolTip: "Search (⌘K)",
                action: #selector(search(_:))
            )
        default:
            return nil
        }
    }
}

extension NativeWorkspaceToolbarController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ItemID.back:
            return handlers.canGoBack()
        case ItemID.forward:
            return handlers.canGoForward()
        default:
            return true
        }
    }
}
