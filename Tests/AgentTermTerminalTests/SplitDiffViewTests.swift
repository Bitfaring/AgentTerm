import AgentTermProtocol
import AppKit
import XCTest

@testable import AgentTermTerminal

/// GIT-75 (#82): the two-panel diff as one text for each side.
@MainActor
final class SplitDiffViewTests: XCTestCase {
    private func texts(_ patch: String) -> SplitDiffTexts {
        let (advance, lineHeight) = SplitDiffTexts.metrics(11.5)
        return SplitDiffTexts(patch: patch, fontSize: 11.5, advance: advance, lineHeight: lineHeight)
    }

    private func lines(_ text: NSAttributedString) -> [String] {
        Array(text.string.components(separatedBy: "\n").dropLast())
    }

    /// Both sides have a line for every row, facing each other; the numbers
    /// and the marks are not in the text; the header is said on the left.
    func testBothSidesHaveALineForEveryRow() {
        let patch = "@@ -1,3 +1,4 @@\n same\n-old\n+new\n+more\n@@ -10,2 +11,2 @@ func f()\n-gone\n kept"
        let texts = texts(patch)
        XCTAssertEqual(texts.rows, SplitDiff.rows(for: patch).count)
        XCTAssertEqual(lines(texts.left), ["@@ -1,3 +1,4 @@", "same", "old", "", "@@ -10,2 +11,2 @@ func f()", "gone", "kept"])
        XCTAssertEqual(lines(texts.right), ["", "same", "new", "more", "", "", "kept"])
        func number(_ text: NSAttributedString, line: Int) -> Int? {
            let start = (text.string as NSString).range(of: lines(text)[line]).location
            return text.attribute(SplitDiffTexts.number, at: line == 0 ? 0 : start, effectiveRange: nil) as? Int
        }
        XCTAssertEqual(number(texts.left, line: 2), 2)
        XCTAssertEqual(number(texts.right, line: 3), 3)
        XCTAssertEqual(number(texts.left, line: 6), 11)
        XCTAssertEqual(number(texts.right, line: 6), 11)
        XCTAssertNil(texts.left.attribute(SplitDiffTexts.number, at: 0, effectiveRange: nil), "a header has no number")
        XCTAssertGreaterThan(texts.right.length, 0)
    }

    /// A long diff is shown whole: no row is left out, where 2,500 were the
    /// most before.
    func testALongDiffIsShownWhole() {
        let patch = "@@ -1,20000 +1,20000 @@\n" + (1...20_000).map { "-line \($0)\n+changed \($0)" }.joined(separator: "\n")
        let texts = texts(patch)
        XCTAssertEqual(texts.rows, 20_001)
        XCTAssertEqual(lines(texts.left).count, 20_001)
        XCTAssertEqual(lines(texts.right).last, "changed 20000")
    }

    /// The work of laying a diff out grows with it, not faster: ten times
    /// the rows take less than fifteen times as long, in the best of three
    /// rounds. Compared with itself rather than with a number of seconds,
    /// as SES-21 is.
    func testTheWorkGrowsWithTheDiff() {
        func time(_ count: Int) -> TimeInterval {
            let patch = "@@ -1,\(count) +1,\(count) @@\n" + (1...count).map { "-line \($0) of the old file\n+line \($0) of the new one" }.joined(separator: "\n")
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                let texts = texts(patch)
                let storage = NSTextStorage(attributedString: texts.right)
                let layout = SplitDiffLayout()
                storage.addLayoutManager(layout)
                let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                layout.addTextContainer(container)
                layout.ensureLayout(for: container)
                // Every row, and the empty line after the last.
                XCTAssertEqual(layout.usedRect(for: container).height, CGFloat(texts.rows + 1) * SplitDiffTexts.rowHeight(11.5), accuracy: 1, "a row is one line, of one height")
                best = min(best, Date().timeIntervalSince(start))
            }
            return best
        }
        // Three rounds, and the one in which the work grew least: a runner of
        // CI that is slow for a few seconds makes a round say more than the
        // work does (16.1 times once, where it says 11; #136). Work that
        // grows as the square of the rows says a hundred times in each.
        let rounds = (0..<3).map { _ in (small: time(2_000), large: time(20_000)) }
        let best = rounds.min { $0.large / $0.small < $1.large / $1.small } ?? rounds[0]
        // Said each time: a run that passes tells how near it was.
        print(
            "MEASURE the diff's layout: " + rounds.map { String(format: "%.1f", $0.large / $0.small) }.joined(separator: ", ")
                + String(format: " times in three rounds; the least with 2,000 rows %.4f s, 20,000 rows %.4f s", best.small, best.large))
        XCTAssertLessThan(best.large, best.small * 15, "in the best of three rounds 2,000 rows took \(best.small) s, 20,000 took \(best.large) s")
    }
}
