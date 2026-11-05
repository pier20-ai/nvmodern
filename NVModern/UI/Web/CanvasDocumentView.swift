import AppKit
import SwiftUI
import WebKit

/// A retained, file-backed Excalidraw surface owned by a workspace tab.
@MainActor
final class CanvasDocumentContentController: NSObject, WKScriptMessageHandler, WKUIDelegate {
    struct Marker: Equatable {
        let fileURL: URL
        let reloadToken: String
        let isReadOnly: Bool
    }

    let ownerTabID: TabID
    var onDidAttachToWindow: ((NSWindow) -> Void)?
    var onSave: ((Data) throws -> Void)?

    private var webView: WKWebView?
    private weak var hostView: CanvasDocumentContentHostView?
    private var hostColorScheme: String?
    private var currentMarker: Marker?
    private var loadedMarker: Marker?
    private var focusRequestID = 0
    private var lastHandledFocusRequestID = 0
    private var pendingScene: Data?
    private var saveWorkItem: DispatchWorkItem?
    private var isReady = false
    private var isInvalidated = false

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    func matches(marker: Marker) -> Bool { currentMarker == marker }

    func update(marker: Marker, focusRequestID: Int, onSave: @escaping (Data) throws -> Void) {
        if currentMarker != marker {
            flushPendingSave()
            currentMarker = marker
            isReady = false
            pendingScene = nil
        }
        self.focusRequestID = focusRequestID
        self.onSave = onSave
        if let webView {
            loadIfNeeded(in: webView)
            focusIfNeeded(in: webView)
        }
    }

    func attach(to container: NSView) {
        guard !isInvalidated else { return }
        if let host = container as? CanvasDocumentContentHostView {
            hostView = host
            host.onEffectiveAppearanceChange = { [weak self] appearance in
                self?.synchronizeAppearance(using: appearance)
            }
            synchronizeAppearance(using: host.effectiveAppearance)
        }
        let view = ensureWebView()
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        if let window = view.window { onDidAttachToWindow?(window) }
        synchronizeAppearance(using: container.effectiveAppearance)
        loadIfNeeded(in: view)
        focusIfNeeded(in: view)
    }

    func detach() {
        hostView?.onEffectiveAppearanceChange = nil
        hostView = nil
        webView?.removeFromSuperview()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        flushPendingSave()
        isInvalidated = true
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nvmodernCanvas")
        webView?.removeFromSuperview()
        webView = nil
        hostView?.onEffectiveAppearanceChange = nil
        hostView = nil
        currentMarker = nil
        loadedMarker = nil
        onSave = nil
    }

    private func synchronizeAppearance(using appearance: NSAppearance? = nil) {
        let resolved = appearance ?? hostView?.effectiveAppearance ?? NSApp.effectiveAppearance
        let colorScheme = resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        guard hostColorScheme != colorScheme else { return }
        hostColorScheme = colorScheme
        webView?.appearance = NSAppearance(named: colorScheme == "dark" ? .darkAqua : .aqua)
        guard isReady, let webView else { return }
        webView.evaluateJavaScript("window.nvmodernCanvasSetAppearance('\(colorScheme)')") { _, error in
            if let error { print("[NVModern][Canvas] Appearance update failed: \(error)") }
        }
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        configuration.preferences.setValue(true, forKey: "DOMPasteAllowed")
        configuration.userContentController.add(self, name: "nvmodernCanvas")
        let view = WKWebView(frame: .zero, configuration: configuration)
        if let hostColorScheme {
            view.appearance = NSAppearance(named: hostColorScheme == "dark" ? .darkAqua : .aqua)
        }
        view.uiDelegate = self
        #if DEBUG
        view.isInspectable = true
        #endif
        webView = view
        return view
    }

    private func loadIfNeeded(in view: WKWebView) {
        guard let currentMarker, loadedMarker != currentMarker else { return }
        guard let bundleURL = Bundle.main.url(forResource: "canvas", withExtension: "html", subdirectory: "WebEditor")
            ?? Bundle.main.url(forResource: "canvas", withExtension: "html") else {
            print("[NVModern][Canvas] canvas.html is missing from the app bundle")
            return
        }
        loadedMarker = currentMarker
        isReady = false
        view.loadFileURL(bundleURL, allowingReadAccessTo: bundleURL.deletingLastPathComponent())
    }

    private func focusIfNeeded(in view: WKWebView) {
        guard focusRequestID != lastHandledFocusRequestID, let window = view.window else { return }
        window.makeFirstResponder(view)
        lastHandledFocusRequestID = focusRequestID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch event {
        case "ready":
            isReady = true
            guard let marker = currentMarker, let webView else { return }
            synchronizeAppearance(using: hostView?.effectiveAppearance)
            do {
                let scene = try String(contentsOf: marker.fileURL, encoding: .utf8)
                guard Self.isScene(scene) else { throw NSError(domain: "NVModernCanvas", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Excalidraw scene"] ) }
                let appearance = hostColorScheme ?? "light"
                let arguments = try JSONSerialization.data(withJSONObject: [scene, appearance, marker.isReadOnly])
                guard let json = String(data: arguments, encoding: .utf8) else { return }
                webView.evaluateJavaScript("window.nvmodernCanvasLoad(...\(json))") { _, error in
                    if let error { print("[NVModern][Canvas] Load failed: \(error)") }
                }
            } catch {
                print("[NVModern][Canvas] Open failed: \(error)")
                webView.evaluateJavaScript("document.getElementById('root').textContent = 'Could not open canvas';")
            }
        case "change":
            guard isReady, let scene = payload["scene"] as? String, Self.isScene(scene) else { return }
            pendingScene = Data(scene.utf8)
            scheduleSave()
        case "error":
            print("[NVModern][Canvas] \(payload["message"] ?? "Unknown web error")")
        default:
            break
        }
    }

    static func isScene(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["type"] as? String == "excalidraw" && object["elements"] is [Any]
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let data = pendingScene, let onSave else { return }
        do {
            try onSave(data)
            pendingScene = nil
        } catch {
            print("[NVModern][Canvas] Save failed: \(error)")
        }
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
}

private final class CanvasDocumentContentHostView: NSView {
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

struct CanvasDocumentContentHost: NSViewRepresentable {
    let controller: CanvasDocumentContentController
    var backgroundColor: NSColor = .windowBackgroundColor
    var prepareForDisplay: ((CanvasDocumentContentController) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        let view = CanvasDocumentContentHostView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.backgroundColor = backgroundColor.cgColor
        prepareForDisplay?(controller)
        controller.attach(to: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    final class Coordinator {
        let controller: CanvasDocumentContentController
        init(controller: CanvasDocumentContentController) { self.controller = controller }
    }
}
