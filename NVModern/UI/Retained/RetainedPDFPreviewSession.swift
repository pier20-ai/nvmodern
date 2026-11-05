import AppKit
import PDFKit
import SwiftUI

@MainActor
final class PDFPreviewContentController {
    struct Marker: Equatable {
        let fileURL: URL
        let reloadToken: String
    }

    let ownerTabID: TabID

    private var instantiatedView: ZoomablePDFView?
    /// Holds the PDF and its annotation notes; this is what attaches to the host.
    private var container: PDFAnnotationContainerView?
    let annotations = PDFAnnotationLayer()
    private var isInvalidated = false

    private let loadQueue = DispatchQueue(label: "nvmodern.pdf.content-load", qos: .userInitiated)
    private var latestLoadID: Int = 0
    private var currentMarker: Marker?
    private var loadedMarker: Marker?
    private var loadingMarker: Marker?
    private var pendingInitialScrollRatio: Double?
    private var traceDocumentPath: String?
    private var zoomCommand: PDFZoomCommand?
    private var navigationCommand: PDFNavigationCommand?
    private var focusRequestID: Int = 0
    private var lastHandledZoomCommandID: Int = 0
    private var lastHandledNavigationCommandID: Int = 0
    private var lastHandledFocusRequestID: Int = 0

    var onDidAttachToWindow: ((NSWindow) -> Void)?
    var onInteraction: (() -> Void)?
    var onScrollChange: ((Double) -> Void)?
    var onPageInfoChange: ((PDFPageInfo) -> Void)?
    var onOutlineChange: (([PDFOutlineItem]) -> Void)?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var isAttached: Bool {
        container?.superview != nil
    }

    /// The PDF's current text selection, with its 1-based page range.
    func selectionSnapshot() -> WorkspaceEditorSelectionSnapshot {
        guard let view = instantiatedView, let document = view.document,
              let selection = view.currentSelection,
              let text = selection.string, !text.isEmpty
        else {
            return WorkspaceEditorSelectionSnapshot(text: "", startLine: nil, endLine: nil, empty: true)
        }
        let pages = selection.pages.map { document.index(for: $0) + 1 }
        return WorkspaceEditorSelectionSnapshot(
            text: text,
            startLine: nil,
            endLine: nil,
            empty: false,
            startPage: pages.min(),
            endPage: pages.max()
        )
    }

    /// Runs an annotation request against the loaded PDF; nil until `fileURL` is loaded.
    func performAnnotationRequest(_ request: [String: ActionValue], expectedFileURL: URL) -> ActionValue? {
        guard let loadedMarker,
              loadedMarker.fileURL.standardizedFileURL.path == expectedFileURL.standardizedFileURL.path,
              instantiatedView?.document != nil
        else {
            return nil
        }
        return annotations.handle(request)
    }

    func matches(marker: Marker) -> Bool {
        loadedMarker == marker
    }

    func update(
        marker: Marker,
        initialScrollRatio: Double?,
        traceDocumentPath: String?,
        zoomCommand: PDFZoomCommand?,
        navigationCommand: PDFNavigationCommand?,
        focusRequestID: Int,
        onInteraction: (() -> Void)?,
        onScrollChange: ((Double) -> Void)?,
        onPageInfoChange: ((PDFPageInfo) -> Void)?,
        onOutlineChange: (([PDFOutlineItem]) -> Void)?
    ) {
        currentMarker = marker
        pendingInitialScrollRatio = initialScrollRatio
        self.traceDocumentPath = traceDocumentPath
        self.zoomCommand = zoomCommand
        self.navigationCommand = navigationCommand
        self.focusRequestID = focusRequestID
        self.onInteraction = onInteraction
        self.onScrollChange = onScrollChange
        self.onPageInfoChange = onPageInfoChange
        self.onOutlineChange = onOutlineChange

        if let view = instantiatedView {
            applyConfiguration(to: view)
        }
    }

    func attach(to containerView: NSView) {
        guard !isInvalidated else { return }

        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "pdf.session.attach.start")
        let view = ensureView()
        applyConfiguration(to: view)
        guard let container else { return }

        if container.superview !== containerView {
            container.removeFromSuperview()
            container.frame = containerView.bounds
            container.autoresizingMask = [.width, .height]
            containerView.addSubview(container)
        } else if container.frame != containerView.bounds {
            container.frame = containerView.bounds
        }
        annotations.layoutContainer()

        if let window = view.window {
            onDidAttachToWindow?(window)
        }

        WorkspaceActivationTraceCenter.shared.mark(
            tabID: ownerTabID,
            event: "pdf.session.attach.end",
            details: [
                "attached": isAttached ? "true" : "false",
                "loaded": currentMarker == nil ? "false" : "true"
            ]
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            WorkspaceActivationTraceCenter.shared.finishIfExpected(
                tabID: self.ownerTabID,
                mode: .pdfAttachReady,
                event: "pdf.ready.reusedSession",
                details: [
                    "attached": self.isAttached ? "true" : "false",
                    "path": self.currentMarker?.fileURL.path ?? ""
                ]
            )
        }
    }

    func detach() {
        instantiatedView?.emitCurrentScrollRatio()
        container?.removeFromSuperview()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        loadedMarker = nil
        loadingMarker = nil

        annotations.uninstall()
        guard let view = instantiatedView else { return }
        view.emitCurrentScrollRatio()
        view.cleanupObservers()
        container?.removeFromSuperview()
        container = nil
        instantiatedView = nil
    }

    private func ensureView() -> ZoomablePDFView {
        if let instantiatedView {
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "pdf.view.reuse")
            return instantiatedView
        }

        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "pdf.view.create.start")
        let view = ZoomablePDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 8.0
        instantiatedView = view

        let container = PDFAnnotationContainerView(frame: .zero)
        view.frame = container.bounds
        container.addSubview(view)
        self.container = container
        annotations.install(container: container, pdfView: view)
        view.onAskShortcut = { [weak self] in
            self?.annotations.beginAsk() ?? false
        }
        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "pdf.view.create.end")
        return view
    }

    private func applyConfiguration(to view: ZoomablePDFView) {
        view.onScrollRatioChange = onScrollChange
        view.onPageInfoChange = onPageInfoChange
        view.onOutlineChange = onOutlineChange
        view.onInteraction = onInteraction

        if let marker = currentMarker {
            loadDocumentIfNeeded(into: view, marker: marker)
        }

        view.applyInitialScrollRatioIfNeeded(pendingInitialScrollRatio)

        if let zoomCommand,
           zoomCommand.id != lastHandledZoomCommandID {
            view.apply(zoomAction: zoomCommand.action)
            lastHandledZoomCommandID = zoomCommand.id
        }

        if let navigationCommand,
           navigationCommand.id != lastHandledNavigationCommandID {
            view.apply(navigationAction: navigationCommand.action)
            lastHandledNavigationCommandID = navigationCommand.id
        }

        if focusRequestID != lastHandledFocusRequestID,
           container?.superview != nil {
            view.focusContent()
            lastHandledFocusRequestID = focusRequestID
        }
    }

    private func loadDocumentIfNeeded(into view: ZoomablePDFView, marker: Marker) {
        guard loadedMarker != marker,
              loadingMarker != marker else {
            return
        }

        latestLoadID += 1
        let loadID = latestLoadID
        loadingMarker = marker
        loadedMarker = nil
        view.document = nil
        view.resetDocumentTracking()

        WorkspaceActivationTraceCenter.shared.mark(
            tabID: ownerTabID,
            event: "pdf.load.start",
            details: ["path": traceDocumentPath ?? marker.fileURL.path]
        )

        let tracePath = traceDocumentPath ?? marker.fileURL.path
        loadQueue.async {
            let loadStart = ProcessInfo.processInfo.systemUptime
            let document = PDFDocument(url: marker.fileURL)
            let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isInvalidated,
                      loadID == self.latestLoadID,
                      self.currentMarker == marker,
                      let view = self.instantiatedView else {
                    return
                }

                self.loadingMarker = nil
                self.loadedMarker = marker
                view.document = document
                view.autoScales = true
                view.resetDocumentTracking()
                self.annotations.documentDidLoad(document, fileURL: marker.fileURL)
                WorkspaceActivationTraceCenter.shared.mark(
                    tabID: self.ownerTabID,
                    event: "pdf.load.end",
                    details: [
                        "path": tracePath,
                        "pageCount": String(document?.pageCount ?? 0),
                        "durationMs": String(format: "%.2f", loadDurationMs)
                    ]
                )
                self.applyConfiguration(to: view)
            }
        }
    }
}

struct PDFPreviewContentHost: NSViewRepresentable {
    let controller: PDFPreviewContentController
    var backgroundColor: NSColor = .windowBackgroundColor
    var prepareForDisplay: ((PDFPreviewContentController) -> Void)? = nil

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
        let controller: PDFPreviewContentController

        init(controller: PDFPreviewContentController) {
            self.controller = controller
        }
    }
}
