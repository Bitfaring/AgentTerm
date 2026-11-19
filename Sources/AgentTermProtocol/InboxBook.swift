import Foundation

/// A device's own Inbox (#66, decided 2026-11-19): what it was told of,
/// kept after it is read, for 30 days, until it is deleted here. Read and
/// deleted are this device's alone; whether a notice was handled, and how,
/// is the host's, the same everywhere. Kept by each app, the same way.
public struct InboxBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var notice: Notice
        public var read: Bool
        public var id: UInt64 { notice.id }

        /// An agent that still waits for its answer stays until it is
        /// answered: it is not deleted.
        public var canBeDeleted: Bool { !(notice.handled == nil && notice.state?.isWaiting == true) }
    }

    /// Newest first.
    public private(set) var entries: [Entry] = []
    /// What was deleted here, so that the host's log does not bring it back.
    public private(set) var deleted: Set<UInt64> = []

    public init() {}

    public var unread: Int { entries.filter { !$0.read }.count }

    /// Notices from the host: new ones added unread, known ones brought up
    /// to date. `log` says these are all the host keeps, so that what it no
    /// longer has is forgotten here too, deleted marks included.
    public mutating func take(_ notices: [Notice], log: Bool = false, now: Date = Date()) {
        for notice in notices where !deleted.contains(notice.id) {
            if let index = entries.firstIndex(where: { $0.id == notice.id }) {
                entries[index].notice = notice
            } else {
                entries.append(Entry(notice: notice, read: false))
            }
        }
        if log {
            let kept = Set(notices.map(\.id))
            deleted.formIntersection(kept)
        }
        entries.sort { ($0.notice.at, $0.id) > ($1.notice.at, $1.id) }
        prune(now: now)
    }

    public mutating func handled(_ id: UInt64, _ handled: Notice.Handled) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].notice.handled = handled
    }

    public mutating func markRead(_ id: UInt64) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].read = true
    }

    /// Its session was opened here: what it said is read.
    public mutating func markRead(session: SessionID) {
        for index in entries.indices where entries[index].notice.session == session { entries[index].read = true }
    }

    /// False, and nothing deleted, for an agent that still waits.
    @discardableResult
    public mutating func delete(_ id: UInt64) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), entry.canBeDeleted else { return false }
        entries.removeAll { $0.id == id }
        deleted.insert(id)
        return true
    }

    public mutating func deleteRead() {
        for entry in entries where entry.read && entry.canBeDeleted { delete(entry.id) }
    }

    /// All but what still waits for an answer.
    public mutating func deleteAll() {
        for entry in entries where entry.canBeDeleted { delete(entry.id) }
    }

    public mutating func prune(now: Date = Date()) {
        let oldest = now.addingTimeInterval(-Notice.kept)
        entries.removeAll { $0.notice.at < oldest }
    }
}
