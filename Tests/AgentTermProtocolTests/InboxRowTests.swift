import AgentTermProtocol
import XCTest

/// INBOX-13 (#218): a row of the Inbox's list shows the end of what was
/// said, a few lines of it, with "…" in front when the beginning is left
/// out; all of it is in the item's detail.
final class InboxRowTests: XCTestCase {
    func testAShortAnswerIsShownWholeAndNotMarkedAsCut() {
        XCTAssertEqual(Inbox.rowTexts("All 12 tests pass."), ["All 12 tests pass."])
        XCTAssertEqual(Inbox.rowTexts(""), [])
        XCTAssertEqual(Inbox.rowTexts(" \n "), [])
    }

    func testALongAnswerIsItsEndBegunAtAWordWithTheMarkInFront() {
        let said = (1...200).map { "word\($0)" }.joined(separator: " ")
        let texts = Inbox.rowTexts(said)
        XCTAssertGreaterThan(texts.count, 1, "a narrow list has nothing shorter to take")
        for text in texts {
            XCTAssertTrue(text.hasPrefix(Inbox.cutMark), "what is cut is not marked: \(text)")
            let end = String(text.dropFirst(Inbox.cutMark.count))
            XCTAssertTrue(said.hasSuffix(end), "a row shows something else than the end")
            XCTAssertTrue(end.hasPrefix("word"), "a row begins inside a word: \(end)")
            XCTAssertLessThanOrEqual(end.count, Inbox.rowLength)
        }
        // The longest first: the app takes the first that fits.
        XCTAssertEqual(texts.map(\.count), texts.map(\.count).sorted(by: >))
        XCTAssertLessThanOrEqual(texts.last?.count ?? .max, 41)
    }

    /// An answer's paragraphs are not a line each: its line breaks are spaces.
    func testLineBreaksAreSpacesInARow() {
        XCTAssertEqual(Inbox.rowTexts("Done.\n\n- one\n- two\n"), ["Done. - one - two"])
    }

    /// One too long for the widest row and short enough for a narrower
    /// candidate is whole there, never cut twice.
    func testOneBetweenTwoLengthsIsCutOnceThenWhole() {
        let said = String(repeating: "abcd ", count: 50).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(said.count, 249)
        XCTAssertEqual(Inbox.rowTexts(said).first, said)
        XCTAssertTrue(Inbox.rowTexts(said).dropFirst().allSatisfy { $0.hasPrefix(Inbox.cutMark) })
    }

    /// Two lengths that come to the same text once begun at a word give it
    /// once: the Mac's row names each by its text, and one given twice
    /// crashed the app (#240).
    func testNoTextIsGivenTwice() {
        let said = String(repeating: "x", count: 200) + " " + String(repeating: "y", count: 70)
        let texts = Inbox.rowTexts(said)
        XCTAssertEqual(texts.count, Set(texts).count, "a text is given twice: \(texts)")
        XCTAssertTrue(texts.contains(Inbox.cutMark + String(repeating: "y", count: 70)))
    }

    /// One word longer than a row is cut inside it rather than not shown.
    func testAWordLongerThanARowIsCutInside() {
        let said = String(repeating: "x", count: 500)
        XCTAssertEqual(Inbox.rowTexts(said).first, Inbox.cutMark + String(repeating: "x", count: Inbox.rowLength))
    }
}
