import AppKit
import Combine
import SwiftUI

/// Native side of a tab's side stack (ticket 0031): hosts the `stack.html`
/// web surface, keeps the card bodies it shows, and turns stack events into
/// tab navigation. Owned by the tab's `WorkspaceTabController`, so the web
/// view and its card editors survive tab switches and main-view navigation.
///
/// The card list itself lives in `WorkspaceTabState.sideStack` (persisted with
/// the tab); the tab view binds read/write access to it. Bodies are never
/// persisted: they are read from the workspace when the stack renders and
/// re-read when the note is saved or changes on disk.
@MainActor
final class SideStackController {
    let ownerTabID: TabID
    private let bridgeService: DocumentSurfaceBridgeService
    private(set) var webController: EditorWebContentController?

    private weak var notesModel: NotesWorkspaceModel?
    private var readState: () -> SideStackState = { .empty }
    private var writeState: (SideStackState) -> Void = { _ in }
    private var isBound = false

    /// Full note text per workspace path. A path is absent until first read.
    private var bodies: [String: String] = [:]
    private var loadingPaths: Set<String> = []
    private var pendingRevealID: String?
    private var pendingFlashID: String?
    private var pendingFocusID: String??
    /// Body of each card as last sent, to skip redundant `setStack` pushes.
    private var lastSentSignature: [String]?
    private var lastSentThemeCSS: String??
    private var modelSubscriptions: Set<AnyCancellable> = []
    private var observedModel: ObjectIdentifier?
    private var isInvalidated = false

    /// Open `path` in the tab's main view, jumping to `focus` when set.
    var onOpenInMain: ((String, SideStackFocus?) -> Void)?
    /// A workspace file from a Markdown/Org link in a card.
    var onOpenWorkspaceFile: ((String) -> Void)?
    /// Pointer or focus inside the stack.
    var onInteraction: (() -> Void)?
    /// Return keyboard focus to the main document.
    var onFocusMain: (() -> Void)?

    init(ownerTabID: TabID, bridgeService: DocumentSurfaceBridgeService) {
        self.ownerTabID = ownerTabID
        self.bridgeService = bridgeService
    }

    // MARK: - Binding

    /// Connects the controller to its tab's state and workspace. Called by the
    /// tab view whenever it appears; rebinding is cheap.
    func bind(
        notesModel: NotesWorkspaceModel,
        read: @escaping () -> SideStackState,
        write: @escaping (SideStackState) -> Void
    ) {
        guard !isInvalidated else { return }
        readState = read
        writeState = write
        isBound = true
        if observedModel != ObjectIdentifier(notesModel) {
            self.notesModel = notesModel
            observedModel = ObjectIdentifier(notesModel)
            bodies.removeAll()
            lastSentSignature = nil
            subscribe(to: notesModel)
        }
        let controller = ensureWebController(rootURL: notesModel.runtimeConfig.rootURL)
        controller.updateRootURL(notesModel.runtimeConfig.rootURL)
        render()
    }

    var state: SideStackState {
        readState()
    }

    /// Whether keyboard focus is in the stack's web view.
    var hasKeyboardFocus: Bool {
        webController?.isWebViewFirstResponder ?? false
    }

    /// The text card a note can become: Markdown, Org, and plain text.
    nonisolated static func isStackable(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return stackableExtensions.contains(ext)
    }

    nonisolated static let stackableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "org", "txt", "text"]

    /// Resolves what a caller names — a workspace-relative path, an absolute
    /// path inside the workspace, or a bare note name — to a workspace path.
    func resolveWorkspacePath(_ raw: String) -> String? {
        guard let notesModel else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rootPath = notesModel.runtimeConfig.rootURL.standardizedFileURL.path
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard standardized.hasPrefix(prefix) else { return nil }
            return String(standardized.dropFirst(prefix.count))
        }
        if let url = notesModel.workspaceURL(for: trimmed),
           FileManager.default.fileExists(atPath: url.path) {
            return trimmed
        }
        return notesModel.resolveWikilinkTarget(trimmed, from: nil)
    }

    // MARK: - Mutations

    /// Pushes a card for `path` (focused on `focus`), or reveals and flashes
    /// the card already showing the same path and focus.
    @discardableResult
    func push(path: String, focus: SideStackFocus?) -> SideStackState.PushOutcome {
        var next = state
        let outcome = next.push(path: path, focus: focus)
        switch outcome {
        case .added(let id):
            pendingRevealID = id
        case .existing(let id):
            pendingFlashID = id
        }
        commit(next)
        return outcome
    }

    /// Pushes a stackable note; anything else (PDF, image, CSV…) opens in
    /// the main view instead.
    func pushOrOpenInMain(path: String, focus: SideStackFocus?) {
        if Self.isStackable(path: path) {
            push(path: path, focus: focus)
        } else {
            onOpenInMain?(path, focus)
        }
    }

    @discardableResult
    func close(id: String) -> Bool {
        var next = state
        guard next.close(id: id) else { return false }
        commit(next)
        return true
    }

    func clear() {
        var next = state
        next.clear()
        commit(next)
    }

    /// Shows or hides the column; the cards stay either way.
    @discardableResult
    func toggleVisibility() -> Bool {
        var next = state
        next.isOpen.toggle()
        commit(next)
        return next.isOpen
    }

    func setOpen(_ isOpen: Bool) {
        var next = state
        guard next.isOpen != isOpen else { return }
        next.isOpen = isOpen
        commit(next)
    }

    func setWidth(_ width: Double) {
        var next = state
        let clamped = SideStackState.clampedWidth(width)
        guard next.width != clamped else { return }
        next.width = clamped
        commit(next)
    }

    /// Moves keyboard focus into the stack, opening the column if needed.
    /// Returns false when there is nothing to focus.
    @discardableResult
    func focusStack(cardID: String? = nil) -> Bool {
        var next = state
        if !next.isOpen {
            next.isOpen = true
            commit(next)
        }
        pendingFocusID = .some(cardID)
        applyPendingFocusIfPossible()
        return true
    }

    /// Toggles focus between the main document and the stack. Returns the
    /// area that has focus afterwards ("stack" or "main").
    @discardableResult
    func toggleFocus() -> String {
        if hasKeyboardFocus {
            onFocusMain?()
            return "main"
        }
        focusStack()
        return "stack"
    }

    private func commit(_ next: SideStackState) {
        let hadFocus = hasKeyboardFocus
        writeState(next)
        render(next)
        // Hiding the column must not strand keyboard focus in a detached view.
        if !next.isOpen, hadFocus {
            onFocusMain?()
        }
    }

    // MARK: - Note changes

    /// The main editor saved `path`; refresh any card showing it.
    func noteDidSave(path: String, body: String) {
        guard state.cards.contains(where: { $0.path == path }) else { return }
        guard bodies[path] != body else { return }
        bodies[path] = body
        render()
    }

    private func subscribe(to notesModel: NotesWorkspaceModel) {
        modelSubscriptions.removeAll()
        notesModel.$lastLiveSyncUpdate
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                MainActor.assumeIsolated {
                    self?.applyLiveUpdate(update)
                }
            }
            .store(in: &modelSubscriptions)
        notesModel.$runtimeConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sendTheme()
                }
            }
            .store(in: &modelSubscriptions)
    }

    private func applyLiveUpdate(_ update: WorkspaceLiveSyncUpdate) {
        guard isBound else { return }
        var next = state
        var changedState = false
        if next.applyRenames(update.renamedPaths) {
            for (oldPath, newPath) in update.renamedPaths {
                if let body = bodies.removeValue(forKey: oldPath) {
                    bodies[newPath] = body
                }
            }
            changedState = true
        }
        if next.removeCards(atPaths: update.externalDeletedPaths) {
            changedState = true
        }
        if changedState {
            writeState(next)
        }

        let cardPaths = Set(next.cards.map(\.path))
        let touched = update.changedPaths
            .union(update.externalModifiedPaths)
            .union(update.selfWriteConfirmedPaths)
            .intersection(cardPaths)
        for path in touched {
            reloadBody(path: path)
        }
        if changedState {
            render(next)
        }
    }

    // MARK: - Rendering

    private func render(_ explicitState: SideStackState? = nil) {
        guard !isInvalidated, isBound else { return }
        let current = explicitState ?? state
        // Bodies load lazily: only once the column's page is up.
        guard let webController, webController.isBridgeReady else { return }

        let missing = Set(current.cards.map(\.path)).filter { bodies[$0] == nil }
        if !missing.isEmpty {
            for path in missing {
                loadBody(path: path)
            }
            return
        }

        let cards: [[String: Any]] = current.cards.map { card in
            var payload: [String: Any] = [
                "id": card.id,
                "path": card.path,
                "body": bodies[card.path] ?? "",
                "collapsed": card.collapsed
            ]
            if let focus = card.focus {
                payload["focus"] = focus.bridgePayload
            }
            if let showWholeNote = card.showWholeNote {
                payload["showWholeNote"] = showWholeNote
            }
            return payload
        }
        let signature = current.cards.map { card in
            "\(card.id)|\(card.collapsed)|\(String(describing: card.showWholeNote))|\(bodies[card.path]?.hashValue ?? 0)"
        }

        if signature != lastSentSignature || pendingRevealID != nil {
            var payload: [String: Any] = ["cards": cards]
            if let pendingRevealID {
                payload["revealId"] = pendingRevealID
            }
            webController.bridge.sendCommand("setStack", payload: payload)
            lastSentSignature = signature
        }
        pendingRevealID = nil

        if let pendingFlashID {
            webController.bridge.sendCommand("flashCard", payload: ["id": pendingFlashID])
            self.pendingFlashID = nil
        }
        applyPendingFocusIfPossible()
    }

    private func loadBody(path: String) {
        guard !loadingPaths.contains(path) else { return }
        guard let url = notesModel?.workspaceURL(for: path) else {
            bodies[path] = ""
            render()
            return
        }
        loadingPaths.insert(path)
        Task { @MainActor [weak self] in
            let text = (try? await WorkspaceFileIO.shared.readText(from: url)) ?? nil
            guard let self, !self.isInvalidated else { return }
            self.loadingPaths.remove(path)
            self.bodies[path] = text ?? ""
            self.render()
        }
    }

    /// Re-reads a card's note after a change on disk, keeping the old body on
    /// screen until the new one arrives.
    private func reloadBody(path: String) {
        guard let url = notesModel?.workspaceURL(for: path) else { return }
        Task { @MainActor [weak self] in
            let text = (try? await WorkspaceFileIO.shared.readText(from: url)) ?? nil
            guard let self, !self.isInvalidated else { return }
            guard let text, self.bodies[path] != text else { return }
            self.bodies[path] = text
            self.render()
        }
    }

    private func sendTheme(force: Bool = false) {
        guard let webController, let notesModel else { return }
        let css = notesModel.runtimeConfig.editorThemeCSS(forPath: nil)
        if !force, let lastSentThemeCSS, lastSentThemeCSS == css {
            return
        }
        lastSentThemeCSS = .some(css)
        webController.bridge.sendCommand("setTheme", payload: ["userThemeCSS": css as Any])
    }

    private func applyPendingFocusIfPossible() {
        guard let pendingFocusID,
              let webController,
              webController.isAttached else {
            return
        }
        guard webController.makeWebViewFirstResponder() else { return }
        self.pendingFocusID = nil
        var payload: [String: Any] = [:]
        if let id = pendingFocusID {
            payload["id"] = id
        }
        webController.bridge.sendCommand("focusStack", payload: payload)
    }

    // MARK: - Web surface

    /// The stack's web surface. Creating it is cheap: the web view itself is
    /// only built when the column first attaches.
    @discardableResult
    func ensureWebController(rootURL: URL) -> EditorWebContentController {
        if let webController {
            return webController
        }
        let controller = EditorWebContentController(ownerTabID: ownerTabID, rootURL: rootURL, entryResource: "stack")
        controller.onDidAttachToWindow = { [weak self] _ in
            self?.applyPendingFocusIfPossible()
        }
        controller.onProcessTermination = { [weak self] in
            self?.lastSentSignature = nil
            self?.lastSentThemeCSS = nil
        }
        controller.bridge.onReady = { [weak self] in
            guard let self else { return }
            self.lastSentSignature = nil
            self.sendTheme(force: true)
            self.render()
        }
        controller.bridge.onEvent = { [weak self] event, payload in
            self?.handleEvent(event, payload: payload)
        }
        controller.bridge.onRequest = { [weak self] method, params in
            guard let self else { return nil }
            return try await self.handleRequest(method: method, params: params)
        }
        webController = controller
        return controller
    }

    func invalidate() {
        isInvalidated = true
        modelSubscriptions.removeAll()
        webController?.invalidate()
        webController = nil
        onOpenInMain = nil
        onOpenWorkspaceFile = nil
        onInteraction = nil
        onFocusMain = nil
    }

    // MARK: - Bridge

    private func handleRequest(method: String, params: [String: Any]) async throws -> Any? {
        // Cards are read-only: they resolve embeds and nothing else.
        guard method == "transclusion.resolve", let notesModel else {
            throw NSError(
                domain: "NVModern.SideStack",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported side stack request \(method)"]
            )
        }
        var policy = DocumentSurfaceBridgeService.WritePolicy()
        policy.isReadOnly = true
        policy.allowsWorkspaceWrites = false
        if case .handled(let result) = try await bridgeService.handleSharedRequest(
            method: method,
            params: params,
            notesModel: notesModel,
            policy: policy
        ) {
            return result
        }
        return nil
    }

    private func handleEvent(_ event: String, payload: [String: Any]) {
        switch event {
        case "stackOpenInMain":
            guard let path = Self.nonEmptyString(payload["path"]) else { return }
            onOpenInMain?(path, Self.focus(from: payload["focus"]))

        case "stackClose":
            guard let id = Self.nonEmptyString(payload["id"]) else { return }
            close(id: id)

        case "stackCollapse":
            guard let id = Self.nonEmptyString(payload["id"]),
                  let collapsed = payload["collapsed"] as? Bool else { return }
            var next = state
            guard next.setCollapsed(collapsed, id: id) else { return }
            commit(next)

        case "stackShowWholeNote":
            guard let id = Self.nonEmptyString(payload["id"]),
                  let showWholeNote = payload["showWholeNote"] as? Bool else { return }
            var next = state
            guard next.setShowWholeNote(showWholeNote, id: id) else { return }
            commit(next)

        case "stackLinkOpen":
            guard let notesModel,
                  let target = Self.nonEmptyString(payload["target"]) else { return }
            var linkPayload: [String: Any] = ["target": target]
            if let fromPath = Self.nonEmptyString(payload["fromPath"]) {
                linkPayload["filePath"] = fromPath
            }
            guard let navigation = DocumentSurfaceBridgeService.wikilinkNavigation(
                payload: linkPayload,
                notesModel: notesModel
            ) else {
                NSSound.beep()
                return
            }
            let focus = SideStackFocus(reference: navigation.reference)
            if Self.intentIsPush(payload) {
                pushOrOpenInMain(path: navigation.path, focus: focus)
            } else {
                onOpenInMain?(navigation.path, focus)
            }

        case "stackInlineLinkOpen":
            if Self.intentIsPush(payload),
               let resolvedPath = Self.nonEmptyString(payload["resolvedPath"]),
               Self.isStackable(path: resolvedPath) {
                push(path: resolvedPath, focus: nil)
                return
            }
            DocumentSurfaceBridgeService.routeInlineLink(payload: payload) { [weak self] path in
                self?.onOpenWorkspaceFile?(path)
            }

        case "contentInteraction":
            onInteraction?()

        case "pageBackground":
            return

        case "mainScriptLoadError", "jsError", "unhandledRejection", "consoleError":
            LocalDiagnosticsCenter.shared.log(
                level: event == "consoleError" ? .warning : .error,
                category: "web.stack",
                event: event,
                metadata: ["payload": String(describing: payload)]
            )
            print("[NVModern][WebStack] \(event) payload=\(payload)")

        default:
            return
        }
    }

    private static func intentIsPush(_ payload: [String: Any]) -> Bool {
        if let intent = payload["intent"] as? String {
            return intent == "push"
        }
        return payload["shiftKey"] as? Bool == true
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    static func focus(from value: Any?) -> SideStackFocus? {
        guard let object = value as? [String: Any] else { return nil }
        return SideStackFocus(heading: object["heading"] as? String, block: object["block"] as? String)
    }
}

/// Lays the side stack out beside the tab's main content. The column sits to
/// the right with a draggable divider; when the main content would drop below
/// `minimumMainWidth` it overlays the content from the right as a sheet
/// instead of squeezing it.
struct SideStackColumnLayout<Primary: View, Stack: View>: View {
    static var minimumMainWidth: CGFloat { 520 }

    let isPresented: Bool
    let width: Double
    let onWidthCommit: (Double) -> Void
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let stack: () -> Stack

    @State private var containerWidth: CGFloat = 0
    @State private var dragWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private var columnWidth: CGFloat {
        dragWidth ?? CGFloat(width)
    }

    private var overlaysContent: Bool {
        containerWidth > 0 && containerWidth - columnWidth - 1 < Self.minimumMainWidth
    }

    var body: some View {
        // `primary` keeps one structural position whether or not the column
        // is shown, so toggling the stack never rebuilds the tab's surface.
        HStack(spacing: 0) {
            primary()
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

            if isPresented && !overlaysContent {
                divider
                stack()
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .trailing) {
            if isPresented && overlaysContent {
                stack()
                    .frame(width: min(columnWidth, max(240, containerWidth - 48)))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(DesignTokens.TextStyle.tertiary.opacity(0.22))
                            .frame(width: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 14, x: -4, y: 0)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignTokens.TextStyle.tertiary.opacity(0.22))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartWidth ?? CGFloat(width)
                                if dragStartWidth == nil {
                                    dragStartWidth = start
                                }
                                let maxForWindow = max(
                                    CGFloat(SideStackState.widthRange.lowerBound),
                                    containerWidth - Self.minimumMainWidth - 1
                                )
                                let proposed = start - value.translation.width
                                dragWidth = min(
                                    maxForWindow,
                                    CGFloat(SideStackState.clampedWidth(Double(proposed)))
                                )
                            }
                            .onEnded { _ in
                                if let dragWidth {
                                    onWidthCommit(Double(dragWidth))
                                }
                                dragWidth = nil
                                dragStartWidth = nil
                            }
                    )
                    .onHover { isHovering in
                        (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
            }
    }
}

/// The stack's web surface, hosted from the tab's `SideStackController`.
struct SideStackSurface: View {
    let controller: EditorWebContentController

    var body: some View {
        EditorWebContentHost(controller: controller, backgroundColor: .textBackgroundColor)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
