import AppKit
import CoreImage
import SwiftUI

struct ImageAdjustmentSettings: Equatable {
    var exposure: Double
    var saturation: Double
    var contrast: Double

    static let identity = ImageAdjustmentSettings(exposure: 0, saturation: 1, contrast: 1)
}

struct ImageZoomCommand: Equatable {
    enum Action: Equatable {
        case zoomIn
        case zoomOut
        case reset
        case fit
    }

    let id: Int
    let action: Action
}

@MainActor
final class ImagePreviewContentController {
    struct Marker: Equatable {
        let fileURL: URL
        let reloadToken: String
    }

    let ownerTabID: TabID

    private var instantiatedView: ZoomableImagePreviewView?
    private var isInvalidated = false
    private var currentMarker: Marker?
    private var loadedMarker: Marker?
    private var sourceImage: CIImage?
    private var currentAdjustments: ImageAdjustmentSettings = .identity
    private var latestRenderID: Int = 0
    private var needsFitAfterRender = true
    private var needsRenderedImageRefresh = false
    private var zoomCommand: ImageZoomCommand?
    private var focusRequestID: Int = 0
    private var lastHandledZoomCommandID: Int = 0
    private var lastHandledFocusRequestID: Int = 0

    private let ciContext = CIContext(options: nil)
    private let renderQueue = DispatchQueue(label: "nvmodern.image-preview.render", qos: .userInitiated)

    var onDidAttachToWindow: ((NSWindow) -> Void)?

    init(ownerTabID: TabID) {
        self.ownerTabID = ownerTabID
    }

    var existingView: ZoomableImagePreviewView? {
        instantiatedView
    }

    func update(
        marker: Marker,
        adjustments: ImageAdjustmentSettings,
        zoomCommand: ImageZoomCommand?,
        focusRequestID: Int
    ) {
        currentMarker = marker
        self.zoomCommand = zoomCommand
        self.focusRequestID = focusRequestID

        if loadedMarker != marker {
            loadedMarker = marker
            sourceImage = CIImage(contentsOf: marker.fileURL, options: [.applyOrientationProperty: true])
            currentAdjustments = adjustments
            needsFitAfterRender = true
            needsRenderedImageRefresh = true
            if let view = instantiatedView {
                scheduleRender(on: view, settings: adjustments)
            }
        } else if currentAdjustments != adjustments {
            currentAdjustments = adjustments
            needsRenderedImageRefresh = true
            if let view = instantiatedView {
                scheduleRender(on: view, settings: adjustments)
            }
        } else if let view = instantiatedView {
            applyTransientCommands(to: view)
        }
    }

    func attach(to containerView: NSView) {
        guard !isInvalidated else { return }

        let view = ensureView()
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

        applyConfiguration(to: view)
    }

    func detach() {
        instantiatedView?.removeFromSuperview()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        instantiatedView?.removeFromSuperview()
        instantiatedView = nil
        sourceImage = nil
        loadedMarker = nil
        currentMarker = nil
    }

    private func ensureView() -> ZoomableImagePreviewView {
        if let instantiatedView {
            return instantiatedView
        }

        let view = ZoomableImagePreviewView(frame: .zero)
        instantiatedView = view
        return view
    }

    private func applyConfiguration(to view: ZoomableImagePreviewView) {
        if let currentMarker,
           loadedMarker != currentMarker {
            sourceImage = CIImage(contentsOf: currentMarker.fileURL, options: [.applyOrientationProperty: true])
            loadedMarker = currentMarker
            needsFitAfterRender = true
            needsRenderedImageRefresh = true
            scheduleRender(on: view, settings: currentAdjustments)
        } else if needsRenderedImageRefresh {
            scheduleRender(on: view, settings: currentAdjustments)
        }

        if sourceImage == nil {
            view.setRenderedImage(nil, fitToView: true)
        }

        applyTransientCommands(to: view)
    }

    private func applyTransientCommands(to view: ZoomableImagePreviewView) {
        if let zoomCommand,
           zoomCommand.id != lastHandledZoomCommandID {
            view.apply(zoomAction: zoomCommand.action)
            lastHandledZoomCommandID = zoomCommand.id
        }

        if focusRequestID != lastHandledFocusRequestID,
           view.superview != nil {
            view.focusContent()
            lastHandledFocusRequestID = focusRequestID
        }
    }

    private func scheduleRender(on view: ZoomableImagePreviewView, settings: ImageAdjustmentSettings) {
        guard let sourceImage else {
            view.setRenderedImage(nil, fitToView: true)
            return
        }

        latestRenderID += 1
        let renderID = latestRenderID
        let shouldFit = needsFitAfterRender
        needsFitAfterRender = false
        needsRenderedImageRefresh = false
        let ciContext = self.ciContext

        renderQueue.async { [weak self] in
            guard let self else { return }
            let output = self.applyFilters(to: sourceImage, settings: settings)
            guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
                DispatchQueue.main.async {
                    guard renderID == self.latestRenderID else { return }
                    view.setRenderedImage(nil, fitToView: true)
                }
                return
            }

            let rendered = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async {
                guard renderID == self.latestRenderID else { return }
                view.setRenderedImage(rendered, fitToView: shouldFit)
                self.applyTransientCommands(to: view)
            }
        }
    }

    private func applyFilters(to source: CIImage, settings: ImageAdjustmentSettings) -> CIImage {
        var output = source

        if abs(settings.exposure) > 0.001,
           let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(output, forKey: kCIInputImageKey)
            exposureFilter.setValue(settings.exposure, forKey: kCIInputEVKey)
            output = exposureFilter.outputImage ?? output
        }

        if abs(settings.saturation - 1) > 0.001 || abs(settings.contrast - 1) > 0.001,
           let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(output, forKey: kCIInputImageKey)
            colorFilter.setValue(settings.saturation, forKey: kCIInputSaturationKey)
            colorFilter.setValue(settings.contrast, forKey: kCIInputContrastKey)
            colorFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
            output = colorFilter.outputImage ?? output
        }

        return output
    }
}

struct ImagePreviewContentHost: NSViewRepresentable {
    let controller: ImagePreviewContentController
    var backgroundColor: NSColor = .windowBackgroundColor
    var prepareForDisplay: ((ImagePreviewContentController) -> Void)? = nil

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
        let controller: ImagePreviewContentController

        init(controller: ImagePreviewContentController) {
            self.controller = controller
        }
    }
}

struct ImagePreviewView: NSViewRepresentable {
    let fileURL: URL
    var reloadToken: String = ""
    var adjustments: ImageAdjustmentSettings
    var zoomCommand: ImageZoomCommand?
    var focusRequestID: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomableImagePreviewView {
        let view = ZoomableImagePreviewView(frame: .zero)
        updateImageIfNeeded(on: view, context: context)
        return view
    }

    func updateNSView(_ nsView: ZoomableImagePreviewView, context: Context) {
        updateImageIfNeeded(on: nsView, context: context)

        if let zoomCommand,
           zoomCommand.id != context.coordinator.lastHandledZoomCommandID {
            nsView.apply(zoomAction: zoomCommand.action)
            context.coordinator.lastHandledZoomCommandID = zoomCommand.id
        }

        if focusRequestID != context.coordinator.lastHandledFocusRequestID {
            nsView.focusContent()
            context.coordinator.lastHandledFocusRequestID = focusRequestID
        }
    }

    private func updateImageIfNeeded(on view: ZoomableImagePreviewView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.loadedURL != fileURL || coordinator.loadedReloadToken != reloadToken {
            coordinator.loadedURL = fileURL
            coordinator.loadedReloadToken = reloadToken
            coordinator.sourceImage = CIImage(contentsOf: fileURL, options: [.applyOrientationProperty: true])
            coordinator.currentAdjustments = adjustments
            coordinator.needsFitAfterRender = true
            scheduleRender(on: view, coordinator: coordinator, settings: adjustments)
            return
        }

        if coordinator.currentAdjustments != adjustments {
            coordinator.currentAdjustments = adjustments
            scheduleRender(on: view, coordinator: coordinator, settings: adjustments)
        }
    }

    private func scheduleRender(on view: ZoomableImagePreviewView, coordinator: Coordinator, settings: ImageAdjustmentSettings) {
        guard let sourceImage = coordinator.sourceImage else {
            view.setRenderedImage(nil, fitToView: true)
            return
        }

        coordinator.latestRenderID += 1
        let renderID = coordinator.latestRenderID
        let shouldFit = coordinator.needsFitAfterRender
        coordinator.needsFitAfterRender = false

        let ciContext = coordinator.ciContext
        coordinator.renderQueue.async {
            let output = applyFilters(to: sourceImage, settings: settings)
            guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
                DispatchQueue.main.async {
                    if renderID == coordinator.latestRenderID {
                        view.setRenderedImage(nil, fitToView: true)
                    }
                }
                return
            }

            let rendered = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            DispatchQueue.main.async {
                guard renderID == coordinator.latestRenderID else { return }
                view.setRenderedImage(rendered, fitToView: shouldFit)
            }
        }
    }

    private func applyFilters(to source: CIImage, settings: ImageAdjustmentSettings) -> CIImage {
        var output = source

        if abs(settings.exposure) > 0.001,
           let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(output, forKey: kCIInputImageKey)
            exposureFilter.setValue(settings.exposure, forKey: kCIInputEVKey)
            output = exposureFilter.outputImage ?? output
        }

        if abs(settings.saturation - 1) > 0.001 || abs(settings.contrast - 1) > 0.001,
           let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(output, forKey: kCIInputImageKey)
            colorFilter.setValue(settings.saturation, forKey: kCIInputSaturationKey)
            colorFilter.setValue(settings.contrast, forKey: kCIInputContrastKey)
            colorFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
            output = colorFilter.outputImage ?? output
        }

        return output
    }

    final class Coordinator {
        var loadedURL: URL?
        var loadedReloadToken: String?
        var sourceImage: CIImage?
        var currentAdjustments: ImageAdjustmentSettings = .identity
        var lastHandledZoomCommandID: Int = 0
        var lastHandledFocusRequestID: Int = 0
        var latestRenderID: Int = 0
        var needsFitAfterRender = true

        let ciContext = CIContext(options: nil)
        let renderQueue = DispatchQueue(label: "nvmodern.image-preview.render", qos: .userInitiated)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class EventForwardingScrollView: NSScrollView {
    var onCommandScrollWheel: ((NSEvent) -> Bool)?
    var onMagnify: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onCommandScrollWheel?(event) == true {
            return
        }

        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if onMagnify?(event) == true {
            return
        }

        super.magnify(with: event)
    }
}

final class ZoomableImagePreviewView: NSView {
    private let scrollView = EventForwardingScrollView()
    private let documentContainerView = FlippedView()
    private let imageView = NSImageView()

    private var zoomFactor: CGFloat = 1.0
    private let defaultZoomFactor: CGFloat = 1.0
    private let minZoomFactor: CGFloat = 0.05
    private let maxZoomFactor: CGFloat = 16.0
    private let zoomStep: CGFloat = 1.12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateDocumentLayout()
    }

    override func keyDown(with event: NSEvent) {
        if handleZoomShortcut(event) {
            return
        }

        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if handleCommandScrollWheel(event) {
            return
        }

        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if handleMagnify(event) {
            return
        }

        super.magnify(with: event)
    }

    func setRenderedImage(_ image: NSImage?, fitToView: Bool) {
        imageView.image = image

        guard image != nil else {
            imageView.frame = .zero
            documentContainerView.frame = .zero
            return
        }

        if fitToView {
            zoomFactor = defaultZoomFactor
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        updateDocumentLayout()
    }

    func apply(zoomAction: ImageZoomCommand.Action) {
        switch zoomAction {
        case .zoomIn:
            setZoomFactor(clampedZoomFactor(zoomFactor * zoomStep), recenter: true)
        case .zoomOut:
            setZoomFactor(clampedZoomFactor(zoomFactor / zoomStep), recenter: true)
        case .reset, .fit:
            zoomFactor = defaultZoomFactor
            updateDocumentLayout()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func focusContent() {
        window?.makeFirstResponder(self)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = false
        scrollView.scrollerStyle = .overlay
        scrollView.onCommandScrollWheel = { [weak self] event in
            self?.handleCommandScrollWheel(event) ?? false
        }
        scrollView.onMagnify = { [weak self] event in
            self?.handleMagnify(event) ?? false
        }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = .zero

        documentContainerView.frame = .zero
        documentContainerView.addSubview(imageView)
        scrollView.documentView = documentContainerView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setZoomFactor(_ newValue: CGFloat, recenter: Bool, anchorInViewport: NSPoint? = nil) {
        let clamped = clampedZoomFactor(newValue)
        guard abs(clamped - zoomFactor) > 0.0001 else { return }

        let oldImageFrame = imageView.frame
        let viewportSize = scrollView.contentView.bounds.size
        let clipOrigin = scrollView.contentView.bounds.origin

        var anchorContext: (viewportY: CGFloat, normalizedImageY: CGFloat)?
        if let anchorInViewport,
           oldImageFrame.height > 0,
           viewportSize.height > 0 {
            let anchorDocumentY = clipOrigin.y + anchorInViewport.y
            let normalizedImageY = (anchorDocumentY - oldImageFrame.minY) / oldImageFrame.height
            anchorContext = (anchorInViewport.y, normalizedImageY)
        }

        zoomFactor = clamped
        updateDocumentLayout()

        if let anchorContext {
            scrollViewport(toKeepImageAnchorAt: anchorContext)
        } else if recenter {
            centerViewportOnImage()
        }
    }

    private func handleCommandScrollWheel(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              !flags.contains(.function)
        else {
            return false
        }

        let anchor = anchorPointInViewport(from: event)

        if event.deltaY < 0 {
            setZoomFactor(clampedZoomFactor(zoomFactor * zoomStep), recenter: false, anchorInViewport: anchor)
            return true
        }

        if event.deltaY > 0 {
            setZoomFactor(clampedZoomFactor(zoomFactor / zoomStep), recenter: false, anchorInViewport: anchor)
            return true
        }

        return false
    }

    private func handleMagnify(_ event: NSEvent) -> Bool {
        guard event.magnification != 0 else {
            return false
        }

        let next = clampedZoomFactor(zoomFactor * (1.0 + event.magnification))
        setZoomFactor(next, recenter: false, anchorInViewport: anchorPointInViewport(from: event))
        return true
    }

    private func fitHeightScale(for viewportHeight: CGFloat, imageHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, imageHeight > 0 else { return 1.0 }
        return viewportHeight / imageHeight
    }

    private func updateDocumentLayout() {
        guard let image = imageView.image,
              image.size.width > 0,
              image.size.height > 0
        else {
            imageView.frame = .zero
            documentContainerView.frame = .zero
            return
        }

        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let scale = fitHeightScale(for: viewportSize.height, imageHeight: image.size.height) * zoomFactor
        let displayWidth = image.size.width * scale
        let displayHeight = image.size.height * scale
        let documentHeight = max(viewportSize.height, displayHeight)

        documentContainerView.frame = NSRect(x: 0, y: 0, width: viewportSize.width, height: documentHeight)

        imageView.frame = NSRect(
            x: (viewportSize.width - displayWidth) * 0.5,
            y: max(0, (documentHeight - displayHeight) * 0.5),
            width: displayWidth,
            height: displayHeight
        )
    }

    private func centerViewportOnImage() {
        let viewportSize = scrollView.contentView.bounds.size
        let documentHeight = documentContainerView.frame.height
        guard viewportSize.height > 0, documentHeight > viewportSize.height else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let centeredOriginY = max(0, min((documentHeight - viewportSize.height) * 0.5, documentHeight - viewportSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: centeredOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollViewport(toKeepImageAnchorAt anchorContext: (viewportY: CGFloat, normalizedImageY: CGFloat)) {
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentContainerView.frame.height

        guard viewportHeight > 0, documentHeight > 0, imageView.frame.height > 0 else {
            return
        }

        let normalizedImageY = min(max(anchorContext.normalizedImageY, 0), 1)
        let anchorDocumentY = imageView.frame.minY + (imageView.frame.height * normalizedImageY)
        let targetOriginY = anchorDocumentY - anchorContext.viewportY
        let clampedOriginY = max(0, min(targetOriginY, max(0, documentHeight - viewportHeight)))

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func anchorPointInViewport(from event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        return scrollView.contentView.convert(event.locationInWindow, from: nil)
    }

    private func clampedZoomFactor(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoomFactor), maxZoomFactor)
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
}
