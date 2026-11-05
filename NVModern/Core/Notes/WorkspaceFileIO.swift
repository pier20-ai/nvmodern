import Foundation

actor WorkspaceFileIO {
    static let shared = WorkspaceFileIO()

    func readText(from url: URL) throws -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }

        return String(data: data, encoding: .ascii)
    }

    func readData(from url: URL) throws -> Data? {
        try Data(contentsOf: url)
    }

    func writeText(_ body: String, to url: URL) throws {
        try body.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}
