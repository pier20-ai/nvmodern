import AppKit
import SwiftUI

/// Flips once a window is actually on screen.
///
/// Pre-warmed spare windows are fully built but never ordered in. Their SwiftUI
/// content still resolves its `NSWindow`, so without this gate a spare would
/// register an action runtime for an offscreen window and write itself into the
/// session store as a restorable tab. The coordinator activates the gate at the
/// moment it hands the spare to a tab group; every other window is created
/// without a gate and counts as activated from the start.
@MainActor
final class WorkspaceWindowActivationGate {
    private(set) var isActivated: Bool
    private(set) var sidebarVisible: Bool?
    private var request: WorkspaceWindowLaunchStore.WindowRequest?
    var onActivate: ((NSWindow) -> Void)?

    init(isActivated: Bool) {
        self.isActivated = isActivated
    }

    func activate(sidebarVisible: Bool?, request: WorkspaceWindowLaunchStore.WindowRequest?, window: NSWindow) {
        self.sidebarVisible = sidebarVisible
        self.request = request
        isActivated = true
        // One shot: release the closure's SwiftUI state references on adoption.
        let handler = onActivate
        onActivate = nil
        handler?(window)
    }

    func consumeRequest() -> WorkspaceWindowLaunchStore.WindowRequest? {
        guard isActivated else { return nil }
        defer { request = nil }
        return request
    }

    func consumeSidebarVisibility() -> Bool? {
        guard isActivated else { return nil }
        defer { sidebarVisible = nil }
        return sidebarVisible
    }
}

/// Owns every workspace window in the native shell.
///
/// SwiftUI still renders each workspace, but it no longer creates or retains
/// workspace windows. Keeping one AppKit controller per native tab gives the
/// tab bar, Cmd-T, and the tab-bar add button one creation path.
@MainActor
final class WorkspaceApplicationCoordinator {
    static let shared = WorkspaceApplicationCoordinator()

    private struct SpareWindow {
        let controller: WorkspaceWindowController
        let activationGate: WorkspaceWindowActivationGate
        let projectRootPath: String?
    }

    private var controllers: [ObjectIdentifier: WorkspaceWindowController] = [:]
    private weak var lastActiveController: WorkspaceWindowController?
    private var didBootstrap = false
    /// At most one warm spare per project root.
    private var sparesByRootKey: [String: SpareWindow] = [:]
    private static let disablesToolbarForPerformanceTesting =
        ProcessInfo.processInfo.environment["NVMODERN_DISABLE_NATIVE_TOOLBAR"] == "1"
    private static let disablesSpareWindows =
        ProcessInfo.processInfo.environment["NVMODERN_DISABLE_SPARE_WINDOW"] == "1"
    private static let defaultProjectRootKey = "<default-project>"

    private init() {}

    func installLaunchHandler() {
        WorkspaceWindowLaunchStore.shared.registerOpenWorkspaceWindowAction { [weak self] in
            self?.openNextRequestedWindow()
        }
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        var openedWorkspace = false
        while let request = WorkspaceWindowLaunchStore.shared.claimNextWindowRequest() {
            openWindow(request: request)
            openedWorkspace = true
        }

        // Every native tab persists as a window, so a session is a flat list
        // of window states. Rebuild one tab group per project root instead of
        // ordering each state in as its own top-level window.
        var restoredStates: [PersistedWorkspaceWindowState] = []
        while let restoredState = WorkspaceSessionStore.shared.claimNextLaunchWindowState() {
            restoredStates.append(restoredState)
        }
        var hostByRootPath: [String: WorkspaceWindowController] = [:]
        var deferredTabStates: [(host: WorkspaceWindowController, state: PersistedWorkspaceWindowState)] = []
        for restoredState in restoredStates {
            let rootKey = restoredState.rootPath ?? Self.defaultProjectRootKey
            if let host = hostByRootPath[rootKey] {
                deferredTabStates.append((host, restoredState))
            } else {
                hostByRootPath[rootKey] = openWindow(restoredState: restoredState)
            }
            openedWorkspace = true
        }
        // The group hosts are on screen now. Their remaining tabs join on the
        // next turn, once each host has had its first layout, matching the
        // Cmd-T path where the host is always an already-displayed window.
        if !deferredTabStates.isEmpty {
            let firstHost = deferredTabStates.first?.host
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for entry in deferredTabStates {
                    self.createController(request: nil, restoredState: entry.state, tabbingWith: entry.host)
                }
                // Each tab became key as it was added; land on the first persisted one.
                firstHost?.window?.makeKeyAndOrderFront(nil)
            }
        }

        if !openedWorkspace {
            openWindow()
        }
    }

    func openNextRequestedWindow() {
        let request = WorkspaceWindowLaunchStore.shared.claimNextWindowRequest()
        openWindow(request: request)
    }

    @discardableResult
    func openWindow(
        request: WorkspaceWindowLaunchStore.WindowRequest? = nil,
        restoredState: PersistedWorkspaceWindowState? = nil
    ) -> WorkspaceWindowController {
        createController(request: request, restoredState: restoredState, tabbingWith: nil)
    }

    @discardableResult
    func openTab(
        relativeTo explicitHost: NSWindow? = nil,
        sharedNotesModel: NotesWorkspaceModel? = nil,
        sharedWorkspaceTabControllerRegistry: WorkspaceTabControllerRegistry? = nil
    ) -> WorkspaceWindowController {
        PerformanceDiagnostics.markPendingNewTab("coordinator.openTab")
        let hostController = explicitHost.flatMap(controller(for:)) ?? lastActiveController
        let hostRootKey = hostController.flatMap { Self.rootKey(for: Self.projectRootPath(ofHost: $0)) }

        // A spare starts as a launchpad and receives its document request on
        // activation. Retain the request if adoption fails so cold fallback
        // cannot silently open an empty tab.
        var claimedRequest: WorkspaceWindowLaunchStore.WindowRequest?
        if let hostController,
           let hostRootKey,
           sparesByRootKey[hostRootKey] != nil,
           Self.spareCanServe(WorkspaceWindowLaunchStore.shared.peekNextWindowRequest(), rootKey: hostRootKey),
           let spare = sparesByRootKey.removeValue(forKey: hostRootKey) {
            claimedRequest = WorkspaceWindowLaunchStore.shared.claimNextWindowRequest()
            if let controller = adoptSpare(spare, host: hostController, request: claimedRequest) {
                return controller
            }
            // The spare was unusable (its window went away); fall through.
        }

        PerformanceDiagnostics.markPendingNewTab("coordinator.spareBypassed", metadata: [
            "available": hostRootKey.flatMap { sparesByRootKey[$0] } == nil ? "false" : "true",
            "hasDocuments": WorkspaceWindowLaunchStore.shared.peekNextWindowRequest()?.documents.isEmpty == false ? "true" : "false"
        ])
        let request = claimedRequest ?? WorkspaceWindowLaunchStore.shared.claimNextWindowRequest()
        return createController(
            request: request,
            restoredState: nil,
            tabbingWith: hostController,
            sharedNotesModel: sharedNotesModel,
            sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry,
            warmsSpareAfterOpen: true
        )
    }

    func reopenWorkspace() {
        if let controller = lastActiveController ?? controllers.values.first {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
    }

    func noteBecameKey(_ controller: WorkspaceWindowController) {
        lastActiveController = controller
    }

    func windowDidClose(_ controller: WorkspaceWindowController) {
        let identifier = ObjectIdentifier(controller)
        if lastActiveController === controller {
            lastActiveController = controllers.values.first { $0 !== controller }
        }
        if let rootKey = controller.projectRootKey,
           !controllers.values.contains(where: { $0 !== controller && $0.projectRootKey == rootKey }) {
            // The last tab of this project root is going away; its warm spare
            // has nothing left to join.
            discardSpare(forRootKey: rootKey)
        }
        DispatchQueue.main.async { [weak self] in
            self?.controllers.removeValue(forKey: identifier)
        }
    }

    /// Closes every pre-warmed window. Called before termination so a spare
    /// never reaches the session store or AppKit's window list teardown.
    func discardSpareWindows() {
        let spares = sparesByRootKey.values
        sparesByRootKey.removeAll()
        for spare in spares {
            spare.controller.window?.close()
        }
    }

    func controller(for window: NSWindow) -> WorkspaceWindowController? {
        controllers.values.first { $0.window === window }
    }

    // MARK: - Window creation

    @discardableResult
    private func createController(
        request: WorkspaceWindowLaunchStore.WindowRequest?,
        restoredState: PersistedWorkspaceWindowState?,
        tabbingWith hostController: WorkspaceWindowController?,
        sharedNotesModel: NotesWorkspaceModel? = nil,
        sharedWorkspaceTabControllerRegistry: WorkspaceTabControllerRegistry? = nil,
        warmsSpareAfterOpen: Bool = false
    ) -> WorkspaceWindowController {
        let hostWindow = hostController?.window
        let contentSize = hostWindow?.contentLayoutRect.size ?? NSSize(width: 1200, height: 760)
        // A tab opened from the tab bar's "+" carries no request; it inherits
        // the host window's project so the shared model registry hits.
        let projectRootPath = request?.projectRootPath
            ?? restoredState?.rootPath
            ?? hostController.flatMap(Self.projectRootPath(ofHost:))
        let window = Self.makeWorkspaceWindow(contentSize: contentSize)
        if hostController != nil {
            PerformanceDiagnostics.bindPendingNewTab(to: window)
            PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.windowAllocated")
        }
        window.title = request?.documents.first?.tabPresentation.title
            ?? request?.initialTabState?.openedDocument?.tabPresentation.title
            ?? restoredState.flatMap(Self.restoredTitle)
            ?? "nvModern"
        if let hostWindow {
            window.setFrame(hostWindow.frame, display: false)
        }
        #if DEBUG
        print("[NVModern][Coordinator] createController host=\(hostWindow?.windowNumber.description ?? "none") hostFrame=\(hostWindow?.frame.debugDescription ?? "-") hostContentLayout=\(hostWindow?.contentLayoutRect.debugDescription ?? "-") newFrame=\(window.frame.debugDescription) restored=\(restoredState != nil)")
        #endif

        let controller = WorkspaceWindowController(window: window, coordinator: self)
        controller.projectRootKey = Self.rootKey(for: projectRootPath)
        controllers[ObjectIdentifier(controller)] = controller

        // The toolbar is AppKit-owned (see `NativeWorkspaceToolbarController`);
        // only the navigation title is bridged from SwiftUI. Bridging
        // `.toolbars` rebuilt every item on each key-window change.
        let toolbarController = Self.makeToolbarController()
        controller.toolbarController = toolbarController
        toolbarController?.attach(to: window)

        let installContent = {
            let rootView = NativeWorkspaceWindowView(
                initialRestoredWindowState: restoredState,
                initialSidebarVisible: hostWindow.flatMap {
                    WorkspaceActionRouter.runtime(for: $0.windowNumber)?.isSidebarVisible
                },
                initialProjectRootPath: projectRootPath,
                initialPendingDocuments: request?.documents ?? [],
                initialPendingJump: request?.pendingJump,
                initialTabState: request?.initialTabState,
                isRequestedOrRestoredWindow: true,
                sharedNotesModel: sharedNotesModel,
                sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry,
                toolbarController: toolbarController,
                performanceWindow: window
            )
            window.contentView = Self.makeHostingView(rootView: rootView, contentSize: contentSize)
            PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.contentInstalled")
        }

        guard let hostWindow else {
            // First window of a group (launch / restore): nothing is on screen
            // to keep responsive, so build synchronously and order in once.
            installContent()
            if restoredState?.frame == nil {
                window.center()
            }
            Self.activateAppIfNeeded()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            scheduleSpareWindow(
                hostController: controller,
                sharedNotesModel: sharedNotesModel,
                sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry
            )
            return controller
        }

        // Build the first tab offscreen with its final sidebar visibility. A
        // placeholder rendered as an all-columns split for one frame, so the
        // first Cmd-T appeared to open the sidebar and immediately close it.
        installContent()
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.layout.begin")
        window.contentView?.layoutSubtreeIfNeeded()
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.layout.end")
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.addTabbedWindow.begin")
        hostWindow.addTabbedWindow(window, ordered: .above)
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.addTabbedWindow.end")

        Self.activateAppIfNeeded()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.makeKeyAndOrderFront.returned")

        DispatchQueue.main.async { [weak self] in
            PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.nextRunLoop")
            DispatchQueue.main.async {
                PerformanceDiagnostics.finishNewTab(window: window, event: "coordinator.secondRunLoop")
                guard warmsSpareAfterOpen, let self, let hostController else { return }
                self.scheduleSpareWindow(
                    hostController: hostController,
                    sharedNotesModel: sharedNotesModel,
                    sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry
                )
            }
        }
        return controller
    }

    // MARK: - Warm spare

    /// Give the opening/restored tab its first frames before spending main-
    /// thread time on the next spare. Resolve the root after runtime registration
    /// so the initial default-project window warms the actual project's spare.
    private func scheduleSpareWindow(
        hostController: WorkspaceWindowController,
        sharedNotesModel: NotesWorkspaceModel?,
        sharedWorkspaceTabControllerRegistry: WorkspaceTabControllerRegistry?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak hostController] in
            guard let self, let hostController,
                  self.controllers[ObjectIdentifier(hostController)] != nil else { return }
            let root = Self.projectRootPath(ofHost: hostController)
            hostController.projectRootKey = Self.rootKey(for: root)
            self.prepareSpareWindow(
                hostController: hostController,
                projectRootPath: root,
                sharedNotesModel: sharedNotesModel,
                sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry
            )
        }
    }

    /// Builds one launchpad window and starts its text web bundle offscreen.
    /// Both empty and document tabs reuse it; it is never ordered in here.
    private func prepareSpareWindow(
        hostController: WorkspaceWindowController,
        projectRootPath: String?,
        sharedNotesModel: NotesWorkspaceModel?,
        sharedWorkspaceTabControllerRegistry: WorkspaceTabControllerRegistry?
    ) {
        guard !Self.disablesSpareWindows else { return }
        let rootKey = Self.rootKey(for: projectRootPath)
        guard sparesByRootKey[rootKey] == nil else { return }
        guard let hostWindow = hostController.window, hostWindow.isVisible else { return }

        let contentSize = hostWindow.contentLayoutRect.size
        guard contentSize.width > 1, contentSize.height > 1 else { return }

        let window = Self.makeWorkspaceWindow(contentSize: contentSize)
        window.title = "nvModern"
        window.setFrame(hostWindow.frame, display: false)

        let controller = WorkspaceWindowController(window: window, coordinator: self)
        controller.projectRootKey = rootKey

        let toolbarController = Self.makeToolbarController()
        controller.toolbarController = toolbarController
        toolbarController?.attach(to: window)

        let activationGate = WorkspaceWindowActivationGate(isActivated: false)
        let rootView = NativeWorkspaceWindowView(
            initialSidebarVisible: WorkspaceActionRouter.runtime(for: hostWindow.windowNumber)?.isSidebarVisible,
            initialProjectRootPath: projectRootPath,
            isRequestedOrRestoredWindow: true,
            activationGate: activationGate,
            sharedNotesModel: sharedNotesModel,
            sharedWorkspaceTabControllerRegistry: sharedWorkspaceTabControllerRegistry,
            toolbarController: toolbarController
        )
        let hostingView = Self.makeHostingView(rootView: rootView, contentSize: contentSize)
        window.contentView = hostingView
        // Pay the NavigationSplitView / sidebar layout here, offscreen. Never
        // order the window in: that is what the tab-group join is for.
        hostingView.layoutSubtreeIfNeeded()

        sparesByRootKey[rootKey] = SpareWindow(
            controller: controller,
            activationGate: activationGate,
            projectRootPath: projectRootPath
        )
        PerformanceDiagnostics.background(
            kind: "new-tab",
            event: "coordinator.spareCreated",
            metadata: ["root": rootKey, "window": String(window.windowNumber)]
        )
    }

    /// Joins an already-built spare to the host's tab group.
    private func adoptSpare(
        _ spare: SpareWindow,
        host hostController: WorkspaceWindowController,
        request: WorkspaceWindowLaunchStore.WindowRequest?
    ) -> WorkspaceWindowController? {
        guard let hostWindow = hostController.window,
              let window = spare.controller.window else {
            return nil
        }

        PerformanceDiagnostics.bindPendingNewTab(to: window)
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.spareUsed")

        // The gate must open before the window resolves as key, so the window
        // registers its action runtime and starts persisting as a real tab.
        spare.activationGate.activate(
            sidebarVisible: WorkspaceActionRouter.runtime(for: hostWindow.windowNumber)?.isSidebarVisible,
            request: request,
            window: window
        )
        if window.frame != hostWindow.frame {
            window.setFrame(hostWindow.frame, display: false)
        }
        controllers[ObjectIdentifier(spare.controller)] = spare.controller
        window.title = request?.documents.first?.tabPresentation.title ?? "nvModern"

        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.addTabbedWindow.begin")
        hostWindow.addTabbedWindow(window, ordered: .above)
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.addTabbedWindow.end")

        Self.activateAppIfNeeded()
        spare.controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.makeKeyAndOrderFront.returned")

        DispatchQueue.main.async { [weak self] in
            PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.nextRunLoop")
            DispatchQueue.main.async {
                PerformanceDiagnostics.finishNewTab(window: window, event: "coordinator.secondRunLoop")
                self?.scheduleSpareWindow(
                    hostController: spare.controller,
                    sharedNotesModel: nil,
                    sharedWorkspaceTabControllerRegistry: nil
                )
            }
        }
        return spare.controller
    }

    private func discardSpare(forRootKey rootKey: String) {
        guard let spare = sparesByRootKey.removeValue(forKey: rootKey) else { return }
        spare.controller.window?.close()
    }

    /// Plain launchpads and a single document can use the activation handoff.
    /// Jumps and copied/restored state keep their existing cold path.
    static func spareCanServe(
        _ request: WorkspaceWindowLaunchStore.WindowRequest?,
        rootKey: String
    ) -> Bool {
        guard let request else { return true }
        guard request.documents.count <= 1,
              request.pendingJump == nil,
              request.initialTabState == nil else {
            return false
        }
        return Self.rootKey(for: request.projectRootPath) == rootKey
    }

    // MARK: - Window plumbing

    private static func makeWorkspaceWindow(contentSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        NativeWindowConfigurator.configure(window)
        window.tabbingIdentifier = "nvmodern.workspace"
        return window
    }

    private static func makeToolbarController() -> NativeWorkspaceToolbarController? {
        disablesToolbarForPerformanceTesting ? nil : NativeWorkspaceToolbarController()
    }

    private static func makeHostingView(
        rootView: NativeWorkspaceWindowView,
        contentSize: NSSize
    ) -> NSHostingView<AnyView> {
        let hostingView = NSHostingView(rootView: AnyView(rootView))
        hostingView.sceneBridgingOptions = [.title]
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        return hostingView
    }

    /// Stand-in content for the first frames of a new tab: opaque, in the
    /// window background color, and free of constraints, so the layout passes
    /// AppKit forces during the tab join cost nothing.
    private static func makePlaceholderContentView(size: NSSize) -> NSView {
        let view = PlaceholderContentView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    private static func activateAppIfNeeded() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func projectRootPath(ofHost controller: WorkspaceWindowController) -> String? {
        guard let window = controller.window else { return nil }
        return WorkspaceActionRouter.runtime(for: window.windowNumber)?.projectRootPath
    }

    private static func rootKey(for projectRootPath: String?) -> String {
        projectRootPath ?? defaultProjectRootKey
    }

    private static func restoredTitle(_ state: PersistedWorkspaceWindowState) -> String? {
        guard !state.tabs.isEmpty else { return nil }
        let index = max(0, min(state.selectedTabIndex, state.tabs.count - 1))
        return state.tabs[index].title
    }
}

private final class PlaceholderContentView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private weak var workspaceCoordinator: WorkspaceApplicationCoordinator?
    /// Retained here: `NSWindow.toolbar` keeps the toolbar, but the toolbar
    /// only holds its delegate weakly.
    var toolbarController: NativeWorkspaceToolbarController?
    /// Which project root this window's tab belongs to; the coordinator keys
    /// warm spares by the same value.
    var projectRootKey: String?

    init(window: NSWindow, coordinator: WorkspaceApplicationCoordinator) {
        workspaceCoordinator = coordinator
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func newWindowForTab(_ sender: Any?) {
        PerformanceDiagnostics.beginNewTab(
            trigger: "native-tab-bar-button",
            requestedWindowNumber: window?.windowNumber
        )
        workspaceCoordinator?.openTab(relativeTo: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspaceCoordinator?.noteBecameKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        workspaceCoordinator?.windowDidClose(self)
    }
}
