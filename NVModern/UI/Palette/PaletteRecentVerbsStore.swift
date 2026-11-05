import Foundation

/// The last few verbs the user ran from the palette, by method. Shown first in
/// an empty verbs menu. Three is deliberate: enough to make the common case
/// one keystroke, few enough that the menu below never shifts much.
@MainActor
final class PaletteRecentVerbsStore: ObservableObject {
    static let shared = PaletteRecentVerbsStore()

    @Published private(set) var methods: [String]

    private let defaults: UserDefaults
    private let storageKey: String
    private let limit: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "nvmodern.recentPaletteVerbs",
        limit: Int = 3
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.limit = limit
        methods = Array((defaults.stringArray(forKey: storageKey) ?? []).prefix(limit))
    }

    func record(_ method: String) {
        methods.removeAll { $0 == method }
        methods.insert(method, at: 0)
        methods = Array(methods.prefix(limit))
        defaults.set(methods, forKey: storageKey)
    }
}
