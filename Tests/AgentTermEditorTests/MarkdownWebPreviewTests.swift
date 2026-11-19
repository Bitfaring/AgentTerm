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
        // Its cells, which MarkdownUI's own HTML leaves out.
        XCTAssertTrue(page.contains("<th>A</th>") && page.contains("<th>B</th>"), "the table's heading cells")
        XCTAssertTrue(page.contains("<td>1</td>") && page.contains("<td>2</td>"), "the table's cells")
        XCTAssertTrue(page.contains("<a href=\"other.md\">a link</a>"), "the link")
        XCTAssertTrue(page.contains("class=\"language-swift\""), "the code block, to be coloured")
        // Its words may show as text; never as a script.
        XCTAssertFalse(page.contains("<script>alert"), "a script of the file is in the page")
        XCTAssertTrue(page.contains("script-src 'nonce-N0NCE'"), "only the page's own scripts may run")
        XCTAssertFalse(page.contains("<script>"), "a script without the nonce")
        XCTAssertTrue(page.contains("<base href=\"file:///tmp/docs/\">"), "pictures and links next to the document")
    }

    func testWhatGitHubAddsToMarkdownIsInThePage() {
        let page = MarkdownPreview.page(for: "~~gone~~\n\n- [x] done\n- [ ] to do\n\nSee https://example.com now.\n", baseURL: nil, nonce: "n")
        XCTAssertTrue(page.contains("<del>gone</del>"), "struck-through text")
        XCTAssertTrue(page.contains("type=\"checkbox\" checked=\"\" disabled=\"\""), "a task that is done")
        XCTAssertTrue(page.contains("<a href=\"https://example.com\">"), "a link found in the text")
    }

    /// FILE-13 (#126): the pages written for the preview are in a folder of
    /// the build's and the process's own; what an ended app of the same
    /// build left is taken away, and nothing of another build or of a
    /// running app is touched.
    func testThePagesAreInAFolderOfTheBuildsAndTheProcesssOwn() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("preview-pages-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        // A process that has ended: one started and waited for.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let running = ProcessInfo.processInfo.processIdentifier
        for name in ["com.example.app-preview-\(ended.processIdentifier)", "com.example.app.dev-preview-\(ended.processIdentifier)", "com.example.app-preview-1"] {
            try manager.createDirectory(at: temporary.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let folder = PreviewPages.folder(in: temporary, identifier: "com.example.app", pid: running)
        XCTAssertEqual(folder.lastPathComponent, "com.example.app-preview-\(running)")
        let left = Set(try manager.contentsOfDirectory(atPath: temporary.path))
        XCTAssertEqual(
            left, ["com.example.app-preview-\(running)", "com.example.app.dev-preview-\(ended.processIdentifier)", "com.example.app-preview-1"],
            "only the ended app's folder of the same build is taken away; launchd's, running, and another build's are kept")
    }

    func testMermaidIsInThePageOnlyForADiagram() {
        let plain = MarkdownPreview.page(for: "Some text.", baseURL: nil, nonce: "n")
        let diagram = MarkdownPreview.page(for: "```mermaid\ngraph TD; A-->B\n```", baseURL: nil, nonce: "n")
        XCTAssertLessThan(plain.count, 500_000, "Mermaid's 2.5 MB in a page without a diagram")
        XCTAssertGreaterThan(diagram.count, 1_000_000, "no Mermaid for a diagram")
        XCTAssertTrue(diagram.contains("language-mermaid"))
    }
}
