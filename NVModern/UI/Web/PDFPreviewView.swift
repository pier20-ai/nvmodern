import AppKit
import CoreImage
import PDFKit
import SwiftUI

struct PDFZoomCommand: Equatable {
    enum Action: Equatable {
        case zoomIn
        case zoomOut
        case reset
    }

    let id: Int
    let action: Action
}

struct PDFNavigationCommand: Equatable {
    enum Action: Equatable {
        case previousPage
        case nextPage
        case goToPage(index: Int)
    }

    let id: Int
    let action: Action
}

struct PDFPageInfo: Equatable {
    let currentPageIndex: Int
    let currentPageLabel: String
    let pageCount: Int
}

struct PDFOutlineItem: Identifiable, Equatable {
    let id: String
    let title: String
    let pageIndex: Int?
    let pageLabel: String?
    let children: [PDFOutlineItem]
}

/// Native PDF preview wrapper with scroll restoration.
///
/// Scroll is persisted as a normalized vertical ratio (0...1) so we can restore across
/// window restores, tab closes/reopens, and small geometry changes.
struct PDFPreviewView: NSViewRepresentable {
    let fileURL: URL
    var reloadToken: String = ""
    var initialScrollRatio: Double?
    var traceTabID: TabID?
    var traceDocumentPath: String?
    var zoomCommand: PDFZoomCommand?
    var navigationCommand: PDFNavigationCommand?
    var focusRequestID: Int = 0
    var onInteraction: (() -> Void)?
    var onScrollChange: ((Double) -> Void)?
    var onPageInfoChange: ((PDFPageInfo) -> Void)?
    var onOutlineChange: (([PDFOutlineItem]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomablePDFView {
        let view = ZoomablePDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 8.0
        view.onScrollRatioChange = onScrollChange
        view.onPageInfoChange = onPageInfoChange
        view.onOutlineChange = onOutlineChange
        view.onInteraction = onInteraction

        loadDocumentIfNeeded(into: view, coordinator: context.coordinator)
        view.applyInitialScrollRatioIfNeeded(initialScrollRatio)

        return view
    }

    func updateNSView(_ nsView: ZoomablePDFView, context: Context) {
        nsView.onScrollRatioChange = onScrollChange
        nsView.onPageInfoChange = onPageInfoChange
        nsView.onOutlineChange = onOutlineChange
        nsView.onInteraction = onInteraction

        loadDocumentIfNeeded(into: nsView, coordinator: context.coordinator)
        nsView.applyInitialScrollRatioIfNeeded(initialScrollRatio)

        if let zoomCommand,
           zoomCommand.id != context.coordinator.lastHandledZoomCommandID {
            nsView.apply(zoomAction: zoomCommand.action)
            context.coordinator.lastHandledZoomCommandID = zoomCommand.id
        }

        if let navigationCommand,
           navigationCommand.id != context.coordinator.lastHandledNavigationCommandID {
            nsView.apply(navigationAction: navigationCommand.action)
            context.coordinator.lastHandledNavigationCommandID = navigationCommand.id
        }

        if focusRequestID != context.coordinator.lastHandledFocusRequestID {
            nsView.focusContent()
            context.coordinator.lastHandledFocusRequestID = focusRequestID
        }
    }

    static func dismantleNSView(_ nsView: ZoomablePDFView, coordinator: Coordinator) {
        nsView.emitCurrentScrollRatio()
        nsView.cleanupObservers()
    }

    private func loadDocumentIfNeeded(into view: ZoomablePDFView, coordinator: Coordinator) {
        if coordinator.loadedURL != fileURL || coordinator.loadedReloadToken != reloadToken {
            if let traceTabID {
                WorkspaceActivationTraceCenter.shared.mark(
                    tabID: traceTabID,
                    event: "pdf.load.start",
                    details: ["path": traceDocumentPath ?? fileURL.path]
                )
            }
            let loadStart = ProcessInfo.processInfo.systemUptime
            let document = PDFDocument(url: fileURL)
            let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            view.document = document
            coordinator.loadedURL = fileURL
            coordinator.loadedReloadToken = reloadToken
            view.autoScales = true
            view.resetDocumentTracking()
            if let traceTabID {
                WorkspaceActivationTraceCenter.shared.mark(
                    tabID: traceTabID,
                    event: "pdf.load.end",
                    details: [
                        "path": traceDocumentPath ?? fileURL.path,
                        "pageCount": String(document?.pageCount ?? 0),
                        "durationMs": String(format: "%.2f", loadDurationMs)
                    ]
                )
            }
        }
    }

    final class Coordinator {
        var loadedURL: URL?
        var loadedReloadToken: String?
        var lastHandledZoomCommandID: Int = 0
        var lastHandledNavigationCommandID: Int = 0
        var lastHandledFocusRequestID: Int = 0
    }
}

/// `PDFView` subclass that exposes a stable app-level notion of scroll position.
///
/// PDFKit does not give us a ready-made persisted reading position abstraction for this
/// app, so we watch the embedded scroll view, translate offsets <-> normalized ratios,
/// and emit updates back to `WorkspaceSessionStore` through `WorkspaceView`.
final class ZoomablePDFView: PDFView {
    var onScrollRatioChange: ((Double) -> Void)?
    var onPageInfoChange: ((PDFPageInfo) -> Void)?
    var onOutlineChange: (([PDFOutlineItem]) -> Void)?
    var onInteraction: (() -> Void)?
    /// Command-Shift-M: annotate the selection with a question.
    var onAskShortcut: (() -> Bool)?

    private weak var observedScrollView: NSScrollView?
    private var clipViewObserver: NSObjectProtocol?
    private var pageChangeObserver: NSObjectProtocol?
    private var pendingInitialScrollRatio: Double?
    private var lastEmittedScrollRatio: Double?
    private var lastEmittedPageInfo: PDFPageInfo?
    private var lastEmittedOutlineItems: [PDFOutlineItem] = []
    private var appliedInitialScrollRatioForDocumentURL: URL?
    private var scrollEmitWorkItem: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollObservationIfNeeded()
        installPageObservationIfNeeded()
        updateAppearanceStyling()
        applyPendingInitialScrollIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceStyling()
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "m",
           window?.firstResponder === self || window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) == true }) == true,
           onAskShortcut?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleZoomShortcut(event) || handleArrowNavigation(event) {
            return
        }

        super.keyDown(with: event)
    }

    override func moveLeft(_ sender: Any?) {
        apply(navigationAction: .previousPage)
    }

    override func moveRight(_ sender: Any?) {
        apply(navigationAction: .nextPage)
    }

    override func moveUp(_ sender: Any?) {
        apply(navigationAction: .previousPage)
    }

    override func moveDown(_ sender: Any?) {
        apply(navigationAction: .nextPage)
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control), !flags.contains(.function) {
            if event.deltaY < 0 {
                apply(zoomAction: .zoomIn)
            } else if event.deltaY > 0 {
                apply(zoomAction: .zoomOut)
            }
            return
        }

        super.scrollWheel(with: event)
        scheduleScrollRatioEmit()
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else {
            super.magnify(with: event)
            return
        }

        autoScales = false
        let factor = scaleFactor * (1.0 + event.magnification)
        scaleFactor = min(max(factor, minScaleFactor), maxScaleFactor)
        scheduleScrollRatioEmit()
    }

    func resetDocumentTracking() {
        pendingInitialScrollRatio = nil
        lastEmittedScrollRatio = nil
        lastEmittedPageInfo = nil
        lastEmittedOutlineItems = []
        appliedInitialScrollRatioForDocumentURL = nil
        cleanupObservers()
        installScrollObservationIfNeeded()
        installPageObservationIfNeeded()
        updateAppearanceStyling()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installScrollObservationIfNeeded()
            self.installPageObservationIfNeeded()
            self.updateAppearanceStyling()
            self.emitCurrentScrollRatio()
            self.emitCurrentPageInfo()
            self.emitCurrentOutline()
        }
    }

    func applyInitialScrollRatioIfNeeded(_ ratio: Double?) {
        pendingInitialScrollRatio = ratio.map { max(0, min(1, $0)) }
        applyPendingInitialScrollIfNeeded()
    }

    func apply(zoomAction: PDFZoomCommand.Action) {
        switch zoomAction {
        case .zoomIn:
            autoScales = false
            zoomIn(nil)
        case .zoomOut:
            autoScales = false
            zoomOut(nil)
        case .reset:
            autoScales = true
        }

        scheduleScrollRatioEmit()
    }

    func apply(navigationAction: PDFNavigationCommand.Action) {
        switch navigationAction {
        case .previousPage:
            goToPreviousPage(nil)
        case .nextPage:
            goToNextPage(nil)
        case .goToPage(let index):
            guard let document,
                  index >= 0,
                  index < document.pageCount,
                  let page = document.page(at: index) else {
                return
            }
            go(to: page)
        }

        emitCurrentPageInfo()
        scheduleScrollRatioEmit()

        DispatchQueue.main.async { [weak self] in
            self?.emitCurrentPageInfo()
            self?.scheduleScrollRatioEmit()
        }
    }

    func focusContent() {
        window?.makeFirstResponder(self)
    }

    func emitCurrentScrollRatio() {
        let ratio = currentScrollRatio()
        guard lastEmittedScrollRatio != ratio else { return }
        lastEmittedScrollRatio = ratio
        onScrollRatioChange?(ratio)
    }

    func emitCurrentPageInfo() {
        let info = currentPageInfo()
        guard lastEmittedPageInfo != info else { return }
        lastEmittedPageInfo = info
        onPageInfoChange?(info)
    }

    func emitCurrentOutline() {
        let items = currentOutlineItems()
        guard lastEmittedOutlineItems != items else { return }
        lastEmittedOutlineItems = items
        onOutlineChange?(items)
    }

    func cleanupObservers() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }

        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
            self.pageChangeObserver = nil
        }

        observedScrollView = nil
        scrollEmitWorkItem?.cancel()
        scrollEmitWorkItem = nil
    }

    deinit {
        cleanupObservers()
    }

    private func installScrollObservationIfNeeded() {
        guard let scrollView = embeddedScrollView() else { return }
        if observedScrollView === scrollView { return }

        cleanupObservers()
        observedScrollView = scrollView

        clipViewObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleScrollRatioEmit()
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        updateAppearanceStyling()
        installPageObservationIfNeeded()
    }

    private func installPageObservationIfNeeded() {
        guard pageChangeObserver == nil else { return }

        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewPageChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.emitCurrentPageInfo()
            self?.scheduleScrollRatioEmit()
        }
    }

    private func embeddedScrollView() -> NSScrollView? {
        if let observedScrollView {
            return observedScrollView
        }

        return firstScrollView(in: self)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }

    /// PDFKit on macOS does not expose Preview.app-style dark rendering for page content.
    /// We approximate it in dark appearance by applying a filter chain to the rendered
    /// document view while keeping the surrounding chrome dark as well.
    ///
    /// The text softness comes from filtered post-processing of PDFKit's rendered output,
    /// so we also force the involved layers to the correct backing scale and apply a very
    /// light unsharp pass to tighten glyph edges.
    private func updateAppearanceStyling() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let chromeBackground = isDarkMode ? NSColor.black : NSColor.textBackgroundColor
        let backingScale = currentBackingScaleFactor()

        backgroundColor = chromeBackground

        guard let scrollView = embeddedScrollView() else { return }

        scrollView.backgroundColor = chromeBackground
        scrollView.drawsBackground = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = chromeBackground.cgColor
        scrollView.contentView.layer?.contentsScale = backingScale

        guard let documentView = scrollView.documentView else { return }

        propagateLayerScale(in: documentView, scale: backingScale)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = chromeBackground.cgColor
        documentView.layer?.contentsScale = backingScale
        documentView.contentFilters = isDarkMode ? Self.darkModeContentFilters() : []
    }

    private func currentBackingScaleFactor() -> CGFloat {
        window?.backingScaleFactor
            ?? window?.screen?.backingScaleFactor
            ?? NSApp.keyWindow?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
    }

    private func propagateLayerScale(in view: NSView, scale: CGFloat) {
        if let layer = view.layer {
            layer.contentsScale = scale
        }

        for subview in view.subviews {
            propagateLayerScale(in: subview, scale: scale)
        }
    }

    private static func darkModeContentFilters() -> [CIFilter] {
        let invert = CIFilter(name: "CIColorInvert")

        let unsharpMask = CIFilter(name: "CIUnsharpMask")
        unsharpMask?.setValue(0.35, forKey: kCIInputRadiusKey)
        unsharpMask?.setValue(0.55, forKey: kCIInputIntensityKey)

        let controls = CIFilter(name: "CIColorControls")
        controls?.setValue(0.0, forKey: kCIInputSaturationKey)
        controls?.setValue(1.14, forKey: kCIInputContrastKey)
        controls?.setValue(-0.01, forKey: kCIInputBrightnessKey)

        return [invert, unsharpMask, controls].compactMap { $0 }
    }

    private func applyPendingInitialScrollIfNeeded() {
        guard let documentURL = document?.documentURL,
              appliedInitialScrollRatioForDocumentURL != documentURL,
              let ratio = pendingInitialScrollRatio else {
            return
        }

        installScrollObservationIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setScrollRatio(ratio)
            self.appliedInitialScrollRatioForDocumentURL = documentURL
            self.emitCurrentScrollRatio()
            self.emitCurrentPageInfo()
        }
    }

    private func currentScrollRatio() -> Double {
        guard let scrollView = embeddedScrollView(),
              let documentView = scrollView.documentView else {
            return 0
        }

        let visibleHeight = scrollView.contentView.bounds.height
        let contentHeight = documentView.frame.height
        let maxOffset = max(0, contentHeight - visibleHeight)
        guard maxOffset > 0 else { return 0 }

        let y = scrollView.contentView.bounds.origin.y
        let rawRatio = documentView.isFlipped ? (y / maxOffset) : ((maxOffset - y) / maxOffset)
        return max(0, min(1, rawRatio))
    }

    private func setScrollRatio(_ ratio: Double) {
        guard let scrollView = embeddedScrollView(),
              let documentView = scrollView.documentView else {
            return
        }

        let visibleHeight = scrollView.contentView.bounds.height
        let contentHeight = documentView.frame.height
        let maxOffset = max(0, contentHeight - visibleHeight)
        guard maxOffset > 0 else { return }

        let clampedRatio = max(0, min(1, ratio))
        let y = documentView.isFlipped ? (maxOffset * clampedRatio) : (maxOffset * (1 - clampedRatio))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func currentPageInfo() -> PDFPageInfo {
        guard let document else {
            return PDFPageInfo(currentPageIndex: 0, currentPageLabel: "—", pageCount: 0)
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            return PDFPageInfo(currentPageIndex: 0, currentPageLabel: "—", pageCount: 0)
        }

        let page = currentPage ?? document.page(at: 0)
        let pageIndex = page.map { document.index(for: $0) }.flatMap { $0 == NSNotFound ? nil : $0 } ?? 0
        let pageLabel = page?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPageLabel = (pageLabel?.isEmpty == false ? pageLabel : nil) ?? String(pageIndex + 1)

        return PDFPageInfo(
            currentPageIndex: max(0, pageIndex),
            currentPageLabel: resolvedPageLabel,
            pageCount: pageCount
        )
    }

    private func currentOutlineItems() -> [PDFOutlineItem] {
        guard let root = document?.outlineRoot else {
            return []
        }

        return outlineItems(from: root, path: [])
    }

    private func outlineItems(from outline: PDFOutline, path: [Int]) -> [PDFOutlineItem] {
        var items: [PDFOutlineItem] = []

        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }

            let childPath = path + [childIndex]
            let nestedItems = outlineItems(from: child, path: childPath)
            let pageIndex = pageIndex(for: child)
            let pageLabel = pageIndex.flatMap { resolvedPageLabel(at: $0) }
            let title = child.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                ?? ""
            let resolvedTitle = title.isEmpty
                ? (pageLabel.map { "Page \($0)" } ?? "Untitled Section")
                : title
            let itemID = childPath.map { String($0) }.joined(separator: ".")

            items.append(
                PDFOutlineItem(
                    id: itemID,
                    title: resolvedTitle,
                    pageIndex: pageIndex,
                    pageLabel: pageLabel,
                    children: nestedItems
                )
            )
        }

        return items
    }

    private func pageIndex(for outline: PDFOutline) -> Int? {
        guard let document,
              let destination = outlineDestination(for: outline),
              let page = destination.page else {
            return nil
        }

        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    private func outlineDestination(for outline: PDFOutline) -> PDFDestination? {
        if let destination = outline.destination {
            return destination
        }

        if let action = outline.action as? PDFActionGoTo {
            return action.destination
        }

        return nil
    }

    private func resolvedPageLabel(at index: Int) -> String? {
        guard let document,
              index >= 0,
              index < document.pageCount,
              let page = document.page(at: index) else {
            return nil
        }

        let label = page.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false ? label : nil) ?? String(index + 1)
    }

    private func scheduleScrollRatioEmit() {
        scrollEmitWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.emitCurrentScrollRatio()
        }

        scrollEmitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              !flags.contains(.function)
        else {
            return false
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "=", "+":
            apply(zoomAction: .zoomIn)
            return true
        case "-", "_":
            apply(zoomAction: .zoomOut)
            return true
        case "0":
            apply(zoomAction: .reset)
            return true
        default:
            switch event.keyCode {
            case 69: // numpad +
                apply(zoomAction: .zoomIn)
                return true
            case 78: // numpad -
                apply(zoomAction: .zoomOut)
                return true
            case 82: // numpad 0
                apply(zoomAction: .reset)
                return true
            default:
                return false
            }
        }
    }

    private func handleArrowNavigation(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meaningfulFlags = flags.subtracting([.function, .numericPad])
        guard meaningfulFlags.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 123, 126: // left, up
            apply(navigationAction: .previousPage)
            return true
        case 124, 125: // right, down
            apply(navigationAction: .nextPage)
            return true
        default:
            return false
        }
    }
}
