import XCTest
@testable import nvModern

final class DocumentFrontmatterAppearanceTests: XCTestCase {
    func testYAMLFrontmatterOverridesThemeWidthAndFontFamily() throws {
        let body = """
        ---
        theme: riso
        width: extra-wide
        font-family: Avenir Next, Georgia, serif
        ---
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        XCTAssertEqual(frontmatter.theme, DocumentThemeID(rawValue: "riso"))
        XCTAssertEqual(frontmatter.width, .extraWide)
        XCTAssertEqual(frontmatter.fontFamily, "Avenir Next, Georgia, serif")

        let fallback = DocumentInspectorSettings(width: .narrow, theme: DocumentThemeID(rawValue: "kunsthalle"), scale: .large)
        let appearance = frontmatter.applied(to: fallback)
        XCTAssertEqual(appearance.settings.theme, DocumentThemeID(rawValue: "riso"))
        XCTAssertEqual(appearance.settings.width, .extraWide)
        XCTAssertEqual(appearance.settings.scale, .large)
        XCTAssertTrue(appearance.css.contains("--nv3-font-sans: Avenir Next, Georgia, serif;"))
        XCTAssertTrue(appearance.css.contains("--nv3-font-display: Avenir Next, Georgia, serif;"))
    }

    func testFrontmatterFontFollowsDocumentThemeAndKeepsItsXHeight() throws {
        let settings = DocumentInspectorSettings(width: .comfortable, theme: DocumentThemeID(rawValue: "laurenziana"))
        let css = DocumentInspectorAppearance(settings: settings, fontFamily: "IBM Plex Mono").css

        let themeRange = try XCTUnwrap(css.range(of: "--nv3-theme-name: Laurenziana"))
        let fontRange = try XCTUnwrap(css.range(of: "--nv3-font-sans: IBM Plex Mono, system-ui, sans-serif;"))
        XCTAssertLessThan(themeRange.lowerBound, fontRange.lowerBound)
        XCTAssertTrue(css.contains("--nv3-content-font-size-adjust: var(--nv3-font-size-adjust);"))
    }

    func testTOMLFrontmatterAcceptsSameAppearanceFields() throws {
        let body = """
        +++
        theme = "gruvbox"
        width = "full_width"
        "font-family" = "Georgia, serif"
        +++
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        // Theme ids are an open set: any clean id is carried through, whether
        // bundled or a user theme file.
        XCTAssertEqual(frontmatter.theme, DocumentThemeID(rawValue: "gruvbox"))
        XCTAssertEqual(frontmatter.width, .full)
        XCTAssertEqual(frontmatter.fontFamily, "Georgia, serif")
    }

    func testPartialFrontmatterLeavesFallbackSettingsInPlace() throws {
        let body = """
        ---
        width: wide
        ---
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        let fallback = DocumentInspectorSettings(width: .comfortable, theme: DocumentThemeID(rawValue: "cyanotype"), scale: .small)
        let appearance = frontmatter.applied(to: fallback)

        XCTAssertEqual(appearance.settings.theme, DocumentThemeID(rawValue: "cyanotype"))
        XCTAssertEqual(appearance.settings.width, .wide)
        XCTAssertEqual(appearance.settings.scale, .small)
        XCTAssertNil(appearance.fontFamily)
    }

    func testInvalidValuesDoNotProduceOverrides() {
        let body = """
        ---
        theme: ../secrets
        width: enormous
        font-family: "Georgia"; body { color: red }
        ---
        # Document
        """

        XCTAssertNil(DocumentFrontmatterAppearance.parse(from: body))
    }

    func testUnknownButCleanThemeIDIsAccepted() throws {
        let body = """
        ---
        theme: my-custom-theme
        ---
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        // A theme id that resolves to no file applies no palette; the id is
        // still accepted so frontmatter survives a missing user theme.
        XCTAssertEqual(frontmatter.theme, DocumentThemeID(rawValue: "my-custom-theme"))
    }

    func testSystemThemeKeywordIsNormalized() throws {
        let body = """
        ---
        theme: system
        ---
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        XCTAssertEqual(frontmatter.theme, .system)
    }

    func testFontFamilyAliasesAreAccepted() throws {
        let body = """
        ---
        font_family: ui-serif, Georgia, serif
        ---
        # Document
        """

        let frontmatter = try XCTUnwrap(DocumentFrontmatterAppearance.parse(from: body))
        XCTAssertEqual(frontmatter.fontFamily, "ui-serif, Georgia, serif")
    }

    func testLegacyInspectorScaleDecodesIntoNumericPercentage() throws {
        let data = Data(#"{"width":"comfortable","theme":"system","scale":"large"}"#.utf8)
        let settings = try JSONDecoder().decode(DocumentInspectorSettings.self, from: data)

        XCTAssertEqual(settings.scale.percentage, 110)
        XCTAssertFalse(settings.unwrapMarkdownLines)
    }

    func testInspectorScaleClampsAndProducesCSSPercentage() {
        let low = DocumentInspectorScale(percentage: 60)
        let high = DocumentInspectorScale(percentage: 140)
        let custom = DocumentInspectorSettings(
            width: .comfortable,
            theme: .system,
            scale: DocumentInspectorScale(percentage: 83)
        )

        XCTAssertEqual(low.percentage, 75)
        XCTAssertEqual(high.percentage, 125)
        XCTAssertTrue(custom.css.contains("--nv3-document-scale: 83%;"))
    }
}
