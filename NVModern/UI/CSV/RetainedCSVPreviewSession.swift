import AppKit
import SwiftUI

@MainActor
final class CSVPreviewContentController {
    struct Marker: Equatable {
        let fileURL: URL
        let reloadToken: String
    }

    let ownerTabID: TabID

    private var instantiatedView: CSVGridNativePreviewContainerView?
    private var isInvalidated = false

    private let loadQueue = DispatchQueue(label: "nvmodern.csv-grid.content-load", qos: .userInitiated)
    private var latestLoadID: Int = 0
    private var currentMarker: Marker?
    private var loadedMarker: Marker?
    private var loadingMarker: Marker?
    private var sourceRelativePath: String?
    private var focusRequestID: Int = 0
    private var lastHandledFocusRequestID: Int = 0

    var onDidAttachToWindow: ((NSWindow) -> Void)?
    var onDocumentChange: ((CSVGridSaveSnapshot) -> Void)?
    var onOpenWikilink: ((String) -> Void)?
    var onOpenWikilinkInNewTab: ((String) -> Void)?
    var wikilinkSuggestionsProvider: ((String, String?) -> [WikilinkAutocompleteSuggestion])?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var isAttached: Bool {
        instantiatedView?.superview != nil
    }

    func matches(marker: Marker) -> Bool {
        loadedMarker == marker
    }

    func update(
        marker: Marker,
        sourceRelativePath: String?,
        focusRequestID: Int,
        onDocumentChange: ((CSVGridSaveSnapshot) -> Void)?,
        onOpenWikilink: ((String) -> Void)?,
        onOpenWikilinkInNewTab: ((String) -> Void)?,
        wikilinkSuggestionsProvider: ((String, String?) -> [WikilinkAutocompleteSuggestion])?
    ) {
        currentMarker = marker
        self.sourceRelativePath = sourceRelativePath
        self.focusRequestID = focusRequestID
        self.onDocumentChange = onDocumentChange
        self.onOpenWikilink = onOpenWikilink
        self.onOpenWikilinkInNewTab = onOpenWikilinkInNewTab
        self.wikilinkSuggestionsProvider = wikilinkSuggestionsProvider

        if let view = instantiatedView {
            applyConfiguration(to: view)
        }
    }

    func attach(to containerView: NSView) {
        guard !isInvalidated else { return }

        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "csv.session.attach.start")
        let view = ensureView()
        applyConfiguration(to: view)

        if view.superview !== containerView {
            view.removeFromSuperview()
            view.frame = containerView.bounds
            view.autoresizingMask = [.width, .height]
            containerView.addSubview(view)
        } else if view.frame != containerView.bounds {
            view.frame = containerView.bounds
        }

        if let window = view.window {
            onDidAttachToWindow?(window)
        }

        WorkspaceActivationTraceCenter.shared.mark(
            tabID: ownerTabID,
            event: "csv.session.attach.end",
            details: [
                "attached": isAttached ? "true" : "false",
                "loaded": loadedMarker == currentMarker ? "true" : "false"
            ]
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            WorkspaceActivationTraceCenter.shared.finishIfExpected(
                tabID: self.ownerTabID,
                mode: .csvAttachReady,
                event: "csv.ready.reusedSession",
                details: [
                    "attached": self.isAttached ? "true" : "false",
                    "path": self.currentMarker?.fileURL.path ?? ""
                ]
            )
        }
    }

    func detach() {
        instantiatedView?.removeFromSuperview()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        instantiatedView?.removeFromSuperview()
        instantiatedView = nil
    }

    private func ensureView() -> CSVGridNativePreviewContainerView {
        if let instantiatedView {
            WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "csv.view.reuse")
            return instantiatedView
        }

        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "csv.view.create.start")
        let view = CSVGridNativePreviewContainerView(frame: .zero)
        instantiatedView = view
        WorkspaceActivationTraceCenter.shared.mark(tabID: ownerTabID, event: "csv.view.create.end")
        return view
    }

    private func applyConfiguration(to view: CSVGridNativePreviewContainerView) {
        view.sourceRelativePath = sourceRelativePath
        view.onDocumentChange = onDocumentChange
        view.onOpenWikilink = onOpenWikilink
        view.onOpenWikilinkInNewTab = onOpenWikilinkInNewTab
        view.wikilinkSuggestionsProvider = wikilinkSuggestionsProvider

        if let marker = currentMarker {
            loadIfNeeded(marker: marker, into: view)
        }

        if focusRequestID != lastHandledFocusRequestID,
           view.superview != nil {
            view.focusContent()
            lastHandledFocusRequestID = focusRequestID
        }
    }

    private func loadIfNeeded(marker: Marker, into view: CSVGridNativePreviewContainerView) {
        guard loadedMarker != marker, loadingMarker != marker else {
            return
        }

        latestLoadID += 1
        let loadID = latestLoadID
        loadingMarker = marker
        view.setLoading(fileURL: marker.fileURL)
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: ownerTabID,
            event: "csv.load.start",
            details: ["path": sourceRelativePath ?? marker.fileURL.path]
        )

        loadQueue.async {
            let result: Result<CSVGridDocument, Error>
            do {
                result = .success(try CSVGridDocument.load(from: marker.fileURL))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isInvalidated,
                      loadID == self.latestLoadID,
                      self.currentMarker == marker,
                      let view = self.instantiatedView else {
                    return
                }

                self.loadingMarker = nil

                switch result {
                case .success(let document):
                    self.loadedMarker = marker
                    WorkspaceActivationTraceCenter.shared.mark(
                        tabID: self.ownerTabID,
                        event: "csv.load.end",
                        details: [
                            "path": self.sourceRelativePath ?? marker.fileURL.path,
                            "rows": String(document.rowCount),
                            "columns": String(document.columnCount)
                        ]
                    )
                    view.apply(document: document)
                    WorkspaceActivationTraceCenter.shared.finishIfExpected(
                        tabID: self.ownerTabID,
                        mode: .csvDocumentApplied,
                        event: "csv.ready.documentApplied",
                        details: [
                            "path": self.sourceRelativePath ?? marker.fileURL.path,
                            "rows": String(document.rowCount),
                            "columns": String(document.columnCount)
                        ]
                    )

                case .failure(let error):
                    self.loadedMarker = nil
                    WorkspaceActivationTraceCenter.shared.mark(
                        tabID: self.ownerTabID,
                        event: "csv.load.failed",
                        details: [
                            "path": self.sourceRelativePath ?? marker.fileURL.path,
                            "error": error.localizedDescription
                        ]
                    )
                    view.setError(message: error.localizedDescription)
                }
            }
        }
    }
}

struct CSVPreviewContentHost: NSViewRepresentable {
    let controller: CSVPreviewContentController
    var backgroundColor: NSColor = .windowBackgroundColor
    var prepareForDisplay: ((CSVPreviewContentController) -> Void)? = nil

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
        let controller: CSVPreviewContentController

        init(controller: CSVPreviewContentController) {
            self.controller = controller
        }
    }
}
