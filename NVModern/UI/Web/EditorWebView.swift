import AppKit
import SwiftUI
import WebKit

@MainActor
final class WebEditorBridge: ObservableObject {
    typealias EventHandler = (_ event: String, _ payload: [String: Any]) -> Void
    typealias EventInterceptor = (_ event: String, _ payload: [String: Any]) -> Bool
    typealias RequestHandler = (_ method: String, _ params: [String: Any]) async throws -> Any?

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingScripts: [String] = []
    private var lastEvaluateJavaScriptFailureEvent = ""
    private var lastEvaluateJavaScriptFailureMessage = ""
    private var lastEvaluateJavaScriptFailureReportedAt: TimeInterval = 0
    private var suppressedEvaluateJavaScriptFailureCount = 0

    var performanceTabID: TabID?
    var onReady: (() -> Void)?
    var onInterceptEvent: EventInterceptor?
    var onEvent: EventHandler?
    var onRequest: RequestHandler?

    var isReadyForCommands: Bool {
        isReady
    }

    func attach(webView: WKWebView) {
        if self.webView !== webView {
            isReady = false
        }
        self.webView = webView
    }

    func detach(webView: WKWebView? = nil) {
        if let webView, self.webView !== webView {
            return
        }

        self.webView = nil
        isReady = false
    }

    func webContentDidStartNavigation() {
        isReady = false
    }

    func receive(messageBody: Any) {
        guard let object = messageBody as? [String: Any],
              let kind = object["kind"] as? String
        else {
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.bridge",
                event: "unsupportedMessage",
                metadata: ["messageBody": String(describing: messageBody)]
            )
            print("[NVModern][WebBridge] Unsupported message: \(messageBody)")
            return
        }

        switch kind {
        case "ready":
            markReady()

        case "event":
            guard let event = object["event"] as? String else {
                LocalDiagnosticsCenter.shared.log(level: .warning, category: "web.bridge", event: "missingEventName")
                print("[NVModern][WebBridge] Missing event name")
                return
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if event == "arborTrace" {
                logArborBridge(
                    level: .debug,
                    event: "rendererTrace",
                    metadata: ["payload": diagnosticJSON(payload)]
                )
                return
            }
            if event == "docChange",
               (payload["path"] as? String)?.lowercased().hasSuffix(".outline") == true {
                logArborBridge(
                    event: "rendererDocumentChange",
                    metadata: ["payload": diagnosticJSON(payload)]
                )
            }
            if onInterceptEvent?(event, payload) == true {
                return
            }
            onEvent?(event, payload)

        case "request":
            guard let requestId = object["requestId"] as? String,
                  let method = object["method"] as? String
            else {
                LocalDiagnosticsCenter.shared.log(
                    level: .warning,
                    category: "web.bridge",
                    event: "invalidRequestEnvelope",
                    metadata: ["message": String(describing: object)]
                )
                print("[NVModern][WebBridge] Invalid request envelope")
                return
            }

            let params = object["params"] as? [String: Any] ?? [:]
            let arborRequest = method.hasPrefix("arbor.")
            let startedAt = ProcessInfo.processInfo.systemUptime
            if arborRequest {
                logArborBridge(
                    event: "rendererRequest",
                    metadata: [
                        "method": method,
                        "requestID": requestId,
                        "params": diagnosticJSON(params)
                    ]
                )
            }
            Task { [weak self] in
                guard let self else { return }

                do {
                    guard let handler = self.onRequest else {
                        throw NSError(
                            domain: "NVModern.WebBridge",
                            code: 500,
                            userInfo: [NSLocalizedDescriptionKey: "No request handler registered"]
                        )
                    }

                    let result = try await handler(method, params)
                    if arborRequest {
                        self.logArborBridge(
                            event: "hostResponse",
                            metadata: [
                                "durationMs": String(format: "%.1f", max(
                                    0,
                                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                                )),
                                "method": method,
                                "requestID": requestId,
                                "result": self.diagnosticJSON(result)
                            ]
                        )
                    }
                    self.sendResponse(requestId: requestId, result: result, error: nil)
                } catch {
                    if arborRequest {
                        self.logArborBridge(
                            level: .error,
                            event: "hostResponseError",
                            metadata: [
                                "durationMs": String(format: "%.1f", max(
                                    0,
                                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                                )),
                                "error": String(describing: error),
                                "method": method,
                                "requestID": requestId
                            ]
                        )
                    }
                    self.sendResponse(requestId: requestId, result: nil, error: String(describing: error))
                }
            }

        default:
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.bridge",
                event: "unknownMessageKind",
                metadata: ["kind": kind]
            )
            print("[NVModern][WebBridge] Unknown message kind '\(kind)'")
        }
    }

    func sendCommand(_ command: String, payload: [String: Any]) {
        if command == "setContext", let performanceTabID {
            PerformanceDiagnostics.markNewTab(tabID: performanceTabID, event: "web.setContext", metadata: [
                "kind": payload["kind"] as? String ?? "",
                "path": payload["path"] as? String ?? "",
                "bridgeReady": String(isReady)
            ])
        }
        let envelope: [String: Any] = [
            "kind": "command",
            "command": command,
            "payload": Self.jsonSafeValue(payload)
        ]

        send(envelope: envelope)
    }

    private func sendResponse(requestId: String, result: Any?, error: String?) {
        var envelope: [String: Any] = [
            "kind": "response",
            "requestId": requestId
        ]

        if let error {
            envelope["error"] = error
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.bridge",
                event: "swiftResponseError",
                metadata: [
                    "requestId": requestId,
                    "error": error
                ]
            )
            print("[NVModern][WebBridge] Swift response id=\(requestId) error=\(error)")
        } else {
            envelope["result"] = Self.jsonSafeValue(result)
        }

        send(envelope: envelope)
    }

    private func send(envelope: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: []),
              let json = String(data: data, encoding: .utf8)
        else {
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.bridge",
                event: "serializeMessageFailed",
                metadata: ["envelope": String(describing: envelope)]
            )
            print("[NVModern][WebBridge] Unable to serialize message")
            return
        }

        let script = "(function(){ if (window.nvmodernReceive) { window.nvmodernReceive(\(json)); } return null; })();"
        enqueueOrRun(script: script)
    }

    private func logArborBridge(
        level: LocalDiagnosticLevel = .info,
        event: String,
        metadata: [String: String]
    ) {
        LocalDiagnosticsCenter.shared.log(
            level: level,
            category: "arbor.bridge",
            event: event,
            metadata: metadata
        )
    }

    private func diagnosticJSON(_ value: Any?) -> String {
        let safe = Self.jsonSafeValue(value)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(
                withJSONObject: safe,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return text
    }

    private func enqueueOrRun(script: String) {
        guard isReady else {
            pendingScripts.append(script)
            return
        }

        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                if self.recordEvaluateJavaScriptFailure(event: "evaluateJavaScriptFailed", error: error) {
                    print("[NVModern][WebBridge] evaluateJavaScript failed: \(error)")
                }
            }
        }
    }

    private func markReady() {
        if let performanceTabID {
            PerformanceDiagnostics.markNewTab(tabID: performanceTabID, event: "web.ready")
        }
        isReady = true
        // Flush any commands that were queued while the bundle was still loading
        // before firing `onReady`. The tab view's ready handler may immediately
        // send a fresh `setContext`, and that latest push must win over any older
        // queued startup/restore context.
        flushPendingScripts()
        onReady?()
    }

    private func flushPendingScripts() {
        let queued = pendingScripts
        pendingScripts.removeAll()

        for script in queued {
            webView?.evaluateJavaScript(script) { _, error in
                if let error {
                    if self.recordEvaluateJavaScriptFailure(event: "flushQueuedScriptFailed", error: error) {
                        print("[NVModern][WebBridge] evaluateJavaScript failed while flushing queue: \(error)")
                    }
                }
            }
        }
    }

    @discardableResult
    private func recordEvaluateJavaScriptFailure(event: String, error: Error) -> Bool {
        let message = error.localizedDescription
        let now = ProcessInfo.processInfo.systemUptime
        if event == lastEvaluateJavaScriptFailureEvent,
           message == lastEvaluateJavaScriptFailureMessage,
           now - lastEvaluateJavaScriptFailureReportedAt < 5 {
            suppressedEvaluateJavaScriptFailureCount += 1
            return false
        }

        var metadata = ["error": message]
        if suppressedEvaluateJavaScriptFailureCount > 0 {
            metadata["suppressedDuplicates"] = String(suppressedEvaluateJavaScriptFailureCount)
        }
        suppressedEvaluateJavaScriptFailureCount = 0
        lastEvaluateJavaScriptFailureEvent = event
        lastEvaluateJavaScriptFailureMessage = message
        lastEvaluateJavaScriptFailureReportedAt = now

        LocalDiagnosticsCenter.shared.log(
            level: .error,
            category: "web.bridge",
            event: event,
            metadata: metadata
        )
        return true
    }

    nonisolated static func jsonSafeValue(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }

        switch value {
        case let string as String:
            return string
        // JSONSerialization represents both JSON numbers and booleans as
        // NSNumber. Preserve that identity before Swift's Bool bridging can
        // turn the numbers 0 and 1 into false and true.
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.path
        case let array as [Any]:
            return array.map { jsonSafeValue($0) }
        case let dict as [String: Any]:
            return dict.mapValues { jsonSafeValue($0) }
        case let array as NSArray:
            return array.map { jsonSafeValue($0) }
        case let dict as NSDictionary:
            var result: [String: Any] = [:]
            dict.forEach { key, value in
                if let key = key as? String {
                    result[key] = jsonSafeValue(value)
                }
            }
            return result
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}

private func resolvedColor(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
    var resolvedColor = color
    appearance.performAsCurrentDrawingAppearance {
        resolvedColor = NSColor(cgColor: color.cgColor) ?? color
    }
    return resolvedColor
}

private func resolvedTextBackgroundColor(for appearance: NSAppearance) -> NSColor {
    resolvedColor(.textBackgroundColor, for: appearance)
}

private enum WebEditorHostColorScheme: String {
    case light
    case dark

    static func resolve(from appearance: NSAppearance?) -> WebEditorHostColorScheme {
        let resolvedAppearance = appearance ?? NSApp.effectiveAppearance
        return resolvedAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    var backgroundColor: NSColor {
        let resolvedAppearance = nsAppearance ?? NSApp.effectiveAppearance
        return resolvedTextBackgroundColor(for: resolvedAppearance)
    }
}

fileprivate struct WebEditorContextMenuContext {
    struct ArborBlock {
        let canMoveUp: Bool
        let canMoveDown: Bool
    }

    struct OrgTodo {
        let current: String
        let states: [String]
    }

    let kind: String
    let isEditable: Bool
    let selectedText: String
    let isInMarkdownTable: Bool
    let arborBlock: ArborBlock?
    let orgTodo: OrgTodo?
}

private struct WebEditorContextMenuAction {
    enum Kind {
        case responder(Selector)
        case bridge(String)
    }

    let title: String
    let kind: Kind
    var isEnabled = true
    var state: NSControl.StateValue = .off

    static let undo = WebEditorContextMenuAction(title: "Undo", kind: .responder(Selector(("undo:"))))
    static let redo = WebEditorContextMenuAction(title: "Redo", kind: .responder(Selector(("redo:"))))
    static let cut = WebEditorContextMenuAction(title: "Cut", kind: .responder(#selector(NSText.cut(_:))))
    static let copy = WebEditorContextMenuAction(title: "Copy", kind: .responder(#selector(NSText.copy(_:))))
    static let paste = WebEditorContextMenuAction(title: "Paste", kind: .responder(#selector(NSText.paste(_:))))
    static let selectAll = WebEditorContextMenuAction(title: "Select All", kind: .responder(#selector(NSResponder.selectAll(_:))))
    static let markdownTableInsertRowAbove = WebEditorContextMenuAction(title: "Insert Row Above", kind: .bridge("markdownTableInsertRowAbove"))
    static let markdownTableInsertRowBelow = WebEditorContextMenuAction(title: "Insert Row Below", kind: .bridge("markdownTableInsertRowBelow"))
    static let markdownTableDeleteRow = WebEditorContextMenuAction(title: "Delete Row", kind: .bridge("markdownTableDeleteRow"))
    static let markdownTableMoveRowUp = WebEditorContextMenuAction(title: "Move Row Up", kind: .bridge("markdownTableMoveRowUp"))
    static let markdownTableMoveRowDown = WebEditorContextMenuAction(title: "Move Row Down", kind: .bridge("markdownTableMoveRowDown"))
    static let markdownTableInsertColumnLeft = WebEditorContextMenuAction(title: "Insert Column Left", kind: .bridge("markdownTableInsertColumnLeft"))
    static let markdownTableInsertColumnRight = WebEditorContextMenuAction(title: "Insert Column Right", kind: .bridge("markdownTableInsertColumnRight"))
    static let markdownTableDeleteColumn = WebEditorContextMenuAction(title: "Delete Column", kind: .bridge("markdownTableDeleteColumn"))
    static let markdownTableMoveColumnLeft = WebEditorContextMenuAction(title: "Move Column Left", kind: .bridge("markdownTableMoveColumnLeft"))
    static let markdownTableMoveColumnRight = WebEditorContextMenuAction(title: "Move Column Right", kind: .bridge("markdownTableMoveColumnRight"))
    static let markdownTableAlignColumnLeft = WebEditorContextMenuAction(title: "Left", kind: .bridge("markdownTableAlignColumnLeft"))
    static let markdownTableAlignColumnCenter = WebEditorContextMenuAction(title: "Center", kind: .bridge("markdownTableAlignColumnCenter"))
    static let markdownTableAlignColumnRight = WebEditorContextMenuAction(title: "Right", kind: .bridge("markdownTableAlignColumnRight"))
    static let markdownTableClearCell = WebEditorContextMenuAction(title: "Clear Cell", kind: .bridge("markdownTableClearCell"))
    static let arborCopyText = WebEditorContextMenuAction(title: "Copy Text", kind: .bridge("arborContextMenu.copyText"))
    static let arborCopyID = WebEditorContextMenuAction(title: "Copy ID", kind: .bridge("arborContextMenu.copyId"))
    static let arborDelete = WebEditorContextMenuAction(title: "Delete", kind: .bridge("arborContextMenu.delete"))
}

private enum WebEditorContextMenuEntry {
    case action(WebEditorContextMenuAction)
    case submenu(String, [WebEditorContextMenuEntry])
    case separator
}

@MainActor
private final class WebEditorContextMenuController: NSObject {
    weak var webView: WKWebView?
    private let bridge: WebEditorBridge
    var contextProvider: () -> WebEditorContextMenuContext = {
        WebEditorContextMenuContext(
            kind: "unsupported",
            isEditable: false,
            selectedText: "",
            isInMarkdownTable: false,
            arborBlock: nil,
            orgTodo: nil
        )
    }

    init(bridge: WebEditorBridge) {
        self.bridge = bridge
    }

    func makeMenu() -> NSMenu {
        focusWebViewIfNeeded()

        let context = contextProvider()
        let menu = NSMenu(title: "Editor")
        menu.autoenablesItems = context.arborBlock == nil && context.orgTodo == nil

        for entry in menuEntries(for: context) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                menu.addItem(makeMenuItem(for: action))
            case .submenu(let title, let entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeSubmenu(title: title, entries: entries)
                menu.addItem(item)
            }
        }

        if context.arborBlock == nil, context.orgTodo == nil {
            let trimmedSelection = context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSelection.isEmpty {
                menu.addItem(.separator())
                menu.addItem(makeLookUpMenuItem(for: trimmedSelection))
            }

            menu.addItem(.separator())
            menu.addItem(makeMenuItem(for: .selectAll))
        }
        return menu
    }

    private var lastMenuPoint: CGPoint = .zero

    func presentMenu(atViewportPoint viewportPoint: CGPoint) {
        guard let webView else {
            return
        }

        let menu = makeMenu()
        let fallbackPoint = fallbackMenuPoint(in: webView)
        let localPoint = localMenuPoint(for: viewportPoint, in: webView, fallback: fallbackPoint)
        lastMenuPoint = localPoint
        menu.popUp(positioning: nil, at: localPoint, in: webView)
    }

    @objc
    private func performBridgeAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            return
        }
        focusWebViewIfNeeded()
        bridge.sendCommand(command, payload: [:])
    }

    @objc
    private func performLookUp(_ sender: NSMenuItem) {
        guard let webView,
              let selectedText = sender.representedObject as? String else {
            return
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        focusWebViewIfNeeded()
        webView.showDefinition(
            for: NSAttributedString(string: trimmed),
            at: lastMenuPoint
        )
    }

    private func focusWebViewIfNeeded() {
        guard let webView,
              let window = webView.window,
              window.firstResponder !== webView else {
            return
        }

        window.makeFirstResponder(webView)
    }

    private func localMenuPoint(for viewportPoint: CGPoint, in webView: WKWebView, fallback: CGPoint) -> CGPoint {
        let bounds = webView.bounds
        guard viewportPoint.x.isFinite,
              viewportPoint.y.isFinite,
              viewportPoint.x >= 0,
              viewportPoint.y >= 0 else {
            return clampMenuPoint(fallback, in: bounds)
        }

        let convertedPoint = CGPoint(
            x: viewportPoint.x,
            y: webView.isFlipped ? viewportPoint.y : (bounds.height - viewportPoint.y)
        )
        return clampMenuPoint(convertedPoint, in: bounds)
    }

    private func fallbackMenuPoint(in webView: WKWebView) -> CGPoint {
        guard let window = webView.window else {
            return CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = webView.convert(windowPoint, from: nil)
        return clampMenuPoint(viewPoint, in: webView.bounds)
    }

    private func clampMenuPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX + 1), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY + 1), bounds.maxY - 1)
        )
    }

    private func menuEntries(for context: WebEditorContextMenuContext) -> [WebEditorContextMenuEntry] {
        if let orgTodo = context.orgTodo {
            return orgTodo.states.map { state in
                .action(WebEditorContextMenuAction(
                    title: state,
                    kind: .bridge("orgTodoSet.\(state)"),
                    isEnabled: context.isEditable,
                    state: state == orgTodo.current ? .on : .off
                ))
            }
        }

        if let arborBlock = context.arborBlock {
            return [
                .action(.arborCopyText),
                .action(.arborCopyID),
                .separator,
                .action(WebEditorContextMenuAction(
                    title: "Move Up",
                    kind: .bridge("arborContextMenu.moveUp"),
                    isEnabled: context.isEditable && arborBlock.canMoveUp
                )),
                .action(WebEditorContextMenuAction(
                    title: "Move Down",
                    kind: .bridge("arborContextMenu.moveDown"),
                    isEnabled: context.isEditable && arborBlock.canMoveDown
                )),
                .separator,
                .action(WebEditorContextMenuAction(
                    title: WebEditorContextMenuAction.arborDelete.title,
                    kind: WebEditorContextMenuAction.arborDelete.kind,
                    isEnabled: context.isEditable
                ))
            ]
        }

        if context.isEditable {
            var entries: [WebEditorContextMenuEntry] = [
                .action(.undo),
                .action(.redo),
                .separator,
                .action(.cut),
                .action(.copy),
                .action(.paste)
            ]
            if context.kind == "text", context.isInMarkdownTable {
                entries.append(.separator)
                entries.append(contentsOf: markdownTableMenuEntries())
            }
            return entries
        }

        return [.action(.copy)]
    }

    private func markdownTableMenuEntries() -> [WebEditorContextMenuEntry] {
        [
            .submenu("Row", [
                .action(.markdownTableInsertRowAbove),
                .action(.markdownTableInsertRowBelow),
                .separator,
                .action(.markdownTableDeleteRow),
                .separator,
                .action(.markdownTableMoveRowUp),
                .action(.markdownTableMoveRowDown)
            ]),
            .submenu("Column", [
                .action(.markdownTableInsertColumnLeft),
                .action(.markdownTableInsertColumnRight),
                .separator,
                .action(.markdownTableDeleteColumn),
                .separator,
                .action(.markdownTableMoveColumnLeft),
                .action(.markdownTableMoveColumnRight),
                .separator,
                .submenu("Align", [
                    .action(.markdownTableAlignColumnLeft),
                    .action(.markdownTableAlignColumnCenter),
                    .action(.markdownTableAlignColumnRight)
                ])
            ]),
            .submenu("Cell", [
                .action(.markdownTableClearCell)
            ])
        ]
    }

    private func makeSubmenu(title: String, entries: [WebEditorContextMenuEntry]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = true

        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                menu.addItem(makeMenuItem(for: action))
            case .submenu(let title, let entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeSubmenu(title: title, entries: entries)
                menu.addItem(item)
            }
        }

        return menu
    }

    private func makeMenuItem(for action: WebEditorContextMenuAction) -> NSMenuItem {
        switch action.kind {
        case .responder(let selector):
            let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
            item.target = nil
            item.isEnabled = action.isEnabled
            item.state = action.state
            return item
        case .bridge(let command):
            let item = NSMenuItem(title: action.title, action: #selector(performBridgeAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.isEnabled = action.isEnabled
            item.state = action.state
            return item
        }
    }

    private func lookUpMenuTitle(for selectedText: String) -> String {
        let collapsed = selectedText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let preview = collapsed.count > 40 ? String(collapsed.prefix(37)) + "…" : collapsed
        return "Look Up \"\(preview)\""
    }

    private func makeLookUpMenuItem(for selectedText: String) -> NSMenuItem {
        let item = NSMenuItem(title: lookUpMenuTitle(for: selectedText), action: #selector(performLookUp(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = selectedText
        return item
    }
}

final class EditorWebContentHostView: NSView {
    var backgroundColor: NSColor = .textBackgroundColor {
        didSet {
            updateResolvedBackgroundColor()
        }
    }

    var onEffectiveAppearanceChange: ((NSAppearance) -> Void)?
    var onWindowChange: ((EditorWebContentHostView) -> Void)?

    override var wantsUpdateLayer: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateResolvedBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateResolvedBackgroundColor()
        onEffectiveAppearanceChange?(effectiveAppearance)
        onWindowChange?(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateResolvedBackgroundColor()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }

    override func updateLayer() {
        super.updateLayer()
        updateResolvedBackgroundColor()
    }

    override func layout() {
        super.layout()
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }

    private func updateResolvedBackgroundColor() {
        layer?.backgroundColor = resolvedColor(backgroundColor, for: effectiveAppearance).cgColor
    }
}

private final class EditorWKWebView: WKWebView {
    let contextMenuController: WebEditorContextMenuController
    var onEffectiveAppearanceChange: ((NSAppearance) -> Void)?
    private var appliedHostColorScheme: WebEditorHostColorScheme?

    init(frame: CGRect, configuration: WKWebViewConfiguration, bridge: WebEditorBridge) {
        contextMenuController = WebEditorContextMenuController(bridge: bridge)
        super.init(frame: frame, configuration: configuration)
        contextMenuController.webView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }

    func applyHostAppearance(_ colorScheme: WebEditorHostColorScheme) {
        guard appliedHostColorScheme != colorScheme else {
            return
        }
        appliedHostColorScheme = colorScheme
        let backgroundColor = colorScheme.backgroundColor
        appearance = colorScheme.nsAppearance
        setValue(true, forKey: "drawsBackground")
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        if #available(macOS 13.0, *) {
            underPageBackgroundColor = backgroundColor
        }
        needsDisplay = true
    }
}

/// Persistent tab-scoped editor content controller.
///
/// The `WKWebView` stays alive across tab switches so the editor JS runtime and CM state do
/// not need to reboot every time a text tab becomes active again. Crucially, the web view is
/// detached from the AppKit view hierarchy while inactive, which prevents hidden surfaces from
/// participating in cursor rect / tracking updates.
@MainActor
final class EditorWebContentController {
    struct ContextMarker: Equatable {
        let kind: String
        let path: String
        let reloadToken: String
        let isEditable: Bool
    }

    let ownerTabID: TabID
    let bridge = WebEditorBridge()
    /// Bundled page this controller loads: `index` (the editor) or `stack`
    /// (the side stack, ticket 0031). Both speak the same bridge.
    let entryResource: String

    private let previewFileSchemeHandler: PreviewFileSchemeHandler
    private let coordinator: Coordinator
    private var instantiatedWebView: WKWebView?
    private weak var hostView: EditorWebContentHostView?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var lastKnownHostColorScheme = WebEditorHostColorScheme.resolve(from: nil)
    private var lastQueuedHostColorScheme: WebEditorHostColorScheme?
    var onDidAttachToWindow: ((NSWindow) -> Void)?
    var onProcessTermination: (() -> Void)?
    private var isInvalidated = false
    private var lastPushedContextMarker: ContextMarker?
    private var needsReloadAfterProcessTermination = false

    init(ownerTabID: TabID, rootURL: URL, entryResource: String = "index") {
        self.ownerTabID = ownerTabID
        self.entryResource = entryResource
        if entryResource == "index" {
            bridge.performanceTabID = ownerTabID
        }
        previewFileSchemeHandler = PreviewFileSchemeHandler(rootURL: rootURL)
        coordinator = Coordinator(bridge: bridge, ownerTabID: ownerTabID)
        coordinator.onDidStartNavigation = { [weak self] in
            if let webView = self?.instantiatedWebView { AppHelpService.shared.dismiss(ownedBy: webView) }
            self?.lastQueuedHostColorScheme = nil
        }
        coordinator.onProcessTermination = { [weak self] webView in
            AppHelpService.shared.dismiss(ownedBy: webView)
            self?.handleProcessTermination(for: webView)
        }
        bridge.onInterceptEvent = { [weak self] event, payload in
            guard let self else { return false }
            return self.handleBridgeEventIntercept(event: event, payload: payload)
        }
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeAppearance()
            }
        }
    }

    var isAttached: Bool {
        instantiatedWebView?.superview != nil
    }

    var isBridgeReady: Bool {
        bridge.isReadyForCommands
    }

    func updateRootURL(_ rootURL: URL) {
        previewFileSchemeHandler.updateRootURL(rootURL)
    }

    func synchronizeAppearance(using appearance: NSAppearance? = nil) {
        guard !isInvalidated else { return }

        let resolvedAppearance = appearance
            ?? hostView?.effectiveAppearance
            ?? instantiatedWebView?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        let resolvedColorScheme = WebEditorHostColorScheme.resolve(from: resolvedAppearance)
        lastKnownHostColorScheme = resolvedColorScheme
        hostView?.backgroundColor = resolvedColorScheme.backgroundColor

        if let webView = instantiatedWebView as? EditorWKWebView {
            webView.applyHostAppearance(resolvedColorScheme)
        } else {
            instantiatedWebView?.appearance = resolvedColorScheme.nsAppearance
            instantiatedWebView?.wantsLayer = true
            instantiatedWebView?.layer?.backgroundColor = resolvedColorScheme.backgroundColor.cgColor
            if #available(macOS 13.0, *) {
                instantiatedWebView?.underPageBackgroundColor = resolvedColorScheme.backgroundColor
            }
        }

        guard lastQueuedHostColorScheme != resolvedColorScheme else {
            return
        }

        lastQueuedHostColorScheme = resolvedColorScheme
        bridge.sendCommand(
            "setHostAppearance",
            payload: ["colorScheme": resolvedColorScheme.rawValue]
        )
    }

    func attach(to containerView: NSView) {
        guard !isInvalidated else { return }

        guard containerView.window != nil else {
            return
        }

        if let resolvedHostView = containerView as? EditorWebContentHostView {
            hostView = resolvedHostView
            resolvedHostView.onEffectiveAppearanceChange = { [weak self] appearance in
                Task { @MainActor [weak self] in
                    self?.synchronizeAppearance(using: appearance)
                }
            }
            synchronizeAppearance(using: resolvedHostView.effectiveAppearance)
        }

        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.session.attach.start")
        let webView = ensureWebView()

        if webView.superview !== containerView {
            webView.removeFromSuperview()
            webView.frame = containerView.bounds
            webView.autoresizingMask = [.width, .height]
            containerView.addSubview(webView)
        } else if webView.frame != containerView.bounds {
            webView.frame = containerView.bounds
        }

        synchronizeAppearance(using: containerView.effectiveAppearance)

        if let window = webView.window {
            onDidAttachToWindow?(window)
        }

        DispatchQueue.main.async { [weak self, weak containerView, weak webView] in
            guard let self, !self.isInvalidated, let containerView, let webView, webView.superview === containerView else {
                return
            }
            if webView.frame != containerView.bounds {
                webView.frame = containerView.bounds
            }
        }

        WorkspaceActivationTraceCenter.shared.mark(
            tabID: ownerTabID,
            event: "web.session.attach.end",
            details: [
                "bridgeReady": isBridgeReady ? "true" : "false",
                "attached": isAttached ? "true" : "false"
            ]
        )
        if isBridgeReady && isAttached && entryResource == "index" {
            WorkspaceActivationTraceCenter.shared.finishIfExpected(
                tabID: ownerTabID,
                mode: .webAttachReady,
                event: "web.ready.reusedSession",
                details: [
                    "bridgeReady": "true",
                    "attached": "true"
                ]
            )
        }
    }

    @discardableResult
    func replaceSelection(with text: String, expectedPath: String) -> Bool {
        guard !isInvalidated,
              isAttached,
              let lastPushedContextMarker,
              lastPushedContextMarker.kind == "text",
              lastPushedContextMarker.path == expectedPath else {
            logRejectedEditorCommand("replaceSelection", expectedPath: expectedPath)
            return false
        }

        bridge.sendCommand(
            "replaceSelection",
            payload: [
                "path": expectedPath,
                "text": text
            ]
        )
        requestFocus()
        return true
    }

    @discardableResult
    func toggleMarkdownHighlightSelection(expectedPath: String) -> Bool {
        guard !isInvalidated,
              isAttached,
              let lastPushedContextMarker,
              lastPushedContextMarker.kind == "text",
              lastPushedContextMarker.path == expectedPath else {
            logRejectedEditorCommand("toggleMarkdownHighlightSelection", expectedPath: expectedPath)
            return false
        }

        bridge.sendCommand(
            "toggleMarkdownHighlightSelection",
            payload: [
                "path": expectedPath
            ]
        )
        requestFocus()
        return true
    }

    @discardableResult
    func performEditorCommand(
        _ command: String,
        expectedPath: String,
        payload: [String: ActionValue] = [:]
    ) -> Bool {
        guard !isInvalidated,
              isAttached,
              let lastPushedContextMarker,
              lastPushedContextMarker.kind == "text",
              lastPushedContextMarker.path == expectedPath else {
            logRejectedEditorCommand(command, expectedPath: expectedPath)
            return false
        }

        var bridgePayload = payload.mapValues { $0.jsonObject() }
        bridgePayload["path"] = expectedPath
        bridge.sendCommand(command, payload: bridgePayload)
        requestFocus()
        return true
    }

    private func logRejectedEditorCommand(_ command: String, expectedPath: String) {
        LocalDiagnosticsCenter.shared.log(category: "editorAction", event: "bridge.rejected", metadata: [
            "command": command,
            "expectedPath": expectedPath,
            "contextPath": lastPushedContextMarker?.path ?? "none",
            "contextKind": lastPushedContextMarker?.kind ?? "none",
            "attached": String(isAttached),
            "invalidated": String(isInvalidated),
            "bridgeReady": String(isBridgeReady),
        ])
    }

    func requestFocus() {
        guard !isInvalidated,
              let webView = instantiatedWebView,
              webView.superview != nil else {
            return
        }

        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript("window.focus && window.focus(); document.querySelector('.cm-content') && document.querySelector('.cm-content').focus && document.querySelector('.cm-content').focus();") { _, error in
                if let error {
                    print("[NVModern][WebView] focus restore failed: \(error)")
                }
            }
        }
    }

    /// Whether keyboard focus is inside this controller's web view.
    var isWebViewFirstResponder: Bool {
        guard let webView = instantiatedWebView,
              let responder = webView.window?.firstResponder as? NSView else {
            return false
        }
        return responder === webView || responder.isDescendant(of: webView)
    }

    /// Makes the web view first responder without focusing any element in
    /// the page; the caller sends its own focus command.
    @discardableResult
    func makeWebViewFirstResponder() -> Bool {
        guard !isInvalidated,
              let webView = instantiatedWebView,
              let window = webView.window else {
            return false
        }
        return window.makeFirstResponder(webView)
    }

    func resignFocusIfNeeded() {
        guard let webView = instantiatedWebView,
              let window = webView.window,
              let responder = window.firstResponder as? NSView,
              responder === webView || responder.isDescendant(of: webView) else {
            return
        }
        window.makeFirstResponder(nil)
    }

    func detach() {
        detach(from: nil)
    }

    func detach(from containerView: NSView?) {
        if let containerView,
           let currentSuperview = instantiatedWebView?.superview,
           currentSuperview !== containerView {
            if hostView === containerView {
                hostView?.onEffectiveAppearanceChange = nil
                hostView = nil
            }
            return
        }

        if let webView = instantiatedWebView { AppHelpService.shared.dismiss(ownedBy: webView) }
        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.session.detach")
        if containerView == nil || hostView === containerView {
            hostView?.onEffectiveAppearanceChange = nil
            hostView = nil
        }
        instantiatedWebView?.removeFromSuperview()
    }

    var lastKnownSelectedText: String {
        coordinator.lastKnownSelectedText
    }

    func queryEditorContext(_ query: WorkspaceEditorContextQuery) async -> WorkspaceEditorContextSnapshot? {
        guard let webView = instantiatedWebView else { return nil }

        let payload: [String: Any] = [
            "includeSelection": query.includeSelection,
            "includeViewport": query.includeViewport,
            "includeCursor": query.includeCursor,
            "radiusLines": query.radiusLines,
            "maxChars": query.maxChars
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let script = """
        (function() {
          var fn = window.nvmodernQueryEditorContext;
          if (typeof fn !== 'function') return null;
          var result = fn(\(json));
          return result == null ? null : JSON.stringify(result);
        })()
        """

        do {
            let raw = try await webView.evaluateJavaScript(script)
            guard let encoded = raw as? String,
                  let encodedData = encoded.data(using: .utf8)
            else {
                return nil
            }
            let decoded = try JSONDecoder().decode(JSEditorContextPayload.self, from: encodedData)
            return WorkspaceEditorContextSnapshot(
                path: decoded.path,
                title: decoded.title,
                surface: "primary",
                selection: decoded.selection,
                viewport: decoded.viewport,
                cursor: decoded.cursor
            )
        } catch {
            return nil
        }
    }

    /// Runs an annotation request against the mounted text editor. Returns nil
    /// while no editor is mounted or it shows a different document than
    /// `request["expectedPath"]`, so callers can wait for a document to load.
    func performAnnotationRequest(_ request: [String: ActionValue]) async -> ActionValue? {
        guard let webView = instantiatedWebView,
              let data = try? JSONEncoder().encode(ActionValue.object(request)),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let script = """
        (function() {
          var fn = window.nvmodernAnnotations;
          if (typeof fn !== 'function') return null;
          var result = fn(\(json));
          return result == null ? null : JSON.stringify(result);
        })()
        """

        do {
            guard let encoded = try await webView.evaluateJavaScript(script) as? String,
                  let encodedData = encoded.data(using: .utf8)
            else {
                return nil
            }
            return try JSONDecoder().decode(ActionValue.self, from: encodedData)
        } catch {
            return nil
        }
    }

    private struct JSEditorContextPayload: Decodable {
        var path: String?
        var title: String?
        var selection: WorkspaceEditorSelectionSnapshot?
        var viewport: WorkspaceEditorTextSlice?
        var cursor: WorkspaceEditorCursorSnapshot?
    }

    func shouldPushContext(_ marker: ContextMarker) -> Bool {
        if lastPushedContextMarker == marker {
            return false
        }
        if let webView = instantiatedWebView { AppHelpService.shared.dismiss(ownedBy: webView) }
        lastPushedContextMarker = marker
        return true
    }

    func clearContextMarker() {
        if let webView = instantiatedWebView { AppHelpService.shared.dismiss(ownedBy: webView) }
        lastPushedContextMarker = nil
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if let webView = instantiatedWebView { AppHelpService.shared.dismiss(ownedBy: webView) }

        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
            self.systemAppearanceObserver = nil
        }

        hostView?.onEffectiveAppearanceChange = nil
        hostView = nil

        guard let webView = instantiatedWebView else { return }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nvmodern")
        webView.removeFromSuperview()
        bridge.detach(webView: webView)
        lastPushedContextMarker = nil
        lastQueuedHostColorScheme = nil
        instantiatedWebView = nil
    }

    deinit {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
    }

    private func handleBridgeEventIntercept(event: String, payload: [String: Any]) -> Bool {
        switch event {
        case "help.browse":
            if let webView = instantiatedWebView, webView.window != nil {
                AppHelpService.shared.present(providerID: payload["providerID"] as? String, in: webView)
            }
            return true

        case "help.open":
            guard let webView = instantiatedWebView, webView.window != nil,
                  let providerID = payload["providerID"] as? String,
                  let token = payload["token"] as? String else { return true }
            let marker = lastPushedContextMarker
            AppHelpService.shared.present(
                providerID: providerID, in: webView,
                canInsert: payload["canInsert"] as? Bool ?? false,
                allowsMultiline: payload["allowsMultiline"] as? Bool ?? false,
                onInsert: { [weak self, weak webView] template in
                    guard let self, let webView, self.instantiatedWebView === webView,
                          webView.window != nil, !self.isInvalidated, self.lastPushedContextMarker == marker else { return }
                    self.bridge.sendCommand("help.insert", payload: ["token": token, "template": template])
                },
                onClose: { [weak self, weak webView] in
                    guard let self, let webView, self.instantiatedWebView === webView,
                          webView.window != nil, !self.isInvalidated, self.lastPushedContextMarker == marker else { return }
                    self.bridge.sendCommand("help.closed", payload: ["token": token])
                }
            )
            return true

        case "contextMenuRequested":
            guard let webView = instantiatedWebView as? EditorWKWebView else {
                return true
            }

            let x = (payload["x"] as? NSNumber)?.doubleValue ?? payload["x"] as? Double ?? 0
            let y = (payload["y"] as? NSNumber)?.doubleValue ?? payload["y"] as? Double ?? 0
            coordinator.lastKnownSelectedText = payload["selectionText"] as? String ?? ""
            coordinator.lastKnownContextMenuIsInMarkdownTable = payload["markdownTable"] is [String: Any]
            if let arbor = payload["arbor"] as? [String: Any] {
                coordinator.lastKnownArborContextMenuBlock = WebEditorContextMenuContext.ArborBlock(
                    canMoveUp: arbor["canMoveUp"] as? Bool ?? false,
                    canMoveDown: arbor["canMoveDown"] as? Bool ?? false
                )
            } else {
                coordinator.lastKnownArborContextMenuBlock = nil
            }
            if let orgTodo = payload["orgTodo"] as? [String: Any] {
                coordinator.lastKnownOrgTodoMenu = WebEditorContextMenuContext.OrgTodo(
                    current: orgTodo["current"] as? String ?? "",
                    states: orgTodo["states"] as? [String] ?? []
                )
            } else {
                coordinator.lastKnownOrgTodoMenu = nil
            }
            webView.contextMenuController.presentMenu(
                atViewportPoint: CGPoint(x: x, y: y)
            )
            return true

        default:
            return false
        }
    }

    /// Load the bundle without attaching a surface or accepting a document.
    /// The owning tab runtime retains this controller until the spare is used.
    func prewarm() {
        guard !isInvalidated else { return }
        _ = ensureWebView()
    }

    private func ensureWebView() -> WKWebView {
        if let instantiatedWebView {
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.webView.reuse")
            if needsReloadAfterProcessTermination {
                needsReloadAfterProcessTermination = false
                WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.reloadDeferredAfterTermination")
                loadEditorBundle(in: instantiatedWebView)
            }
            return instantiatedWebView
        }

        PerformanceDiagnostics.markNewTab(tabID: ownerTabID, event: "web.webView.create.start")
        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.webView.create.start")
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: "nvmodern")
        contentController.addUserScript(
            WKUserScript(
                source: Self.bridgeDebugScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: PageBackgroundReporter.script(event: "pageBackground"),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.setURLSchemeHandler(
            previewFileSchemeHandler,
            forURLScheme: PreviewFileSchemeHandler.scheme
        )
        configuration.setURLSchemeHandler(FontFaceSchemeHandler(), forURLScheme: UserFontFaceCatalog.scheme)

        let webView = EditorWKWebView(frame: .zero, configuration: configuration, bridge: bridge)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        // Appearance is driven from the host view during attach and host appearance changes.
        // Listening to the WKWebView's own effective-appearance changes creates a feedback
        // path because applying the host appearance mutates the web view appearance.
        webView.contextMenuController.contextProvider = { [weak self] in
            guard let self,
                  let marker = self.lastPushedContextMarker else {
                return WebEditorContextMenuContext(
                    kind: "unsupported",
                    isEditable: false,
                    selectedText: "",
                    isInMarkdownTable: false,
                    arborBlock: nil,
                    orgTodo: nil
                )
            }
            return WebEditorContextMenuContext(
                kind: marker.kind,
                isEditable: marker.isEditable,
                selectedText: self.coordinator.lastKnownSelectedText,
                isInMarkdownTable: self.coordinator.lastKnownContextMenuIsInMarkdownTable,
                arborBlock: self.coordinator.lastKnownArborContextMenuBlock,
                orgTodo: self.coordinator.lastKnownOrgTodoMenu
            )
        }
        webView.setValue(true, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = lastKnownHostColorScheme.backgroundColor.cgColor
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView.configuration.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        webView.configuration.preferences.setValue(true, forKey: "DOMPasteAllowed")

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        bridge.attach(webView: webView)
        synchronizeAppearance(using: hostView?.effectiveAppearance)
        PerformanceDiagnostics.markNewTab(tabID: ownerTabID, event: "web.webView.create.end")
        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.webView.create.end")
        loadEditorBundle(in: webView)

        instantiatedWebView = webView
        return webView
    }

    private func loadEditorBundle(in webView: WKWebView) {
        lastQueuedHostColorScheme = nil
        synchronizeAppearance()
        if let indexURL = Bundle.main.url(forResource: entryResource, withExtension: "html", subdirectory: "WebEditor")
            ?? Bundle.main.url(forResource: entryResource, withExtension: "html")
        {
            let readAccessURL = indexURL.deletingLastPathComponent()
            print("[NVModern][WebView] Loading editor bundle from \(indexURL.path)")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.loadFileURL", details: ["index": indexURL.path])
            webView.loadFileURL(indexURL, allowingReadAccessTo: readAccessURL)
        } else {
            print("[NVModern][WebView] Missing bundled index.html")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.missingBundle")
            webView.loadHTMLString(Self.missingBundleHTML, baseURL: nil)
        }
    }

    private func handleProcessTermination(for webView: WKWebView) {
        guard !isInvalidated,
              instantiatedWebView === webView else {
            return
        }

        lastPushedContextMarker = nil
        bridge.webContentDidStartNavigation()

        if isAttached {
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.reloadAfterTermination")
            loadEditorBundle(in: webView)
        } else {
            needsReloadAfterProcessTermination = true
        }

        onProcessTermination?()
    }

    private static let bridgeDebugScript = #"""
    (function () {
      function send(event, payload) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nvmodern;
          if (!handler) return;
          handler.postMessage({ kind: "event", event: event, payload: payload || {} });
        } catch (_) {}
      }

      var originalError = console.error;
      console.error = function () {
        try {
          var args = Array.prototype.slice.call(arguments).map(function (value) {
            if (typeof value === "string") return value;
            try { return JSON.stringify(value); } catch (_) { return String(value); }
          });
          send("consoleError", { args: args });
        } catch (_) {}
        return originalError.apply(console, arguments);
      };

      window.addEventListener("error", function (event) {
        var payload = {
          message: event && event.message ? String(event.message) : "Unknown JS error",
          source: event && event.filename ? String(event.filename) : "",
          line: event && event.lineno ? Number(event.lineno) : 0,
          column: event && event.colno ? Number(event.colno) : 0,
          stack: event && event.error && event.error.stack ? String(event.error.stack) : ""
        };
        send("jsError", payload);
      });

      window.addEventListener("unhandledrejection", function (event) {
        var reason = event && event.reason ? event.reason : "Unhandled rejection";
        var text = typeof reason === "string" ? reason : (reason && reason.message ? reason.message : String(reason));
        var stack = reason && reason.stack ? String(reason.stack) : "";
        send("unhandledRejection", { message: text, stack: stack });
      });
    })();
    """#

    private static let missingBundleHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset=\"utf-8\" />
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 16px; }
          .err { color: #b00020; }
        </style>
      </head>
      <body>
        <p class=\"err\">Web editor bundle not found. Run <code>make</code> to build bundled web assets.</p>
      </body>
    </html>
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let bridge: WebEditorBridge
        private let ownerTabID: TabID
        var onDidStartNavigation: (() -> Void)?
        var onProcessTermination: ((WKWebView) -> Void)?
        var lastKnownSelectedText = ""
        var lastKnownContextMenuIsInMarkdownTable = false
        fileprivate var lastKnownArborContextMenuBlock: WebEditorContextMenuContext.ArborBlock?
        fileprivate var lastKnownOrgTodoMenu: WebEditorContextMenuContext.OrgTodo?

        init(bridge: WebEditorBridge, ownerTabID: TabID) {
            self.bridge = bridge
            self.ownerTabID = ownerTabID
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[NVModern][WebView] didStartProvisionalNavigation")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.didStart")
            onDidStartNavigation?()
            lastKnownSelectedText = ""
            lastKnownContextMenuIsInMarkdownTable = false
            lastKnownArborContextMenuBlock = nil
            lastKnownOrgTodoMenu = nil
            bridge.webContentDidStartNavigation()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[NVModern][WebView] didFinishNavigation")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.didFinish")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.navigation",
                event: "didFailNavigation",
                metadata: [
                    "tabID": String(describing: ownerTabID),
                    "error": error.localizedDescription
                ]
            )
            print("[NVModern][WebView] didFailNavigation error=\(error)")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.didFail", details: ["error": String(describing: error)])
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.navigation",
                event: "didFailProvisionalNavigation",
                metadata: [
                    "tabID": String(describing: ownerTabID),
                    "error": error.localizedDescription
                ]
            )
            print("[NVModern][WebView] didFailProvisionalNavigation error=\(error)")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.didFailProvisional", details: ["error": String(describing: error)])
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            LocalDiagnosticsCenter.shared.log(
                level: .fault,
                category: "web.navigation",
                event: "contentProcessTerminated",
                metadata: ["tabID": String(describing: ownerTabID)]
            )
            print("[NVModern][WebView] content process terminated")
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "web.navigation.processTerminated")
            onProcessTermination?(webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            bridge.receive(messageBody: message.body)
        }
    }
}

struct EditorWebContentHost: NSViewRepresentable {
    let controller: EditorWebContentController
    var backgroundColor: NSColor = .textBackgroundColor
    var prepareForDisplay: ((EditorWebContentController) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> EditorWebContentHostView {
        let view = EditorWebContentHostView(frame: .zero)
        view.backgroundColor = backgroundColor
        view.onEffectiveAppearanceChange = { appearance in
            Task { @MainActor in
                controller.synchronizeAppearance(using: appearance)
            }
        }
        return view
    }

    func updateNSView(_ nsView: EditorWebContentHostView, context: Context) {
        if context.coordinator.controller !== controller {
            context.coordinator.controller.detach(from: nsView)
            context.coordinator.controller = controller
        }
        nsView.backgroundColor = backgroundColor
        nsView.onEffectiveAppearanceChange = { appearance in
            Task { @MainActor in
                controller.synchronizeAppearance(using: appearance)
            }
        }
        nsView.onWindowChange = { view in
            prepareForDisplay?(controller)
            guard view.window != nil else {
                return
            }
            controller.attach(to: view)
        }
        nsView.onWindowChange?(nsView)
    }

    static func dismantleNSView(_ nsView: EditorWebContentHostView, coordinator: Coordinator) {
        nsView.onEffectiveAppearanceChange = nil
        nsView.onWindowChange = nil
        coordinator.controller.detach(from: nsView)
    }

    final class Coordinator {
        var controller: EditorWebContentController

        init(controller: EditorWebContentController) {
            self.controller = controller
        }
    }
}
