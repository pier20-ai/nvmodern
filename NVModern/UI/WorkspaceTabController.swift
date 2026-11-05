import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkspaceTabController: ObservableObject {
    enum FocusArea: Equatable {
        case content
    }

    let tabID: TabID
    let arborKernelSupervisor: ArborKernelSupervisor
    let bridgeService: DocumentSurfaceBridgeService
    /// The tab's side stack (ticket 0031): retained with the tab like the
    /// content runtimes, independent of what the main view shows.
    let sideStack: SideStackController

    @Published private(set) var attachedPaneID: PaneID?
    @Published private(set) var isFocusedLeaf = false
    @Published private var workspaceState: WorkspaceTabState = .initial

    /// Window-chrome history affordances. The native toolbar renders the
    /// back/forward buttons, but the navigation stacks live in the tab view,
    /// which pushes availability here and installs the handlers below — the
    /// same hand-off pattern `updateEditorCommandTarget` uses.
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canNavigateForward = false
    @Published private(set) var millerHorizontalScrollRequest = MillerHorizontalScrollRequest(
        id: 1,
        edge: .left
    )
    private var navigateBackHandler: (() -> Void)?
    private var navigateForwardHandler: (() -> Void)?
    private var showInParentFolderHandler: ((String, Bool) -> Bool)?

    let millerDropRouter: MillerNativeDropRouter

    private let hostingController: NSHostingController<AnyView>
    private let ownsArborKernelSupervisor: Bool
    private let dropHostingController: MillerDropHostingViewController
    private let primaryRuntimes: DocumentSurfaceRuntimeBag
    private var hasInstalledRootView = false
    private var onLifecycleStateChange: (() -> Void)?
    private var onStateChange: ((WorkspaceTabState) -> Void)?
    private var pendingFocusArea: FocusArea?
    private var contentFocusHandler: (() -> Void)?
    private var isApplyingFocus = false
    private var editorCommandTargetSnapshot: WorkspaceEditorCommandTargetSnapshot?
    private var replaceCurrentSelectionHandler: ((String) -> Bool)?
    private var toggleCurrentSelectionHighlightHandler: (() -> Bool)?
    private var performEditorBridgeCommandHandler: ((String, [String: ActionValue]) -> Bool)?

    init(
        tabID: TabID,
        arborKernelSupervisor: ArborKernelSupervisor? = nil,
        rootView: AnyView = AnyView(EmptyView())
    ) {
        let millerDropRouter = MillerNativeDropRouter()
        let hostingController = NSHostingController(rootView: rootView)
        let resolvedArborKernelSupervisor = arborKernelSupervisor ?? ArborKernelSupervisor()
        self.tabID = tabID
        self.arborKernelSupervisor = resolvedArborKernelSupervisor
        self.ownsArborKernelSupervisor = arborKernelSupervisor == nil
        self.millerDropRouter = millerDropRouter
        self.hostingController = hostingController
        self.dropHostingController = MillerDropHostingViewController(
            contentController: hostingController,
            router: millerDropRouter
        )
        self.primaryRuntimes = DocumentSurfaceRuntimeBag(tabID: tabID)
        let bridgeService = DocumentSurfaceBridgeService(arborKernelSupervisor: resolvedArborKernelSupervisor)
        self.bridgeService = bridgeService
        self.sideStack = SideStackController(ownerTabID: tabID, bridgeService: bridgeService)
    }

    var rootViewController: NSViewController {
        dropHostingController
    }

    deinit {
        if ownsArborKernelSupervisor {
            arborKernelSupervisor.shutdown()
        }
    }

    var textContent: WorkspaceTextTabContentRuntime {
        primaryRuntimes.textContent
    }

    var previewContent: WorkspacePreviewTabContentRuntime {
        primaryRuntimes.previewContent
    }

    var pdfContent: WorkspacePDFTabContentRuntime {
        primaryRuntimes.pdfContent
    }

    var csvContent: WorkspaceCSVTabContentRuntime {
        primaryRuntimes.csvContent
    }

    var canvasContent: WorkspaceCanvasTabContentRuntime {
        primaryRuntimes.canvasContent
    }

    var imageContent: WorkspaceImageTabContentRuntime {
        primaryRuntimes.imageContent
    }

    var htmlContent: WorkspaceHTMLTabContentRuntime {
        primaryRuntimes.htmlContent
    }

    var epubContent: WorkspaceEPUBTabContentRuntime {
        primaryRuntimes.epubContent
    }

    var existingTextEditorController: EditorWebContentController? {
        primaryRuntimes.textContent.existingController
    }

    var existingPreviewController: EditorWebContentController? {
        primaryRuntimes.previewContent.existingController
    }

    var existingPDFController: PDFPreviewContentController? {
        primaryRuntimes.pdfContent.existingController
    }

    var existingCSVController: CSVPreviewContentController? {
        primaryRuntimes.csvContent.existingController
    }

    var existingCanvasController: CanvasDocumentContentController? {
        primaryRuntimes.canvasContent.existingController
    }

    var existingImageController: ImagePreviewContentController? {
        primaryRuntimes.imageContent.existingController
    }

    var existingHTMLController: HTMLPreviewContentController? {
        primaryRuntimes.htmlContent.existingController
    }

    var existingEPUBController: EditorWebContentController? {
        primaryRuntimes.epubContent.existingController
    }

    func clearWebContextMarkers() {
        primaryRuntimes.clearWebContextMarkers()
    }

    func updateEditorCommandTarget(
        _ snapshot: WorkspaceEditorCommandTargetSnapshot?,
        replaceCurrentSelection: ((String) -> Bool)?,
        toggleCurrentSelectionHighlight: (() -> Bool)?,
        performEditorBridgeCommand: ((String, [String: ActionValue]) -> Bool)?
    ) {
        editorCommandTargetSnapshot = snapshot
        replaceCurrentSelectionHandler = replaceCurrentSelection
        toggleCurrentSelectionHighlightHandler = toggleCurrentSelectionHighlight
        performEditorBridgeCommandHandler = performEditorBridgeCommand
        logEditorCommandState("target.published")
    }

    func currentEditorCommandTargetSnapshot() -> WorkspaceEditorCommandTargetSnapshot? {
        editorCommandTargetSnapshot
    }

    @discardableResult
    func replaceCurrentSelection(with text: String) -> Bool {
        logEditorCommandState("selection.replace")
        guard let replaceCurrentSelectionHandler else {
            return false
        }
        return replaceCurrentSelectionHandler(text)
    }

    @discardableResult
    func toggleCurrentSelectionHighlight() -> Bool {
        guard let toggleCurrentSelectionHighlightHandler else {
            return false
        }
        return toggleCurrentSelectionHighlightHandler()
    }

    @discardableResult
    func performEditorBridgeCommand(
        _ command: String,
        payload: [String: ActionValue] = [:]
    ) -> Bool {
        logEditorCommandState("command.perform", command: command)
        guard let performEditorBridgeCommandHandler else {
            return false
        }
        return performEditorBridgeCommandHandler(command, payload)
    }

    func logEditorCommandState(_ event: String, command: String = "") {
        let editor = existingTextEditorController
        LocalDiagnosticsCenter.shared.log(category: "editorAction", event: event, metadata: [
            "tabID": tabID.id.uuidString,
            "path": editorCommandTargetSnapshot?.path ?? "none",
            "surface": editorCommandTargetSnapshot?.surfaceKind.rawValue ?? "none",
            "editable": String(editorCommandTargetSnapshot?.isEditable ?? false),
            "supportsReplacement": String(editorCommandTargetSnapshot?.supportsSelectionReplacement ?? false),
            "replacementHandler": String(replaceCurrentSelectionHandler != nil),
            "commandHandler": String(performEditorBridgeCommandHandler != nil),
            "attached": String(editor?.isAttached ?? false),
            "bridgeReady": String(editor?.isBridgeReady ?? false),
            "command": command,
        ])
    }

    func invalidateAllContentControllers() {
        updateEditorCommandTarget(nil, replaceCurrentSelection: nil, toggleCurrentSelectionHighlight: nil, performEditorBridgeCommand: nil)
        primaryRuntimes.invalidate()
    }

    /// Tears down the side stack's web surface. Unlike the content runtimes it
    /// outlives the main document, so only closing the tab ends it.
    func invalidateSideStack() {
        sideStack.invalidate()
    }

    func installRootViewIfNeeded(_ rootView: AnyView) {
        guard !hasInstalledRootView else {
            #if DEBUG
            print("[NVModern][WorkspaceTabController] rootView already installed tab=\(tabID)")
            #endif
            return
        }
        #if DEBUG
        print("[NVModern][WorkspaceTabController] installRootView tab=\(tabID)")
        #endif
        hostingController.rootView = rootView
        hasInstalledRootView = true
    }

    func syncState(_ state: WorkspaceTabState, onChange: @escaping (WorkspaceTabState) -> Void) {
        onStateChange = onChange
        if workspaceState != state {
            workspaceState = state
        }
    }

    func stateBinding() -> Binding<WorkspaceTabState> {
        Binding(
            get: { [weak self] in
                self?.workspaceState ?? .initial
            },
            set: { [weak self] newValue in
                guard let self else { return }
                self.workspaceState = newValue
                self.onStateChange?(newValue)
            }
        )
    }

    func installFocusHandlers(content: (() -> Void)?) {
        #if DEBUG
        print("[NVModern][WorkspaceTabController] installFocusHandlers tab=\(tabID) focusedLeaf=\(isFocusedLeaf) attachedPane=\(String(describing: attachedPaneID)) handlers(content=\(content != nil))")
        #endif
        contentFocusHandler = content
        applyPendingFocusIfPossible()
    }

    func focusContent() {
        queueFocus(.content)
    }

    func setIsFocusedLeaf(_ isFocusedLeaf: Bool) {
        guard self.isFocusedLeaf != isFocusedLeaf else { return }
        #if DEBUG
        print("[NVModern][WorkspaceTabController] setIsFocusedLeaf tab=\(tabID) value=\(isFocusedLeaf) attachedPane=\(String(describing: attachedPaneID))")
        #endif
        self.isFocusedLeaf = isFocusedLeaf
        applyPendingFocusIfPossible()
    }

    func setLifecycleStateChangeHandler(_ handler: (() -> Void)?) {
        onLifecycleStateChange = handler
    }

    func updateHistoryNavigation(
        canGoBack: Bool,
        canGoForward: Bool,
        navigateBack: (() -> Void)?,
        navigateForward: (() -> Void)?
    ) {
        canNavigateBack = canGoBack
        canNavigateForward = canGoForward
        navigateBackHandler = navigateBack
        navigateForwardHandler = navigateForward
    }

    func updateMillerNavigation(
        showInParentFolder: ((String, Bool) -> Bool)?
    ) {
        showInParentFolderHandler = showInParentFolder
    }

    @discardableResult
    func showInParentFolder(relativePath: String, selectDocument: Bool) -> Bool {
        showInParentFolderHandler?(relativePath, selectDocument) ?? false
    }

    func requestMillerHorizontalScroll(to edge: MillerHorizontalScrollEdge) {
        millerHorizontalScrollRequest = MillerHorizontalScrollRequest(
            id: millerHorizontalScrollRequest.id &+ 1,
            edge: edge
        )
    }

    func navigateBackInHistory() {
        navigateBackHandler?()
    }

    func navigateForwardInHistory() {
        navigateForwardHandler?()
    }

    private func queueFocus(_ area: FocusArea) {
        #if DEBUG
        print("[NVModern][WorkspaceTabController] requestFocus tab=\(tabID) area=\(String(describing: area)) focusedLeaf=\(isFocusedLeaf) attachedPane=\(String(describing: attachedPaneID))")
        #endif
        pendingFocusArea = area
        applyPendingFocusIfPossible()
    }

    private func applyPendingFocusIfPossible() {
        guard !isApplyingFocus else { return }
        guard isFocusedLeaf else {
            #if DEBUG
            if let pendingFocusArea {
                print("[NVModern][WorkspaceTabController] pendingFocus blocked tab=\(tabID) area=\(String(describing: pendingFocusArea)) focusedLeaf=\(isFocusedLeaf) attachedPane=\(String(describing: attachedPaneID)) hasHandler=\(focusHandler(for: pendingFocusArea) != nil)")
            }
            #endif
            return
        }

        isApplyingFocus = true
        defer { isApplyingFocus = false }

        while let pendingFocusArea,
              let handler = focusHandler(for: pendingFocusArea) {
            #if DEBUG
            print("[NVModern][WorkspaceTabController] applyPendingFocus tab=\(tabID) area=\(String(describing: pendingFocusArea))")
            #endif
            self.pendingFocusArea = nil
            handler()
            if self.pendingFocusArea == pendingFocusArea {
                self.pendingFocusArea = nil
                break
            }
        }
    }

    private func focusHandler(for area: FocusArea) -> (() -> Void)? {
        switch area {
        case .content:
            return contentFocusHandler
        }
    }
}

@MainActor
final class WorkspaceTabControllerRegistry: ObservableObject {
    private static var nativeShellRegistriesByRoot: [String: WorkspaceTabControllerRegistry] = [:]

    static func nativeShellShared(at rootURL: URL) -> WorkspaceTabControllerRegistry {
        let rootPath = rootURL.standardizedFileURL.path
        if let registry = nativeShellRegistriesByRoot[rootPath] {
            return registry
        }

        let registry = WorkspaceTabControllerRegistry()
        nativeShellRegistriesByRoot[rootPath] = registry
        return registry
    }

    let arborKernelSupervisor: ArborKernelSupervisor
    private var controllers: [TabID: WorkspaceTabController] = [:]
    private var focusedPaneID: PaneID?
    private var indexedArborRootPath: String?
    private var attachmentGCRootPath: String?
    private var attachmentGCTask: Task<Void, Never>?

    init(arborKernelSupervisor: ArborKernelSupervisor = ArborKernelSupervisor()) {
        self.arborKernelSupervisor = arborKernelSupervisor
    }

    deinit {
        attachmentGCTask?.cancel()
        arborKernelSupervisor.shutdown()
    }

    func startAttachmentGC(at rootURL: URL) {
        let rootPath = rootURL.standardizedFileURL.path
        guard attachmentGCRootPath != rootPath else { return }

        attachmentGCTask?.cancel()
        attachmentGCRootPath = rootPath
        attachmentGCTask = Task.detached(priority: .utility) {
            await AttachmentGC.runLoop(rootURL: rootURL)
        }
    }

    func indexArborWorkspace(at rootURL: URL) async {
        let rootPath = rootURL.standardizedFileURL.path
        guard indexedArborRootPath != rootPath else { return }
        if indexedArborRootPath != nil {
            arborKernelSupervisor.shutdown()
        }
        indexedArborRootPath = rootPath
        let documents = await Task.detached {
            let startedAt = ProcessInfo.processInfo.systemUptime
            PerformanceDiagnostics.background(
                kind: "arbor-index",
                event: "load.begin",
                metadata: ["root": rootPath]
            )
            let documents = ArborWorkspaceDocumentLoader.load(from: rootURL)
            PerformanceDiagnostics.background(
                kind: "arbor-index",
                event: "load.end",
                startedAt: startedAt,
                metadata: ["documentCount": String(documents.count), "root": rootPath]
            )
            return documents
        }.value
        for document in documents {
            _ = await arborKernelSupervisor.replaceDocument(
                document,
                requestID: "workspace-index:\(document.id ?? document.path)"
            )
        }
    }

    func upsertController(
        for tabID: TabID,
        makeIfNeeded: () -> WorkspaceTabController,
        configure: (WorkspaceTabController) -> Void
    ) -> WorkspaceTabController {
        let controller: WorkspaceTabController
        if let existing = controllers[tabID] {
            controller = existing
        } else {
            controller = makeIfNeeded()
            install(controller)
            controllers[tabID] = controller
        }

        configure(controller)
        applyFocusState(to: controller)
        return controller
    }

    @discardableResult
    func upsertBoundController(
        for tabID: TabID,
        state: WorkspaceTabState,
        onChange: @escaping (WorkspaceTabState) -> Void,
        makeIfNeeded: () -> WorkspaceTabController,
        rootView: ((WorkspaceTabController) -> AnyView)? = nil
    ) -> WorkspaceTabController {
        upsertController(for: tabID, makeIfNeeded: makeIfNeeded) { controller in
            controller.syncState(state, onChange: onChange)
            if let rootView {
                controller.installRootViewIfNeeded(rootView(controller))
            }
        }
    }

    func controller(for tabID: TabID) -> WorkspaceTabController? {
        controllers[tabID]
    }

    func clearWebContextMarkers(for tabID: TabID) {
        controllers[tabID]?.clearWebContextMarkers()
    }

    func invalidateContentControllers(for tabID: TabID) {
        controllers[tabID]?.invalidateAllContentControllers()
    }

    func setFocusedPaneID(_ paneID: PaneID?) {
        focusedPaneID = paneID
        for controller in controllers.values {
            applyFocusState(to: controller)
        }
    }

    func releaseContentController(for tabID: TabID) {
        guard let controller = controllers.removeValue(forKey: tabID) else { return }
        controller.setLifecycleStateChangeHandler(nil)
        controller.setIsFocusedLeaf(false)
        controller.updateEditorCommandTarget(nil, replaceCurrentSelection: nil, toggleCurrentSelectionHighlight: nil, performEditorBridgeCommand: nil)
        controller.invalidateAllContentControllers()
        controller.invalidateSideStack()
    }

    private func install(_ controller: WorkspaceTabController) {
        controller.setLifecycleStateChangeHandler { [weak self, weak controller] in
            guard let self, let controller else { return }
            applyFocusState(to: controller)
        }
    }

    private func applyFocusState(to controller: WorkspaceTabController) {
        controller.setIsFocusedLeaf(controller.attachedPaneID == focusedPaneID)
    }

}

struct WorkspaceTabControllerRootView<Content: View>: View {
    @ObservedObject var controller: WorkspaceTabController
    let content: (WorkspaceTabController) -> Content

    var body: some View {
        content(controller)
    }
}
