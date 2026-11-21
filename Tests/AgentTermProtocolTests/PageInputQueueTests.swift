import AgentTermProtocol
import XCTest

/// What a Mac showing another Mac's page sends, and in which order
/// (`PageInputQueue`, BROWSER-50 and BROWSER-54 in docs/TESTING.md).
final class PageInputQueueTests: XCTestCase {
    private func pointer(_ kind: PagePointer.Kind, x: Double = 10, held: Bool = false) -> BrowserRequest {
        .pointer(tab: "7", event: PagePointer(kind: kind, x: x, y: 20, held: held))
    }

    /// Sends what may go: the one the link has, at most.
    private func sent(_ queue: inout PageInputQueue<String>) -> BrowserRequest? { queue.next()?.request }

    /// BROWSER-54 (#199): text typed and a key pressed right after a click,
    /// while the click's release is not answered yet, wait for it: they are
    /// sent after it, never before. Before the fix they were sent at once,
    /// and reached the other Mac before the release had put the caret.
    func testTextTypedRightAfterAClickWaitsForItsRelease() {
        var queue = PageInputQueue<String>()
        for request in [pointer(.moved), pointer(.pressed, held: true), pointer(.released)] { XCTAssertNil(queue.add(request)) }
        XCTAssertEqual(sent(&queue), pointer(.moved))
        queue.answered()
        XCTAssertEqual(sent(&queue), pointer(.pressed, held: true))
        queue.answered()
        // The release is sent, and its answer held back.
        XCTAssertEqual(sent(&queue), pointer(.released))
        XCTAssertNil(queue.add(.text(tab: "7", text: "h")), "text typed was sent before the click's release was answered")
        XCTAssertNil(queue.add(.text(tab: "7", text: "i")), "text typed was sent before the click's release was answered")
        XCTAssertNil(queue.add(.press(tab: "7", key: "Enter")), "a key was sent before the click's release was answered")
        XCTAssertNil(queue.next(), "something went while the release waited for its answer")
        queue.answered()
        // Typed text joined, never dropped; the key after it.
        XCTAssertEqual(sent(&queue), .text(tab: "7", text: "hi"))
        queue.answered()
        XCTAssertEqual(sent(&queue), .press(tab: "7", key: "Enter"))
        queue.answered()
        XCTAssertNil(queue.next())
    }

    /// BROWSER-54 (#199): a scroll right after a drag, while the drag's
    /// moves still wait, comes after its release; the wheel's steps
    /// meanwhile are added up, none lost.
    func testAScrollAfterADragWaitsForTheDrag() {
        var queue = PageInputQueue<String>()
        XCTAssertNil(queue.add(pointer(.pressed, held: true)))
        XCTAssertEqual(sent(&queue), pointer(.pressed, held: true))
        for step in 1...3 { XCTAssertNil(queue.add(pointer(.moved, x: Double(10 * step), held: true))) }
        XCTAssertNil(queue.add(pointer(.released, x: 30)))
        XCTAssertNil(queue.add(.scroll(tab: "7", ref: nil, x: 0, y: 40)), "a scroll was sent before the drag was done")
        XCTAssertNil(queue.add(.scroll(tab: "7", ref: nil, x: 5, y: 60)), "a scroll was sent before the drag was done")
        XCTAssertNil(queue.next(), "something went while the press waited for its answer")
        queue.answered()
        // The moves kept to the latest, as before (#191).
        XCTAssertEqual(sent(&queue), pointer(.moved, x: 30, held: true))
        queue.answered()
        XCTAssertEqual(sent(&queue), pointer(.released, x: 30))
        queue.answered()
        XCTAssertEqual(sent(&queue), .scroll(tab: "7", ref: nil, x: 5, y: 100))
        queue.answered()
        XCTAssertNil(queue.next())
    }

    /// BROWSER-54 (#199): everything the page's view sends of the mouse,
    /// the keyboard and its menu waits its turn; a watch and a new tab,
    /// which follow none of it, are given back to be sent at once.
    func testAllTheInputWaitsItsTurnAndAWatchDoesNot() {
        let input: [BrowserRequest] = [
            pointer(.pressed, held: true), .text(tab: "7", text: "a"), .press(tab: "7", key: "Backspace"), .scroll(tab: "7", ref: nil, x: 0, y: 30),
            .tap(tab: "7", x: 1, y: 2), .history(tab: "7", step: -1), .copy(tab: "7"), .contextAt(tab: "7", x: 1, y: 2),
        ]
        for request in input {
            var queue = PageInputQueue<String>()
            XCTAssertNil(queue.add(pointer(.released)))
            XCTAssertNotNil(queue.next())
            XCTAssertNil(queue.add(request), "\(request) was sent at once")
            XCTAssertNil(queue.next(), "\(request) went before the release was answered")
            queue.answered()
            XCTAssertEqual(queue.next()?.request, request)
        }
        for request: BrowserRequest in [.watch(tab: "7", on: true, width: 300), .newTab(project: "", url: "https://example.com", profile: nil, private: false)] {
            var queue = PageInputQueue<String>()
            XCTAssertNil(queue.add(pointer(.released)))
            XCTAssertNotNil(queue.next())
            XCTAssertEqual(queue.add(request)?.request, request, "\(request) waited for the mouse")
        }
    }

    /// What reads (#191) is never joined, and each is answered to its own.
    func testWhatReadsIsNeverJoined() {
        var queue = PageInputQueue<String>()
        XCTAssertNil(queue.add(pointer(.released)))
        XCTAssertNotNil(queue.next())
        XCTAssertNil(queue.add(.copy(tab: "7"), answer: "first"))
        XCTAssertNil(queue.add(.copy(tab: "7"), answer: "second"))
        XCTAssertNil(queue.add(.text(tab: "7", text: "a")))
        XCTAssertNil(queue.add(.text(tab: "8", text: "b")))
        XCTAssertEqual(queue.queued, [.copy(tab: "7"), .copy(tab: "7"), .text(tab: "7", text: "a"), .text(tab: "8", text: "b")])
        queue.answered()
        XCTAssertEqual(queue.next()?.answer, "first")
        queue.answered()
        XCTAssertEqual(queue.next()?.answer, "second")
    }
}
