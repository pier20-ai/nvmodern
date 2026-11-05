import AppKit
import SwiftUI
import WebKit

/// Uses WebKit's CSS cascade so previews support the same variables and color
/// syntax as the editor, including user themes and appearance-specific rules.
@MainActor
final class EditorThemePreviewStore: NSObject, ObservableObject, WKNavigationDelegate {
    struct Preview {
        let colors: [Color]
        let font: NSFont
    }

    @Published private(set) var previews: [String: Preview] = [:]
    private var webView: WKWebView?
    private var pendingThemes: [AvailableEditorTheme] = []
    private var dark = false
    private var generation = 0

    func load(themes: [AvailableEditorTheme], dark: Bool) {
        generation += 1
        self.pendingThemes = themes
        self.dark = dark
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        self.webView = webView
        webView.navigationDelegate = self
        webView.loadHTMLString("""
        <!doctype html><html><head><style id="base"></style><style id="theme"></style></head>
        <body><div class="cm-editor"><div class="cm-scroller"><div class="cm-content">Body</div></div></div>
        <span id="color"></span></body></html>
        """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        let currentGeneration = generation
        let themes = pendingThemes.map { theme in
            ["id": theme.id, "css": theme.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""]
        }
        let baseCSS = Bundle.main.url(forResource: "main", withExtension: "css", subdirectory: "WebEditor")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        webView.callAsyncJavaScript(Self.script, arguments: ["themes": themes, "baseCSS": baseCSS, "dark": dark], in: nil, in: .page) { [weak self] result in
            guard let self, currentGeneration == self.generation,
                  case .success(let value) = result,
                  let rows = value as? [[String: Any]] else { return }
            var previews: [String: Preview] = [:]
            for row in rows {
                guard let id = row["id"] as? String, let colors = row["colors"] as? [[Double]],
                      let family = row["font"] as? String else { continue }
                previews[id] = Preview(
                    colors: colors.compactMap { rgba in
                        guard rgba.count == 4 else { return nil }
                        return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
                    },
                    font: Self.bodyFont(family)
                )
            }
            self.previews = previews
            self.webView = nil
        }
    }

    static func bodyFont(_ cssFamily: String) -> NSFont {
        for raw in cssFamily.split(separator: ",") {
            let family = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch family.lowercased() {
            case "ui-sans-serif", "system-ui", "-apple-system", "sans-serif":
                return .systemFont(ofSize: 13)
            case "ui-monospace", "monospace":
                return .monospacedSystemFont(ofSize: 13, weight: .regular)
            case "ui-serif", "serif":
                return NSFont(name: "Times-Roman", size: 13) ?? .systemFont(ofSize: 13)
            default:
                if let font = NSFont(name: family, size: 13)
                    ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                    return font
                }
            }
        }
        return .systemFont(ofSize: 13)
    }

    static let script = """
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    document.getElementById('base').textContent = baseCSS;
    const sheet = document.getElementById('theme');
    const probe = document.getElementById('color');
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 1;
    const ctx = canvas.getContext('2d', {willReadFrequently: true});
    const color = (token) => {
        probe.style.color = `var(${token})`;
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = getComputedStyle(probe).color;
        ctx.fillRect(0, 0, 1, 1);
        return Array.from(ctx.getImageData(0, 0, 1, 1).data, v => v / 255);
    };
    return themes.map(theme => {
        sheet.textContent = theme.css;
        return {
            id: theme.id,
            colors: ['--nv3-color-bg', '--nv3-color-text', '--nv3-color-accent'].map(color),
            font: getComputedStyle(document.querySelector('.cm-content')).fontFamily
        };
    });
    """
}
