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
}
