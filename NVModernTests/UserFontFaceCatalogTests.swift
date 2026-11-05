import XCTest
import WebKit
@testable import nvModern

final class UserFontFaceCatalogTests: XCTestCase {
    func testReadsConcreteFamiliesFromFontTokensAndDeclarations() {
        let css = """
        :root {
          --nv3-font-sans: "Michelangelus", "Iowan Old Style", Palatino, Georgia, serif;
          --nv3-font-label: var(--nv3-font-sans);
          --nv3-font-mono: "Courier Prime", ui-monospace, monospace;
          --nv3-md-h3-font-family: 'Gill Sans', -apple-system, sans-serif;
          --nv3-md-h1-font-feature-settings: "dlig", "kern";
          --nv3-content-font-size: 1.125em;
        }
        .cm-editor { font-family: IBM Plex Mono, system-ui; }
        """

        XCTAssertEqual(
            UserFontFaceCatalog.referencedFamilies(in: css),
            ["Michelangelus", "Iowan Old Style", "Palatino", "Georgia", "Courier Prime", "Gill Sans", "IBM Plex Mono"]
        )
    }

    func testIgnoresCSSWithoutFontFamilies() {
        XCTAssertEqual(UserFontFaceCatalog.referencedFamilies(in: ":root { --nv3-color-bg: #fff; }"), [])
        XCTAssertEqual(UserFontFaceCatalog.appendingFontFaces(to: ":root { --nv3-color-bg: #fff; }"), ":root { --nv3-color-bg: #fff; }")
    }

    func testSystemFamiliesNeedNoFontFaces() {
        // Gill Sans ships in /System/Library/Fonts, which WebKit already sees.
        XCTAssertEqual(UserFontFaceCatalog.fontFaceCSS(forFamiliesIn: "a { font-family: \"Gill Sans\"; }"), "")
    }

    /// End to end: a family WebKit cannot see by name loads through the
    /// served @font-face rules. Skips on machines with no user-installed fonts.
    @MainActor
    func testUserInstalledFamilyLoadsInWebView() async throws {
        let family = try XCTUnwrap(
            NSFontManager.shared.availableFontFamilies.first { family in
                !UserFontFaceCatalog.fontFaceCSS(forFamiliesIn: "a { font-family: \"\(family)\"; }").isEmpty
            },
            "no user-installed font families on this machine"
        )
        let css = UserFontFaceCatalog.fontFaceCSS(forFamiliesIn: "a { font-family: \"\(family)\"; }")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmodern-font-face-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("index.html")
        try "<html><head><style>\(css)</style></head><body>probe</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FontFaceSchemeHandler(), forURLScheme: UserFontFaceCatalog.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), configuration: configuration)
        let loaded = expectation(description: "page loaded")
        let delegate = NavigationFinishedDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadFileURL(page, allowingReadAccessTo: directory)
        await fulfillment(of: [loaded], timeout: 10)

        let result = try await webView.callAsyncJavaScript(
            """
            await document.fonts.load('16px "' + family + '"');
            return [...document.fonts]
              .filter(face => face.family.replace(/"/g, '') === family)
              .map(face => face.status);
            """,
            arguments: ["family": family],
            contentWorld: .page
        )
        let statuses = try XCTUnwrap(result as? [String])
        XCTAssertTrue(statuses.contains("loaded"), "\(family): \(statuses)")
    }
}

private final class NavigationFinishedDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
