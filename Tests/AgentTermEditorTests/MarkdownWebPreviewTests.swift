import XCTest

@testable import AgentTermEditor

/// FILE-12 (#126): the Markdown preview is a web page made from the
/// document, in which nothing of the file runs.
final class MarkdownWebPreviewTests: XCTestCase {
    func testThePageHoldsTheDocumentAndNothingOfTheFileRuns() {
        let text = """
            # Title

            | A | B |
            |---|---|
            | 1 | 2 |

            [a link](other.md) and <script>alert('from the file')</script>

            ```swift
            let x = 1
            ```
            """
        let page = MarkdownPreview.page(for: text, baseURL: URL(fileURLWithPath: "/tmp/docs"), nonce: "N0NCE")
        XCTAssertTrue(page.contains("<h1>Title</h1>"), "the heading")
        XCTAssertTrue(page.contains("<table>"), "the table")
        XCTAssertTrue(page.contains("<a href=\"other.md\">a link</a>"), "the link")
        XCTAssertTrue(page.contains("class=\"language-swift\""), "the code block, to be coloured")
        // Its words may show as text; never as a script.
        XCTAssertFalse(page.contains("<script>alert"), "a script of the file is in the page")
        XCTAssertTrue(page.contains("script-src 'nonce-N0NCE'"), "only the page's own scripts may run")
        XCTAssertFalse(page.contains("<script>"), "a script without the nonce")
        XCTAssertTrue(page.contains("<base href=\"file:///tmp/docs/\">"), "pictures and links next to the document")
    }

    func testMermaidIsInThePageOnlyForADiagram() {
        let plain = MarkdownPreview.page(for: "Some text.", baseURL: nil, nonce: "n")
        let diagram = MarkdownPreview.page(for: "```mermaid\ngraph TD; A-->B\n```", baseURL: nil, nonce: "n")
        XCTAssertLessThan(plain.count, 500_000, "Mermaid's 2.5 MB in a page without a diagram")
        XCTAssertGreaterThan(diagram.count, 1_000_000, "no Mermaid for a diagram")
        XCTAssertTrue(diagram.contains("language-mermaid"))
    }
}
