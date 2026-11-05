import AppKit

@MainActor
protocol WorkspaceTabChildContentRuntime: AnyObject {
    func invalidate()
}

@MainActor
class WorkspaceWebTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID

    private var controller: EditorWebContentController?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingController: EditorWebContentController? {
        controller
    }

    @discardableResult
    func prepare(
        rootURL: URL,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil,
        onProcessTermination: (() -> Void)? = nil,
        onBridgeReady: (() -> Void)? = nil,
        onEvent: WebEditorBridge.EventHandler? = nil,
        onRequest: WebEditorBridge.RequestHandler? = nil
    ) -> EditorWebContentController {
        let resolvedController: EditorWebContentController
        if let existing = controller {
            existing.updateRootURL(rootURL)
            resolvedController = existing
        } else {
            resolvedController = EditorWebContentController(ownerTabID: ownerTabID, rootURL: rootURL)
            controller = resolvedController
        }

        resolvedController.onDidAttachToWindow = onDidAttachToWindow
        resolvedController.onProcessTermination = onProcessTermination
        resolvedController.bridge.onReady = onBridgeReady
        resolvedController.bridge.onEvent = onEvent
        resolvedController.bridge.onRequest = onRequest
        return resolvedController
    }

    func clearContextMarker() {
        controller?.clearContextMarker()
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class WorkspaceTextTabContentRuntime: WorkspaceWebTabContentRuntime {}

@MainActor
final class WorkspacePreviewTabContentRuntime: WorkspaceWebTabContentRuntime {}

/// Retains the WebEditor-backed EPUB reader across native tab switches. EPUB is
/// rendered by the bundled web surface so its navigation, themes, and reading
/// location can use the same structured bridge as Markdown and org documents.
@MainActor
final class WorkspaceEPUBTabContentRuntime: WorkspaceWebTabContentRuntime {}

@MainActor
final class WorkspacePDFTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID

    private var controller: PDFPreviewContentController?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingController: PDFPreviewContentController? {
        controller
    }

    @discardableResult
    func prepare(
        marker: PDFPreviewContentController.Marker,
        initialScrollRatio: Double?,
        traceDocumentPath: String?,
        zoomCommand: PDFZoomCommand?,
        navigationCommand: PDFNavigationCommand?,
        focusRequestID: Int,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil,
        onInteraction: (() -> Void)? = nil,
        onScrollChange: ((Double) -> Void)? = nil,
        onPageInfoChange: ((PDFPageInfo) -> Void)? = nil,
        onOutlineChange: (([PDFOutlineItem]) -> Void)? = nil
    ) -> PDFPreviewContentController {
        let resolvedController: PDFPreviewContentController
        if let existing = controller {
            resolvedController = existing
        } else {
            resolvedController = PDFPreviewContentController(ownerTabID: ownerTabID)
            controller = resolvedController
        }

        resolvedController.onDidAttachToWindow = onDidAttachToWindow
        resolvedController.update(
            marker: marker,
            initialScrollRatio: initialScrollRatio,
            traceDocumentPath: traceDocumentPath,
            zoomCommand: zoomCommand,
            navigationCommand: navigationCommand,
            focusRequestID: focusRequestID,
            onInteraction: onInteraction,
            onScrollChange: onScrollChange,
            onPageInfoChange: onPageInfoChange,
            onOutlineChange: onOutlineChange
        )
        return resolvedController
    }

    func matches(marker: PDFPreviewContentController.Marker) -> Bool {
        controller?.matches(marker: marker) ?? false
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class WorkspaceCSVTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID

    private var controller: CSVPreviewContentController?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingController: CSVPreviewContentController? {
        controller
    }

    @discardableResult
    func prepare(
        marker: CSVPreviewContentController.Marker,
        sourceRelativePath: String?,
        focusRequestID: Int,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil,
        onDocumentChange: ((CSVGridSaveSnapshot) -> Void)? = nil,
        onOpenWikilink: ((String) -> Void)? = nil,
        onOpenWikilinkInNewTab: ((String) -> Void)? = nil,
        wikilinkSuggestionsProvider: ((String, String?) -> [WikilinkAutocompleteSuggestion])? = nil
    ) -> CSVPreviewContentController {
        let resolvedController: CSVPreviewContentController
        if let existing = controller {
            resolvedController = existing
        } else {
            resolvedController = CSVPreviewContentController(ownerTabID: ownerTabID)
            controller = resolvedController
        }

        resolvedController.onDidAttachToWindow = onDidAttachToWindow
        resolvedController.update(
            marker: marker,
            sourceRelativePath: sourceRelativePath,
            focusRequestID: focusRequestID,
            onDocumentChange: onDocumentChange,
            onOpenWikilink: onOpenWikilink,
            onOpenWikilinkInNewTab: onOpenWikilinkInNewTab,
            wikilinkSuggestionsProvider: wikilinkSuggestionsProvider
        )
        return resolvedController
    }

    func matches(marker: CSVPreviewContentController.Marker) -> Bool {
        controller?.matches(marker: marker) ?? false
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class WorkspaceCanvasTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID
    private var controller: CanvasDocumentContentController?

    init(ownerTabID: TabID) { self.ownerTabID = ownerTabID }

    var existingController: CanvasDocumentContentController? { controller }

    @discardableResult
    func prepare(
        marker: CanvasDocumentContentController.Marker,
        focusRequestID: Int,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil,
        onSave: @escaping (Data) throws -> Void
    ) -> CanvasDocumentContentController {
        let resolved = controller ?? CanvasDocumentContentController(ownerTabID: ownerTabID)
        controller = resolved
        resolved.onDidAttachToWindow = onDidAttachToWindow
        resolved.update(marker: marker, focusRequestID: focusRequestID, onSave: onSave)
        return resolved
    }

    func matches(marker: CanvasDocumentContentController.Marker) -> Bool {
        controller?.matches(marker: marker) ?? false
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class WorkspaceImageTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID

    private var controller: ImagePreviewContentController?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingController: ImagePreviewContentController? {
        controller
    }

    @discardableResult
    func prepare(
        marker: ImagePreviewContentController.Marker,
        adjustments: ImageAdjustmentSettings,
        zoomCommand: ImageZoomCommand?,
        focusRequestID: Int,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil
    ) -> ImagePreviewContentController {
        let resolvedController: ImagePreviewContentController
        if let existing = controller {
            resolvedController = existing
        } else {
            resolvedController = ImagePreviewContentController(ownerTabID: ownerTabID)
            controller = resolvedController
        }

        resolvedController.onDidAttachToWindow = onDidAttachToWindow
        resolvedController.update(
            marker: marker,
            adjustments: adjustments,
            zoomCommand: zoomCommand,
            focusRequestID: focusRequestID
        )
        return resolvedController
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class WorkspaceHTMLTabContentRuntime: WorkspaceTabChildContentRuntime {
    let ownerTabID: TabID

    private var controller: HTMLPreviewContentController?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingController: HTMLPreviewContentController? {
        controller
    }

    @discardableResult
    func prepare(
        marker: HTMLPreviewContentController.Marker,
        focusRequestID: Int,
        onDidAttachToWindow: ((NSWindow) -> Void)? = nil
    ) -> HTMLPreviewContentController {
        let resolvedController: HTMLPreviewContentController
        if let existing = controller {
            resolvedController = existing
        } else {
            resolvedController = HTMLPreviewContentController(ownerTabID: ownerTabID)
            controller = resolvedController
        }

        resolvedController.onDidAttachToWindow = onDidAttachToWindow
        resolvedController.update(marker: marker, focusRequestID: focusRequestID)
        return resolvedController
    }

    func matches(marker: HTMLPreviewContentController.Marker) -> Bool {
        controller?.matches(marker: marker) ?? false
    }

    func invalidate() {
        controller?.invalidate()
        controller = nil
    }
}

@MainActor
final class DocumentSurfaceRuntimeBag {
    let tabID: TabID

    let textContent: WorkspaceTextTabContentRuntime
    let previewContent: WorkspacePreviewTabContentRuntime
    let pdfContent: WorkspacePDFTabContentRuntime
    let imageContent: WorkspaceImageTabContentRuntime
    let htmlContent: WorkspaceHTMLTabContentRuntime
    let epubContent: WorkspaceEPUBTabContentRuntime
    let csvContent: WorkspaceCSVTabContentRuntime
    let canvasContent: WorkspaceCanvasTabContentRuntime

    init(tabID: TabID) {
        self.tabID = tabID
        textContent = WorkspaceTextTabContentRuntime(ownerTabID: tabID)
        previewContent = WorkspacePreviewTabContentRuntime(ownerTabID: tabID)
        pdfContent = WorkspacePDFTabContentRuntime(ownerTabID: tabID)
        imageContent = WorkspaceImageTabContentRuntime(ownerTabID: tabID)
        htmlContent = WorkspaceHTMLTabContentRuntime(ownerTabID: tabID)
        epubContent = WorkspaceEPUBTabContentRuntime(ownerTabID: tabID)
        csvContent = WorkspaceCSVTabContentRuntime(ownerTabID: tabID)
        canvasContent = WorkspaceCanvasTabContentRuntime(ownerTabID: tabID)
    }

    func clearWebContextMarkers() {
        textContent.clearContextMarker()
        previewContent.clearContextMarker()
        epubContent.clearContextMarker()
    }

    func invalidate() {
        textContent.invalidate()
        previewContent.invalidate()
        pdfContent.invalidate()
        imageContent.invalidate()
        htmlContent.invalidate()
        epubContent.invalidate()
        csvContent.invalidate()
        canvasContent.invalidate()
    }
}
