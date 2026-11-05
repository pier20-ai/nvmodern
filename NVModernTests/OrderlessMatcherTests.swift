import XCTest
@testable import nvModern

final class OrderlessMatcherTests: XCTestCase {
    func testComponentsMatchInAnyOrder() {
        XCTAssertTrue(OrderlessMatcher.matches("selected quote", candidate: "Quote Selected"))
    }

    func testAllComponentsMustMatch() {
        XCTAssertFalse(OrderlessMatcher.matches("quote missing", candidate: "Quote Selected"))
    }

    func testInitialismMatching() {
        XCTAssertTrue(OrderlessMatcher.matches("gtl", candidate: "Go to Line"))
    }

    func testFlexMatching() {
        XCTAssertTrue(OrderlessMatcher.matches("qtsl", candidate: "Quote Selected"))
    }

    func testConcatenatedWordPrefixes() {
        XCTAssertTrue(OrderlessMatcher.matches("fise", candidate: "File Search"))
    }

    func testRegularExpressionMatching() {
        XCTAssertTrue(OrderlessMatcher.matches("^quo.*ted$", candidate: "Quote Selected"))
    }

    func testComponentsCanMatchNameAndPath() {
        XCTAssertTrue(
            OrderlessMatcher.matches(
                "rep weekly",
                candidate: "Weekly Review 23-Market-Research/Reports/Weekly Review.md"
            )
        )
    }

    func testLiteralMatchRanksAheadOfFlexMatch() {
        let literal = OrderlessMatcher.score("quote", candidate: "Quote Selected")
        let flex = OrderlessMatcher.score("quote", candidate: "Quick Outline Utility Text Editor")
        XCTAssertNotNil(literal)
        XCTAssertNotNil(flex)
        XCTAssertLessThan(literal!, flex!)
    }

    func testCompiledPatternCanScoreMultipleCandidates() {
        let pattern = OrderlessMatcher.compile("quote sel")

        XCTAssertNotNil(pattern.score(candidate: "Quote Selected"))
        XCTAssertNil(pattern.score(candidate: "Unquote Lines"))
    }
}
