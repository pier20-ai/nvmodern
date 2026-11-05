import AppKit
import SwiftUI

/// Window-level host for the command palette, rendered as a SwiftUI overlay.
///
/// The palette used to be an `NSHostingView` inserted into the window's content
/// view. That works on macOS 15, where SwiftUI hosts a window in an
/// `NSHostingView` whose subviews are real AppKit views. It does not work on
/// macOS 26: SwiftUI hosts windows in `AppKitWindowHostingView` and renders
/// almost entirely into layers, and a foreign subview added there joins the
/// view tree — laying out and hit-testing correctly — without ever joining the
/// layer tree. The palette was fully functional and completely invisible.
///
/// A plain `NSView` inserted the same way failed identically, so this is not
/// specific to hosting SwiftUI inside SwiftUI: nothing foreign composites in
/// that hierarchy. The fix is to stop inserting AppKit views into it and let
/// SwiftUI render the palette, which is how `WorkspaceTabSwitcherView` has
/// always worked.
///
/// The API mirrors the controller this replaces so call sites are unchanged.
@MainActor
final class WorkspacePaletteHost: ObservableObject {
    struct Presentation: Identifiable {
        let id = UUID()
        let preferredHeight: CGFloat
        let content: AnyView
        let onEscape: (() -> Void)?
        let onClose: () -> Void
    }

    @Published private(set) var presentation: Presentation?

    let dismissCoordinator = WorkspaceCommandOverlayDismissCoordinator()

    /// Escape backstop. `.onExitCommand` only fires when the overlay is in the
    /// responder chain and nothing upstream consumes the key, so it does not
    /// cover the case where focus has moved elsewhere in the window. The AppKit
    /// controller this replaces watched for Escape globally; keep that, since
    /// palette dismissal is a documented UX invariant.
    private var escapeMonitor: Any?

    var isVisible: Bool {
        presentation != nil
    }

    func present<Content: View>(
        preferredHeight: CGFloat = 352,
        onEscape: (() -> Void)? = nil,
        onClose: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        // Any in-flight dismissal is abandoned rather than allowed to land on
        // the presentation replacing it.
        dismissCoordinator.isDismissing = false
        let rootView = content()
            .environment(\.workspaceCommandOverlayDismissCoordinator, dismissCoordinator)
        paletteDebugLog("host.present height=\(preferredHeight)")
        installEscapeMonitorIfNeeded()
        presentation = Presentation(
            preferredHeight: preferredHeight,
            content: AnyView(rootView),
            onEscape: onEscape,
            onClose: onClose
        )
    }

    func close() {
        removeEscapeMonitor()
        guard let presentation else { return }
        dismissCoordinator.isDismissing = true
        self.presentation = nil
        presentation.onClose()
    }

    /// Kept distinct from `close()` because callers use it to tear the palette
    /// down before immediately presenting another one, where an animated
    /// dismissal would visibly cross-fade the two.
    func closeImmediately() {
        removeEscapeMonitor()
        guard let presentation else {
            dismissCoordinator.isDismissing = false
            return
        }
        dismissCoordinator.isDismissing = false
        self.presentation = nil
        presentation.onClose()
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.presentation != nil, event.keyCode == 53 else { return event }
            // A modal session owns Escape. This monitor stays installed while
            // an NSAlert runs its own event loop, and swallowing the key there
            // would leave the dialog uncancellable.
            guard NSApp.modalWindow == nil else { return event }
            Task { @MainActor in self.handleEscape() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    func handleEscape() {
        guard let presentation else { return }
        if let onEscape = presentation.onEscape {
            onEscape()
        } else {
            close()
        }
    }
}

/// The palette surface itself: a click-catching backdrop with the palette
/// centred on top, sized the way the old AppKit layout sized it.
struct WorkspacePaletteOverlay: View {
    @ObservedObject var host: WorkspacePaletteHost

    var body: some View {
        if let presentation = host.presentation {
            GeometryReader { proxy in
                // Sizing comes from the same geometry the AppKit overlay used,
                // which WorkspaceChromeLayoutTests covers.
                let target = WorkspaceCommandOverlayLayout.targetFrame(
                    in: NSRect(origin: .zero, size: proxy.size),
                    preferredHeight: presentation.preferredHeight
                )
                let width = target?.width ?? WorkspaceCommandOverlayLayout.preferredWidth
                let height = target?.height ?? presentation.preferredHeight

                ZStack {
                    // Click-outside dismissal, which the AppKit event monitor
                    // used to provide.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { host.close() }

                    // The palette hugs its rows up to the preferred height and
                    // keeps its top edge where the full-height frame would sit,
                    // so a short list does not float down the window.
                    VStack(spacing: 0) {
                        presentation.content
                            .frame(width: width)
                            .frame(maxHeight: height)
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, height: height, alignment: .top)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .transition(.opacity)
            .onExitCommand { host.handleEscape() }
        }
    }
}
