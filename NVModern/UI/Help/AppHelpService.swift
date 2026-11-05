import AppKit
import QuartzCore

/// One in-window help drawer for the app. Providers supply content; callers optionally supply insertion.
@MainActor
final class AppHelpService {
    static let shared = AppHelpService()
    private(set) var providers: [HelpProvider] = []
    var isPresented: Bool { panel != nil }
    private var panel: HelpPanel?
    private var controller: HelpDrawerController?
    private weak var owner: NSView?
    private weak var previousResponder: NSResponder?
    private var onClose: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        if let url = Bundle.main.url(forResource: "help-catalog", withExtension: "json", subdirectory: "WebEditor")
            ?? Bundle.main.url(forResource: "help-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? JSONDecoder().decode([HelpProvider].self, from: data) {
            bundled.forEach { register($0) }
        }
    }

    /// The build-time Markdown rendering of a provider (generated from the same data as the drawer).
    static func markdown(forProvider id: String) -> String? {
        guard !id.contains("/"), !id.contains("..") else { return nil }
        let url = Bundle.main.url(forResource: id, withExtension: "md", subdirectory: "WebEditor/help")
            ?? Bundle.main.url(forResource: id, withExtension: "md", subdirectory: "help")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func register(_ provider: HelpProvider) {
        guard !provider.id.isEmpty, !provider.topics.isEmpty,
              Set(provider.topics.map(\.id)).count == provider.topics.count else { return }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    func present(
        providerID: String? = nil,
        in source: NSView,
        canInsert: Bool = false,
        allowsMultiline: Bool = true,
        onInsert: ((String) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        guard let window = source.window, !(window is HelpPanel), !providers.isEmpty,
              providerID == nil || providers.contains(where: { $0.id == providerID }) else { return }
        dismiss(animated: false)
        owner = source
        previousResponder = window.firstResponder
        self.onClose = onClose
        let content = HelpDrawerController(
            providers: providers, selectedProviderID: providerID,
            canInsert: canInsert && onInsert != nil, allowsMultiline: allowsMultiline
        )
        content.onInsert = { [weak self, weak source] template in
            guard let self, let source, self.owner === source, source.window != nil else { return }
            onInsert?(template)
            self.dismiss()
        }
        content.onClose = { [weak self] in self?.dismiss() }
        let panel = HelpPanel(content: content)
        panel.onCancel = { [weak self] in self?.dismiss() }
        self.panel = panel
        controller = content
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(animated: false) }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, let panel = self.panel else { return }
                    panel.setFrame(Self.drawerFrame(in: window), display: true)
                }
            },
            // Clicking back into the workspace, switching native tabs, or opening another app window dismisses help.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let other = note.object as? NSWindow, other !== panel else { return }
                    self.dismiss()
                }
            },
        ]
        window.addChildWindow(panel, ordered: .above)
        panel.reveal(at: Self.drawerFrame(in: window))
        panel.makeKey()
        content.focusSearch()
    }

    func presentFromActiveWindow() {
        if let panel { panel.makeKey(); controller?.focusSearch(); return }
        guard let view = MenuCommandContext.sheetHostWindow?.contentView else { return }
        present(in: view)
    }

    func dismiss(ownedBy source: NSView) {
        if owner === source { dismiss(animated: false) }
    }

    func dismiss(animated: Bool = true) {
        guard let panel else { return }
        let content = controller
        let close = onClose
        let window = owner?.window
        let responder = previousResponder
        self.panel = nil
        controller = nil
        onClose = nil
        owner = nil
        previousResponder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Disable outgoing actions immediately, while the closing animation is still visible.
        content?.onInsert = nil
        content?.onClose = nil
        panel.onCancel = nil
        let restoreFocus = window != nil && NSApp.keyWindow === panel
        panel.hide(animated: animated) {
            content?.invalidate()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if restoreFocus, let window {
            window.makeKey()
            if let view = responder as? NSView, view.window === window { window.makeFirstResponder(view) }
        }
        close?()
    }

    /// A wide, short shelf along the bottom of the workspace content area (below the toolbar), in screen coordinates.
    static func drawerFrame(in window: NSWindow) -> NSRect {
        let content = window.convertToScreen(window.contentLayoutRect)
        let inset: CGFloat = 10
        let width = max(320, content.width - inset * 2)
        let height = min(400, max(240, (content.height * 0.44).rounded()))
        return NSRect(x: content.minX + inset, y: content.minY + inset, width: width, height: min(height, content.height - inset * 2)).integral
    }
}

/// A borderless child panel: native glass needs its own transparent window, and SwiftUI must not own its view.
@MainActor
final class HelpPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 880, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        contentViewController = content
        setAccessibilityLabel("nvModern Help")
        setAccessibilitySubrole(.dialog)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var transition: Timer?

    func reveal(at frame: NSRect) {
        let start = reducesMotion ? frame : frame.offsetBy(dx: 0, dy: -14)
        setFrame(start, display: false)
        alphaValue = 0
        orderFront(nil)
        animate(from: start, to: frame, alpha: (0, 1), duration: reducesMotion ? 0.12 : 0.28, easeOut: true) {}
    }

    func hide(animated: Bool, completion: @escaping () -> Void) {
        guard animated else { transition?.invalidate(); completion(); return }
        let end = reducesMotion ? frame : frame.offsetBy(dx: 0, dy: -10)
        animate(from: frame, to: end, alpha: (alphaValue, 0), duration: reducesMotion ? 0.1 : 0.18, easeOut: false, completion: completion)
    }

    /// Window animator proxies do not run reliably for child panels, so drive the transition directly.
    private func animate(from: NSRect, to: NSRect, alpha: (CGFloat, CGFloat), duration: TimeInterval,
                         easeOut: Bool, completion: @escaping () -> Void) {
        transition?.invalidate()
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); completion(); return }
                let t = min(1, (CACurrentMediaTime() - began) / duration)
                let p = easeOut ? 1 - pow(1 - t, 3) : t * t
                self.alphaValue = alpha.0 + (alpha.1 - alpha.0) * p
                self.setFrameOrigin(NSPoint(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p))
                if t >= 1 { timer.invalidate(); self.transition = nil; completion() }
            }
        }
        transition = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
