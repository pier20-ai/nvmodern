import AppKit
import Foundation
import SwiftUI
import WebKit

/// Marker subclass. `MillerKeyboardMonitor` lets the browser keep arrow keys
/// while this view is first responder, unlike every other `WKWebView` in the
/// app, which owns its keys.
final class MillerPreviewWebView: WKWebView {}

struct MillerMarkdownPreview: NSViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MillerPreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = MillerPreviewWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setAccessibilityLabel("Markdown preview")
        context.coordinator.attach(to: webView)
        context.coordinator.load(fileURL)
        return webView
    }

    func updateNSView(_ webView: MillerPreviewWebView, context: Context) {
        context.coordinator.attach(to: webView)
        context.coordinator.load(fileURL)
    }

    static func dismantleNSView(_ webView: MillerPreviewWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var requestedURL: URL?
        private var requestID = UUID()

        func attach(to webView: WKWebView) {
            self.webView = webView
        }

        func load(_ fileURL: URL) {
            guard requestedURL != fileURL else { return }

            requestedURL = fileURL
            let currentRequestID = UUID()
            requestID = currentRequestID
            let startedAt = ProcessInfo.processInfo.systemUptime

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Result<(html: String, sourceByteCount: Int), Error>
                do {
                    let source = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    let sourceText = String(decoding: source, as: UTF8.self)
                    let markdown = fileURL.pathExtension.lowercased() == "org"
                        ? MillerOrgPreviewConverter.markdown(from: sourceText)
                        : sourceText
                    let html = try MillerMarkdownHTMLRenderer.render(
                        markdown: markdown,
                        title: fileURL.lastPathComponent,
                        baseURL: fileURL.deletingLastPathComponent()
                    )
                    result = .success((html, source.count))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async {
                    guard let self,
                          self.requestID == currentRequestID,
                          self.requestedURL == fileURL,
                          let webView = self.webView else { return }

                    switch result {
                    case .success(let rendered):
                        webView.loadHTMLString(
                            rendered.html,
                            baseURL: fileURL.deletingLastPathComponent()
                        )
                        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                        let formattedElapsedMS = String(format: "%.2f", elapsedMS)
                        millerDebugLog(
                            "MarkdownPreview",
                            "rendered path=\(fileURL.path) sourceBytes=\(rendered.sourceByteCount) htmlBytes=\(rendered.html.utf8.count) elapsedMS=\(formattedElapsedMS)"
                        )
                    case .failure(let error):
                        webView.loadHTMLString(
                            MillerMarkdownHTMLRenderer.errorDocument(
                                title: fileURL.lastPathComponent,
                                message: error.localizedDescription
                            ),
                            baseURL: nil
                        )
                        millerDebugLog(
                            "MarkdownPreview",
                            "failed path=\(fileURL.path) error=\(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        func cancel() {
            requestID = UUID()
            requestedURL = nil
            webView = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.fragment != nil,
               url.deletingFragment == webView.url?.deletingFragment {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

enum MillerOrgPreviewConverter {
    static func markdown(from org: String) -> String {
        var output: [String] = []
        var skipsPropertyDrawer = false
        var isQuoteBlock = false
        var isSourceBlock = false

        for line in org.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare(":PROPERTIES:") == .orderedSame {
                skipsPropertyDrawer = true
                continue
            }
            if skipsPropertyDrawer {
                if trimmed.caseInsensitiveCompare(":END:") == .orderedSame {
                    skipsPropertyDrawer = false
                }
                continue
            }

            if let match = capture(line, pattern: #"^#\+TITLE:\s*(.*)$"#, options: [.caseInsensitive]) {
                output.append("# \(match[0])")
                continue
            }
            if let match = capture(line, pattern: #"^#\+BEGIN_SRC\s*([^\s]*)"#, options: [.caseInsensitive]) {
                output.append("```\(match[0])")
                isSourceBlock = true
                continue
            }
            if line.range(of: #"^#\+END_SRC\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                output.append("```")
                isSourceBlock = false
                continue
            }
            if isSourceBlock {
                output.append(line)
                continue
            }
            if line.range(of: #"^#\+BEGIN_QUOTE\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                isQuoteBlock = true
                continue
            }
            if line.range(of: #"^#\+END_QUOTE\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                isQuoteBlock = false
                continue
            }
            if trimmed.uppercased().hasPrefix("#+") {
                continue
            }
            if let heading = capture(line, pattern: #"^(\*{1,6})\s+(?:(TODO|DOING|DONE|POSTPONED|DROPPED)\s+)?(.*)$"#) {
                let level = heading[0].count
                let state = heading[1].isEmpty ? "" : "**\(heading[1])** "
                output.append("\(String(repeating: "#", count: level)) \(state)\(inlineMarkdown(heading[2]))")
                continue
            }

            let isTableRule = line.range(
                of: #"^\s*\|[-+|: ]+\|\s*$"#,
                options: .regularExpression
            ) != nil
            let normalizedLine = isTableRule
                ? line.replacingOccurrences(of: "+", with: "|")
                : line
            let renderedLine = inlineMarkdown(normalizedLine)
            output.append(isQuoteBlock ? "> \(renderedLine)" : renderedLine)
        }

        return output.joined(separator: "\n")
    }

    private static func inlineMarkdown(_ source: String) -> String {
        source
            .replacingOccurrences(
                of: #"\[\[([^\]]+)\]\[([^\]]+)\]\]"#,
                with: "[$2]($1)",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[\[([^\]]+)\]\]"#,
                with: "<$1>",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\w)/([^/\n]+)/(?=\W|$)"#, with: "*$1*", options: .regularExpression)
            .replacingOccurrences(of: #"[=~]([^=~\n]+)[=~]"#, with: "`$1`", options: .regularExpression)
    }

    private static func capture(
        _ source: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = expression.firstMatch(in: source, range: range), match.range.location != NSNotFound else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: source) else { return "" }
            return String(source[range])
        }
    }
}

enum MillerMarkdownHTMLRenderer {
    static func render(markdown: String, title: String, baseURL: URL?) throws -> String {
        let attributed = try AttributedString(
            markdown: markdown,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            ),
            baseURL: baseURL
        )
        let body = blockTree(from: attributed).children.map(renderNode).joined()
        return document(title: title, body: body)
    }

    static func errorDocument(title: String, message: String) -> String {
        document(
            title: title,
            body: "<div class=\"preview-error\"><strong>Preview unavailable</strong><p>\(escapeText(message))</p></div>"
        )
    }

    private static func blockTree(from attributed: AttributedString) -> BlockNode {
        let root = BlockNode(identity: 0, kind: nil)
        var nodesByIdentity: [Int: BlockNode] = [:]
        var fallbackIdentity = -1

        for run in attributed.runs {
            let fragment = InlineFragment(
                text: String(attributed[run.range].characters),
                intent: run.inlinePresentationIntent ?? [],
                link: run.link,
                imageURL: run.imageURL,
                alternateDescription: run.alternateDescription
            )

            guard let presentation = run.presentationIntent else {
                let node = BlockNode(identity: fallbackIdentity, kind: .paragraph)
                fallbackIdentity -= 1
                node.fragments.append(fragment)
                root.children.append(node)
                continue
            }

            var parent = root
            for component in presentation.components.reversed() {
                let node: BlockNode
                if let existing = nodesByIdentity[component.identity] {
                    node = existing
                } else {
                    node = BlockNode(identity: component.identity, kind: component.kind)
                    nodesByIdentity[component.identity] = node
                    parent.children.append(node)
                }
                parent = node
            }
            parent.fragments.append(fragment)
        }

        return root
    }

    private static func renderNode(_ node: BlockNode) -> String {
        guard let kind = node.kind else {
            return renderInline(node.fragments) + node.children.map(renderNode).joined()
        }

        switch kind {
        case .paragraph:
            return "<p>\(renderInline(node.fragments))\(node.children.map(renderNode).joined())</p>"
        case .header(let level):
            let safeLevel = min(max(level, 1), 6)
            return "<h\(safeLevel)>\(renderInline(node.fragments))</h\(safeLevel)>"
        case .orderedList:
            return "<ol>\(node.children.map(renderNode).joined())</ol>"
        case .unorderedList:
            return "<ul>\(node.children.map(renderNode).joined())</ul>"
        case .listItem(let ordinal):
            return "<li value=\"\(ordinal)\">\(renderInline(node.fragments))\(node.children.map(renderNode).joined())</li>"
        case .codeBlock(let languageHint):
            let languageClass = languageHint.map {
                " class=\"language-\(escapeAttribute($0))\""
            } ?? ""
            return "<pre><code\(languageClass)>\(escapeText(plainText(node.fragments)))</code></pre>"
        case .blockQuote:
            return "<blockquote>\(node.children.map(renderNode).joined())</blockquote>"
        case .thematicBreak:
            return "<hr>"
        case .table(let columns):
            return renderTable(node, columns: columns)
        case .tableHeaderRow:
            return renderTableRow(node, header: true, columns: [])
        case .tableRow:
            return renderTableRow(node, header: false, columns: [])
        case .tableCell:
            return "<td>\(renderInline(node.fragments))\(node.children.map(renderNode).joined())</td>"
        @unknown default:
            return renderInline(node.fragments) + node.children.map(renderNode).joined()
        }
    }

    private static func renderTable(
        _ node: BlockNode,
        columns: [PresentationIntent.TableColumn]
    ) -> String {
        let headerRows = node.children.compactMap { child -> String? in
            guard case .tableHeaderRow? = child.kind else { return nil }
            return renderTableRow(child, header: true, columns: columns)
        }.joined()
        let bodyRows = node.children.compactMap { child -> String? in
            guard case .tableRow? = child.kind else { return nil }
            return renderTableRow(child, header: false, columns: columns)
        }.joined()
        let header = headerRows.isEmpty ? "" : "<thead>\(headerRows)</thead>"
        let body = bodyRows.isEmpty ? "" : "<tbody>\(bodyRows)</tbody>"
        return "<div class=\"table-scroll\"><table>\(header)\(body)</table></div>"
    }

    private static func renderTableRow(
        _ node: BlockNode,
        header: Bool,
        columns: [PresentationIntent.TableColumn]
    ) -> String {
        let tag = header ? "th" : "td"
        let cells = node.children.map { cell -> String in
            let columnIndex: Int
            if case .tableCell(let index)? = cell.kind {
                columnIndex = index
            } else {
                columnIndex = 0
            }
            let alignment: String
            if columns.indices.contains(columnIndex) {
                switch columns[columnIndex].alignment {
                case .left: alignment = "left"
                case .center: alignment = "center"
                case .right: alignment = "right"
                @unknown default: alignment = "left"
                }
            } else {
                alignment = "left"
            }
            return "<\(tag) style=\"text-align: \(alignment)\">\(renderInline(cell.fragments))\(cell.children.map(renderNode).joined())</\(tag)>"
        }.joined()
        return "<tr>\(cells)</tr>"
    }

    private static func renderInline(_ fragments: [InlineFragment]) -> String {
        fragments.map { fragment in
            var html: String
            if let imageURL = fragment.imageURL {
                let alternateDescription = fragment.alternateDescription ?? fragment.text
                html = "<img src=\"\(escapeAttribute(imageURL.absoluteURL.absoluteString))\" alt=\"\(escapeAttribute(alternateDescription))\" loading=\"lazy\">"
            } else {
                html = escapeText(fragment.text).replacingOccurrences(of: "\n", with: "<br>")
            }

            if fragment.intent.contains(.code), fragment.imageURL == nil {
                html = "<code>\(html)</code>"
            }
            if fragment.intent.contains(.stronglyEmphasized) {
                html = "<strong>\(html)</strong>"
            }
            if fragment.intent.contains(.emphasized) {
                html = "<em>\(html)</em>"
            }
            if fragment.intent.contains(.strikethrough) {
                html = "<del>\(html)</del>"
            }
            if let link = fragment.link {
                html = "<a href=\"\(escapeAttribute(link.absoluteURL.absoluteString))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    private static func plainText(_ fragments: [InlineFragment]) -> String {
        fragments.map(\.text).joined()
    }

    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: https: http:; style-src 'unsafe-inline'">
        <title>\(escapeText(title))</title>
        <style>
        :root { color-scheme: light dark; --text: rgba(23, 23, 25, .92); --muted: rgba(60, 60, 67, .68); --line: rgba(60, 60, 67, .20); --soft: rgba(118, 118, 128, .11); --quote: rgba(0, 122, 255, .72); }
        @media (prefers-color-scheme: dark) { :root { --text: rgba(246, 246, 248, .92); --muted: rgba(235, 235, 245, .64); --line: rgba(235, 235, 245, .18); --soft: rgba(118, 118, 128, .19); --quote: rgba(64, 156, 255, .82); } }
        * { box-sizing: border-box; }
        html, body { width: 100%; max-width: 100%; overflow-x: hidden; }
        html { min-height: 100%; background: transparent; }
        body { min-height: 100%; margin: 0 auto; padding: 28px 32px 64px; color: var(--text); background: transparent; font: 15px/1.58 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4, h5, h6 { margin: 1.45em 0 .5em; line-height: 1.22; letter-spacing: -.015em; }
        h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
        h1 { font-size: 2em; } h2 { font-size: 1.55em; } h3 { font-size: 1.25em; } h4 { font-size: 1.08em; }
        p { margin: 0 0 1em; }
        a { color: -webkit-link; text-decoration-thickness: .08em; text-underline-offset: .14em; }
        strong { font-weight: 650; }
        code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        code { padding: .12em .34em; border-radius: 5px; background: var(--soft); font-size: .9em; }
        pre { margin: 1.15em 0; padding: 14px 16px; overflow: auto; border: 1px solid var(--line); border-radius: 9px; background: var(--soft); font-size: 13px; line-height: 1.5; }
        pre code { padding: 0; background: transparent; font-size: inherit; }
        blockquote { margin: 1.1em 0; padding: .05em 0 .05em 1em; border-left: 3px solid var(--quote); color: var(--muted); }
        blockquote > :last-child { margin-bottom: 0; }
        ul, ol { margin: .6em 0 1em; padding-left: 1.65em; }
        li { margin: .24em 0; }
        li > p { margin: 0; }
        li > ul, li > ol { margin: .2em 0 .35em; }
        hr { height: 1px; margin: 1.6em 0; border: 0; background: var(--line); }
        img { display: block; max-width: 100%; height: auto; margin: 1em auto; border-radius: 7px; }
        .table-scroll { max-width: 100%; margin: 1.1em 0; overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; font-size: .94em; }
        th, td { padding: 8px 10px; border: 1px solid var(--line); vertical-align: top; }
        th { background: var(--soft); font-weight: 650; }
        .preview-error { margin-top: 12px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 9px; background: var(--soft); }
        .preview-error p { margin: .35em 0 0; color: var(--muted); }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private final class BlockNode {
        let identity: Int
        let kind: PresentationIntent.Kind?
        var fragments: [InlineFragment] = []
        var children: [BlockNode] = []

        init(identity: Int, kind: PresentationIntent.Kind?) {
            self.identity = identity
            self.kind = kind
        }
    }

    private struct InlineFragment {
        let text: String
        let intent: InlinePresentationIntent
        let link: URL?
        let imageURL: URL?
        let alternateDescription: String?
    }
}

private extension URL {
    var deletingFragment: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.fragment = nil
        return components.url
    }
}
