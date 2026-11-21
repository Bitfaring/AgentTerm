import Foundation

/// What a Mac showing another Mac's page (#147, `RemotePageView`) sends of
/// what its mouse and its keyboard do there, and of what reads what they
/// did (⌘C, a right click): one at a time, in the order done, the next
/// once the last is answered (#191, #199). The Mac whose page it is does a
/// device's input in the order it arrives (`followsTheDevicesInput`);
/// sending the next only once the last is answered keeps that order over
/// the link too, so that text typed right after a click goes where the
/// click put the caret, and a scroll comes after the drag before it.
///
/// While one waits for its answer, what comes after it is kept, never
/// dropped: moves of the mouse to the latest, scrolls added up, text typed
/// joined. What reads (a copy, what is at a point) is never joined, and is
/// answered to its own `answer`.
public struct PageInputQueue<Answer> {
    public struct Item {
        public let request: BrowserRequest
        /// Whom its answer is for; nil for what only acts.
        public let answer: Answer?
    }

    private var waiting: [Item] = []
    /// Whether one was sent and is not answered yet.
    public private(set) var waitsForAnAnswer = false

    public init() {}

    /// What waits its turn, in order.
    public var queued: [BrowserRequest] { waiting.map(\.request) }

    /// Takes what is to be sent. What follows none of the input before it
    /// (a watch, a new tab) is given back, to be sent at once; the rest
    /// waits its turn, and nil is returned.
    public mutating func add(_ request: BrowserRequest, answer: Answer? = nil) -> Item? {
        guard Self.waitsInTurn(request) else { return Item(request: request, answer: answer) }
        if answer == nil, let last = waiting.last, last.answer == nil, let joined = Self.join(last.request, request) {
            waiting[waiting.count - 1] = Item(request: joined, answer: nil)
        } else {
            waiting.append(Item(request: request, answer: answer))
        }
        return nil
    }

    /// The next to send, taken from the queue: nil while the last sent is
    /// not answered yet, or when none waits.
    public mutating func next() -> Item? {
        guard !waitsForAnAnswer, !waiting.isEmpty else { return nil }
        waitsForAnAnswer = true
        return waiting.removeFirst()
    }

    /// The last sent is answered: the next may go.
    public mutating func answered() { waitsForAnAnswer = false }

    /// What the Mac whose page it is does after the input before it waits
    /// its turn here too: the mouse, the keys, text, the wheel, a tap, back
    /// and forward, a copy, what is at a point. Before #199 only the mouse,
    /// a copy and what is at a point did.
    static func waitsInTurn(_ request: BrowserRequest) -> Bool { request.followsTheDevicesInput }

    /// Two that may go as one, the second right after the first.
    static func join(_ first: BrowserRequest, _ second: BrowserRequest) -> BrowserRequest? {
        switch (first, second) {
        case (.pointer(let tab, let before), .pointer(let other, let after)) where tab == other && before.kind == .moved && after.kind == .moved:
            return second
        case (.scroll(let tab, nil, let x, let y), .scroll(let other, nil, let moreX, let moreY)) where tab == other:
            return .scroll(tab: tab, ref: nil, x: x + moreX, y: y + moreY)
        case (.text(let tab, let text), .text(let other, let more)) where tab == other:
            return .text(tab: tab, text: text + more)
        default:
            return nil
        }
    }
}
