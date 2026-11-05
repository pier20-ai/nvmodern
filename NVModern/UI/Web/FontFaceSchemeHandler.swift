import Foundation
import WebKit

/// Serves the font files `UserFontFaceCatalog` registered for `@font-face`
/// rules (`nvmodern-font://face/<token>`). Unknown tokens are refused, so the
/// scheme can only ever return fonts a stylesheet named.
final class FontFaceSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == UserFontFaceCatalog.scheme,
              url.host == UserFontFaceCatalog.host else {
            fail(urlSchemeTask, code: 400, message: "Unsupported font URL")
            return
        }

        let method = (urlSchemeTask.request.httpMethod ?? "GET").uppercased()
        if method == "OPTIONS" {
            respond(urlSchemeTask, url: url, statusCode: 204, data: nil)
            return
        }

        guard let fileURL = UserFontFaceCatalog.fileURL(forToken: url.lastPathComponent) else {
            fail(urlSchemeTask, code: 404, message: "Unknown font")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            respond(urlSchemeTask, url: url, statusCode: 200, data: method == "HEAD" ? nil : data)
        } catch {
            fail(urlSchemeTask, code: 500, message: "Failed to read font: \(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, statusCode: Int, data: Data?) {
        // The editor page loads from file://, so font fetches are cross-origin
        // and CORS-checked.
        let origin = task.request.value(forHTTPHeaderField: "Origin")
        var headers = [
            "Access-Control-Allow-Origin": origin == "null" ? "null" : (origin ?? "*"),
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Vary": "Origin",
            "Cache-Control": "max-age=86400",
        ]
        headers["Content-Type"] = mimeType(forExtension: url.pathExtension.lowercased())

        if let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
        }
        if let data {
            task.didReceive(data)
        }
        task.didFinish()
    }

    private func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "ttc", "otc": return "font/collection"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private func fail(_ task: any WKURLSchemeTask, code: Int, message: String) {
        task.didFailWithError(NSError(
            domain: "NVModern.FontFaceScheme",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
