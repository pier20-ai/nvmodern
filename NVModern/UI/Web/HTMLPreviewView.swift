import AppKit
import SwiftUI
import WebKit

@MainActor
final class HTMLPreviewContentController {
    struct Marker: Equatable {
        let fileURL: URL
        let readAccessURL: URL
        let reloadToken: String
    }

    let ownerTabID: TabID

    private var instantiatedWebView: WKWebView?
    private var currentMarker: Marker?
    private var loadedMarker: Marker?
    private var focusRequestID = 0
    private var lastHandledFocusRequestID = 0
    private var isInvalidated = false

    var onDidAttachToWindow: ((NSWindow) -> Void)?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    func matches(marker: Marker) -> Bool {
        currentMarker == marker
    }

    func update(marker: Marker, focusRequestID: Int) {
        currentMarker = marker
        self.focusRequestID = focusRequestID

        if let webView = instantiatedWebView {
            loadIfNeeded(in: webView)
            focusIfNeeded(in: webView)
        }
    }

    func attach(to containerView: NSView) {
        guard !isInvalidated else { return }

        let webView = ensureWebView()
        if webView.superview !== containerView {
            webView.removeFromSuperview()
            webView.frame = containerView.bounds
            webView.autoresizingMask = [.width, .height]
            containerView.addSubview(webView)
        } else if webView.frame != containerView.bounds {
            webView.frame = containerView.bounds
        }

        if let window = webView.window {
            onDidAttachToWindow?(window)
        }

        loadIfNeeded(in: webView)
        focusIfNeeded(in: webView)
    }

    func detach() {
        instantiatedWebView?.removeFromSuperview()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        instantiatedWebView?.stopLoading()
        instantiatedWebView?.removeFromSuperview()
        instantiatedWebView = nil
        currentMarker = nil
        loadedMarker = nil
    }

    private func ensureWebView() -> WKWebView {
        if let instantiatedWebView {
            return instantiatedWebView
        }

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        instantiatedWebView = webView
        return webView
    }

    private func loadIfNeeded(in webView: WKWebView) {
        guard let currentMarker,
              loadedMarker != currentMarker else {
            return
        }

        loadedMarker = currentMarker
        webView.loadFileURL(
            currentMarker.fileURL,
            allowingReadAccessTo: currentMarker.readAccessURL
        )
    }

    private func focusIfNeeded(in webView: WKWebView) {
        guard focusRequestID != lastHandledFocusRequestID,
              let window = webView.window else {
            return
        }

        window.makeFirstResponder(webView)
        lastHandledFocusRequestID = focusRequestID
    }
}

struct HTMLPreviewContentHost: NSViewRepresentable {
    let controller: HTMLPreviewContentController
    var backgroundColor: NSColor = .windowBackgroundColor
    var prepareForDisplay: ((HTMLPreviewContentController) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.cgColor
        prepareForDisplay?(controller)
        controller.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    final class Coordinator {
        let controller: HTMLPreviewContentController

        init(controller: HTMLPreviewContentController) {
            self.controller = controller
        }
    }
}
