import XCTest
@testable import nvModern

final class MillerHorizontalScrollTests: XCTestCase {
    func testVisibleColumnPreservesCurrentOrigin() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 480,
            viewportWidth: 720,
            contentWidth: 1_445,
            targetMinX: 721,
            targetMaxX: 961
        )

        XCTAssertEqual(origin, 480)
    }

    func testColumnBeyondTrailingEdgeScrollsOnlyEnoughToRevealIt() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 0,
            viewportWidth: 720,
            contentWidth: 1_445,
            targetMinX: 721,
            targetMaxX: 961
        )

        XCTAssertEqual(origin, 241)
    }

    func testColumnBeforeLeadingEdgeScrollsOnlyEnoughToRevealIt() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 480,
            viewportWidth: 720,
            contentWidth: 1_445,
            targetMinX: 241,
            targetMaxX: 481
        )

        XCTAssertEqual(origin, 241)
    }

    func testOriginIsClampedToContentBounds() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 600,
            viewportWidth: 720,
            contentWidth: 1_200,
            targetMinX: 1_000,
            targetMaxX: 1_240
        )

        XCTAssertEqual(origin, 480)
    }

    func testPreviewRevealAlignsTheAccessoryTrailingEdge() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 241,
            viewportWidth: 1_000,
            contentWidth: 1_685,
            targetMinX: 965,
            targetMaxX: 1_685
        )

        XCTAssertEqual(origin, 685)
    }

    func testAlreadyVisiblePreviewPreservesManualOrigin() {
        let origin = MillerHorizontalScrollGeometry.revealedOrigin(
            currentOrigin: 685,
            viewportWidth: 1_000,
            contentWidth: 1_685,
            targetMinX: 965,
            targetMaxX: 1_685
        )

        XCTAssertEqual(origin, 685)
    }
}
