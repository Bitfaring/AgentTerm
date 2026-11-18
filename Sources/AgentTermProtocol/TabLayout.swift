import Foundation

/// How the tabs of a window are arranged: their order, and which are
/// pinned. Tabs are named by opaque ids; what a tab shows is not this
/// type's business. Pinned tabs always come first. Tab groups were taken
/// away (#127): the shells, the files and the pages are each held in one
/// tab instead.
public struct TabLayout: Codable, Equatable, Sendable {
    public private(set) var order: [String] = []
    public private(set) var pinned: Set<String> = []

    public init() {}

    // MARK: Reading

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// The tabs on show, in order: what Command and a number counts.
    public func visibleTabs(front: String? = nil) -> [String] { order }

    // MARK: Keeping up with the tabs that exist

    /// Drops tabs that are gone and adds new ones at the end. A client that
    /// knows only some kinds of tab says which with `owns`; tabs of other
    /// kinds are left alone, for the client that knows them.
    public mutating func sync(with live: [String], owns: (String) -> Bool = { _ in true }) {
        let existing = Set(live).union(order.filter { !owns($0) })
        order.removeAll { !existing.contains($0) }
        for id in live where !order.contains(id) { order.append(id) }
        pinned.formIntersection(existing)
        normalize()
    }

    // MARK: Arranging

    /// Moves a tab to just before another, or to the end when `target` is
    /// nil. It takes on the place it lands in: pinned among the pinned.
    public mutating func move(_ id: String, before target: String?) {
        guard order.contains(id), id != target else { return }
        order.removeAll { $0 == id }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(id, at: index)
            adopt(id, placeOf: target)
        } else {
            order.append(id)
            pinned.remove(id)
        }
        normalize()
    }

    /// Moves a tab to just after another, taking on that one's place as in
    /// `move(_:before:)`.
    public mutating func move(_ id: String, after target: String) {
        guard id != target, order.contains(target), let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        let to = order.firstIndex(of: target).map { $0 + 1 } ?? order.count
        order.insert(id, at: to)
        adopt(id, placeOf: target)
        normalize()
    }

    /// Moves a tab one place to the left (-1) or right (+1).
    public mutating func move(_ id: String, by offset: Int, front: String? = nil) {
        let visible = visibleTabs(front: front)
        guard let index = visible.firstIndex(of: id), visible.indices.contains(index + offset) else { return }
        let neighbor = visible[index + offset]
        if offset < 0 { move(id, before: neighbor) } else { move(id, after: neighbor) }
    }

    private mutating func adopt(_ id: String, placeOf other: String) {
        if pinned.contains(other) { pinned.insert(id) } else { pinned.remove(id) }
    }

    public mutating func setPinned(_ id: String, _ isPinned: Bool) {
        guard order.contains(id) else { return }
        if isPinned {
            pinned.insert(id)
        } else {
            pinned.remove(id)
            // Lands right after the pinned tabs, where it was in view.
            order.removeAll { $0 == id }
            order.insert(id, at: order.filter { pinned.contains($0) }.count)
        }
        normalize()
    }

    // MARK: The rule

    private mutating func normalize() {
        order = order.filter { pinned.contains($0) } + order.filter { !pinned.contains($0) }
    }
}

extension SessionInfo {
    /// Whether a name in a `TabLayout` is a session's.
    public static func isLayoutID(_ id: String) -> Bool { id.hasPrefix("s:") }

    /// This session's name in a `TabLayout`. A session's number starts over
    /// with every host, so the moment it was started is part of the name: a
    /// pin never lands on another session that gets the same number.
    public var layoutID: String { "s:\(id):\(Int(createdAt.timeIntervalSince1970))" }

    /// The sessions that have a tab of their own in the Mac's strip (#127):
    /// the agents'. A shell has none: one an agent opened is in its agent's
    /// tab while that agent runs, and the user's are in the Shells tab of
    /// their folder. The Mac and the phones keep the same ones in the
    /// arrangement, or each would take out what the other put in.
    public static func withTabs(_ sessions: [SessionInfo]) -> [SessionInfo] {
        let agents = Set(sessions.filter { $0.agent != nil }.map(\.id))
        return sessions.filter { $0.agent != nil && !($0.openedBy.map(agents.contains) ?? false) }
    }
}
