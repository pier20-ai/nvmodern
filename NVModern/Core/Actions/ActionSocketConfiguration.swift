import Foundation

struct ActionSocketConfiguration: Hashable, Sendable {
    let isEnabled: Bool
    let socketURL: URL

    static func defaultSocketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("nvModern", isDirectory: true)
            .appendingPathComponent("action.sock", isDirectory: false)
    }

    static func make(
        enabled: Bool?,
        path: String?,
        home: URL,
        resolvePath: (String) -> URL
    ) -> ActionSocketConfiguration? {
        guard enabled ?? true else { return nil }

        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = (trimmed?.isEmpty == false) ? trimmed! : defaultSocketURL(home: home).path
        return ActionSocketConfiguration(isEnabled: true, socketURL: resolvePath(spec))
    }
}
