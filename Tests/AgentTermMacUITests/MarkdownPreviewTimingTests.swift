import ApplicationServices
import XCTest

/// PERF-15 (#126): a long Markdown document, `docs/TESTING.md` of this
/// repository, opened in its preview and scrolled through, holds the Mac
/// app's main thread up no longer than a small one does, give or take a
/// frame (16 ms, the threshold of `docs/PERFORMANCE.md`). The work is
/// compared with itself, as SES-21's is, not with a number of seconds that
/// holds on one machine only. Its figures, and those of `RELEASE.md`,
/// `SPEC.md` and `DESIGN.md`, are printed as `MEASURE markdown, …`.
final class MarkdownPreviewTimingTests: MacUITestCase {
    /// Where the app notes its stalls: named before the test's own folder
    /// is made, which the app is started with.
    private let notes = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-main-thread-\(UUID().uuidString).txt")
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let documents = ["RELEASE.md", "SPEC.md", "DESIGN.md", "TESTING.md"]

    override func setUpWithError() throws {
        appEnvironment["AGENTTERM_MEASURE_MAIN"] = notes.path
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: notes)
        try super.tearDownWithError()
    }

    override func makeFixtures() throws {
        try super.makeFixtures()
        try write("# First\n\nThe first preview, which starts WebKit's process.\n", to: "first.md")
        try write("# Small\n\nA few words, and a [link](other.md).\n", to: "small.md")
        try write("# Other\n\nOther words, as few.\n", to: "other.md")
        for name in documents {
            try write(String(contentsOf: repository.appendingPathComponent("docs/" + name), encoding: .utf8), to: name)
        }
    }

    /// The stalls the app noted since a moment, each in ms.
    private func stalls(since start: Date) -> [Double] {
        let text = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let at = Double(parts[0]), let took = Double(parts[1]) else { return nil }
            return at >= start.timeIntervalSince1970 ? took : nil
        }
    }

    /// Does a step, leaves the app alone for a while, asking it nothing,
    /// and returns the longest stall meanwhile.
    private func longestStall(_ what: String, for seconds: TimeInterval = 3, _ step: () -> Void) -> Double {
        Thread.sleep(forTimeInterval: 0.5)
        let start = Date()
        step()
        Thread.sleep(forTimeInterval: seconds)
        let found = stalls(since: start)
        let longest = found.max() ?? 0
        print(
            String(
                format: "MEASURE markdown, %@: %@", what,
                found.isEmpty
                    ? "never held up over 16 ms"
                    : String(format: "held up %d times, the longest %.0f ms, %.0f ms in all", found.count, longest, found.reduce(0, +))))
        return longest
    }

    private func size(of element: AXUIElement) -> CGSize {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        var size = CGSize.zero
        if let value, CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return size
    }

    /// The tallest scroll bar that goes up and down: the preview's.
    private func tallestScrollBar() -> AXUIElement? {
        app.nodes().filter { $0.role == kAXScrollBarRole as String }.map(\.element)
            .filter { size(of: $0).height > size(of: $0).width }
            .max { size(of: $0).height < size(of: $1).height }
    }

    /// Opens a document of the Files tab, and how long the app was held up.
    private func open(_ name: String, showing words: String) -> Double {
        let row = app.wait(for: .button(name), timeout: 20)
        let longest = longestStall("\(name) opened") {
            if let row { AXUIElementPerformAction(row.element, kAXPressAction as CFString) }
        }
        app.wait(for: .containing(words), timeout: 20)
        return longest
    }

    func testALongDocumentHoldsTheWindowUpNoLongerThanASmallOne() throws {
        app.press(.button("Files"))
        app.wait(for: .button("small.md"), timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        let atRest = longestStall("at rest, the window open") {}
        // The first preview of all starts WebKit's process, whatever its
        // size: not what is compared.
        _ = open("first.md", showing: "The first preview")
        // A text file, in the editor: what any tab opened costs.
        _ = open("notes.txt", showing: "first line")
        // Two small ones, the longer of the two kept: what opening any
        // document varies by.
        let small = max(open("small.md", showing: "A few words"), open("other.md", showing: "Other words"))
        var opened: [String: Double] = [:]
        for name in documents {
            let firstWords = try XCTUnwrap(
                String(contentsOf: project.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
                    .first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) })
            opened[name] = open(name, showing: firstWords)
        }
        // TESTING.md is on show: from its top to its bottom in a second,
        // sixty steps.
        var scrolled: Double?
        if let bar = tallestScrollBar() {
            scrolled = longestStall("TESTING.md scrolled from top to bottom in a second") {
                for step in 1...60 {
                    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(step) / 60))
                    usleep(16_000)
                }
            }
        } else {
            print("MEASURE markdown, TESTING.md scrolled: not measured, no scroll bar was found")
        }

        let frame = 16.0
        let allowed = max(small, atRest) + frame
        let testing = try XCTUnwrap(opened["TESTING.md"])
        XCTAssertLessThanOrEqual(testing, allowed, "TESTING.md held the window up \(Int(testing)) ms as it opened; a small document \(Int(small)) ms")
        if let scrolled {
            XCTAssertLessThanOrEqual(scrolled, allowed, "scrolling TESTING.md held the window up \(Int(scrolled)) ms")
        }
    }
}
