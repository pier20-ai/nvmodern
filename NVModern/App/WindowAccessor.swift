import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    /// Fires synchronously the moment the hosted view joins its window —
    /// before SwiftUI orders the window front. Window-level configuration
    /// that must not be visible (joining an AppKit tab group) belongs here;
    /// doing it in `onResolve` runs after the window has already appeared,
    /// which shows a separate-window flash before the merge.
    var onAttaching: ((NSWindow) -> Void)? = nil
    var onDidBecomeKey: ((NSWindow) -> Void)? = nil
    var onDidResignKey: ((NSWindow) -> Void)? = nil
    var onWillClose: ((NSWindow) -> Void)? = nil
    var onFirstDraw: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        ResolverView(
            onResolve: onResolve,
            onAttaching: onAttaching,
            onDidBecomeKey: onDidBecomeKey,
            onDidResignKey: onDidResignKey,
            onWillClose: onWillClose,
            onFirstDraw: onFirstDraw
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let resolverView = nsView as? ResolverView else { return }
        resolverView.updateCallbacks(
            onResolve: onResolve,
            onAttaching: onAttaching,
            onDidBecomeKey: onDidBecomeKey,
            onDidResignKey: onDidResignKey,
            onWillClose: onWillClose,
            onFirstDraw: onFirstDraw
        )
    }

    private final class ResolverView: NSView {
        private var onResolve: (NSWindow) -> Void
        private var onAttaching: ((NSWindow) -> Void)?
        private var onDidBecomeKey: ((NSWindow) -> Void)?
        private var onDidResignKey: ((NSWindow) -> Void)?
        private var onWillClose: ((NSWindow) -> Void)?
        private var onFirstDraw: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var didReportFirstDraw = false

        init(
            onResolve: @escaping (NSWindow) -> Void,
            onAttaching: ((NSWindow) -> Void)?,
            onDidBecomeKey: ((NSWindow) -> Void)?,
            onDidResignKey: ((NSWindow) -> Void)?,
            onWillClose: ((NSWindow) -> Void)?,
            onFirstDraw: ((NSWindow) -> Void)?
        ) {
            self.onResolve = onResolve
            self.onAttaching = onAttaching
            self.onDidBecomeKey = onDidBecomeKey
            self.onDidResignKey = onDidResignKey
            self.onWillClose = onWillClose
            self.onFirstDraw = onFirstDraw
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func updateCallbacks(
            onResolve: @escaping (NSWindow) -> Void,
            onAttaching: ((NSWindow) -> Void)?,
            onDidBecomeKey: ((NSWindow) -> Void)?,
            onDidResignKey: ((NSWindow) -> Void)?,
            onWillClose: ((NSWindow) -> Void)?,
            onFirstDraw: ((NSWindow) -> Void)?
        ) {
            self.onResolve = onResolve
            self.onAttaching = onAttaching
            self.onDidBecomeKey = onDidBecomeKey
            self.onDidResignKey = onDidResignKey
            self.onWillClose = onWillClose
            self.onFirstDraw = onFirstDraw
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            guard let window else { return }

            didReportFirstDraw = false
            PerformanceDiagnostics.markNewTab(window: window, event: "accessor.attached")

            onAttaching?(window)

            let notificationCenter = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification
            ]

            for name in names {
                let observer = notificationCenter.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] notification in
                    guard let self else { return }
                    self.onResolve(window)

                    switch notification.name {
                    case NSWindow.didBecomeKeyNotification:
                        PerformanceDiagnostics.appLifecycle("windowDidBecomeKey", window: window)
                        PerformanceDiagnostics.markNewTab(window: window, event: "window.didBecomeKey")
                        self.onDidBecomeKey?(window)
                    case NSWindow.didResignKeyNotification:
                        PerformanceDiagnostics.appLifecycle("windowDidResignKey", window: window)
                        self.onDidResignKey?(window)
                    default:
                        break
                    }
                }
                observers.append(observer)
            }

            if let onWillClose {
                let closeObserver = notificationCenter.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    onWillClose(window)
                }
                observers.append(closeObserver)
            }

            DispatchQueue.main.async {
                self.onResolve(window)
            }
        }

        override func viewWillDraw() {
            super.viewWillDraw()
            guard !didReportFirstDraw, let window else { return }
            didReportFirstDraw = true
            onFirstDraw?(window)
        }
    }
}
enum WindowConfigurator {
    private static let trafficLightsLeftInset: CGFloat = 16
    private static let trafficLightsSpacing: CGFloat = 8
    private static let trafficLightsTopGap: CGFloat = 12

    static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor

        let didAdjustTrafficLights = adjustTrafficLights(for: window)
        if !didAdjustTrafficLights {
            DispatchQueue.main.async {
                _ = adjustTrafficLights(for: window)
            }
        }
    }

    @discardableResult
    private static func adjustTrafficLights(for window: NSWindow) -> Bool {
        guard
            let close = window.standardWindowButton(.closeButton),
            let mini = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let titlebarContainer = close.superview
        else {
            return false
        }

        let y = max(0, titlebarContainer.bounds.height - close.frame.height - trafficLightsTopGap)
        close.setFrameOrigin(NSPoint(x: trafficLightsLeftInset, y: y))
        mini.setFrameOrigin(NSPoint(x: trafficLightsLeftInset + close.frame.width + trafficLightsSpacing, y: y))
        zoom.setFrameOrigin(NSPoint(x: trafficLightsLeftInset + (close.frame.width + trafficLightsSpacing) * 2, y: y))
        return true
    }
}

/// Native-shell window configuration: standard titled window with a SwiftUI
/// toolbar and AppKit window tabbing, replacing the custom transparent
/// titlebar + Bonsplit tab bar of the old shell.
enum NativeWindowConfigurator {
    /// Records the document colour `window` wants on the native tab bar.
    /// AppKit keeps one tab bar per tab group and moves it into the selected
    /// window, so the bar is repainted with the selected window's colour
    /// whenever the group's selection or tabs change.
    static func setTabBarTint(_ color: NSColor?, for window: NSWindow) {
        guard #available(macOS 26.0, *) else { return }
        TabBarTinter.shared.setTint(color, for: window)
    }

    static func configure(_ window: NSWindow) {
        // WorkspaceSessionStore owns restoration. Keeping AppKit's parallel
        // window snapshots enabled can trigger its crash-history restoration
        // prompt before SwiftUI has presented an application window.
        window.isRestorable = false
        window.disableSnapshotRestoration()
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .preferred
        window.isMovable = true
        window.backgroundColor = .windowBackgroundColor
    }
}

/// Paints a document colour onto AppKit's tab bar, which has no public tint
/// API. The bar and its tabs are found by accessibility role rather than
/// AppKit's internal class names. The selected tab is an `NSGlassEffectView`
/// and takes a translucent tint; the track behind the tabs is a private,
/// mostly opaque neutral glass with no tint of its own, so it is painted over.
@available(macOS 26.0, *)
private final class TabBarTinter {
    static let shared = TabBarTinter()

    private struct GroupObservation {
        weak var group: NSWindowTabGroup?
        let observations: [NSKeyValueObservation]
    }

    private let tints = NSMapTable<NSWindow, NSColor>.weakToStrongObjects()
    private var groupObservations: [GroupObservation] = []

    func setTint(_ color: NSColor?, for window: NSWindow) {
        if let color {
            tints.setObject(color, forKey: window)
        } else {
            tints.removeObject(forKey: window)
        }
        if let group = window.tabGroup {
            observe(group)
        }
        // The bar is only in the window while it is the selected tab.
        paint(window)
    }

    private func observe(_ group: NSWindowTabGroup) {
        groupObservations.removeAll { $0.group == nil }
        guard !groupObservations.contains(where: { $0.group === group }) else { return }
        // Selecting, adding or closing a tab moves the bar or rebuilds its
        // buttons without necessarily changing the key window. A new tab's
        // bar arrives after `windows` changes, hence the next-turn repaint.
        let repaint: (NSWindowTabGroup) -> Void = { [weak self] group in
            DispatchQueue.main.async {
                guard let window = group.selectedWindow else { return }
                self?.paint(window)
            }
        }
        groupObservations.append(GroupObservation(group: group, observations: [
            group.observe(\.selectedWindow) { group, _ in repaint(group) },
            group.observe(\.windows) { group, _ in repaint(group) }
        ]))
    }

    private func paint(_ window: NSWindow) {
        guard let tabBar = tabBar(in: window) else { return }
        let paint = TabBarPaint(
            documentColor: tints.object(forKey: window),
            isDarkAppearance: tabBar.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
        tintGlass(in: tabBar, paint?.selectedTabTint)
        if let track = track(in: tabBar) {
            // AppKit sorts this view's subviews as tab buttons. Keep its view
            // collection intact and paint only the existing backing layer.
            let color = paint?.trackColor.cgColor
            track.wantsLayer = true
            if track.layer?.backgroundColor != color {
                track.layer?.backgroundColor = color
                track.layer?.cornerRadius = track.bounds.height / 2
            }
        }
    }

    private func tabBar(in window: NSWindow) -> NSView? {
        func find(in view: NSView) -> NSView? {
            if view === window.contentView { return nil }
            if view.accessibilityRole() == .tabGroup { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView?.superview.flatMap(find)
    }

    /// Every tab carries its own glass; only the selected one shows it.
    private func tintGlass(in view: NSView, _ tint: NSColor?) {
        if let glass = view as? NSGlassEffectView, glass.tintColor != tint {
            glass.tintColor = tint
        }
        for child in view.subviews { tintGlass(in: child, tint) }
    }

    /// The view behind the tab buttons, inside the track's glass: the
    /// nearest common ancestor of the tabs.
    private func track(in tabBar: NSView) -> NSView? {
        var tabs: [NSView] = []
        func collectTabs(in view: NSView) {
            if view.accessibilityRole() == .radioButton {
                tabs.append(view)
                return
            }
            for child in view.subviews { collectTabs(in: child) }
        }
        collectTabs(in: tabBar)
        guard let first = tabs.first else { return nil }
        var container = first.superview
        while let candidate = container,
              !tabs.allSatisfy({ $0.isDescendant(of: candidate) }) {
            container = candidate.superview
        }
        return container === tabBar ? nil : container
    }
}

/// How a document colour lands on the native tab bar, or nil to leave
/// AppKit's own bar alone.
struct TabBarPaint {
    let selectedTabTint: NSColor
    let trackColor: NSColor

    init?(documentColor: NSColor?, isDarkAppearance: Bool) {
        guard let color = documentColor?.usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        // Glass tint carries hue. A neutral page colour (the system theme's
        // white or #191919) has none, and AppKit's own bar already suits it.
        guard max(r, g, b) - min(r, g, b) > 0.03 else { return nil }
        // A page whose lightness disagrees with the appearance would put the
        // appearance's tab labels on a track they cannot be read against.
        let isDark = 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5
        guard isDark == isDarkAppearance else { return nil }
        // An opaque tint fills the glass with the page colour and flattens
        // it; at 30% it stays glass. A dark colour is lifted first so the
        // selected tab stays lighter than the track, as in AppKit's dark bar.
        let lifted = isDark ? color.blended(withFraction: 0.25, of: .white) ?? color : color
        selectedTabTint = lifted.withAlphaComponent(0.3)
        // AppKit's track is a mostly opaque grey a shade off the window:
        // darker in light, lighter in dark. Shade the page colour the same
        // way and let a little of the glass show through.
        let shaded = color.blended(withFraction: isDark ? 0.08 : 0.1, of: isDark ? .white : .black) ?? color
        trackColor = shaded.withAlphaComponent(0.85)
    }
}
