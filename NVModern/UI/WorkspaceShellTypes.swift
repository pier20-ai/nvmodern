import Foundation

/// Opaque identifier for a workspace tab.
///
/// These used to come from the vendored Bonsplit package. The native-shell
/// experiment removed the package, but the identifier is threaded through the
/// persisted tab state, the action runtime, and the content controllers, so
/// the shape is kept as an in-tree type.
struct TabID: Hashable, Codable, Sendable {
    let id: UUID

    init() {
        self.id = UUID()
    }

    init(id: UUID) {
        self.id = id
    }
}

/// Opaque identifier for a content pane.
struct PaneID: Hashable, Codable, Sendable {
    let id: UUID

    init() {
        self.id = UUID()
    }

    init(id: UUID) {
        self.id = id
    }
}

/// Optional semantic tint applied to a tab's icon.
enum TabIconTint: String, Codable, Sendable {
    case orange
    case purple
}
