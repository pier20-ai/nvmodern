import Foundation
import UniformTypeIdentifiers
import WebKit

enum PreviewFilePathResolver {
    static func resolve(
        path rawPath: String,
        sourcePath rawSourcePath: String?,
        rootURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let path = normalize(rawPath)
        guard !path.isEmpty else { return nil }

        let candidate: URL
        if path == "~" || path.hasPrefix("~/") {
            let homeRelativePath = String(path.dropFirst()).drop(while: { $0 == "/" })
            candidate = homeRelativePath.isEmpty
                ? homeDirectoryURL
                : homeDirectoryURL.appendingPathComponent(String(homeRelativePath))
        } else if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            let baseDirectory: URL
            if let rawSourcePath {
                let sourcePath = normalize(rawSourcePath)
                if let sourceURL = documentURL(
                    for: sourcePath,
                    rootURL: rootURL,
                    homeDirectoryURL: homeDirectoryURL
                ) {
                    baseDirectory = sourceURL.deletingLastPathComponent()
                } else {
                    baseDirectory = rootURL
                }
            } else {
                baseDirectory = rootURL
            }
            candidate = baseDirectory.appendingPathComponent(path)
        }

        return candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func documentURL(
        for sourcePath: String,
        rootURL: URL,
        homeDirectoryURL: URL
    ) -> URL? {
        guard !sourcePath.isEmpty else { return nil }

        if sourcePath == "~" || sourcePath.hasPrefix("~/") {
            let homeRelativePath = String(sourcePath.dropFirst()).drop(while: { $0 == "/" })
            return homeRelativePath.isEmpty
                ? homeDirectoryURL
                : homeDirectoryURL.appendingPathComponent(String(homeRelativePath))
        }

        if sourcePath.hasPrefix("/") {
            return URL(fileURLWithPath: sourcePath)
        }

        return rootURL.appendingPathComponent(sourcePath)
    }

    private static func normalize(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
    }
}

final class PreviewFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nvmodern-file"

    private let fileManager: FileManager
    private let lock = NSLock()
    private var rootURL: URL

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
        super.init()
    }

    func updateRootURL(_ rootURL: URL) {
        lock.lock()
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(task: urlSchemeTask, code: 400, message: "Missing request URL")
            return
        }

        guard requestURL.scheme == Self.scheme,
              requestURL.host == "preview" else {
            fail(task: urlSchemeTask, code: 400, message: "Unsupported preview URL")
            return
        }

        let method = (urlSchemeTask.request.httpMethod ?? "GET").uppercased()
        if method == "OPTIONS" {
            sendResponse(task: urlSchemeTask, url: requestURL, statusCode: 204, mimeType: nil, data: nil)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            fail(task: urlSchemeTask, code: 405, message: "Method not allowed")
            return
        }

        guard let requestPath = requestPath(from: requestURL) else {
            fail(task: urlSchemeTask, code: 400, message: "Missing or invalid path parameter")
            return
        }

        guard let fileURL = PreviewFilePathResolver.resolve(
            path: requestPath.path,
            sourcePath: requestPath.sourcePath,
            rootURL: currentRootURL()
        ) else {
            fail(task: urlSchemeTask, code: 400, message: "Invalid preview path")
            return
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            fail(task: urlSchemeTask, code: 404, message: "File not found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let payload = method == "HEAD" ? nil : data
            sendResponse(task: urlSchemeTask, url: requestURL, statusCode: 200, mimeType: mimeType(for: fileURL), data: payload)
        } catch {
            fail(task: urlSchemeTask, code: 500, message: "Failed to load file: \(error)")
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func requestPath(from url: URL) -> (path: String, sourcePath: String?)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value
        else {
            return nil
        }

        let sourcePath = components.queryItems?.first(where: { $0.name == "sourcePath" })?.value
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (rawPath, sourcePath)
    }

    private func currentRootURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return rootURL
    }

    private func mimeType(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }

        switch ext {
        case "csv":
            return "text/csv"
        case "pdf":
            return "application/pdf"
        case "epub":
            return "application/epub+zip"
        case "md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline":
            return "text/plain"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        default:
            return "application/octet-stream"
        }
    }

    private func sendResponse(task: any WKURLSchemeTask, url: URL, statusCode: Int, mimeType: String?, data: Data?) {
        let origin = task.request.value(forHTTPHeaderField: "Origin")
        let allowedOrigin = origin == "null" ? "null" : (origin ?? "*")

        var headers: [String: String] = [
            "Access-Control-Allow-Origin": allowedOrigin,
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "*",
            "Access-Control-Allow-Credentials": "false",
            "Vary": "Origin",
            "Cache-Control": "no-store"
        ]

        if let mimeType {
            headers["Content-Type"] = mimeType
        }

        if let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) {
            task.didReceive(response)
        } else {
            let fallback = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data?.count ?? 0,
                textEncodingName: nil
            )
            task.didReceive(fallback)
        }
        if let data {
            task.didReceive(data)
        }
        task.didFinish()
    }

    private func fail(task: any WKURLSchemeTask, code: Int, message: String) {
        let error = NSError(
            domain: "NVModern.PreviewFileScheme",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        task.didFailWithError(error)
    }
}
