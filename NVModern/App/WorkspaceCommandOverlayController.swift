import AppKit
import SwiftUI

/// Signals a palette dismissal to the presented surface so it can run its exit
/// animation before the host tears it down.
final class WorkspaceCommandOverlayDismissCoordinator: ObservableObject {
    @Published var isDismissing = false
}

private struct WorkspaceCommandOverlayDismissCoordinatorKey: EnvironmentKey {
    static let defaultValue: WorkspaceCommandOverlayDismissCoordinator? = nil
}

extension EnvironmentValues {
    var workspaceCommandOverlayDismissCoordinator: WorkspaceCommandOverlayDismissCoordinator? {
        get { self[WorkspaceCommandOverlayDismissCoordinatorKey.self] }
        set { self[WorkspaceCommandOverlayDismissCoordinatorKey.self] = newValue }
    }
}

/// Geometry for the centred palette surface. Kept separate from the view so it
/// stays unit-testable (`WorkspaceChromeLayoutTests`).
enum WorkspaceCommandOverlayLayout {
    static let preferredWidth: CGFloat = 640
    static let edgeInset: CGFloat = 24

    static func targetFrame(in bounds: NSRect, preferredHeight: CGFloat) -> NSRect? {
        let availableWidth = bounds.width - edgeInset * 2
        let availableHeight = bounds.height - edgeInset * 2
        guard availableWidth > 0,
              availableHeight > 0,
              preferredHeight > 0 else {
            return nil
        }

        let width = min(preferredWidth, availableWidth)
        let height = min(preferredHeight, availableHeight)
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}
