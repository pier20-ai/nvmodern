import Combine
import XCTest
@testable import nvModern

final class EditorThemePreviewTests: XCTestCase {
    @MainActor
    func testUserCSSPreviewsResolveCascadeVariablesColorsAndBodyFont() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("custom.css")
        try """
        :root {
            --ink: rgb(20, 40, 60);
            --nv3-color-text: var(--ink);
            --nv3-color-bg: hsl(0, 0%, 100%);
            --nv3-color-accent: color-mix(in srgb, red 50%, blue);
            --body: "Georgia", serif;
            --nv3-font-sans: var(--body);
        }
        [data-theme="dark"] { --nv3-color-bg: #000; }
        """.write(to: file, atomically: true, encoding: .utf8)
        let theme = AvailableEditorTheme(id: "custom", title: "Custom", subtitle: nil,
                                        swatchHexes: [], isBundled: false, fileURL: file)
        let store = EditorThemePreviewStore()
        for dark in [false, true] {
            let resolved = expectation(description: "CSS resolved")
            let subscription = store.$previews.dropFirst().sink { _ in resolved.fulfill() }
            store.load(themes: [theme], dark: dark)
            await fulfillment(of: [resolved], timeout: 10)
            subscription.cancel()
            let preview = try XCTUnwrap(store.previews["custom"])
            XCTAssertEqual(preview.font.familyName, "Georgia")
            let background = try XCTUnwrap(NSColor(preview.colors[0]).usingColorSpace(.sRGB))
            XCTAssertEqual(background.redComponent, dark ? 0 : 1, accuracy: 0.01)
            let ink = try XCTUnwrap(NSColor(preview.colors[1]).usingColorSpace(.sRGB))
            XCTAssertEqual(ink.greenComponent, 40.0 / 255, accuracy: 0.01)
            let accent = try XCTUnwrap(NSColor(preview.colors[2]).usingColorSpace(.sRGB))
            XCTAssertEqual(accent.redComponent, 0.5, accuracy: 0.01)
            XCTAssertEqual(accent.blueComponent, 0.5, accuracy: 0.01)
        }
    }
}
