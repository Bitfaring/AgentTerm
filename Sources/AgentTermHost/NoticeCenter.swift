import AgentTermProtocol
import Foundation

/// The notices of this host (#66, decided 2026-11-19): what agents ask and
/// finish, and the failures that stopped work. Made once, here, for every
/// device; handled on one, handled on all.
///
/// Kept in a file for 30 days, with which device was told which, so that a
/// device that comes back, or a host that starts again, tells nothing
/// twice. Not thread-safe: the host calls it on its queue.
final class NoticeCenter {
    private struct Saved: Codable {
        var log: [Notice]
        var nextID: UInt64
        var told: [String: Set<UInt64>]
        var pushed: [String: Set<UInt64>]
        var due: Set<UInt64>?
        var waiting: [UInt64: Date]?
    }

    private let file: URL?
    private(set) var log: [Notice] = []
    private var nextID: UInt64 = 1
    /// What each session's agent was told in, as `AgentNotice.notices` keeps it.
    private var states: [SessionID: AgentState] = [:]
    /// The notices each device was shown as a notification, by device
    /// (`HostServer.noticeKey`).
    private var told: [String: Set<UInt64>] = [:]
    /// The notices whose time to be a notification has come (`noticeAlert`).
    private var due: Set<UInt64> = []
    /// Of those, the ones told through Apple: taken back the same way.
    private var pushed: [String: Set<UInt64>] = [:]
    /// The notices that wait to be a notification (`Notice.pushWait`), and
    /// when their time comes: kept, so that a host that starts again within
    /// the wait still makes them due (#193).
    private var waits: [UInt64: Date] = [:]

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = MessageCoding.decode(Saved.self, from: data) {
            log = saved.log
            nextID = saved.nextID
            told = saved.told
            pushed = saved.pushed
            due = saved.due ?? []
            waits = saved.waiting ?? [:]
        }
        // A host that starts again has none of the sessions of the last one:
        // what they were told of is over.
        let now = Date()
        for index in log.indices where log[index].handled == nil && log[index].state != nil {
            log[index].handled = Notice.Handled(at: now, how: .movedOn)
        }
    }

    // MARK: Making them

    /// What the sessions say now: the notices it makes, and those it
    /// handles because their agent moved on or their session ended.
    func update(sessions: [SessionInfo], now: Date) -> (new: [Notice], handled: [Notice]) {
        var handled: [Notice] = []
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in log.indices where log[index].handled == nil {
            guard let session = log[index].session, let state = log[index].state else { continue }
            if byID[session]?.state != state {
                log[index].handled = Notice.Handled(at: now, how: .movedOn)
                handled.append(log[index])
            }
        }
        var new: [Notice] = []
        for agent in AgentNotice.notices(in: sessions, told: &states) {
            let notice = Notice(id: nextID, at: now, session: agent.session, name: agent.name, folder: agent.folder, kind: .agent(agent.state))
            nextID += 1
            log.append(notice)
            new.append(notice)
        }
        prune(now: now)
        if !new.isEmpty || !handled.isEmpty { save() }
        return (new, handled)
    }

    /// A failure: in every Inbox; a notification too when it stopped work
    /// (`Notice.alerts`).
    func report(_ failure: PartFailure, now: Date) -> Notice? {
        let notice = Notice(id: nextID, at: failure.at, session: nil, name: failure.name ?? "", folder: "", kind: .failure(failure))
        nextID += 1
        log.append(notice)
        prune(now: now)
        save()
        return notice
    }

    // MARK: Handling them

    /// One notice, as a device says; nil when it was handled already.
    func handle(_ id: UInt64, how: Notice.Handled.How, now: Date) -> Notice? {
        guard let index = log.firstIndex(where: { $0.id == id }), log[index].handled == nil else { return nil }
        log[index].handled = Notice.Handled(at: now, how: how)
        if Notice.reads(how) { log[index].read = true }
        save()
        return log[index]
    }

    /// What its agent says in `state`, in a session: opened or answered.
    func handle(session: SessionID, state: AgentState, how: Notice.Handled.How, now: Date) -> [Notice] {
        let ids = log.filter { $0.handled == nil && $0.session == session && $0.state == state }.map(\.id)
        return ids.compactMap { handle($0, how: how, now: now) }
    }

    /// A failure dismissed: its notice with it.
    func handle(failure id: String, now: Date) -> [Notice] {
        let ids = log.filter {
            if $0.handled == nil, case .failure(let failure) = $0.kind { return failure.id == id }
            return false
        }.map(\.id)
        return ids.compactMap { handle($0, how: .dismissed, now: now) }
    }

    // MARK: Reading them

    /// Read on a device: the ones that were not read yet.
    func read(_ ids: [UInt64]) -> [UInt64] {
        let ids = Set(ids)
        var newly: [UInt64] = []
        for index in log.indices where ids.contains(log[index].id) && log[index].read != true {
            log[index].read = true
            newly.append(log[index].id)
        }
        if !newly.isEmpty { save() }
        return newly
    }

    // MARK: Who was told

    /// Still to be shown as a notification: not handled, not read.
    func pending(_ id: UInt64) -> Notice? {
        log.first { $0.id == id && $0.handled == nil && $0.read != true }
    }

    /// It waits until `until` to be a notification (#193).
    func waits(_ id: UInt64, until: Date) {
        waits[id] = until
        save()
    }

    /// The notices that still wait, not handled nor read, with when their
    /// time comes: for a host that starts again (#193).
    var waiting: [(id: UInt64, until: Date)] {
        waits.filter { pending($0.key) != nil }.map { (id: $0.key, until: $0.value) }.sorted { $0.until < $1.until }
    }

    /// Its time to be a notification has come.
    func becameDue(_ id: UInt64) {
        due.insert(id)
        waits[id] = nil
        save()
    }

    /// The notices due, not handled nor read, that this device was not
    /// shown yet.
    func untold(to device: String) -> [Notice] {
        let known = told[device] ?? []
        return log.filter { due.contains($0.id) && $0.handled == nil && $0.read != true && !known.contains($0.id) }
    }

    func told(_ id: UInt64, to device: String, throughApple: Bool) {
        told[device, default: []].insert(id)
        if throughApple { pushed[device, default: []].insert(id) }
        save()
    }

    /// The devices this notice reached through Apple, to take it back there.
    func pushedTo(_ id: UInt64) -> [String] { pushed.filter { $0.value.contains(id) }.map(\.key) }

    /// A device revoked, or no longer told through Apple.
    func forget(device: String) {
        told[device] = nil
        pushed[device] = nil
        save()
    }

    // MARK: Keeping them

    private func prune(now: Date) {
        let oldest = now.addingTimeInterval(-Notice.kept)
        log.removeAll { $0.at < oldest }
        let ids = Set(log.map(\.id))
        told = told.mapValues { $0.intersection(ids) }
        pushed = pushed.mapValues { $0.intersection(ids) }
        due.formIntersection(ids)
        waits = waits.filter { ids.contains($0.key) }
    }

    private func save() {
        guard let file else { return }
        let data = MessageCoding.encode(Saved(log: log, nextID: nextID, told: told, pushed: pushed, due: due, waiting: waits))
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // What agents said: the user's alone.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
