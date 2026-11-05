import Combine

/// Sidebar visibility for one workspace window.
///
/// This is a reference type on purpose. The action runtime holds a closure that
/// reads the window's sidebar state on demand, and a closure over a `@State`
/// property captures a copy of the enclosing view struct — every later read
/// returns the value from whenever the runtime was registered, not the live
/// one. That stale read is what froze the View menu's sidebar item. Reading
/// through an observable object keeps the runtime, the menu, and the view on
/// the same value.
@MainActor
final class WorkspaceSidebarState: ObservableObject {
    @Published private(set) var isVisible: Bool

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }

    func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else { return }
        self.isVisible = isVisible
    }
}
