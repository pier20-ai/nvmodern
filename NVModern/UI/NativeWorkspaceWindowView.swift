import AppKit
import SwiftUI

/// Native-shell experiment: one window == one tab.
///
/// The old `WorkspaceView` hosted a Bonsplit tab/split tree inside a custom
/// transparent titlebar. This shell replaces that stack with macOS idioms:
///
/// - `NavigationSplitView` hosts the workspace sidebar and the tab content.
/// - AppKit window tabbing (`tabbingPreference = .preferred`) provides the tab
///   bar, so "new tab" opens a new window that joins the key window's tab
///   group. Splits do not exist in this model.
/// - The breadcrumb/history/find/palette affordances of the old omnibox chrome
///   live in an AppKit toolbar owned by the window controller
///   (`NativeWorkspaceToolbarController`); this view only installs the
///   handlers. The open path lives in a Finder-style bottom status bar.
/// - The document navigator and inspector render in a native resizable content
///   split, hosted by `TabWorkspaceView` below AppKit's window tab bar.
///
/// Everything below the chrome is reused from the old shell: the single
/// `WorkspaceTabController` owns the same content runtimes, and
/// `TabWorkspaceView` renders the same launchpad/note surfaces.
@MainActor
struct NativeWorkspaceWindowView: View {
    let initialRestoredWindowState: PersistedWorkspaceWindowState?
    let initialProjectRootPath: String?
    let initialPendingDocuments: [WorkspaceOpenedDocument]
    let initialPendingJump: PendingMarkdownJump?
    let initialTabState: WorkspaceTabState?
    let isRequestedOrRestoredWindow: Bool
    let shouldCloseUnrequestedWindow: Bool
    /// Set only for a pre-warmed spare window, which is fully built but never
    /// ordered in. Until the coordinator opens the gate this window must not
    /// register an action runtime or persist itself as a session tab.
    let activationGate: WorkspaceWindowActivationGate?
    /// Window-owned AppKit toolbar; nil when the toolbar is disabled.
    let toolbarController: NativeWorkspaceToolbarController?

    private var isWindowActivated: Bool {
        activationGate?.isActivated ?? true
    }

    @StateObject private var notesModel: NotesWorkspaceModel
    @StateObject private var workspaceTabControllerRegistry: WorkspaceTabControllerRegistry
    @StateObject private var tabController: WorkspaceTabController
    @StateObject private var openDocumentPathRegistry = WorkspaceOpenDocumentPathRegistry()
    @StateObject private var paletteHost = WorkspacePaletteHost()
    @State private var tabID: TabID
    @State private var tabState: WorkspaceTabState
    @State private var columnVisibility: NavigationSplitViewVisibility
    @StateObject private var sidebarState: WorkspaceSidebarState
    @State private var didInitializeWindowState = false
    @State private var registeredWindowNumber: Int?
    @State private var currentWindowFrame: CGRect?
    @State private var pendingRestoredWindowFrame: CGRect?
    @State private var didApplyRestoredWindowFrame = false
    @State private var isWindowKey = false
    /// The visible document's page colour, which the window chrome takes when
    /// `window_tint` is on.
    @State private var chromeTint: NSColor?
    @State private var isWindowClosing = false
    @State private var lastPersistedWindowState: PersistedWorkspaceWindowState?
    @State private var actionWindowID = UUID().uuidString
    @State private var actionWorkspaceID = UUID().uuidString
    @State private var actionTabID = UUID().uuidString
    @State private var locallyInitiatedRenames: [String: String] = [:]
    @State private var locallyTrashedWorkspacePaths: Set<String> = []
    @State private var diffOriginalSource: WorkspaceDiffSource?
    @State private var didOpenInitialPendingDocuments = false
    @State private var sidebarWidth: CGFloat
    @State private var sidebarExpandedFolderPaths: Set<String>
    @State private var sidebarFocusedRootPath: String?
    @StateObject private var deferredActions = WorkspaceViewDeferredActions()

    private static let windowStatePersistenceDebounce: TimeInterval = 0.18
    /// The SwiftUI toolbar's own sidebar toggle animated the column; the
    /// AppKit toolbar and menu paths set `columnVisibility` directly, so
    /// they wrap the change in this animation to keep the slide.
    private static let sidebarAnimation = Animation.easeInOut(duration: 0.25)
    private static let defaultSidebarWidth: CGFloat = 288
    /// `surface` reported by editor-context queries (MCP `get_context`,
    /// `get_selection`). Kept stable for existing automation clients.
    private static let primaryEditorSurface = "primary"

    init(
        initialRestoredWindowState: PersistedWorkspaceWindowState? = nil,
        initialSidebarVisible: Bool? = nil,
        initialProjectRootPath: String? = nil,
        initialPendingDocuments: [WorkspaceOpenedDocument] = [],
        initialPendingJump: PendingMarkdownJump? = nil,
        initialTabState: WorkspaceTabState? = nil,
        isRequestedOrRestoredWindow: Bool = false,
        shouldCloseUnrequestedWindow: Bool = false,
        activationGate: WorkspaceWindowActivationGate? = nil,
        sharedNotesModel: NotesWorkspaceModel? = nil,
        sharedWorkspaceTabControllerRegistry: WorkspaceTabControllerRegistry? = nil,
        toolbarController: NativeWorkspaceToolbarController? = nil,
        performanceWindow: NSWindow? = nil
    ) {
        self.initialRestoredWindowState = initialRestoredWindowState
        let resolvedInitialProjectRootPath = initialProjectRootPath ?? initialRestoredWindowState?.rootPath
        self.initialProjectRootPath = resolvedInitialProjectRootPath
        self.initialPendingDocuments = initialPendingDocuments
        self.initialPendingJump = initialPendingJump
        self.initialTabState = initialTabState
        self.isRequestedOrRestoredWindow = isRequestedOrRestoredWindow
        self.shouldCloseUnrequestedWindow = shouldCloseUnrequestedWindow
        self.activationGate = activationGate
        self.toolbarController = toolbarController

        let model = sharedNotesModel
            ?? NotesWorkspaceModelRegistry.shared.model(
                projectRootPath: resolvedInitialProjectRootPath
            )
        let initialRuntimeConfig = model.runtimeConfig
        let registry = sharedWorkspaceTabControllerRegistry
            ?? WorkspaceTabControllerRegistry.nativeShellShared(
                at: initialRuntimeConfig.rootURL
            )
        let controller = WorkspaceTabController(
            tabID: TabID(),
            arborKernelSupervisor: registry.arborKernelSupervisor
        )
        if let performanceWindow {
            PerformanceDiagnostics.associateNewTab(controller.tabID, with: performanceWindow)
        }
        if activationGate != nil {
            controller.textContent.prepare(rootURL: initialRuntimeConfig.rootURL).prewarm()
        }
        let restoredTabState = initialRestoredWindowState.flatMap(Self.restoredTabState(from:))

        _notesModel = StateObject(wrappedValue: model)
        _workspaceTabControllerRegistry = StateObject(wrappedValue: registry)
        _tabController = StateObject(wrappedValue: controller)
        _tabID = State(initialValue: controller.tabID)
        _tabState = State(
            initialValue: restoredTabState ?? initialTabState ?? WorkspaceTabState(
                kind: .launchpad,
                selectedFolderChain: [],
                selectedNotePath: nil,
                openedDocument: nil,
                documentInspectorSettings: initialRuntimeConfig.defaultDocumentInspectorSettings,
                millerActiveDepth: 0,
                activeMillerItemPath: nil,
                backHistory: [],
                forwardHistory: [],
                historyCurrentItem: nil
            )
        )
        let isSidebarVisible = initialRestoredWindowState?.isSidebarVisible ?? initialSidebarVisible ?? true
        _columnVisibility = State(initialValue: isSidebarVisible ? .all : .detailOnly)
        _sidebarState = StateObject(wrappedValue: WorkspaceSidebarState(isVisible: isSidebarVisible))
        _pendingRestoredWindowFrame = State(initialValue: initialRestoredWindowState?.frame?.cgRect)
        _sidebarWidth = State(
            initialValue: CGFloat(initialRestoredWindowState?.sidebarWidth ?? Double(Self.defaultSidebarWidth))
        )
        _sidebarExpandedFolderPaths = State(
            initialValue: Set(initialRestoredWindowState?.sidebarExpandedFolderPaths ?? [])
        )
        _sidebarFocusedRootPath = State(initialValue: initialRestoredWindowState?.sidebarFocusedRootPath)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarView(
                notesModel: notesModel,
                expandedFolderPaths: $sidebarExpandedFolderPaths,
                focusedRootPath: sidebarFocusedRootPath,
                selectedDocumentPath: sidebarSelectedDocumentPath,
                onSetFocusedRoot: setSidebarFocusedRoot,
                onOpenDocument: openSidebarDocument,
                onBrowseInColumns: browseFolderInMiller,
                onCreateNoteInFolder: { relativePath in
                    presentNewNotePanel(inFolderRelativePath: relativePath)
                },
            )
            .navigationSplitViewColumnWidth(
                min: 220,
                ideal: sidebarWidth,
                max: 420
            )
        } detail: {
            TabWorkspaceView(
                tabID: tabID,
                state: $tabState,
                notesModel: notesModel,
                workspaceTabController: tabController,
                openDocumentPathRegistry: openDocumentPathRegistry,
                paletteHost: paletteHost,
                onTabPresentationChange: { _ in
                    scheduleWindowStatePersistence()
                },
                onCloseTabRequest: { _ in
                    closeCurrentWindow()
                },
                onWorkspaceItemRenamed: { oldPath, newPath, kind in
                    registerLocallyRenamedWorkspaceItem(from: oldPath, to: newPath, kind: kind)
                },
                onWorkspaceItemTrashed: { relativePath, kind in
                    handleLocallyTrashedWorkspaceItem(relativePath: relativePath, kind: kind)
                },
                onCreateNote: { folderRelativePath in
                    presentNewNotePanel(inFolderRelativePath: folderRelativePath)
                },
                isControllerFocusedLeaf: isWindowKey,
                onLeafInteraction: {
                    makeWindowKey()
                },
                omitsHeaderChrome: true,
                onChromeTintChange: { tint in
                    chromeTint = tint
                    applyChromeTint()
                }
            )
        }
        .navigationTitle(windowTitle)
        .overlay {
            WorkspacePaletteOverlay(host: paletteHost)
        }
        .background(
            WindowAccessor(
                onResolve: { window in
                    guard !isWindowClosing else { return }

                    let existingWorkspaceWindowNumber =
                        WorkspaceActionRouter.runtime(for: nil)?.windowNumber
                    let hasDifferentWorkspaceWindow =
                        existingWorkspaceWindowNumber != nil
                        && existingWorkspaceWindowNumber != window.windowNumber
                    let shouldCloseResolvedWindow =
                        shouldCloseUnrequestedWindow
                        || (!isRequestedOrRestoredWindow && hasDifferentWorkspaceWindow)

                    if shouldCloseResolvedWindow {
                        WorkspaceActionRouter.markUnrequestedWorkspaceWindow(window.windowNumber)
                        isWindowClosing = true
                        window.orderOut(nil)
                        window.close()
                        return
                    }

                    // A pre-warmed spare resolves its window while ordered
                    // out; it becomes a real tab only once the coordinator
                    // hands it to a tab group.
                    guard isWindowActivated else { return }

                    syncWindowActivation(window)
                    registerActionsIfNeeded(for: window)
                    applyChromeTint(to: window)
                    if window.isKeyWindow || window.isMainWindow {
                        WorkspaceActionRouter.markWindowActive(window.windowNumber)
                        isWindowKey = true
                    }
                    restoreWindowFrameIfNeeded(window)

                    currentWindowFrame = window.frame
                    scheduleWindowStatePersistence()
                },
                onAttaching: { window in
                    guard !isWindowClosing else { return }
                    PerformanceDiagnostics.markNewTab(window: window, event: "windowAccessor.onAttaching")
                    NativeWindowConfigurator.configure(window)
                },
                onDidBecomeKey: { window in
                    syncWindowActivation(window)
                    if !isWindowKey {
                        isWindowKey = true
                        tabController.setIsFocusedLeaf(true)
                    }
                    WorkspaceActionRouter.markWindowActive(window.windowNumber)
                },
                onDidResignKey: { window in
                    // App deactivation resigns the key window before its
                    // visibility transition completes. Preserve the selected
                    // tab's live focus graph across Cmd-Tab; only deactivate it
                    // when another nvModern window becomes key.
                    DispatchQueue.main.async {
                        // The window can be key again by the time this runs
                        // (tab regrouping at launch flips it back and forth);
                        // clearing then would leave the visible tab unfocused.
                        guard NSApp.isActive, !window.isKeyWindow else { return }
                        isWindowKey = false
                        tabController.setIsFocusedLeaf(false)
                    }
                },
                onWillClose: { window in
                    handleWindowWillClose(window)
                },
                onFirstDraw: { window in
                    PerformanceDiagnostics.markNewTab(window: window, event: "content.firstDraw")
                }
            )
        )
        .onAppear {
            guard !shouldCloseUnrequestedWindow else {
                return
            }
            if !isWindowActivated {
                activationGate?.onActivate = { window in
                    syncWindowActivation(window)
                }
            }
            syncOpenDocumentPathRegistry()
            installToolbarHandlers()
            tabController.setIsFocusedLeaf(isWindowKey)
            openInitialPendingDocumentsIfNeeded()
            sanitizeSidebarState()
            ensureSidebarTracksFocusedTab()
        }
        .onDisappear {
            unregisterActions()
            flushScheduledWindowStatePersistence()
        }
        .task {
            workspaceTabControllerRegistry.startAttachmentGC(
                at: notesModel.runtimeConfig.rootURL
            )
        }
        .onChange(of: notesModel.runtimeConfig.documentDefaults.tintsWindow) { _, _ in
            applyChromeTint()
        }
        .task(id: notesModel.runtimeConfig.rootURL.path) {
            await workspaceTabControllerRegistry.indexArborWorkspace(
                at: notesModel.runtimeConfig.rootURL
            )
        }
        .onChange(of: tabState) { _, _ in
            scheduleWindowStatePersistence()
            syncOpenDocumentPathRegistry()
            ensureSidebarTracksFocusedTab()
        }
        .onChange(of: columnVisibility) { _, _ in
            sidebarState.setVisible(columnVisibility != .detailOnly)
            scheduleWindowStatePersistence()
        }
        .onChange(of: tabController.canNavigateBack) { _, _ in
            toolbarController?.revalidate()
        }
        .onChange(of: tabController.canNavigateForward) { _, _ in
            toolbarController?.revalidate()
        }
        .onChange(of: sidebarExpandedFolderPaths) { _, _ in
            scheduleWindowStatePersistence()
        }
        .onChange(of: sidebarFocusedRootPath) { _, _ in
            scheduleWindowStatePersistence()
        }
        .onChange(of: notesModel.liveUpdateRevision) { _, _ in
            applyLatestLiveSyncUpdateIfNeeded()
        }
        .onChange(of: notesModel.lastReloadDate) { _, _ in
            sanitizeSidebarState()
            ensureSidebarTracksFocusedTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nvModernConfigDidChange)) { _ in
            // Config edits don't touch the file tree; a full rescan here used
            // to put a synchronous iCloud walk on the main thread. The model
            // still schedules a scan itself if the project root changed.
            notesModel.reloadConfiguration()
        }
    }

    private func syncWindowActivation(_ window: NSWindow) {
        PerformanceDiagnostics.associateNewTab(tabID, with: window)
        if let isVisible = activationGate?.consumeSidebarVisibility() {
            sidebarState.setVisible(isVisible)
            columnVisibility = isVisible ? .all : .detailOnly
        }
        guard let request = activationGate?.consumeRequest() else { return }
        PerformanceDiagnostics.markNewTab(window: window, event: "coordinator.spareRequestDelivered", metadata: [
            "textEditorReady": String(tabController.existingTextEditorController?.isBridgeReady == true)
        ])
        if let document = request.documents.first {
            tabState.navigate(to: document)
            recordRecentDocument(document)
        }
    }

    // MARK: - Chrome

    private var windowTitle: String {
        return tabState.openedDocument?.tabPresentation.title ?? "nvModern"
    }

    /// The toolbar is a plain `NSToolbar` on the window. Its items call these
    /// closures, and back/forward enablement is read through them at
    /// validation time, so nothing here re-renders on key-window changes.
    private func installToolbarHandlers() {
        guard let toolbarController else { return }
        toolbarController.handlers = NativeWorkspaceToolbarController.Handlers(
            toggleSidebar: {
                let isVisible = sidebarState.isVisible
                sidebarState.setVisible(!isVisible)
                withAnimation(Self.sidebarAnimation) {
                    columnVisibility = isVisible ? .detailOnly : .all
                }
                if !isVisible {
                    ensureSidebarTracksFocusedTab()
                }
            },
            goBack: { tabController.navigateBackInHistory() },
            goForward: { tabController.navigateForwardInHistory() },
            canGoBack: { tabController.canNavigateBack },
            canGoForward: { tabController.canNavigateForward },
            newNote: { presentNewNotePanel(inFolderRelativePath: nil) },
            toggleInspector: { requestInspector() },
            search: { requestPalette(.root) }
        )
        toolbarController.revalidate()
    }

    // MARK: - Palette / navigator / inspector requests

    private func requestPalette(_ preset: PalettePreset) {
        guard let windowNumber = registeredWindowNumber else { return }
        WorkspaceMenuCommands.openPalette(preset, windowNumber: windowNumber)
    }

    private func requestDocumentFind() {
        guard let windowNumber = registeredWindowNumber else { return }
        NotificationCenter.default.post(
            name: .documentFindOpenRequested,
            object: nil,
            userInfo: [DocumentNavigatorNotification.windowNumberKey: windowNumber]
        )
    }

    private func requestInspector() {
        guard let windowNumber = registeredWindowNumber else { return }
        NotificationCenter.default.post(
            name: .documentInspectorOpenRequested,
            object: nil,
            userInfo: [DocumentInspectorNotification.windowNumberKey: windowNumber]
        )
    }

    // MARK: - Open document registry

    private var sidebarSelectedDocumentPath: String? {
        guard case .workspaceNote(let relativePath)? = tabState.openedDocument else {
            return nil
        }
        return relativePath
    }

    private func syncOpenDocumentPathRegistry() {
        if case .workspaceNote(let relativePath)? = tabState.openedDocument {
            openDocumentPathRegistry.entries = [
                WorkspaceOpenDocumentPathEntry(
                    tabID: actionTabID,
                    relativePath: relativePath,
                    title: tabState.openedDocument?.tabPresentation.title ?? relativePath
                )
            ]
            openDocumentPathRegistry.documentsByTabID = [tabID: tabState.openedDocument!]
        } else {
            openDocumentPathRegistry.entries = []
            openDocumentPathRegistry.documentsByTabID = [:]
        }
    }

    // MARK: - Window helpers

    /// Like Safari's coloured tab bar: the titlebar and toolbar take the
    /// document's page colour, and the native tab bar's glass picks it up.
    /// Each tab is its own window, so the active tab's colour fills the
    /// chrome as tabs switch.
    private func applyChromeTint(to window: NSWindow? = nil) {
        guard let window = window ?? resolvedWindow() else { return }
        let tint = notesModel.runtimeConfig.documentDefaults.tintsWindow ? chromeTint : nil
        let color = tint ?? .windowBackgroundColor
        if window.backgroundColor != color {
            window.backgroundColor = color
        }
        NativeWindowConfigurator.setTabBarTint(tint, for: window)
    }

    private func resolvedWindow() -> NSWindow? {
        guard let windowNumber = registeredWindowNumber else { return nil }
        return NSApp.windows.first { $0.windowNumber == windowNumber }
    }

    private func makeWindowKey() {
        guard let window = resolvedWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeCurrentWindow() {
        guard let window = resolvedWindow() else { return }
        window.performClose(nil)
    }

    /// Native tabs are windows: "open a new tab" enqueues an explicit window
    /// request (so the launch wrapper does not treat it as an unrequested
    /// phantom window) and asks SwiftUI for a new window, which joins the key
    /// window's tab group via `tabbingPreference`.
    private func openNewNativeTab(
        documents: [WorkspaceOpenedDocument] = [],
        pendingJump: PendingMarkdownJump? = nil,
        initialTabState: WorkspaceTabState? = nil
    ) {
        PerformanceDiagnostics.ensureNewTab(
            trigger: documents.isEmpty ? "runtime.newTab" : "runtime.openDocument",
            requestedWindowNumber: resolvedWindow()?.windowNumber,
            waitsForDocument: !documents.isEmpty,
            documentPath: documents.first?.editorPath
        )
        PerformanceDiagnostics.markPendingNewTab("runtime.openNewNativeTab")
        for document in documents {
            recordRecentDocument(document)
        }
        WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(
            projectRootPath: notesModel.runtimeConfig.rootURL.path,
            documents: documents,
            pendingJump: pendingJump,
            initialTabState: initialTabState
        )
        PerformanceDiagnostics.markPendingNewTab("runtime.requestEnqueued")
        WorkspaceApplicationCoordinator.shared.openTab(
            relativeTo: resolvedWindow(),
            sharedNotesModel: notesModel,
            sharedWorkspaceTabControllerRegistry: workspaceTabControllerRegistry
        )
    }

    // MARK: - Action runtime

    private func registerActionsIfNeeded(for window: NSWindow) {
        let windowNumber = window.windowNumber
        guard registeredWindowNumber != windowNumber else { return }

        if let registeredWindowNumber {
            WorkspaceActionRouter.unregister(windowNumber: registeredWindowNumber)
        }

        let runtime = ClosureWorkspaceActionRuntime(
            windowNumber: windowNumber,
            windowID: actionWindowID,
            workspaceID: actionWorkspaceID,
            projectRootPathProvider: { notesModel.runtimeConfig.rootURL.path },
            orderedTabIDsProvider: { [self.actionTabID] },
            selectedTabIDProvider: { self.actionTabID },
            closeCurrentTab: closeCurrentWindow,
            newTab: { openNewNativeTab() },
            splitHorizontally: { NSSound.beep() },
            splitVertically: { NSSound.beep() },
            focusPreviousSplit: { NSSound.beep() },
            focusNextSplit: { NSSound.beep() },
            selectTab: { publicID in
                guard publicID == self.actionTabID else { return false }
                makeWindowKey()
                return true
            },
            selectPreviousTab: {
                self.resolvedWindow()?.selectPreviousTab(nil)
            },
            selectNextTab: {
                self.resolvedWindow()?.selectNextTab(nil)
            },
            sidebarVisibleProvider: { sidebarState.isVisible },
            setSidebarVisible: { isVisible in
                sidebarState.setVisible(isVisible)
                withAnimation(Self.sidebarAnimation) {
                    columnVisibility = isVisible ? .all : .detailOnly
                }
                if isVisible {
                    ensureSidebarTracksFocusedTab()
                }
            },
            cycleTabSwitcher: { _ in false },
            commitTabSwitcher: { false },
            cancelTabSwitcher: { false },
            duplicateCurrentTab: {
                openNewNativeTab(initialTabState: tabState)
            },
            showAllTabs: {
                // `toggleTabOverview(_:)` is a no-op while
                // `allowsAutomaticWindowTabbing` is off; the tab group's
                // overview flag still drives the same AppKit grid.
                guard let tabGroup = self.resolvedWindow()?.tabGroup else { return }
                tabGroup.isOverviewVisible.toggle()
            },
            presentNewNotePanel: presentNewNotePanel,
            focusDocument: focusDocument,
            openDocument: openDocument,
            showInParentFolder: { relativePath, selectDocument in
                tabController.showInParentFolder(
                    relativePath: relativePath,
                    selectDocument: selectDocument
                )
            },
            revealCurrentDocumentInFinder: revealCurrentDocumentInFinder,
            copyCurrentDocumentLink: copyCurrentDocumentLink,
            duplicateCurrentWorkspaceNote: duplicateCurrentWorkspaceNote,
            refileCurrentWorkspaceNote: refileCurrentWorkspaceNote,
            refileWorkspaceNote: refileWorkspaceNote(relativePath:toFolderRelativePath:),
            renameWorkspaceItem: renameWorkspaceItem(relativePath:to:),
            reloadCurrentDocumentFromDisk: {
                tabState.liveLocalRefreshRevision += 1
                tabState.liveDiskReloadRevision += 1
                return true
            },
            currentDocumentSnapshot: currentActionDocumentSnapshot,
            currentEditorCommandTargetSnapshot: {
                tabController.currentEditorCommandTargetSnapshot()
            },
            currentProjectSnapshot: {
                let project = notesModel.runtimeConfig.activeProject
                return WorkspaceActionProjectSnapshot(
                    name: project.name,
                    rootPath: project.rootURL.path
                )
            },
            listTabs: actionTabSnapshots,
            queryEditorContext: queryActionEditorContext,
            currentDiffOriginalSource: { diffOriginalSource },
            setCurrentDiffOriginalSource: { diffOriginalSource = $0 },
            replaceCurrentEditorSelection: { tabController.replaceCurrentSelection(with: $0) },
            toggleCurrentEditorSelectionHighlight: { tabController.toggleCurrentSelectionHighlight() },
            performCurrentEditorBridgeCommand: { command, payload in
                tabController.performEditorBridgeCommand(command, payload: payload)
            },
            createNote: createNoteThroughActionSystem,
            jumpInCurrentDocument: jumpInCurrentDocument,
            currentDocumentInspectorSettings: { tabState.documentInspectorSettings },
            setCurrentDocumentInspectorSettings: { settings in
                guard tabController.currentEditorCommandTargetSnapshot()?.surfaceKind == .text else { return false }
                tabState.documentInspectorSettings = settings
                return true
            },
            performEditorAnnotationRequest: performActionEditorAnnotationRequest,
            sideStack: { tabController.sideStack }
        )

        WorkspaceActionRouter.register(runtime: runtime)
        registeredWindowNumber = windowNumber
    }

    private func unregisterActions() {
        guard let registeredWindowNumber else { return }
        WorkspaceActionRouter.unregister(windowNumber: registeredWindowNumber)
        self.registeredWindowNumber = nil
    }

    // MARK: - Document opening

    private func openDocument(_ document: WorkspaceOpenedDocument, disposition: WorkspaceActionOpenDisposition) {
        switch disposition {
        case .newTab:
            if focusDocument(document) {
                return
            }
            openNewNativeTab(documents: [document])
        case .backgroundTab:
            // Native tab groups have no background-open concept; the new
            // window joins the tab group without stealing key status beyond
            // what AppKit does.
            openNewNativeTab(documents: [document])
        case .currentTab:
            tabState.navigate(to: document)
        }
    }

    private func focusDocument(_ document: WorkspaceOpenedDocument) -> Bool {
        guard let openedDocument = tabState.openedDocument,
              documentsMatch(openedDocument, document) else {
            return false
        }
        makeWindowKey()
        return true
    }

    private func openSidebarDocument(relativePath: String, inNewTab: Bool) {
        let document = WorkspaceOpenedDocument.workspaceNote(relativePath: relativePath)
        if inNewTab {
            openNewNativeTab(documents: [document])
        } else {
            openDocument(document, disposition: .currentTab)
        }
    }

    private func openInitialPendingDocumentsIfNeeded() {
        guard !didOpenInitialPendingDocuments else { return }
        didOpenInitialPendingDocuments = true

        if !initialPendingDocuments.isEmpty {
            var firstDocument = true
            for document in initialPendingDocuments {
                recordRecentDocument(document)
                if firstDocument, tabState.openedDocument == nil, tabState.kind == .launchpad {
                    tabState.navigate(to: document)
                } else {
                    openNewNativeTab(documents: [document])
                }
                firstDocument = false
            }
            if let jump = initialPendingJump {
                jumpInCurrentDocument(heading: jump.heading, line: jump.line)
            }
            return
        }

        if let jump = initialPendingJump {
            jumpInCurrentDocument(heading: jump.heading, line: jump.line)
        }
    }

    // MARK: - Jump

    private func jumpInCurrentDocument(heading: String?, line: Int?) {
        guard heading != nil || line != nil else { return }
        let jump = PendingMarkdownJump(heading: heading, line: line)
        if sendPendingMarkdownJump(jump) {
            return
        }
        tabState.pendingMarkdownJump = jump
    }

    @discardableResult
    private func sendPendingMarkdownJump(_ jump: PendingMarkdownJump) -> Bool {
        guard let editor = tabController.existingTextEditorController,
              let path = tabState.openedDocument?.editorPath,
              !path.isEmpty
        else {
            return false
        }

        if let heading = jump.heading?.trimmingCharacters(in: .whitespacesAndNewlines), !heading.isEmpty {
            editor.bridge.sendCommand(
                "jumpToMarkdownReference",
                payload: [
                    "id": UUID().uuidString,
                    "path": path,
                    "kind": "heading",
                    "query": heading
                ]
            )
            return true
        }

        if let line = jump.line, line > 0 {
            editor.bridge.sendCommand(
                "jumpToMarkdownReference",
                payload: [
                    "id": UUID().uuidString,
                    "path": path,
                    "kind": "line",
                    "query": String(line)
                ]
            )
            return true
        }

        return false
    }

    // MARK: - Notes actions

    /// File > New Note, the toolbar, the sidebar and the Miller browser all
    /// land here. `folderRelativePath` is the folder the user pointed at, when
    /// there is one; otherwise the panel starts beside the open document.
    private func presentNewNotePanel(inFolderRelativePath folderRelativePath: String?) {
        NewNotePanel.present(
            in: resolvedWindow(),
            directoryURL: newNoteDirectoryURL(folderRelativePath: folderRelativePath)
        ) { result in
            do {
                try createNewNote(at: result.url)
            } catch {
                presentNewNoteError(error)
            }
        }
    }

    /// The pointed-at folder, else the open document's folder, else the folder
    /// open in the Miller browser, else the workspace root.
    private func newNoteDirectoryURL(folderRelativePath: String?) -> URL {
        let rootURL = notesModel.runtimeConfig.rootURL
        func folderURL(_ relativePath: String) -> URL {
            relativePath.isEmpty
                ? rootURL
                : rootURL.appendingPathComponent(relativePath, isDirectory: true)
        }

        if let folderRelativePath {
            return folderURL(folderRelativePath)
        }
        switch tabState.openedDocument {
        case .workspaceNote(let relativePath)?:
            return folderURL((relativePath as NSString).deletingLastPathComponent)
        case .externalMarkdown(let filePath)?:
            return URL(fileURLWithPath: filePath).deletingLastPathComponent()
        default:
            break
        }
        if let millerFolder = tabState.selectedFolderChain.last,
           !LaunchpadRootColumn.isSynthetic(millerFolder) {
            return folderURL(millerFolder)
        }
        return rootURL
    }

    /// Creates the file the panel chose and opens it in this tab. Inside the
    /// workspace it becomes a workspace note; anywhere else an external file.
    /// The panel already confirmed any replacement, so an existing file goes
    /// to the Trash first rather than being overwritten.
    private func createNewNote(at url: URL) throws {
        if let relativePath = workspaceRelativePath(for: url) {
            if FileManager.default.fileExists(atPath: url.path) {
                try notesModel.trashWorkspaceItem(relativePath: relativePath)
                handleLocallyTrashedWorkspaceItem(relativePath: relativePath, kind: .note)
            }
            let createdPath = try notesModel.createNote(
                inFolderRelativePath: (relativePath as NSString).deletingLastPathComponent,
                fileName: url.lastPathComponent
            )
            notesModel.reload()
            openDocument(.workspaceNote(relativePath: createdPath), disposition: .currentTab)
        } else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            try NotesWorkspaceModel.initialFileData(forPath: url.path).write(to: url, options: .atomic)
            openDocument(.externalMarkdown(filePath: url.path), disposition: .currentTab)
        }
    }

    /// `url`'s path inside the workspace root, or nil when it lies outside.
    /// Symlinks are resolved on both sides so an aliased root still matches.
    private func workspaceRelativePath(for url: URL) -> String? {
        let rootPath = notesModel.runtimeConfig.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private func presentNewNoteError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't Create the Note"
        alert.informativeText = error.localizedDescription
        if let window = resolvedWindow() {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func createNoteThroughActionSystem(
        inFolderRelativePath folderRelativePath: String?,
        fileName: String,
        body: String?,
        open: Bool,
        disposition: WorkspaceActionOpenDisposition
    ) throws -> WorkspaceActionNoteCreateResult {
        if open && disposition == .newTab {
            PerformanceDiagnostics.ensureNewTab(
                trigger: "workspace.note.create",
                requestedWindowNumber: resolvedWindow()?.windowNumber,
                waitsForDocument: true
            )
        }
        // Each step is timed: on a synced folder the two writes and the open
        // are where a capture's latency comes from, not the caller.
        var marks: [(String, TimeInterval)] = []
        var lastMark = ProcessInfo.processInfo.systemUptime
        func mark(_ step: String) {
            let now = ProcessInfo.processInfo.systemUptime
            marks.append((step, now - lastMark))
            lastMark = now
        }

        let relativePath = try notesModel.createNote(inFolderRelativePath: folderRelativePath, fileName: fileName)
        mark("createFile")
        if let body, !body.isEmpty {
            try notesModel.saveTextNote(relativePath: relativePath, body: body)
            mark("writeBody")
        }

        notesModel.reload()
        mark("reload")

        if open {
            openDocument(.workspaceNote(relativePath: relativePath), disposition: disposition)
            mark("open")
        }
        LocalDiagnosticsCenter.shared.log(
            category: "workspace",
            event: "createNote.timing",
            metadata: Dictionary(uniqueKeysWithValues: marks.map { ($0.0, String(format: "%.1fms", $0.1 * 1000)) })
                .merging(["path": relativePath]) { current, _ in current }
        )

        return WorkspaceActionNoteCreateResult(
            relativePath: relativePath,
            absolutePath: notesModel.workspaceURL(for: relativePath)?.path ?? "",
            projectRootPath: notesModel.runtimeConfig.rootURL.path,
            wasOpened: open,
            windowID: open ? actionWindowID : nil,
            workspaceID: open ? actionWorkspaceID : nil,
            tabID: open && disposition == .currentTab ? actionTabID : nil
        )
    }

    private func revealCurrentDocumentInFinder() -> Bool {
        guard let document = tabState.openedDocument,
              let url = finderRevealURL(for: document) else {
            NSSound.beep()
            return false
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// Copy Link is available only on file tabs — workspace notes and external
    /// Markdown. Transient surfaces (clipboard, diff) are excluded.
    private func copyCurrentDocumentLink() -> Bool {
        guard tabState.kind == .note,
              let document = tabState.openedDocument else {
            NSSound.beep()
            return false
        }

        let link: String?
        switch document {
        case .workspaceNote(let relativePath):
            if notesModel.workspaceURL(for: relativePath) != nil {
                link = NVModernURLScheme.fileLinkURL(relativePath: relativePath)
            } else {
                link = nil
            }
        case .externalMarkdown(let filePath):
            link = NVModernURLScheme.fileLinkURL(path: filePath)
        case .clipboardMarkdown, .diff:
            link = nil
        }

        guard let link else {
            NSSound.beep()
            return false
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        return true
    }

    private func duplicateCurrentWorkspaceNote() throws -> WorkspaceActionNoteCreateResult? {
        guard case .workspaceNote(let relativePath)? = tabState.openedDocument else {
            return nil
        }

        let duplicatedPath = try notesModel.duplicateWorkspaceNote(relativePath: relativePath)
        notesModel.reload()
        openDocument(.workspaceNote(relativePath: duplicatedPath), disposition: .currentTab)
        return WorkspaceActionNoteCreateResult(
            relativePath: duplicatedPath,
            absolutePath: notesModel.workspaceURL(for: duplicatedPath)?.path ?? "",
            projectRootPath: notesModel.runtimeConfig.rootURL.path,
            wasOpened: true,
            windowID: actionWindowID,
            workspaceID: actionWorkspaceID,
            tabID: actionTabID
        )
    }

    private func refileCurrentWorkspaceNote(toFolderRelativePath folderRelativePath: String?) throws -> WorkspaceActionNoteMoveResult? {
        guard case .workspaceNote(let oldRelativePath)? = tabState.openedDocument else {
            return nil
        }
        return try refileWorkspaceNote(relativePath: oldRelativePath, toFolderRelativePath: folderRelativePath)
    }

    /// Moves any workspace note, whether or not it is the open document. The
    /// palette refiles a bound noun through here, once per member of a batch.
    private func refileWorkspaceNote(
        relativePath oldRelativePath: String,
        toFolderRelativePath folderRelativePath: String?
    ) throws -> WorkspaceActionNoteMoveResult? {
        let isOpenDocument: Bool
        if case .workspaceNote(let openPath)? = tabState.openedDocument, openPath == oldRelativePath {
            isOpenDocument = true
        } else {
            isOpenDocument = false
        }

        if isOpenDocument, let liveBody = tabState.liveCachedTextBody {
            try notesModel.saveTextNote(relativePath: oldRelativePath, body: liveBody)
        }

        let newRelativePath = try notesModel.moveWorkspaceNote(
            relativePath: oldRelativePath,
            toFolderRelativePath: folderRelativePath
        )
        guard newRelativePath != oldRelativePath else {
            return WorkspaceActionNoteMoveResult(
                oldRelativePath: oldRelativePath,
                relativePath: newRelativePath,
                absolutePath: notesModel.workspaceURL(for: newRelativePath)?.path ?? "",
                projectRootPath: notesModel.runtimeConfig.rootURL.path,
                windowID: actionWindowID,
                workspaceID: actionWorkspaceID,
                tabID: actionTabID
            )
        }

        locallyInitiatedRenames[oldRelativePath] = newRelativePath
        notesModel.reload()
        registerLocallyRenamedWorkspaceItem(from: oldRelativePath, to: newRelativePath, kind: .note)
        if isOpenDocument {
            tabController.clearWebContextMarkers()
        }

        return WorkspaceActionNoteMoveResult(
            oldRelativePath: oldRelativePath,
            relativePath: newRelativePath,
            absolutePath: notesModel.workspaceURL(for: newRelativePath)?.path ?? "",
            projectRootPath: notesModel.runtimeConfig.rootURL.path,
            windowID: actionWindowID,
            workspaceID: actionWorkspaceID,
            tabID: actionTabID
        )
    }

    // MARK: - Snapshots

    private func currentActionDocumentSnapshot() -> WorkspaceActionDocumentSnapshot? {
        guard let document = tabState.openedDocument else {
            return nil
        }

        let title = document.tabPresentation.title

        switch document {
        case .workspaceNote(let relativePath):
            return WorkspaceActionDocumentSnapshot(
                kind: .workspaceNote,
                title: title,
                relativePath: relativePath,
                absolutePath: notesModel.workspaceURL(for: relativePath)?.path,
                projectRootPath: notesModel.runtimeConfig.rootURL.path,
                windowID: actionWindowID,
                workspaceID: actionWorkspaceID,
                tabID: actionTabID,
                isEditable: true
            )
        case .externalMarkdown(let filePath):
            return WorkspaceActionDocumentSnapshot(
                kind: .externalMarkdown,
                title: title,
                relativePath: nil,
                absolutePath: filePath,
                projectRootPath: notesModel.runtimeConfig.rootURL.path,
                windowID: actionWindowID,
                workspaceID: actionWorkspaceID,
                tabID: actionTabID,
                isEditable: true
            )
        case .clipboardMarkdown(let clipboardTitle, _):
            return WorkspaceActionDocumentSnapshot(
                kind: .clipboardMarkdown,
                title: clipboardTitle,
                relativePath: nil,
                absolutePath: nil,
                projectRootPath: notesModel.runtimeConfig.rootURL.path,
                windowID: actionWindowID,
                workspaceID: actionWorkspaceID,
                tabID: actionTabID,
                isEditable: false
            )
        case .diff:
            return WorkspaceActionDocumentSnapshot(
                kind: .diff,
                title: title,
                relativePath: nil,
                absolutePath: nil,
                projectRootPath: notesModel.runtimeConfig.rootURL.path,
                windowID: actionWindowID,
                workspaceID: actionWorkspaceID,
                tabID: actionTabID,
                isEditable: false
            )
        }
    }

    private func actionTabSnapshots() -> [WorkspaceActionTabSnapshot] {
        [
            WorkspaceActionTabSnapshot(
                tabID: actionTabID,
                kind: tabState.kind.rawValue,
                title: windowTitle,
                selected: true,
                relativePath: sidebarSelectedDocumentPath
            )
        ]
    }

    private func performActionEditorAnnotationRequest(_ request: [String: ActionValue]) async -> ActionValue? {
        guard let document = tabState.openedDocument else { return nil }
        // Route by what the tab shows: a tab can keep a warm text editor
        // attached while it displays a PDF.
        let showsPDF = URL(fileURLWithPath: document.editorPath).pathExtension.lowercased() == "pdf"
        if showsPDF {
            guard let pdf = tabController.existingPDFController, pdf.isAttached,
                  let path = currentActionDocumentSnapshot()?.absolutePath
            else {
                return nil
            }
            return pdf.performAnnotationRequest(request, expectedFileURL: URL(fileURLWithPath: path))
        }
        guard let editor = tabController.existingTextEditorController, editor.isAttached else { return nil }
        var request = request
        request["expectedPath"] = .string(document.editorPath)
        return await editor.performAnnotationRequest(request)
    }

    private func queryActionEditorContext(_ query: WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot? {
        // A PDF tab answers with its text selection; it has no caret or viewport text.
        if let document = tabState.openedDocument,
           URL(fileURLWithPath: document.editorPath).pathExtension.lowercased() == "pdf",
           let pdf = tabController.existingPDFController, pdf.isAttached {
            return WorkspaceEditorContextSnapshot(
                path: document.editorPath,
                title: document.tabPresentation.title,
                surface: Self.primaryEditorSurface,
                selection: query.includeSelection ? pdf.selectionSnapshot() : nil,
                viewport: nil,
                cursor: nil
            )
        }

        guard let editor = tabController.existingTextEditorController else { return nil }
        let surface = Self.primaryEditorSurface

        var snapshot = await editor.queryEditorContext(query)
        if snapshot == nil, query.includeSelection {
            snapshot = WorkspaceEditorContextSnapshot(
                path: nil,
                title: nil,
                surface: surface,
                selection: WorkspaceEditorSelectionSnapshot(
                    text: editor.lastKnownSelectedText,
                    startLine: nil,
                    endLine: nil,
                    empty: editor.lastKnownSelectedText.isEmpty
                ),
                viewport: nil,
                cursor: nil
            )
        }

        guard var snapshot else { return nil }
        snapshot.surface = surface
        if snapshot.path == nil || snapshot.title == nil {
            let document = tabState.openedDocument
            if snapshot.path == nil {
                snapshot.path = document?.editorPath
            }
            if snapshot.title == nil {
                snapshot.title = document?.tabPresentation.title
            }
        }
        return snapshot
    }

    // MARK: - Sidebar state

    private func setSidebarFocusedRoot(_ relativePath: String?) {
        let normalized = relativePath?
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        sidebarFocusedRootPath = normalized?.isEmpty == false ? normalized : nil
    }

    private func browseFolderInMiller(relativePath: String?) {
        let folderPath = relativePath ?? ""
        let folderChain = validFolderChain(from: folderChainForFolderPath(folderPath))

        tabState.selectedFolderChain = folderChain
        tabState.millerActiveDepth = folderChain.count
        tabState.activeMillerItemPath = nil
    }

    private func ensureSidebarTracksFocusedTab() {
        guard columnVisibility != .detailOnly,
              let selectedDocumentPath = sidebarSelectedDocumentPath else {
            return
        }

        if let focusedRootPath = sidebarFocusedRootPath,
           selectedDocumentPath != focusedRootPath,
           !selectedDocumentPath.hasPrefix(focusedRootPath + "/") {
            sidebarFocusedRootPath = nil
        }

        sidebarExpandedFolderPaths.formUnion(
            WorkspaceSidebarTreeBuilder.ancestorFolderPaths(
                forDocumentPath: selectedDocumentPath
            )
        )
    }

    private func sanitizeSidebarState() {
        guard !notesModel.childrenByFolder.isEmpty else { return }
        let validFolderPaths = WorkspaceSidebarTreeBuilder.folderPaths(
            in: notesModel.childrenByFolder
        )
        sidebarExpandedFolderPaths.formIntersection(validFolderPaths)
        if let focusedRootPath = sidebarFocusedRootPath,
           !validFolderPaths.contains(focusedRootPath) {
            sidebarFocusedRootPath = nil
        }
    }

    // MARK: - Live sync

    private func applyLatestLiveSyncUpdateIfNeeded() {
        guard let update = notesModel.lastLiveSyncUpdate else { return }

        let observesPath: (String) -> Bool = { relativePath in
            if case .workspaceNote(let openedPath)? = tabState.openedDocument {
                return openedPath == relativePath
            }
            return false
        }

        for (oldPath, newPath) in update.renamedPaths {
            let isLocallyInitiated = locallyInitiatedRenames[oldPath] == newPath
            if let source = diffOriginalSource {
                diffOriginalSource = remapDiffSource(source, from: oldPath, to: newPath)
            }
            guard observesPath(oldPath) else {
                if isLocallyInitiated {
                    locallyInitiatedRenames.removeValue(forKey: oldPath)
                }
                continue
            }
            remapWorkspacePathInTabState(from: oldPath, to: newPath)
            if !isLocallyInitiated {
                tabState.liveBanner = renameBanner(from: oldPath, to: newPath, date: Date())
            } else {
                tabState.liveBanner = nil
            }
            tabState.liveDeletedSnapshot = nil
            if isLocallyInitiated {
                locallyInitiatedRenames.removeValue(forKey: oldPath)
            }
        }

        for deletedPath in update.externalDeletedPaths {
            if locallyTrashedWorkspacePaths.contains(deletedPath) {
                locallyTrashedWorkspacePaths.remove(deletedPath)
                continue
            }

            guard observesPath(deletedPath) else { continue }
            if case .diff? = tabState.openedDocument {
                applyLiveFileReload()
                continue
            }
            tabState.liveBanner = deletedBanner(for: deletedPath, date: Date())
            if tabState.liveDeletedSnapshot == nil {
                tabState.liveDeletedSnapshot = deletedSnapshot(for: tabState, relativePath: deletedPath)
            }
            applyDeletedSelectionState(deletedPath: deletedPath)
        }

        for modifiedPath in update.externalModifiedPaths {
            guard observesPath(modifiedPath) else { continue }
            if case .diff? = tabState.openedDocument {
                applyLiveFileReload()
            } else if notesModel.runtimeConfig.sync.mode.automaticallyReloadsFileChanges {
                applyLiveFileReload()
            } else {
                tabState.liveBanner = modifiedBanner(for: modifiedPath, date: Date())
            }
        }

        for restoredPath in update.selfWriteConfirmedPaths {
            guard observesPath(restoredPath) else { continue }
            if let banner = tabState.liveBanner {
                switch banner.kind {
                case .modified(let path, _), .deleted(let path, _):
                    if path == restoredPath {
                        tabState.liveBanner = nil
                        tabState.liveDeletedSnapshot = nil
                    }
                case .renamed:
                    break
                }
            }
        }
    }

    private func applyLiveFileReload() {
        tabState.liveBanner = nil
        tabState.liveDeletedSnapshot = nil
        tabState.liveCachedTextBody = nil
        tabState.liveCachedData = nil
        tabState.liveCachedKind = nil
        tabState.liveCachedTitle = nil
        tabState.persistedTextSnapshot = nil
        tabState.liveLocalRefreshRevision += 1
        tabState.liveDiskReloadRevision += 1
    }

    private func remapWorkspacePathInTabState(from oldPath: String, to newPath: String) {
        if case .workspaceNote(let relativePath)? = tabState.openedDocument,
           relativePath == oldPath {
            tabState.openedDocument = .workspaceNote(relativePath: newPath)
        }
        if case .diff(let left, let right)? = tabState.openedDocument {
            tabState.openedDocument = .diff(
                left: remapDiffSource(left, from: oldPath, to: newPath),
                right: remapDiffSource(right, from: oldPath, to: newPath)
            )
        }
        if tabState.selectedNotePath == oldPath {
            tabState.selectedNotePath = newPath
        }
        if tabState.activeMillerItemPath == oldPath {
            tabState.activeMillerItemPath = newPath
        }
        tabState.selectedFolderChain = WorkspaceTabState.folderChain(for: newPath)
        tabState.millerActiveDepth = tabState.selectedFolderChain.count
        tabState.historyCurrentItem = remapHistoryItem(tabState.historyCurrentItem, from: oldPath, to: newPath)
        tabState.backHistory = tabState.backHistory.map { remapHistoryItem($0, from: oldPath, to: newPath) ?? $0 }
        tabState.forwardHistory = tabState.forwardHistory.map { remapHistoryItem($0, from: oldPath, to: newPath) ?? $0 }
    }

    private func remapDiffSource(_ source: WorkspaceDiffSource, from oldPath: String, to newPath: String) -> WorkspaceDiffSource {
        guard case .workspace(let relativePath) = source,
              relativePath == oldPath else {
            return source
        }
        return .workspace(relativePath: newPath)
    }

    private func remapHistoryItem(_ item: WorkspaceHistoryItem?, from oldPath: String, to newPath: String) -> WorkspaceHistoryItem? {
        guard let item else { return nil }
        switch item {
        case .workspaceNote(let relativePath):
            return .workspaceNote(relativePath: relativePath == oldPath ? newPath : relativePath)
        case .externalMarkdown:
            return item
        }
    }

    /// Window-level rename used by `workspace.document.rename`: the rename is
    /// recorded as locally initiated so the index reload does not read it as a
    /// delete plus an add, the notes model reloads, tab state is remapped onto
    /// the new path, and web context markers are cleared if the open document
    /// was the renamed item.
    private func renameWorkspaceItem(relativePath: String, to newName: String) throws -> String {
        let kind: MillerItemKind = isWorkspaceDirectory(relativePath: relativePath) ? .folder : .note
        let affectsOpenDocument: Bool
        if case .workspaceNote(let openPath)? = tabState.openedDocument {
            affectsOpenDocument = pathMatchesWorkspaceOperationTarget(openPath, targetPath: relativePath, kind: kind)
        } else {
            affectsOpenDocument = false
        }

        let newRelativePath = try notesModel.renameWorkspaceItem(relativePath: relativePath, to: newName)
        guard newRelativePath != relativePath else { return newRelativePath }

        if kind == .note {
            locallyInitiatedRenames[relativePath] = newRelativePath
        }
        notesModel.reload()
        registerLocallyRenamedWorkspaceItem(from: relativePath, to: newRelativePath, kind: kind)
        if affectsOpenDocument {
            tabController.clearWebContextMarkers()
        }
        return newRelativePath
    }

    private func isWorkspaceDirectory(relativePath: String) -> Bool {
        guard let url = notesModel.workspaceItemURL(allowingRootRelativePath: relativePath) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func registerLocallyRenamedWorkspaceItem(from oldPath: String, to newPath: String, kind: MillerItemKind) {
        if kind == .note {
            locallyInitiatedRenames[oldPath] = newPath
        }

        if kind == .folder {
            remapWorkspacePrefixInTabState(from: oldPath, to: newPath)
        } else {
            remapWorkspacePathInTabState(from: oldPath, to: newPath)
        }

        if let source = diffOriginalSource {
            diffOriginalSource = kind == .folder
                ? remapDiffSourcePrefix(source, from: oldPath, to: newPath)
                : remapDiffSource(source, from: oldPath, to: newPath)
        }
    }

    private func handleLocallyTrashedWorkspaceItem(relativePath: String, kind: MillerItemKind) {
        if kind == .note {
            locallyTrashedWorkspacePaths.insert(relativePath)
        }

        let observesTarget: Bool
        if case .workspaceNote(let openedPath)? = tabState.openedDocument {
            observesTarget = pathMatchesWorkspaceOperationTarget(openedPath, targetPath: relativePath, kind: kind)
        } else {
            observesTarget = false
        }

        if observesTarget {
            // The old shell closed matching tabs and reseeded the pane with a
            // welcome tab; the native equivalent is returning this window to
            // the launchpad.
            tabController.invalidateAllContentControllers()
            // The side stack belongs to the tab, not the document.
            let sideStack = tabState.sideStack
            tabState = launchpadTabState()
            tabState.sideStack = sideStack
        } else if kind == .folder {
            clearWorkspacePrefixInTabState(deletedPrefix: relativePath)
        }
    }

    private func pathMatchesWorkspaceOperationTarget(_ path: String, targetPath: String, kind: MillerItemKind) -> Bool {
        if path == targetPath {
            return true
        }

        guard kind == .folder else {
            return false
        }

        return path.hasPrefix(targetPath + "/")
    }

    private func remapWorkspacePrefixInTabState(from oldPrefix: String, to newPrefix: String) {
        if case .workspaceNote(let relativePath)? = tabState.openedDocument,
           let remappedPath = remappedWorkspacePath(relativePath, from: oldPrefix, to: newPrefix) {
            tabState.openedDocument = .workspaceNote(relativePath: remappedPath)
        }

        if case .diff(let left, let right)? = tabState.openedDocument {
            tabState.openedDocument = .diff(
                left: remapDiffSourcePrefix(left, from: oldPrefix, to: newPrefix),
                right: remapDiffSourcePrefix(right, from: oldPrefix, to: newPrefix)
            )
        }

        if let selectedNotePath = tabState.selectedNotePath,
           let remappedPath = remappedWorkspacePath(selectedNotePath, from: oldPrefix, to: newPrefix) {
            tabState.selectedNotePath = remappedPath
        }

        if let activeItemPath = tabState.activeMillerItemPath,
           let remappedPath = remappedWorkspacePath(activeItemPath, from: oldPrefix, to: newPrefix) {
            tabState.activeMillerItemPath = remappedPath
        }

        tabState.selectedFolderChain = tabState.selectedFolderChain.map { folderPath in
            remappedWorkspacePath(folderPath, from: oldPrefix, to: newPrefix) ?? folderPath
        }
        tabState.historyCurrentItem = remapHistoryItemPrefix(tabState.historyCurrentItem, from: oldPrefix, to: newPrefix)
        tabState.backHistory = tabState.backHistory.map { remapHistoryItemPrefix($0, from: oldPrefix, to: newPrefix) ?? $0 }
        tabState.forwardHistory = tabState.forwardHistory.map { remapHistoryItemPrefix($0, from: oldPrefix, to: newPrefix) ?? $0 }

        if let activeItemPath = tabState.activeMillerItemPath {
            tabState.millerActiveDepth = max(0, tabState.selectedFolderChain.firstIndex(of: activeItemPath) ?? tabState.selectedFolderChain.count)
        } else if let selectedNotePath = tabState.selectedNotePath {
            tabState.millerActiveDepth = WorkspaceTabState.folderChain(for: selectedNotePath).count
        } else {
            tabState.millerActiveDepth = tabState.selectedFolderChain.count
        }
    }

    private func remapDiffSourcePrefix(
        _ source: WorkspaceDiffSource,
        from oldPrefix: String,
        to newPrefix: String
    ) -> WorkspaceDiffSource {
        guard case .workspace(let relativePath) = source,
              let remappedPath = remappedWorkspacePath(relativePath, from: oldPrefix, to: newPrefix) else {
            return source
        }
        return .workspace(relativePath: remappedPath)
    }

    private func remapHistoryItemPrefix(_ item: WorkspaceHistoryItem?, from oldPrefix: String, to newPrefix: String) -> WorkspaceHistoryItem? {
        guard let item else { return nil }
        switch item {
        case .workspaceNote(let relativePath):
            guard let remappedPath = remappedWorkspacePath(relativePath, from: oldPrefix, to: newPrefix) else {
                return item
            }
            return .workspaceNote(relativePath: remappedPath)
        case .externalMarkdown:
            return item
        }
    }

    private func remappedWorkspacePath(_ path: String, from oldPrefix: String, to newPrefix: String) -> String? {
        if path == oldPrefix {
            return newPrefix
        }

        let prefix = oldPrefix + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }

        return newPrefix + "/" + String(path.dropFirst(prefix.count))
    }

    private func clearWorkspacePrefixInTabState(deletedPrefix: String) {
        if case .workspaceNote(let relativePath)? = tabState.openedDocument,
           pathMatchesWorkspaceOperationTarget(relativePath, targetPath: deletedPrefix, kind: .folder) {
            tabState.openedDocument = nil
        }

        if let selectedNotePath = tabState.selectedNotePath,
           pathMatchesWorkspaceOperationTarget(selectedNotePath, targetPath: deletedPrefix, kind: .folder) {
            tabState.selectedNotePath = nil
        }

        if let activeItemPath = tabState.activeMillerItemPath,
           pathMatchesWorkspaceOperationTarget(activeItemPath, targetPath: deletedPrefix, kind: .folder) {
            tabState.activeMillerItemPath = nil
        }

        tabState.selectedFolderChain = tabState.selectedFolderChain.filter { folderPath in
            !pathMatchesWorkspaceOperationTarget(folderPath, targetPath: deletedPrefix, kind: .folder)
        }
        tabState.millerActiveDepth = tabState.selectedFolderChain.count
    }

    private func applyDeletedSelectionState(deletedPath: String) {
        tabState.selectedFolderChain = WorkspaceTabState.folderChain(for: deletedPath)
        tabState.selectedNotePath = nil
        tabState.activeMillerItemPath = nil
        tabState.millerActiveDepth = tabState.selectedFolderChain.count
    }

    // MARK: - Banners

    private func modifiedBanner(for path: String, date: Date) -> WorkspaceTabBannerState {
        WorkspaceTabBannerState(
            kind: .modified(path: path, date: date),
            style: .warning,
            symbolName: "exclamationmark.triangle.fill",
            title: "File changed on disk",
            message: path,
            date: date,
            actions: [
                WorkspaceTabBannerAction(id: .keepLocal, title: "Keep Local", style: .normal),
                WorkspaceTabBannerAction(id: .reloadFromDisk, title: "Reload", style: .prominent)
            ]
        )
    }

    private func deletedBanner(for path: String, date: Date) -> WorkspaceTabBannerState {
        WorkspaceTabBannerState(
            kind: .deleted(path: path, date: date),
            style: .danger,
            symbolName: "trash.fill",
            title: "File deleted on disk",
            message: path,
            date: date,
            actions: [
                WorkspaceTabBannerAction(id: .restoreDeleted, title: "Restore", style: .prominent),
                WorkspaceTabBannerAction(id: .closeTab, title: "Close Tab", style: .destructive)
            ]
        )
    }

    private func renameBanner(from oldPath: String, to newPath: String, date: Date) -> WorkspaceTabBannerState {
        WorkspaceTabBannerState(
            kind: .renamed(oldPath: oldPath, newPath: newPath, date: date),
            style: .info,
            symbolName: "arrow.triangle.swap",
            title: "File renamed",
            message: "\(oldPath) → \(newPath)",
            date: date,
            actions: []
        )
    }

    private func deletedSnapshot(for state: WorkspaceTabState, relativePath: String) -> WorkspaceDeletedDocumentSnapshot? {
        let title = state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        if let kind = state.liveCachedKind {
            return WorkspaceDeletedDocumentSnapshot(
                title: title,
                kind: kind,
                relativePath: relativePath,
                textBody: state.liveCachedTextBody,
                data: state.liveCachedData,
                mimeType: nil
            )
        }
        return nil
    }

    // MARK: - Matching helpers

    private func documentsMatch(_ lhs: WorkspaceOpenedDocument, _ rhs: WorkspaceOpenedDocument) -> Bool {
        switch (lhs, rhs) {
        case (.workspaceNote(let lhsPath), .workspaceNote(let rhsPath)):
            return normalizeWorkspacePath(lhsPath) == normalizeWorkspacePath(rhsPath)
        case (.externalMarkdown(let lhsPath), .externalMarkdown(let rhsPath)):
            return URL(fileURLWithPath: lhsPath).standardizedFileURL.path
                == URL(fileURLWithPath: rhsPath).standardizedFileURL.path
        case (.clipboardMarkdown(let lhsTitle, let lhsBody), .clipboardMarkdown(let rhsTitle, let rhsBody)):
            return lhsTitle == rhsTitle && lhsBody == rhsBody
        case (.diff(let lhsLeft, let lhsRight), .diff(let rhsLeft, let rhsRight)):
            return lhsLeft == rhsLeft && lhsRight == rhsRight
        default:
            return false
        }
    }

    private func normalizeWorkspacePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        return normalized
    }

    private func recordRecentDocument(_ document: WorkspaceOpenedDocument) {
        WorkspaceSessionStore.shared.recordRecentDocument(
            rootURL: notesModel.runtimeConfig.rootURL,
            document: document
        )
    }

    private func finderRevealURL(for document: WorkspaceOpenedDocument) -> URL? {
        let url: URL?
        switch document {
        case .workspaceNote(let relativePath):
            url = notesModel.workspaceURL(for: relativePath)
        case .externalMarkdown(let filePath):
            url = URL(fileURLWithPath: filePath)
        case .clipboardMarkdown, .diff:
            url = nil
        }

        guard let url,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return url
    }

    private func launchpadTabState() -> WorkspaceTabState {
        WorkspaceTabState(
            kind: .launchpad,
            selectedFolderChain: [],
            selectedNotePath: nil,
            openedDocument: nil,
            documentInspectorSettings: notesModel.runtimeConfig.defaultDocumentInspectorSettings,
            millerActiveDepth: 0,
            activeMillerItemPath: nil,
            backHistory: [],
            forwardHistory: [],
            historyCurrentItem: nil
        )
    }

    private func validFolderChain(from folderChain: [String]) -> [String] {
        var validChain: [String] = []
        var parentPath = ""
        for folderPath in folderChain {
            let siblings = notesModel.childrenByFolder[parentPath, default: []]
            guard siblings.contains(where: { $0.kind == .folder && $0.relativePath == folderPath }) else {
                break
            }
            validChain.append(folderPath)
            parentPath = folderPath
        }
        return validChain
    }

    private func folderChainForFolderPath(_ folderPath: String) -> [String] {
        guard !folderPath.isEmpty else { return [] }
        let components = folderPath.split(separator: "/")
        var chain: [String] = []
        var current = ""
        for component in components {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            chain.append(current)
        }
        return chain
    }

    // MARK: - Session persistence

    private func restoreWindowFrameIfNeeded(_ window: NSWindow) {
        guard !didApplyRestoredWindowFrame,
              let pendingRestoredWindowFrame else {
            return
        }

        didApplyRestoredWindowFrame = true
        self.pendingRestoredWindowFrame = nil
        window.setFrame(pendingRestoredWindowFrame, display: true)
        currentWindowFrame = window.frame
    }

    private func handleWindowWillClose(_ window: NSWindow) {
        activationGate?.onActivate = nil
        isWindowClosing = true
        deferredActions.cancelWindowStatePersistence()
        tabController.invalidateAllContentControllers()
        tabController.invalidateSideStack()
        lastPersistedWindowState = nil
        currentWindowFrame = nil
        WorkspaceActionRouter.unregister(windowNumber: window.windowNumber)
        if registeredWindowNumber == window.windowNumber {
            registeredWindowNumber = nil
        }
        WorkspaceSessionStore.shared.removeWindowState(windowNumber: window.windowNumber)
    }

    private func scheduleWindowStatePersistence() {
        guard !isWindowClosing else { return }
        deferredActions.scheduleWindowStatePersistence(after: Self.windowStatePersistenceDebounce) {
            flushScheduledWindowStatePersistence()
        }
    }

    private func flushScheduledWindowStatePersistence() {
        deferredActions.cancelWindowStatePersistence()
        persistCurrentWindowState()
    }

    private func persistCurrentWindowState() {
        guard !isWindowClosing,
              isWindowActivated,
              let windowNumber = registeredWindowNumber,
              let frame = currentWindowFrame else {
            return
        }

        let paneState = PersistedWorkspacePaneState(
            tabs: [
                PersistedWorkspaceWindowTab(
                    title: windowTitle,
                    icon: tabState.openedDocument?.tabPresentation.icon,
                    iconTint: nil,
                    state: tabState.persisted
                )
            ],
            selectedTabIndex: 0
        )

        let windowState = PersistedWorkspaceWindowState(
            frame: .init(rect: frame),
            rootPath: notesModel.runtimeConfig.rootURL.standardizedFileURL.path,
            rootNode: .pane(paneState),
            focusedPanePath: [],
            isSidebarVisible: columnVisibility != .detailOnly,
            sidebarWidth: Double(sidebarWidth),
            sidebarExpandedFolderPaths: sidebarExpandedFolderPaths.sorted(),
            sidebarFocusedRootPath: sidebarFocusedRootPath
        )

        guard lastPersistedWindowState != windowState else {
            return
        }

        lastPersistedWindowState = windowState
        WorkspaceSessionStore.shared.upsertWindowState(
            windowNumber: windowNumber,
            state: windowState
        )
    }

    /// Picks the tab this window should restore: the selected tab of the first
    /// pane of a persisted split tree, or the first entry of a legacy flat tab
    /// list. Windows that persisted multiple Bonsplit tabs restore their
    /// leading tab here; the rest are not carried into the native model.
    private static func firstPersistedTabState(
        from windowState: PersistedWorkspaceWindowState
    ) -> PersistedWorkspaceTabState? {
        if let rootNode = windowState.rootNode {
            var node = rootNode
            while case .split(let split) = node {
                node = split.first
            }
            if case .pane(let pane) = node {
                let index = max(0, min(pane.selectedTabIndex, pane.tabs.count - 1))
                return pane.tabs.indices.contains(index) ? pane.tabs[index].state : nil
            }
        }
        guard !windowState.tabs.isEmpty else { return nil }
        let index = max(0, min(windowState.selectedTabIndex, windowState.tabs.count - 1))
        return windowState.tabs[index].state
    }

    private static func restoredTabState(
        from windowState: PersistedWorkspaceWindowState
    ) -> WorkspaceTabState? {
        guard let persisted = firstPersistedTabState(from: windowState) else { return nil }
        let state = WorkspaceTabState(persisted: persisted)
        guard state.kind == .launchpad || state.openedDocument != nil else {
            return nil
        }
        return state
    }
}

/// Debounced persistence helper carried over from the old window shell.
@MainActor
private final class WorkspaceViewDeferredActions: ObservableObject {
    private var pendingWindowStatePersistenceWorkItem: DispatchWorkItem?

    deinit {
        pendingWindowStatePersistenceWorkItem?.cancel()
    }

    func scheduleWindowStatePersistence(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        pendingWindowStatePersistenceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingWindowStatePersistenceWorkItem = nil
                action()
            }
        }

        pendingWindowStatePersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelWindowStatePersistence() {
        pendingWindowStatePersistenceWorkItem?.cancel()
        pendingWindowStatePersistenceWorkItem = nil
    }
}
