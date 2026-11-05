import AppKit
import SwiftUI
import WebKit

@MainActor
final class QuickCaptureEditorController: NSObject {
    private let bridge = WebEditorBridge()
    private lazy var coordinator = Coordinator(controller: self, bridge: bridge)
    private let focusTargetID: WindowFocusCoordinator.TargetID = .quickCaptureEditor

    private weak var containerView: NSView?
    private var webView: WKWebView?
    private var currentFileURL: URL?
    private var currentBody = ""
    private var scratchpadSession: ScratchpadFileSession?
    private var reportedScratchpadError: String?
    var onScratchpadBackgroundChange: ((NSColor) -> Void)?
    private var pendingSaveTask: Task<Void, Never>?
    private var wantsFocusWhenReady = false
    private var openCursorPlacement = "end"
    private var lastPushedHostColorScheme: String?
    private var runtimeConfig = NVModernConfigLoader.load()

    override init() {
        super.init()

        bridge.onReady = { [weak self] in
            guard let self else { return }
            registerFocusTargetIfPossible()
            synchronizeHostAppearance(force: true)
            pushCurrentContext(cursorPlacement: openCursorPlacement)
            if wantsFocusWhenReady {
                requestFocus()
                wantsFocusWhenReady = false
            }
        }

        bridge.onEvent = { [weak self] event, payload in
            self?.handleEditorEvent(event: event, payload: payload)
        }

        bridge.onRequest = { [weak self] method, params in
            guard let self else { return nil }
            return try await self.handleEditorRequest(method: method, params: params)
        }
    }

    func prewarm() {
        _ = ensureWebView()
    }

    func attach(to containerView: NSView) {
        self.containerView = containerView

        let webView = ensureWebView()
        if webView.superview !== containerView {
            webView.removeFromSuperview()
            webView.frame = containerView.bounds
            webView.autoresizingMask = [.width, .height]
            containerView.addSubview(webView)
        } else if webView.frame != containerView.bounds {
            webView.frame = containerView.bounds
        }

        registerFocusTargetIfPossible()
        synchronizeHostAppearance(using: containerView.effectiveAppearance)
    }

    func open(fileURL: URL, cursorPlacement: String = "end") {
        runtimeConfig = NVModernConfigLoader.load()
        openCursorPlacement = cursorPlacement
        let standardizedFileURL = fileURL.standardizedFileURL
        currentFileURL = standardizedFileURL
        _ = ensureWebView()
        synchronizeHostAppearance()

        do {
            currentBody = try loadOrCreateBody(from: standardizedFileURL)
            pushCurrentContext(cursorPlacement: cursorPlacement)
            wantsFocusWhenReady = true
            requestFocus()
        } catch {
            currentBody = ""
            print("[NVModern][QuickCapture] Failed to load \(fileURL.path): \(error)")
        }
    }

    /// Persistent windows opt into disk-baseline checks without changing the
    /// transient panel's existing save behavior.
    func openScratchpad(fileURL: URL, cursorPlacement: String) throws {
        let session = try ScratchpadFileSession(fileURL: fileURL)
        scratchpadSession = session
        currentFileURL = fileURL
        currentBody = session.body
        runtimeConfig = NVModernConfigLoader.load()
        openCursorPlacement = cursorPlacement
        _ = ensureWebView()
        synchronizeHostAppearance()
        pushCurrentContext(cursorPlacement: cursorPlacement)
        wantsFocusWhenReady = true
    }

    func refreshScratchpadFromDisk() {
        guard let session = scratchpadSession else { return }
        do {
            if try session.refresh() {
                currentBody = session.body
                pushCurrentContext(cursorPlacement: openCursorPlacement)
            }
        } catch {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            reportScratchpadError(error)
        }
    }

    @discardableResult
    func flushScratchpadSave() -> Bool {
        guard let session = scratchpadSession else { return true }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        do {
            try session.save()
            reportedScratchpadError = nil
            return true
        } catch {
            reportScratchpadError(error, alwaysBeep: true)
            return false
        }
    }

    var hasScratchpadConflict: Bool { scratchpadSession?.hasConflict == true }
    var scratchpadSaveErrorMessage: String? { reportedScratchpadError }

    @discardableResult
    func resolveScratchpadConflict(reloadFromDisk: Bool) -> Bool {
        guard let session = scratchpadSession else { return false }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        do {
            if reloadFromDisk {
                try session.reloadDiscardingLocalEdits()
                currentBody = session.body
                pushCurrentContext(cursorPlacement: openCursorPlacement)
            } else {
                try session.overwriteWithLocalEdits()
            }
            reportedScratchpadError = nil
            return true
        } catch {
            reportScratchpadError(error, alwaysBeep: true)
            return false
        }
    }

    private func reportScratchpadError(_ error: Error, alwaysBeep: Bool = false) {
        let message = error.localizedDescription
        if reportedScratchpadError != message {
            print("[NVModern][Scratchpad] \(currentFileURL?.path ?? ""): \(message)")
            reportedScratchpadError = message
            NSSound.beep()
        } else if alwaysBeep {
            NSSound.beep()
        }
    }

    func requestFocus() {
        guard let webView else {
            wantsFocusWhenReady = true
            return
        }

        registerFocusTargetIfPossible()

        guard bridge.isReadyForCommands else {
            wantsFocusWhenReady = true
            return
        }

        if let window = webView.window ?? containerView?.window {
            WindowFocusCoordinator.shared.setDesiredTarget(focusTargetID, in: window, reason: "quickCapture.requestFocus")
        }

        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(
                "window.focus && window.focus(); document.querySelector('.cm-content') && document.querySelector('.cm-content').focus && document.querySelector('.cm-content').focus();"
            ) { _, error in
                if let error {
                    print("[NVModern][QuickCapture] focus restore failed: \(error)")
                }
            }
        }
    }

    private func registerFocusTargetIfPossible() {
        guard let webView,
              let window = webView.window ?? containerView?.window else {
            return
        }

        WindowFocusCoordinator.shared.registerTarget(
            in: window,
            targetID: focusTargetID,
            debugName: "Quick Capture Editor",
            owner: webView,
            requestFocus: { [weak self] in
                self?.requestFocus()
            },
            ownsFirstResponder: { [weak self] window in
                self?.ownsEditorFocus(in: window) ?? false
            },
            isAvailable: { [weak self, weak webView] in
                guard let self, let webView else { return false }
                return (webView.window === window || self.containerView?.window === window) && self.bridge.isReadyForCommands
            }
        )
    }

    private func ownsEditorFocus(in window: NSWindow) -> Bool {
        guard let webView else { return false }
        if window.firstResponder === webView {
            return true
        }
        guard let firstResponderView = window.firstResponder as? NSView else {
            return false
        }
        return isDescendant(firstResponderView, of: webView)
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var currentView: NSView? = view
        while let resolvedView = currentView {
            if resolvedView === ancestor {
                return true
            }
            currentView = resolvedView.superview
        }
        return false
    }

    func flushPendingSaveIfNeeded() {
        if scratchpadSession != nil {
            _ = flushScratchpadSave()
            return
        }
        guard let fileURL = currentFileURL else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            try save(body: currentBody, to: fileURL)
        } catch {
            print("[NVModern][QuickCapture] Save failed for \(fileURL.path): \(error)")
        }
    }

    private func pushCurrentContext(cursorPlacement: String?) {
        guard let currentFileURL else { return }

        let title = currentFileURL.deletingPathExtension().lastPathComponent
        var payload: [String: Any] = [
            "kind": "text",
            "title": title,
            "path": currentFileURL.path,
            "body": currentBody,
            "users": runtimeConfig.users,
            "substitutionRules": runtimeConfig.substitutions.map { ["from": $0.from, "to": $0.to] },
            "isEditable": true,
            "presentationMode": "quickCapture",
            "showToc": false
        ]
        if let userThemeCSS = runtimeConfig.editorThemeCSS(forPath: currentFileURL.path) {
            payload["userThemeCSS"] = userThemeCSS
        }
        if let cursorPlacement {
            payload["cursorPlacement"] = cursorPlacement
        }

        bridge.sendCommand("setContext", payload: payload)
    }

    func hostAppearanceDidChange(_ appearance: NSAppearance) {
        synchronizeHostAppearance(using: appearance)
    }

    private func webContentDidStartNavigation() {
        lastPushedHostColorScheme = nil
    }

    private func synchronizeHostAppearance(using appearance: NSAppearance? = nil, force: Bool = false) {
        let resolvedAppearance = appearance
            ?? containerView?.effectiveAppearance
            ?? webView?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        let colorScheme = resolvedAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"

        guard force || lastPushedHostColorScheme != colorScheme else {
            return
        }

        lastPushedHostColorScheme = colorScheme
        bridge.sendCommand(
            "setHostAppearance",
            payload: ["colorScheme": colorScheme]
        )
    }

    private func handleEditorEvent(event: String, payload: [String: Any]) {
        switch event {
        case "scratchpadBackground":
            guard scratchpadSession != nil,
                  let color = PageBackgroundReporter.color(from: payload) else { return }
            onScratchpadBackgroundChange?(color)

        case "contentInteraction":
            if let window = webView?.window ?? containerView?.window {
                WindowFocusCoordinator.shared.setDesiredTarget(focusTargetID, in: window, reason: "quickCapture.contentInteraction")
            }

        case "docChange":
            guard let path = payload["path"] as? String,
                  let body = payload["body"] as? String,
                  let currentFileURL,
                  path == currentFileURL.path else {
                return
            }

            currentBody = body
            scratchpadSession?.update(body)
            scheduleSave(body: body, to: currentFileURL)

        case "jsError":
            let message = payload["message"] as? String ?? "Unknown JS error"
            let source = payload["source"] as? String ?? ""
            let line = payload["line"] as? Int ?? 0
            let column = payload["column"] as? Int ?? 0
            print("[NVModern][QuickCapture][WebJS][Error] \(message) @ \(source):\(line):\(column)")

        case "unhandledRejection":
            let message = payload["message"] as? String ?? "Unhandled rejection"
            print("[NVModern][QuickCapture][WebJS][UnhandledRejection] \(message)")

        case "consoleError":
            let args = payload["args"] as? [String] ?? []
            print("[NVModern][QuickCapture][WebJS][console.error] \(args.joined(separator: " "))")

        case "editorInitError":
            let message = payload["message"] as? String ?? "Editor init failed"
            print("[NVModern][QuickCapture][WebJS][EditorInitError] \(message)")

        default:
            break
        }
    }

    private func handleEditorRequest(method: String, params: [String: Any]) async throws -> Any? {
        switch method {
        case "autocomplete.wikilink":
            return ["items": []]
        case "transclusion.resolve":
            return nil
        case "transclusion.save":
            return ["ok": false]
        case "date.pick":
            return nil
        default:
            print("[NVModern][QuickCapture] Unhandled web request method: \(method) params=\(params)")
            return nil
        }
    }

    private func scheduleSave(body: String, to fileURL: URL) {
        pendingSaveTask?.cancel()
        guard scratchpadSession?.hasConflict != true else { return }
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }

            if scratchpadSession != nil {
                _ = flushScratchpadSave()
                return
            }
            do {
                try save(body: body, to: fileURL)
            } catch {
                print("[NVModern][QuickCapture] Save failed for \(fileURL.path): \(error)")
            }

            pendingSaveTask = nil
        }
    }

    private func save(body: String, to fileURL: URL) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadOrCreateBody(from fileURL: URL) throws -> String {
        let parentDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try "".write(to: fileURL, atomically: true, encoding: .utf8)
            return ""
        }

        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func ensureWebView() -> WKWebView {
        if let webView {
            return webView
        }

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
                source: Self.transparentBackgroundScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        if scratchpadSession != nil {
            contentController.addUserScript(WKUserScript(
                source: PageBackgroundReporter.script(event: "scratchpadBackground"),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.setURLSchemeHandler(FontFaceSchemeHandler(), forURLScheme: UserFontFaceCatalog.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 13.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView.configuration.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        webView.configuration.preferences.setValue(true, forKey: "DOMPasteAllowed")

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        bridge.attach(webView: webView)

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebEditor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(Self.missingBundleHTML, baseURL: nil)
        }

        self.webView = webView
        return webView
    }

    private static let transparentBackgroundScript = #"""
    (function () {
      function applyTransparentBackground() {
        try {
          var style = document.getElementById("nvmodern-quick-capture-transparent");
          if (style) return;
          style = document.createElement("style");
          style.id = "nvmodern-quick-capture-transparent";
          style.textContent = [
            "html, body, #root {",
            "  background: transparent !important;",
            "}",
            ".nvmodern-preview-shell, .nvmodern-preview-content {",
            "  background: transparent !important;",
            "}"
          ].join("\n");
          (document.head || document.documentElement).appendChild(style);
        } catch (_) {}
      }

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", applyTransparentBackground, { once: true });
      } else {
        applyTransparentBackground();
      }
    })();
    """#

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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var controller: QuickCaptureEditorController?
        private let bridge: WebEditorBridge

        init(controller: QuickCaptureEditorController, bridge: WebEditorBridge) {
            self.controller = controller
            self.bridge = bridge
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            controller?.webContentDidStartNavigation()
            bridge.webContentDidStartNavigation()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            bridge.receive(messageBody: message.body)
        }
    }
}

struct QuickCaptureEditorView: NSViewRepresentable {
    let controller: QuickCaptureEditorController

    func makeNSView(context: Context) -> NSView {
        let view = QuickCaptureEditorHostView(frame: .zero)
        view.onEffectiveAppearanceChange = { [weak controller] appearance in
            controller?.hostAppearanceDidChange(appearance)
        }
        controller.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.attach(to: nsView)
    }
}

private final class QuickCaptureEditorHostView: NSView {
    var onEffectiveAppearanceChange: ((NSAppearance) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }
}
