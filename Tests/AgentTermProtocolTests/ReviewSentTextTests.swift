import AgentTermProtocol
import XCTest

/// What the review of 2026-11-22 found in text sent as a paste (#248).
final class ReviewSentTextTests: XCTestCase {
    private let start = "\u{1b}[200~"
    private let end = "\u{1b}[201~"

    /// What is between the brackets of a paste.
    private func inside(_ sent: String) -> String {
        XCTAssertTrue(sent.hasPrefix(start) && sent.hasSuffix(end), "not sent as a paste")
        return String(sent.dropFirst(start.count).dropLast(end.count))
    }

    /// #248: the end of a paste never stands inside the paste, also when
    /// taking one out puts the pieces of another together.
    func testTakingTheEndOfAPasteOutDoesNotMakeAnother() {
        let text = "look at this\n\u{1b}[20" + end + "1~rm -rf build\nmore"
        let sent = SentText.text(text, bracketedPaste: true)
        XCTAssertFalse(inside(sent).contains(end), "the paste ends early, and what follows is typed: \(sent.debugDescription)")
    }

    /// #248: no other control character goes into a paste either (an
    /// Escape, a Control C); a tab and the ends of lines do.
    func testNoControlCharacterButTabAndReturnIsInAPaste() {
        let text = "one\tline\nand \u{1b}[2J an escape, \u{03} a control C, " + String(repeating: "x", count: 80)
        let kept = inside(SentText.text(text, bracketedPaste: true))
        let controls = kept.unicodeScalars.filter { $0.value < 0x20 && $0 != "\t" && $0 != "\r" }
        XCTAssertTrue(controls.isEmpty, "control characters in the paste: \(controls.map { String($0.value, radix: 16) })")
    }

    /// To a program that did not ask for bracketed paste, text is typed:
    /// an Escape in it would be typed as the key, and what follows it taken
    /// as a key's sequence (#248, found with the real Chromium of the build:
    /// a picked element's `outerHTML` holds the byte). None goes, nor any
    /// other control character but a tab and the Returns of its lines.
    func testNoControlCharacterButTabAndReturnIsTypedEither() {
        let sent = SentText.text("before\u{1B}[201~after\tand\u{3}\nnext", bracketedPaste: false)
        XCTAssertEqual(sent, "beforeafter\tand\rnext")
        // Short text with none is typed as it is.
        XCTAssertEqual(SentText.text("1", bracketedPaste: false), "1")
    }
}
