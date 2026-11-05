import XCTest
@testable import nvModern

final class MillerMarkdownHTMLRendererTests: XCTestCase {
    func testRendersCommonMarkdownBlocksAndInlineFormatting() throws {
        let markdown = """
        # Heading *one*

        Paragraph with **bold**, `code`, and [a link](https://example.com?a=1&b=2).

        > Quoted text.

        - First item
          - Nested item
        - Second item

        ```swift
        let result = 1 < 2
        ```

        | Left | Right |
        | :--- | ---: |
        | A | B |
        """

        let html = try MillerMarkdownHTMLRenderer.render(
            markdown: markdown,
            title: "Sample.md",
            baseURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertTrue(html.contains("<h1>Heading <em>one</em></h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("href=\"https://example.com?a=1&amp;b=2\""))
        XCTAssertTrue(html.contains("<blockquote><p>Quoted text.</p></blockquote>"))
        XCTAssertTrue(html.contains("<ul><li value=\"1\"><p>First item</p><ul>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let result = 1 &lt; 2\n</code></pre>"))
        XCTAssertTrue(html.contains("<thead><tr><th style=\"text-align: left\">Left</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align: right\">B</td>"))
    }

    func testEscapesSourceHTMLAndResolvesRelativeImages() throws {
        let baseURL = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let html = try MillerMarkdownHTMLRenderer.render(
            markdown: "Text <script>alert(1)</script> ![A & B](images/photo.png)",
            title: "Unsafe <title>.md",
            baseURL: baseURL
        )

        XCTAssertTrue(html.contains("<title>Unsafe &lt;title&gt;.md</title>"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("src=\"file:///tmp/notes/images/photo.png\""))
        XCTAssertTrue(html.contains("alt=\"A &amp; B\""))
    }

    func testConvertsOrgPreviewToMarkdownHTML() throws {
        let org = """
        #+TITLE: Project Notes
        * TODO First heading
        Paragraph with *bold*, /italic/, =code=, and [[https://example.com][a link]].

        #+BEGIN_SRC swift
        let value = 1 < 2
        #+END_SRC
        """

        let markdown = MillerOrgPreviewConverter.markdown(from: org)
        let html = try MillerMarkdownHTMLRenderer.render(
            markdown: markdown,
            title: "Sample.org",
            baseURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertTrue(html.contains("<h1>Project Notes</h1>"))
        XCTAssertTrue(html.contains("<h1><strong>TODO</strong> First heading</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let value = 1 &lt; 2"))
    }
}
