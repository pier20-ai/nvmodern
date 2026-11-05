import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MillerDragPayload: Codable {
    static let contentType = UTType(exportedAs: "com.nvmodern.workspace-items")
    static let typeIdentifier = contentType.identifier

    let workspaceRootPath: String
    let relativePaths: [String]
}

/// Owns Miller drop routing at the retained tab controller's AppKit root.
/// SwiftUI drop destinations inside the nested NSHostingController never see
/// the drag session, so target marker views only publish live geometry here;
/// the root AppKit destination performs validation and delivery.
@MainActor
final class MillerNativeDropRouter: ObservableObject {
    @Published private(set) var activeTargetID: String?

    /// SwiftUI exposes the promised custom pasteboard type immediately, but
    /// AppKit may ask a synchronous drop destination for its bytes before the
    /// NSItemProvider representation has materialized. Miller drags are
    /// app-local, so retain the exact payload for the lifetime of the drag and
    /// use the pasteboard representation when it is available.
    private static var activeDragPayload: MillerDragPayload?

    private final class TargetRegistration {
        weak var view: NSView?
        var targetID: String
        var priority: Int
        var isEnabled: Bool
        var onDrop: (MillerDragPayload) -> Void

        init(
            view: NSView,
            targetID: String,
            priority: Int,
            isEnabled: Bool,
            onDrop: @escaping (MillerDragPayload) -> Void
        ) {
            self.view = view
            self.targetID = targetID
            self.priority = priority
            self.isEnabled = isEnabled
            self.onDrop = onDrop
        }
    }

    private var registrations: [ObjectIdentifier: TargetRegistration] = [:]

    func beginDrag(_ payload: MillerDragPayload) {
        Self.activeDragPayload = payload
    }

    func register(
        view: NSView,
        targetID: String,
        priority: Int,
        isEnabled: Bool,
        onDrop: @escaping (MillerDragPayload) -> Void
    ) {
        let key = ObjectIdentifier(view)
        if let registration = registrations[key] {
            registration.targetID = targetID
            registration.priority = priority
            registration.isEnabled = isEnabled
            registration.onDrop = onDrop
        } else {
            registrations[key] = TargetRegistration(
                view: view,
                targetID: targetID,
                priority: priority,
                isEnabled: isEnabled,
                onDrop: onDrop
            )
        }
        pruneRegistrations()
    }

    func unregister(view: NSView) {
        let key = ObjectIdentifier(view)
        let removedTargetID = registrations.removeValue(forKey: key)?.targetID
        if activeTargetID == removedTargetID {
            setActiveTarget(nil)
        }
    }

    func draggingEntered(_ sender: any NSDraggingInfo, in destinationView: NSView) -> NSDragOperation {
        updateActiveTarget(for: sender, in: destinationView)
    }

    func draggingUpdated(_ sender: any NSDraggingInfo, in destinationView: NSView) -> NSDragOperation {
        updateActiveTarget(for: sender, in: destinationView)
    }

    func draggingExited() {
        millerDebugLog("Drop", "native exited target=\(activeTargetID ?? "<none>")")
        setActiveTarget(nil)
    }

    func performDrop(_ sender: any NSDraggingInfo, in destinationView: NSView) -> Bool {
        guard accepts(sender),
              let registration = target(for: sender, in: destinationView) else {
            millerDebugLog(
                "Drop",
                "native perform rejected target types=\(sender.draggingPasteboard.types?.map(\.rawValue) ?? []) target=\(activeTargetID ?? "<none>")"
            )
            setActiveTarget(nil)
            return false
        }

        let pasteboardPayload = sender.draggingPasteboard
            .data(forType: NSPasteboard.PasteboardType(MillerDragPayload.typeIdentifier))
            .flatMap { try? JSONDecoder().decode(MillerDragPayload.self, from: $0) }
        guard let payload = pasteboardPayload ?? Self.activeDragPayload else {
            millerDebugLog(
                "Drop",
                "native perform rejected payload types=\(sender.draggingPasteboard.types?.map(\.rawValue) ?? []) target=\(registration.targetID)"
            )
            setActiveTarget(nil)
            return false
        }

        millerDebugLog(
            "Drop",
            "native perform target=\(registration.targetID) transport=\(pasteboardPayload == nil ? "drag-session" : "pasteboard") root=\(payload.workspaceRootPath) paths=\(payload.relativePaths)"
        )
        Self.activeDragPayload = nil
        setActiveTarget(nil)
        registration.onDrop(payload)
        return true
    }

    private func updateActiveTarget(
        for sender: any NSDraggingInfo,
        in destinationView: NSView
    ) -> NSDragOperation {
        guard accepts(sender) else {
            setActiveTarget(nil)
            return []
        }

        let registration = target(for: sender, in: destinationView)
        if setActiveTarget(registration?.targetID) {
            millerDebugLog(
                "Drop",
                "native update target=\(registration?.targetID ?? "<none>") location=\(sender.draggingLocation)"
            )
        }
        return registration == nil ? [] : .move
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        let type = NSPasteboard.PasteboardType(MillerDragPayload.typeIdentifier)
        return sender.draggingPasteboard.availableType(from: [type]) != nil
    }

    private func target(
        for sender: any NSDraggingInfo,
        in destinationView: NSView
    ) -> TargetRegistration? {
        pruneRegistrations()
        guard let destinationWindow = destinationView.window else { return nil }
        let windowPoint = sender.draggingLocation

        return registrations.values
            .compactMap { registration -> (TargetRegistration, CGFloat)? in
                guard registration.isEnabled,
                      let view = registration.view,
                      view.window === destinationWindow,
                      !view.isHidden,
                      view.alphaValue > 0 else {
                    return nil
                }
                let localPoint = view.convert(windowPoint, from: nil)
                guard view.bounds.contains(localPoint) else { return nil }
                return (registration, view.bounds.width * view.bounds.height)
            }
            .sorted { lhs, rhs in
                if lhs.0.priority != rhs.0.priority {
                    return lhs.0.priority > rhs.0.priority
                }
                return lhs.1 < rhs.1
            }
            .first?.0
    }

    @discardableResult
    private func setActiveTarget(_ targetID: String?) -> Bool {
        guard activeTargetID != targetID else { return false }
        activeTargetID = targetID
        return true
    }

    private func pruneRegistrations() {
        registrations = registrations.filter { $0.value.view != nil }
    }
}

final class MillerRootDropDestinationView: NSView {
    private let router: MillerNativeDropRouter
    private let pasteboardType = NSPasteboard.PasteboardType(MillerDragPayload.typeIdentifier)

    init(router: MillerNativeDropRouter) {
        self.router = router
        super.init(frame: .zero)
        registerForDraggedTypes([pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        unregisterDraggedTypes()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        router.draggingEntered(sender, in: self)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        router.draggingUpdated(sender, in: self)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        router.draggingExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        router.performDrop(sender, in: self)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        router.draggingExited()
    }
}

@MainActor
final class MillerDropHostingViewController: NSViewController {
    private let contentController: NSViewController
    private let router: MillerNativeDropRouter

    init(contentController: NSViewController, router: MillerNativeDropRouter) {
        self.contentController = contentController
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = MillerRootDropDestinationView(router: router)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        addChild(contentController)
        let contentView = contentController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }
}

struct MillerNativeDropTarget: NSViewRepresentable {
    let router: MillerNativeDropRouter
    let targetID: String
    let priority: Int
    let isEnabled: Bool
    let onDrop: (MillerDragPayload) -> Void

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TargetView, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: TargetView, coordinator: ()) {
        nsView.unregister()
    }

    private func configure(_ view: TargetView) {
        view.configure(
            router: router,
            targetID: targetID,
            priority: priority,
            isEnabled: isEnabled,
            onDrop: onDrop
        )
    }

    final class TargetView: NSView {
        private weak var router: MillerNativeDropRouter?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func configure(
            router: MillerNativeDropRouter,
            targetID: String,
            priority: Int,
            isEnabled: Bool,
            onDrop: @escaping (MillerDragPayload) -> Void
        ) {
            if self.router !== router {
                unregister()
                self.router = router
            }
            router.register(
                view: self,
                targetID: targetID,
                priority: priority,
                isEnabled: isEnabled,
                onDrop: onDrop
            )
        }

        func unregister() {
            router?.unregister(view: self)
            router = nil
        }

        deinit {
            unregister()
        }
    }
}
