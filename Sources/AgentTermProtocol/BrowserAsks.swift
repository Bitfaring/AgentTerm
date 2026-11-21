import Foundation

/// What a device asked of a Mac's browser and still waits for, by the id
/// the ask went with (`browserAsk(id:request:)`).
///
/// Each is answered once: by what that Mac's browser said
/// (`browserAnswer`), or, once the connection to that Mac closes or is
/// left for another Mac, at once, refused in words that name it and say
/// it may not have been done (`BrowserWords.otherMacClosed`, #196, #198),
/// so that nothing waits for an answer that cannot come. `Done` is what an
/// ask is answered through.
public struct BrowserAsks<Done> {
    private var waiting: [Int: Done] = [:]
    /// Never used again, across connections: an answer of a connection
    /// before, come late, answers nothing of this one.
    private var next = 1

    public init() {}

    /// How many wait.
    public var count: Int { waiting.count }

    /// Keeps what an ask is answered through; the id to send it with.
    public mutating func add(_ done: Done) -> Int {
        let id = next
        next += 1
        waiting[id] = done
        return id
    }

    /// What the answer to `id` goes to: nil when nothing waits for it.
    public mutating func answered(_ id: Int) -> Done? {
        waiting.removeValue(forKey: id)
    }

    /// The connection to `mac` closed, or was left for another Mac: what
    /// waited, the first asked first, and the refusal each is answered
    /// with; nothing waits after. Nil when nothing waited.
    public mutating func closed(mac: String) -> (why: String, waiting: [Done])? {
        let all = waiting
        waiting = [:]
        guard !all.isEmpty else { return nil }
        return (BrowserWords.otherMacClosed(mac), all.sorted { $0.key < $1.key }.map(\.value))
    }
}
