import AppKit
import SwiftUI
import XCTest
@testable import nvModern

final class WorkspaceChromeLayoutTests: XCTestCase {
    func testSidebarInsetConsumesOnlyTheUncoveredTabBarHeight() {
        XCTAssertEqual(
            DesignTokens.WorkspaceChrome.sidebarToolbarTopInset(titlebarHeight: 30),
            10
        )
    }

    func testSidebarInsetWaitsForAValidTitlebarMeasurement() {
        XCTAssertEqual(
            DesignTokens.WorkspaceChrome.sidebarToolbarTopInset(titlebarHeight: 0),
            0
        )
    }

    func testSidebarInsetNeverPullsToolbarIntoATallerTitlebar() {
        XCTAssertEqual(
            DesignTokens.WorkspaceChrome.sidebarToolbarTopInset(titlebarHeight: 44),
            0
        )
    }

    func testCommandOverlayRejectsUnlaidOutContainerBounds() {
        XCTAssertNil(
            WorkspaceCommandOverlayLayout.targetFrame(
                in: .zero,
                preferredHeight: 352
            )
        )
        XCTAssertNil(
            WorkspaceCommandOverlayLayout.targetFrame(
                in: NSRect(x: 0, y: 0, width: 48, height: 600),
                preferredHeight: 352
            )
        )
    }

    func testCommandOverlayUsesPreferredSizeAndCentersInContainer() throws {
        let frame = try XCTUnwrap(
            WorkspaceCommandOverlayLayout.targetFrame(
                in: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                preferredHeight: 352
            )
        )

        XCTAssertEqual(frame, NSRect(x: 180, y: 224, width: 640, height: 352))
    }

    func testCommandOverlayMaintainsEdgeInsetsInSmallContainer() throws {
        let frame = try XCTUnwrap(
            WorkspaceCommandOverlayLayout.targetFrame(
                in: NSRect(x: 0, y: 0, width: 500, height: 300),
                preferredHeight: 352
            )
        )

        XCTAssertEqual(frame, NSRect(x: 24, y: 24, width: 452, height: 252))
    }

    func testTabBarPaintLeavesNeutralPageColoursToAppKit() {
        XCTAssertNil(TabBarPaint(documentColor: srgb(0xffffff), isDarkAppearance: false))
        XCTAssertNil(TabBarPaint(documentColor: srgb(0x191919), isDarkAppearance: true))
        XCTAssertNil(TabBarPaint(documentColor: nil, isDarkAppearance: false))
    }

    func testTabBarPaintSkipsPagesThatDisagreeWithTheAppearance() {
        XCTAssertNil(TabBarPaint(documentColor: srgb(0x282a36), isDarkAppearance: false))
        XCTAssertNil(TabBarPaint(documentColor: srgb(0xf4ecd8), isDarkAppearance: true))
    }

    func testTabBarPaintKeepsTheSelectedTabGlassyAndRaised() throws {
        let light = try XCTUnwrap(TabBarPaint(documentColor: srgb(0xf4ecd8), isDarkAppearance: false))
        XCTAssertEqual(light.selectedTabTint.alphaComponent, 0.3, accuracy: 0.001)
        XCTAssertLessThan(brightness(light.trackColor), brightness(srgb(0xf4ecd8)))

        let dark = try XCTUnwrap(TabBarPaint(documentColor: srgb(0x2e3440), isDarkAppearance: true))
        XCTAssertEqual(dark.selectedTabTint.alphaComponent, 0.3, accuracy: 0.001)
        XCTAssertGreaterThan(brightness(dark.selectedTabTint), brightness(dark.trackColor))
        XCTAssertGreaterThan(brightness(dark.trackColor), brightness(srgb(0x2e3440)))
    }

    private func srgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }

    private func brightness(_ color: NSColor) -> CGFloat {
        color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
    }
}
