import Foundation

/// The agents' notices on show over the window's content (#225, decided by
/// the owner on 2026-11-22): a stack, the newest on top, ten at most, that
/// takes no room from what is under it.
///
/// One of an agent that is done goes by itself after `stays` seconds; one
/// of an agent that waits (a question, a permission) stays until it is
/// answered, opened or dismissed, since going by itself would hide what the
/// agent waits for. While the pointer is over one it does not go, and its
/// time starts again when the pointer leaves. A notice that goes from the
/// stack is still in the Inbox.
///
/// Only which notices are on show and when each is due to go: the clock and
/// the drawing are the app's.
public struct FloatingNotices: Equatable, Sendable {
    public struct Shown: Equatable, Sendable, Identifiable {
        /// The host's number for the notice.
        public var id: UInt64
        public var notice: AgentNotice
        /// When it goes by itself: nil for one that stays, because its
        /// agent waits or the pointer is over it.
        public var goes: Date?
        /// The pointer is over it.
        public var hovered = false
    }

    /// How many are on show at most.
    public static let most = 10

    /// How long one of an agent that is done stays, in seconds.
    public static let stays: TimeInterval = 10

    /// The variable a test shortens `stays` with, for the app that reads it.
    public static let staysVariable = "AGENTTERM_NOTICE_SECONDS"

    /// How long a notice stays, as the environment says or `stays`.
    public static func stays(in environment: [String: String]) -> TimeInterval {
        guard let said = environment[staysVariable].flatMap(TimeInterval.init), said > 0 else { return stays }
        return said
    }

    /// Whole seconds left before one goes by itself, counted up: "10" at
    /// the start, "1" in its last second, never below 0.
    public static func secondsLeft(until goes: Date, at now: Date) -> Int { max(0, Int(goes.timeIntervalSince(now).rounded(.up))) }

    /// What its countdown says: "8s".
    public static func countdown(_ seconds: Int) -> String { "\(seconds)s" }

    /// The same in a sentence, for a tooltip and assistive tools.
    public static func goesIn(_ seconds: Int) -> String { "Closes in \(seconds) \(seconds == 1 ? "second" : "seconds")" }

    /// The notices on show, the newest first: the one drawn on top.
    public private(set) var shown: [Shown] = []
    /// How long one of an agent that is done stays here.
    public var stays: TimeInterval

    public init(stays: TimeInterval = FloatingNotices.stays) {
        self.stays = stays
    }

    public var isEmpty: Bool { shown.isEmpty }

    /// Whether a notice goes by itself: not while its agent waits.
    public static func goesByItself(_ notice: AgentNotice) -> Bool { !notice.state.isWaiting }

    /// A notice the host told. The same one told again takes its own place,
    /// with the time it had; another of the same session takes that
    /// session's place, on top, as the session has one thing to say at a
    /// time. An eleventh takes the place of the oldest that does not wait;
    /// when all ten wait, of the oldest.
    public mutating func show(_ notice: AgentNotice, id: UInt64, at now: Date) {
        if let index = shown.firstIndex(where: { $0.id == id }) {
            shown[index].notice = notice
            if !Self.goesByItself(notice) {
                shown[index].goes = nil
            } else if shown[index].goes == nil, !shown[index].hovered {
                shown[index].goes = now.addingTimeInterval(stays)
            }
            return
        }
        shown.removeAll { $0.notice.session == notice.session }
        if shown.count >= Self.most {
            let pushedOut = shown.lastIndex { Self.goesByItself($0.notice) } ?? shown.count - 1
            shown.remove(at: pushedOut)
        }
        shown.insert(Shown(id: id, notice: notice, goes: Self.goesByItself(notice) ? now.addingTimeInterval(stays) : nil), at: 0)
    }

    /// Handled or read, here or on another device: gone from the stack.
    public mutating func remove(ids: [UInt64]) {
        shown.removeAll { ids.contains($0.id) }
    }

    /// Its session was opened, or came to the front.
    public mutating func remove(session: SessionID) {
        shown.removeAll { $0.notice.session == session }
    }

    /// The sessions as the host has them now: a notice whose agent moved
    /// on, or whose session ended, goes.
    public mutating func keep(where holds: (AgentNotice) -> Bool) {
        shown.removeAll { !holds($0.notice) }
    }

    /// The pointer came over a notice, or left it: it does not go while it
    /// is over it, and its time starts again when it leaves.
    public mutating func hover(_ id: UInt64, _ over: Bool, at now: Date) {
        guard let index = shown.firstIndex(where: { $0.id == id }), shown[index].hovered != over else { return }
        shown[index].hovered = over
        if over {
            shown[index].goes = nil
        } else if Self.goesByItself(shown[index].notice) {
            shown[index].goes = now.addingTimeInterval(stays)
        }
    }

    /// Takes away those whose time has come, and says which.
    @discardableResult
    public mutating func expire(at now: Date) -> [UInt64] {
        let gone = shown.filter { $0.goes.map { $0 <= now } ?? false }.map(\.id)
        if !gone.isEmpty { shown.removeAll { gone.contains($0.id) } }
        return gone
    }

    /// When the next one goes by itself: nil when none does.
    public var nextGoes: Date? { shown.compactMap(\.goes).min() }
}
