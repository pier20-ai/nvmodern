import AppKit
import SwiftUI

@MainActor
final class QuickCapturePanelController: NSObject, NSWindowDelegate {
    private static let fullPanelSize = NSSize(width: 560, height: 640)
    private static let appendPanelSize = NSSize(width: 600, height: 132)
    static let defaultInputPlaceholder = "Capture a thought…"

    /// What the visible panel is for, and where its outcome goes. The panel
    /// itself knows nothing about files or plugins: a session supplies that.
    private struct Session {
        enum Kind {
            /// `deliver` receives the trimmed text, nil when blank or
            /// cancelled. Returning false after an explicit submit keeps the
            /// panel open with its text, so a failed write loses nothing.
            case input(onDismiss: PluginInputRequest.DismissBehavior, deliver: (String?) -> Bool)
            case editor(onClose: () -> Void)
        }

        /// Toggle identity; nil never toggles.
        let id: String?
        let isPluginOwned: Bool
        let kind: Kind
    }

    private let editorController = QuickCaptureEditorController()
    private lazy var appendController = QuickCaptureAppendViewController { [weak self] in
        self?.submitInput()
    }
    private var fullPanel: QuickCapturePanel?
    private var appendPanel: QuickCapturePanel?
    private var escapeMonitor: Any?
    private var session: Session?

    func prewarm() {
        editorController.prewarm()
        _ = ensureAppendPanel()
    }

    /// Show the text panel. Asking for an `id` that is already showing closes
    /// it instead, which is what makes a hotkey a toggle.
    func showInput(
        _ request: PluginInputRequest,
        isPluginOwned: Bool,
        deliver: @escaping (String?) -> Bool
    ) {
        if isShowing(id: request.id) {
            close()
            _ = deliver(nil)
            return
        }

        close()
        session = Session(
            id: request.id,
            isPluginOwned: isPluginOwned,
            kind: .input(onDismiss: request.onDismiss, deliver: deliver)
        )
        let panel = ensureAppendPanel()
        panel.setFrame(positionedFrame(size: Self.appendPanelSize, spotlight: true), display: false)
        appendController.prepare(
            placeholder: request.placeholder ?? QuickCapturePanelController.defaultInputPlaceholder,
            initialText: request.initialText ?? "",
            submitsOnReturn: request.submitKey == .plainReturn
        )
        present(panel)

        DispatchQueue.main.async { [weak self] in
            self?.appendController.requestFocus()
        }
    }

    /// Show the editor panel on a file; toggles on `id` like `showInput`.
    func showEditor(
        _ request: PluginPanelRequest,
        isPluginOwned: Bool,
        onClose: @escaping () -> Void
    ) {
        if isShowing(id: request.id) {
            close()
            onClose()
            return
        }

        close()
        session = Session(id: request.id, isPluginOwned: isPluginOwned, kind: .editor(onClose: onClose))
        let panel = ensureFullPanel()
        panel.setFrame(positionedFrame(size: Self.fullPanelSize, spotlight: false), display: false)
        editorController.open(fileURL: request.fileURL, cursorPlacement: request.cursor.rawValue)
        present(panel)

        DispatchQueue.main.async { [weak self] in
            self?.editorController.requestFocus()
        }
    }

    /// Close whatever a plugin put up; config-driven captures stay.
    func closePluginSession() {
        if session?.isPluginOwned == true {
            close()
        }
    }

    func close() {
        // Cleared first: ordering a panel out resigns key, which re-enters here.
        let ending = session
        session = nil

        switch ending?.kind {
        case .input(let onDismiss, let deliver):
            let text = appendController.currentText()
            appendController.clear()
            appendPanel?.orderOut(nil)
            _ = deliver(onDismiss == .submit ? text : nil)
        case .editor(let onClose):
            editorController.flushPendingSaveIfNeeded()
            fullPanel?.orderOut(nil)
            onClose()
        case nil:
            fullPanel?.orderOut(nil)
            appendPanel?.orderOut(nil)
        }
        removeEscapeMonitor()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        WindowFocusCoordinator.shared.notifyWindowDidBecomeKey(panel)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        WindowFocusCoordinator.shared.notifyWindowDidResignKey(panel)
        if panel === activePanel {
            close()
        }
    }

    private var activePanel: QuickCapturePanel? {
        switch session?.kind {
        case .editor: return fullPanel
        case .input: return appendPanel
        case nil: return nil
        }
    }

    private func isShowing(id: String?) -> Bool {
        guard let id, session?.id == id else { return false }
        return activePanel?.isVisible == true
    }

    private func present(_ panel: QuickCapturePanel) {
        panel.orderFrontRegardless()
        panel.makeKey()
        installEscapeMonitorIfNeeded()
    }

    private func submitInput() {
        guard case .input(_, let deliver)? = session?.kind else { return }
        guard deliver(appendController.currentText()) else { return }
        session = nil
        appendController.clear()
        appendPanel?.orderOut(nil)
        removeEscapeMonitor()
    }

    private func ensureFullPanel() -> QuickCapturePanel {
        if let fullPanel { return fullPanel }

        let panel = makePanel(size: Self.fullPanelSize)
        panel.contentViewController = NSHostingController(
            rootView: QuickCapturePanelRootView(
                editorController: editorController,
                panelSize: Self.fullPanelSize
            )
            .frame(width: Self.fullPanelSize.width, height: Self.fullPanelSize.height)
        )
        WindowFocusCoordinator.shared.registerWindow(
            panel,
            kind: .quickCapturePanel,
            identifier: "quick-capture-full-panel"
        )
        fullPanel = panel
        return panel
    }

    private func ensureAppendPanel() -> QuickCapturePanel {
        if let appendPanel { return appendPanel }

        let panel = makePanel(size: Self.appendPanelSize)
        panel.contentViewController = appendController
        WindowFocusCoordinator.shared.registerWindow(
            panel,
            kind: .quickCapturePanel,
            identifier: "quick-capture-append-panel"
        )
        appendPanel = panel
        return panel
    }

    private func makePanel(size: NSSize) -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.setContentSize(size)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func positionedFrame(size: NSSize, spotlight: Bool) -> NSRect {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }

        let visibleFrame = screen.visibleFrame
        let centerY = spotlight ? visibleFrame.minY + (visibleFrame.height * 0.64) : visibleFrame.midY
        let origin = NSPoint(
            x: round(visibleFrame.midX - (size.width / 2)),
            y: round(centerY - (size.height / 2))
        )
        return NSRect(origin: origin, size: size)
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeMonitor == nil else { return }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let activePanel,
                  activePanel.isVisible,
                  event.window === activePanel else {
                return event
            }

            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class QuickCaptureAppendViewController: NSViewController {
    private let onSubmit: () -> Void
    private let textView = QuickCaptureAppendTextView(frame: .zero)

    init(onSubmit: @escaping () -> Void) {
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        textView.onSubmit = onSubmit
        textView.placeholder = QuickCapturePanelController.defaultInputPlaceholder
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.frame = NSRect(x: 0, y: 0, width: 552, height: 88)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.addSubview(scrollView)

        let rimView = QuickCaptureAppendRimView()
        rimView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rimView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            rimView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rimView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rimView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rimView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glassView = QuickCaptureAppendGlassSurfaceView()
            glassView.contentView = contentView
            if #available(macOS 27.0, *) {
                glassView.effectIsInteractive = true
            }
            view = glassView
        } else {
            let effectView = QuickCaptureAppendFallbackSurfaceView()
            contentView.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            ])
            view = effectView
        }
    }

    func prepare(placeholder: String, initialText: String, submitsOnReturn: Bool) {
        textView.placeholder = placeholder
        textView.submitsOnReturn = submitsOnReturn
        textView.string = initialText
        textView.setSelectedRange(NSRange(location: (initialText as NSString).length, length: 0))
        textView.needsDisplay = true
    }

    func requestFocus() {
        view.window?.makeFirstResponder(textView)
    }

    /// The typed text without surrounding blank lines; nil when there is
    /// nothing but whitespace.
    func currentText() -> String? {
        let text = textView.string.trimmingCharacters(in: .newlines)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    func clear() {
        textView.string = ""
        textView.needsDisplay = true
    }
}

@available(macOS 26.0, *)
private final class QuickCaptureAppendGlassSurfaceView: NSGlassEffectView {
    private static let surfaceCornerRadius: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = Self.surfaceCornerRadius
        style = .regular

        // NSGlassEffectView rounds the glass effect, but its backing layer still
        // occupies the full rectangular window. Clip that layer to keep the
        // transparent panel visible through all four corner cutouts.
        wantsLayer = true
        layer?.cornerRadius = Self.surfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class QuickCaptureAppendFallbackSurfaceView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

/// Dark-mode edge for the append surface. Over a dark page the window shadow
/// has nothing to darken, so the panel gets the light inner border native dark
/// windows carry. In light mode the window shadow's rim already defines the
/// edge, and a stroke on top of it only muddies the glass.
private final class QuickCaptureAppendRimView: NSView {
    private static let cornerRadius: CGFloat = 24

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer.borderColor = isDark ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class QuickCaptureAppendTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// Return submits and Shift+Return breaks the line, instead of Return
    /// breaking the line and Cmd+Return submitting.
    var submitsOnReturn = false
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let placeholderOrigin = NSPoint(
            x: textContainerOrigin.x + 5,
            y: textContainerOrigin.y
        )
        (placeholder as NSString).draw(at: placeholderOrigin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b":
            wrapSelection(prefix: "**", suffix: "**")
            return true
        case "i":
            wrapSelection(prefix: "*", suffix: "*")
            return true
        case "\r", "\n":
            onSubmit?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        if submitsOnReturn, NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
            onSubmit?()
            return
        }

        let selection = selectedRange()
        guard selection.length == 0 else {
            super.insertNewline(sender)
            return
        }

        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefixRange = NSRange(
            location: lineRange.location,
            length: selection.location - lineRange.location
        )
        let linePrefix = source.substring(with: prefixRange)

        if let continuation = QuickCaptureMarkdownContinuation.continuation(for: linePrefix) {
            if continuation.endsList {
                insertText(continuation.indent, replacementRange: prefixRange)
            } else {
                insertText("\n\(continuation.prefix)", replacementRange: selection)
            }
            return
        }

        super.insertNewline(sender)
    }

    private func wrapSelection(prefix: String, suffix: String) {
        let selection = selectedRange()
        let selectedText = (string as NSString).substring(with: selection)
        let replacement = prefix + selectedText + suffix
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }

        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        if selection.length == 0 {
            setSelectedRange(NSRange(location: selection.location + prefix.utf16.count, length: 0))
        } else {
            setSelectedRange(NSRange(location: selection.location + prefix.utf16.count, length: selection.length))
        }
    }

}

private struct QuickCapturePanelRootView: View {
    @Environment(\.colorScheme) private var colorScheme

    let editorController: QuickCaptureEditorController
    let panelSize: NSSize

    private var panelBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
    }

    private var panelSurfaceColor: Color {
        colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.14) : .white
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelSurfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(panelBorderColor, lineWidth: 1)
                )

            QuickCaptureEditorView(controller: editorController)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(8)
        }
        .padding(8)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color.clear)
    }
}
