import XCTest
@testable import nvModern

final class DocumentWordCounterTests: XCTestCase {
    func testCountsWordsAcrossMarkdownAndPunctuation() {
        let body = """
        # Hello, world!

        This is nvModern.
        """

        XCTAssertEqual(DocumentWordCounter.count(in: body), 5)
    }

    func testCountsContractionsAsSingleWords() {
        XCTAssertEqual(DocumentWordCounter.count(in: "It's live, and it doesn't lag."), 6)
    }

    func testEmptyDocumentHasNoWords() {
        XCTAssertEqual(DocumentWordCounter.count(in: " \n\t"), 0)
    }
}
