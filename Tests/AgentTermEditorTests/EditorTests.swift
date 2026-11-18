import AppKit
import SwiftUI
import XCTest

@testable import AgentTermEditor

final class EditorTests: XCTestCase {
    /// FIND-12 (#45): where a line is in a text, for the editor to show it:
    /// by its number from 1, without the line break at its end; the last
    /// line for a number past the end.
    func testWhereALineIsInAText() {
        let text = "one\ntwo\n\nfour" as NSString
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 1, in: text)), "one")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 2, in: text)), "two")
        XCTAssertEqual(LineTarget.range(ofLine: 3, in: text), NSRange(location: 8, length: 0), "an empty line")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 4, in: text)), "four")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 40, in: text)), "four", "past the end: the last line")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 0, in: text)), "one")
        XCTAssertEqual(LineTarget.range(ofLine: 3, in: "" as NSString), NSRange(location: 0, length: 0))
        let windows = "a\r\nb\r\n" as NSString
        XCTAssertEqual(windows.substring(with: LineTarget.range(ofLine: 2, in: windows)), "b")
    }

    /// PERF-11 (#21): text is colored when it is in a language the
    /// highlighter knows and not larger than half a megabyte; a larger file,
    /// and plain text of any size, is shown without, since coloring 5 MB
    /// held the window for seconds.
    @MainActor
    func testLargeAndPlainTextIsNotColored() {
        XCTAssertTrue(Highlighting.colors("/p/main.swift", length: 20_000))
        XCTAssertTrue(Highlighting.colors("/p/main.swift", length: Highlighting.largestColored))
        XCTAssertFalse(Highlighting.colors("/p/main.swift", length: Highlighting.largestColored + 1))
        XCTAssertFalse(Highlighting.colors("/p/notes.txt", length: 10), "plain text has nothing to color")
        XCTAssertFalse(Highlighting.colors("/p/large.log", length: 5 * 1024 * 1024))
        // The storage made for each: the one that colors, or a plain one.
        func colors(_ storage: NSTextStorage) -> Bool { String(describing: type(of: storage)).contains("CodeAttributedString") }
        XCTAssertFalse(colors(Highlighting.storage(for: "/p/notes.txt", fontSize: 12, length: 10)))
        XCTAssertFalse(colors(Highlighting.storage(for: "/p/main.swift", fontSize: 12, length: Highlighting.largestColored + 1)))
        if Highlighting.shared != nil { XCTAssertTrue(colors(Highlighting.storage(for: "/p/main.swift", fontSize: 12, length: 10))) }
    }

    /// PERF-12 (#50): whether the editor colors a file follows the text it
    /// is given, also when that comes after the editor was made, as on the
    /// iPhone, where the file is read after the editor is shown; and
    /// another file opened in it is colored, or not, by its own size.
    @MainActor
    func testWhetherATextIsColoredFollowsTheTextThatArrives() throws {
        final class Holder: ObservableObject {
            @Published var text = ""
            @Published var path = "/p/large.js"
        }
        struct Host: View {
            @ObservedObject var holder: Holder
            var body: some View { CodeEditor(text: $holder.text, path: holder.path) }
        }
        let holder = Holder()
        let view = NSHostingView(rootView: Host(holder: holder))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
        }
        func textView(in view: NSView) -> NSTextView? {
            if let found = view as? NSTextView { return found }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        func colored() throws -> Bool {
            String(describing: type(of: try XCTUnwrap(textView(in: view)?.textStorage))).contains("CodeAttributedString")
        }
        settle()
        XCTAssertNotNil(textView(in: view))

        holder.text = String(repeating: "let value = 1;\n", count: 40_000)
        settle()
        XCTAssertGreaterThan(holder.text.utf16.count, Highlighting.largestColored)
        XCTAssertFalse(try colored(), "a large text that came after the editor was made is colored")
        XCTAssertEqual(textView(in: view)?.string.utf16.count, holder.text.utf16.count)

        guard Highlighting.shared != nil else { return }
        // Another file, small, in a language: colored.
        holder.path = "/p/small.swift"
        holder.text = "let value = 1\n"
        settle()
        XCTAssertTrue(try colored())
        XCTAssertEqual(textView(in: view)?.string, "let value = 1\n")
    }

    /// FILE-10 (#132): a line of many tabs is one line, the lines not being
    /// wrapped: AppKit's own paragraph style has twelve tab stops and breaks
    /// a line at its thirteenth tab. In a plain text and in one that is
    /// colored, given and typed, at the end of the text too.
    @MainActor
    func testALineOfManyTabsIsOneLine() throws {
        final class Holder: ObservableObject {
            @Published var text = ""
            @Published var path = "/p/table.tsv"
        }
        struct Host: View {
            @ObservedObject var holder: Holder
            var body: some View { CodeEditor(text: $holder.text, path: holder.path) }
        }
        let holder = Holder()
        let view = NSHostingView(rootView: Host(holder: holder))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.layoutSubtreeIfNeeded()
        }
        func textView(in view: NSView) -> NSTextView? {
            if let found = view as? NSTextView { return found }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        /// The lines the layout makes of the text.
        func laidOut() throws -> Int {
            let textView = try XCTUnwrap(textView(in: view))
            let layout = try XCTUnwrap(textView.layoutManager)
            layout.ensureLayout(for: try XCTUnwrap(textView.textContainer))
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
            return count
        }
        let tabs = String(repeating: "\t", count: 30)
        func check(_ what: String) throws {
            holder.text = "let one = 1\n\(tabs)let two = 2\nlet three = 3"
            settle()
            XCTAssertEqual(try laidOut(), 3, "\(what): given")
            let textView = try XCTUnwrap(textView(in: view))
            textView.insertText("\(tabs)let more = 0\n", replacementRange: NSRange(location: 0, length: 0))
            settle()
            XCTAssertEqual(try laidOut(), 4, "\(what): a line typed at its start")
            textView.insertText("\n\(tabs)let last = 4", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
            settle()
            XCTAssertEqual(try laidOut(), 5, "\(what): a line typed at its end")
        }
        settle()
        try check("plain text")
        guard Highlighting.shared != nil else { return }
        // Another file, in a language: its storage colors each line that changes, and gives it attributes of its own.
        holder.path = "/p/main.swift"
        try check("colored text")
        XCTAssertTrue(String(describing: type(of: try XCTUnwrap(textView(in: view)?.textStorage))).contains("CodeAttributedString"))
    }

    /// PERF-14 (#104): the line breaks of a text are those the layout makes
    /// lines at, a carriage return and its line feed one break; counted unit
    /// by unit or by Foundation, the same.
    func testTheLineBreaksOfATextAreThoseTheLayoutBreaksAt() {
        for separator in ["\n", "\r\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "a\(separator)b" as NSString
            let named = separator.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            XCTAssertEqual(LineBreaks.count(in: text, range: NSRange(location: 0, length: text.length)), 1, named)
            XCTAssertEqual(LineBreaks.measure(text, odd: true).breaks, 1, named)
        }
        let mixed = "one\r\ntwo\rthree\n\nfive\u{0C}six\u{0B}seven\u{2028}eight\u{2029}nine\u{85}ten\r\n" as NSString
        XCTAssertEqual(LineBreaks.count(in: mixed, range: NSRange(location: 0, length: mixed.length)), 10)
        XCTAssertEqual(LineBreaks.measure(mixed, odd: true).breaks, 10)
        // Foundation's own line ends leave out the form feed and the vertical tab.
        XCTAssertEqual(LineBreaks.measure(mixed, odd: false).breaks, 8)
        // And its longest line is one of Foundation's: across the form feed and the vertical tab, which is wider than it is.
        XCTAssertEqual(LineBreaks.measure(mixed, odd: true).longest, 14, "five, six and seven as one")
        // Part of a text: a line feed whose carriage return is before the part is counted, in the same way before a change and after it.
        XCTAssertEqual(LineBreaks.count(in: "a\r\nb" as NSString, range: NSRange(location: 2, length: 2)), 1)
        XCTAssertEqual(LineBreaks.count(in: "" as NSString, range: NSRange(location: 0, length: 0)), 0)
    }

    /// PERF-14 (#104): a large text's view sizes itself, since AppKit works
    /// out the room of the whole text again at each key. It is as tall as its
    /// lines, at once after each change made in it, and as wide as its widest
    /// line on show or typed in: what AppKit's own layout of the whole text
    /// comes to, which is made here to compare. A small text's is AppKit's.
    @MainActor
    func testALargeTextsViewIsAsTallAsItsLinesAndAsWideAsItsWidestShown() throws {
        final class Holder: ObservableObject {
            @Published var text = ""
        }
        struct Host: View {
            @ObservedObject var holder: Holder
            var body: some View { CodeEditor(text: $holder.text, path: "/p/large.log") }
        }
        let holder = Holder()
        let view = NSHostingView(rootView: Host(holder: holder))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            view.layoutSubtreeIfNeeded()
        }
        func editor(in view: NSView) -> EditorTextView? {
            if let found = view as? EditorTextView { return found }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        settle()
        let editor = try XCTUnwrap(editor(in: view))
        XCTAssertFalse(editor.selfSized, "a text of no length sizes itself")
        XCTAssertTrue(editor.isVerticallyResizable)

        // Lines of every kind, every break the layout knows, tabs that take
        // more room than their one letter, and no break at the end.
        let tabs = String(repeating: "\t", count: 30)
        let kinds =
            "\(tabs)wide\n" + "tiếng Việt có dấu\n" + "日本語の行と中文\r\n" + "smile 😀 flag 🇻🇳\r" + "line\u{2028}" + "paragraph\u{2029}" + "next\u{85}"
            + "form\u{0C}feed\n" + "vertical\u{0B}tab\n"
        holder.text = kinds + String(repeating: "A line of a large file, forty-nine letters long.\n", count: 22_000) + "the last line, with no break after it"
        // The count with its form feed and vertical tab comes off the main thread.
        settle(0.6)
        XCTAssertGreaterThanOrEqual(editor.string.utf16.count, EditorTextView.selfSizedFrom)
        XCTAssertTrue(editor.selfSized)
        XCTAssertFalse(editor.isVerticallyResizable, "AppKit still sizes a large text's view")
        XCTAssertFalse(editor.isHorizontallyResizable)

        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        /// What AppKit's layout of the whole text comes to.
        func laidOut() -> (lines: Int, height: CGFloat) {
            layout.ensureLayout(for: container)
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
            if layout.extraLineFragmentRect.height > 0 { count += 1 }
            return (count, layout.usedRect(for: container).height)
        }
        func isRight(_ what: String, line: UInt = #line) {
            let found = laidOut()
            XCTAssertEqual(editor.lines, found.lines, what, line: line)
            XCTAssertEqual(editor.frame.height, found.height + 2 * editor.textContainerInset.height, accuracy: 0.5, what, line: line)
        }
        isRight("the text as given")
        XCTAssertEqual(editor.lines, 22_000 + 11 + 1, "eleven breaks among the first lines, and the last line")

        // Changes made as typing makes them, each right at once.
        func type(_ text: String, at range: NSRange) { editor.insertText(text, replacementRange: range) }
        let lines = editor.lines
        type("\n", at: NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.lines, lines + 1, "a line break typed")
        isRight("a line break typed")
        // A carriage return put before a line feed makes one break of the two; the line feed taken away leaves one.
        let feed = (editor.string as NSString).range(of: "wide\n").location + 4
        XCTAssertEqual((editor.string as NSString).character(at: feed), 0x0A)
        type("\r", at: NSRange(location: feed, length: 0))
        XCTAssertEqual(editor.lines, lines + 1, "a carriage return before a line feed")
        type("", at: NSRange(location: feed + 1, length: 1))
        XCTAssertEqual(editor.lines, lines + 1, "the line feed of the two taken away")
        type("", at: NSRange(location: feed, length: 1))
        XCTAssertEqual(editor.lines, lines, "the carriage return taken away")
        isRight("breaks parted and brought together")
        type("x\ny\r\nz\u{2028}w\u{0C}v", at: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.lines, lines + 4, "four breaks pasted")
        isRight("lines pasted")
        type("", at: NSRange(location: 0, length: 12))
        isRight("some of them taken away")
        // One too long to count unit by unit: the whole text counted again.
        type(String(repeating: "pasted\n", count: 4_000), at: NSRange(location: 10, length: 0))
        XCTAssertGreaterThan(28_000, EditorTextView.largestCounted)
        isRight("a long text pasted")
        editor.undoManager?.undo()
        isRight("undone")
        // A change it was not asked about is put right a second after it.
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "three\nmore\nlines\n")
        editor.didChangeText()
        settle(1.6)
        isRight("a change it was not asked about")

        // As wide as the widest line on show: the tabs', which its letters do not say.
        let wide = (editor.string as NSString).range(of: "wide")
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.viewWillDraw()
        let tabsEnd = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: wide.location), effectiveRange: nil).maxX
        XCTAssertGreaterThan(tabsEnd, 49 * 8, "the line of tabs is no wider than the longest line by its letters")
        XCTAssertGreaterThanOrEqual(editor.frame.width, tabsEnd + 2 * editor.textContainerInset.width)
        // And as the line typed in: wider at once.
        editor.setSelectedRange(NSRange(location: NSMaxRange(wide), length: 0))
        type(String(repeating: "W", count: 300), at: editor.selectedRange())
        let typedEnd = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: wide.location), effectiveRange: nil).maxX
        XCTAssertGreaterThan(typedEnd, tabsEnd + 2_000)
        XCTAssertGreaterThanOrEqual(editor.frame.width, typedEnd + 2 * editor.textContainerInset.width)
        isRight("typed into a line")

        // A small text given to the same view: AppKit's own sizing again.
        holder.text = "small\n"
        settle()
        XCTAssertFalse(editor.selfSized)
        XCTAssertTrue(editor.isVerticallyResizable)
        XCTAssertTrue(editor.isHorizontallyResizable)
    }
}
