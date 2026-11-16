import AgentTermProtocol
import XCTest

final class SentTextTests: XCTestCase {
    private let start = "\u{1b}[200~"
    private let end = "\u{1b}[201~"

    /// IOS-8: a long prompt goes as a paste to a program that asked for
    /// bracketed paste, so that the Return after it submits it. Codex 0.169
    /// kept a prompt of 437 characters typed as it was, its Return a new
    /// line in it, and one of 4,020 even with the Return 0.8 s later.
    func testALongPromptIsSentAsAPasteWhenTheProgramAsksForIt() {
        let long = String(repeating: "Write the tests first. ", count: 20)
        XCTAssertEqual(SentText.text(long, bracketedPaste: true), start + long + end)
        // A program that did not ask would show the brackets as text.
        XCTAssertEqual(SentText.text(long, bracketedPaste: false), long)
    }

    /// IOS-8: short text is typed as it is, as a question that takes keys
    /// (a permission's "1", a "y") has to have it.
    func testShortTextIsTypedAsItIs() {
        XCTAssertEqual(SentText.text("1", bracketedPaste: true), "1")
        XCTAssertEqual(SentText.text("yes", bracketedPaste: true), "yes")
        let longest = String(repeating: "a", count: SentText.typedLength)
        XCTAssertEqual(SentText.text(longest, bracketedPaste: true), longest)
        XCTAssertEqual(SentText.text(longest + "a", bracketedPaste: true), start + longest + "a" + end)
    }

    /// IOS-8: lines end with Return, as a terminal sends them, and go as
    /// one paste only to a program that asked for it.
    func testLinesEndWithReturnAndArePastedOnlyWhenAsked() {
        XCTAssertEqual(SentText.text("a\nb", bracketedPaste: true), start + "a\rb" + end)
        XCTAssertEqual(SentText.text("a\r\nb", bracketedPaste: true), start + "a\rb" + end)
        XCTAssertEqual(SentText.text("a\nb", bracketedPaste: false), "a\rb")
    }

    /// IOS-8: the end of a paste written in the text does not end the paste.
    func testTheEndOfAPasteInTheTextDoesNotEndIt() {
        let before = String(repeating: "x", count: 70)
        XCTAssertEqual(SentText.text(before + end + "rm -rf ~", bracketedPaste: true), start + before + "rm -rf ~" + end)
    }
}
