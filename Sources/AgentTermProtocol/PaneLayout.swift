import Foundation

/// How the middle of the Mac's window is split into panes for one project
/// (#69): a tree of splits whose leaves are panes, each with tabs of its own
/// and one of them in front. Tabs are named by opaque ids, as in
/// `TabLayout`, which still decides their order, pins and groups; this says
/// only which pane each tab is in.
///
/// A tab is in one pane at most, so a session is shown in one place only:
/// the window is one client of the host, with one size for each session.
/// The Mac app keeps a layout for each host and project; the iPhone has none.
public struct PaneLayout: Codable, Equatable, Sendable {
    /// Side by side (a divider up and down), or one above the other.
    public enum Axis: String, Codable, Sendable {
        case sideBySide
        case stacked
    }

    public enum Direction: String, Codable, Sendable, CaseIterable {
        case left, right, up, down

        var axis: Axis { self == .left || self == .right ? .sideBySide : .stacked }
        /// Toward the second child of a split: right or down.
        var forward: Bool { self == .right || self == .down }
    }

    public struct Pane: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The tabs in this pane, in the order of the strip.
        public var tabs: [String]
        public var front: String?
        /// Made by a split and given no tab yet: kept although it is empty,
        /// so that a tab can be put in it.
        public var keptEmpty: Bool

        public init(id: String, tabs: [String] = [], front: String? = nil, keptEmpty: Bool = false) {
            self.id = id
            self.tabs = tabs
            self.front = front
            self.keptEmpty = keptEmpty
        }
    }

    public indirect enum Node: Codable, Equatable, Sendable {
        case pane(Pane)
        /// `fraction` is the share of the first child, left or above.
        case split(id: String, axis: Axis, fraction: Double, first: Node, second: Node)

        var panes: [Pane] {
            switch self {
            case .pane(let pane): return [pane]
            case .split(_, _, _, let first, let second): return first.panes + second.panes
            }
        }

        func contains(_ paneID: String) -> Bool { panes.contains { $0.id == paneID } }
    }

    public private(set) var root: Node
    /// The pane the keyboard is in: where a new tab goes.
    public private(set) var focused: String
    /// A pane shown alone for a while, the others kept as they are.
    public private(set) var maximized: String?
    private var counter: Int

    public init() {
        root = .pane(Pane(id: "pane-1"))
        focused = "pane-1"
        maximized = nil
        counter = 1
    }

    // MARK: Reading

    /// Every pane, left to right and top to bottom.
    public var panes: [Pane] { root.panes }

    public var isSplit: Bool { panes.count > 1 }

    public func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }

    public func pane(containing tab: String) -> Pane? { panes.first { $0.tabs.contains(tab) } }

    public var focusedPane: Pane { pane(focused) ?? panes[0] }

    /// Every tab in some pane.
    public var allTabs: [String] { panes.flatMap(\.tabs) }

    // MARK: Showing a tab

    /// Brings a tab to the front of its pane and puts the keyboard there. A
    /// tab in no pane yet goes to `paneID`, or the pane the keyboard is in.
    public mutating func show(_ tab: String, in paneID: String? = nil) {
        if let paneID, pane(paneID) != nil, pane(containing: tab)?.id != paneID {
            move(tab, to: paneID)
        } else if pane(containing: tab) == nil {
            let target = paneID.flatMap { pane($0) }?.id ?? focused
            update(target) { $0.tabs.append(tab) }
        }
        guard let home = pane(containing: tab) else { return }
        update(home.id) {
            $0.front = tab
            $0.keptEmpty = false
        }
        focus(home.id)
    }

    /// Puts the keyboard in a pane, without changing what it shows.
    public mutating func focus(_ paneID: String) {
        guard pane(paneID) != nil else { return }
        focused = paneID
        // Another pane comes to the front: the one shown alone gives way.
        if let maximized, maximized != paneID { self.maximized = nil }
    }

    /// The pane next to `paneID` in a direction, by the tree: the nearest
    /// one on that side, or nil at the window's edge.
    public func neighbour(of paneID: String, _ direction: Direction) -> String? {
        func search(_ node: Node) -> (found: Bool, answer: String?) {
            switch node {
            case .pane(let pane):
                return (pane.id == paneID, nil)
            case .split(_, let axis, _, let first, let second):
                let inFirst = search(first)
                if inFirst.found {
                    if inFirst.answer != nil { return inFirst }
                    if axis == direction.axis, direction.forward { return (true, edge(of: second, facing: direction)) }
                    return (true, nil)
                }
                let inSecond = search(second)
                if inSecond.found {
                    if inSecond.answer != nil { return inSecond }
                    if axis == direction.axis, !direction.forward { return (true, edge(of: first, facing: direction)) }
                    return (true, nil)
                }
                return (false, nil)
            }
        }
        return search(root).answer
    }

    /// The pane of `node` that is nearest to one coming from `direction`'s
    /// other side: moving right, the leftmost.
    private func edge(of node: Node, facing direction: Direction) -> String {
        switch node {
        case .pane(let pane): return pane.id
        case .split(_, let axis, _, let first, let second):
            if axis == direction.axis { return edge(of: direction.forward ? first : second, facing: direction) }
            return edge(of: first, facing: direction)
        }
    }

    // MARK: Arranging

    /// Moves a tab to another pane, in front there. A pane it leaves empty
    /// closes, unless it is the only one.
    public mutating func move(_ tab: String, to paneID: String) {
        guard pane(paneID) != nil else { return }
        let source = pane(containing: tab)
        guard source?.id != paneID else { return }
        if let source { take(tab, from: source.id) }
        update(paneID) {
            $0.tabs.append(tab)
            $0.front = tab
            $0.keptEmpty = false
        }
        focus(paneID)
        if let source, let left = pane(source.id), left.tabs.isEmpty, !left.keptEmpty { close(source.id) }
    }

    /// Splits a pane in two, the new one right of it or under it, and puts
    /// the keyboard there. With `tab`, that tab moves into the new pane;
    /// without, the new pane starts empty, to be given one. Returns the
    /// new pane's id.
    @discardableResult
    public mutating func split(_ paneID: String, _ axis: Axis, moving tab: String? = nil) -> String? {
        guard pane(paneID) != nil else { return nil }
        counter += 1
        let new = Pane(id: "pane-\(counter)", keptEmpty: tab == nil)
        let splitID = "split-\(counter)"
        root = replacing(paneID, in: root) { old in
            .split(id: splitID, axis: axis, fraction: 0.5, first: .pane(old), second: .pane(new))
        }
        maximized = nil
        if let tab {
            if let source = pane(containing: tab) { take(tab, from: source.id) }
            update(new.id) {
                $0.tabs.append(tab)
                $0.front = tab
            }
            // The pane the tab came from stays, empty if that was its only
            // tab: the user split it on purpose.
            if let left = pane(paneID), left.tabs.isEmpty { update(paneID) { $0.keptEmpty = true } }
        }
        focus(new.id)
        return new.id
    }

    /// Closes a pane. Its tabs are not closed: they join the pane nearest
    /// to it, which takes the keyboard. The only pane is never closed.
    public mutating func close(_ paneID: String) {
        guard isSplit, let closing = pane(paneID) else { return }
        var heir: String?
        root = removing(paneID, from: root, heir: &heir) ?? root
        guard let heir else { return }
        update(heir) {
            for tab in closing.tabs where !$0.tabs.contains(tab) { $0.tabs.append(tab) }
            if $0.front == nil { $0.front = closing.front ?? $0.tabs.first }
            if !$0.tabs.isEmpty { $0.keptEmpty = false }
        }
        if maximized == paneID { maximized = nil }
        if focused == paneID || pane(focused) == nil { focused = heir }
    }

    /// The share the first side of a split has, kept between a tenth and
    /// nine tenths so that neither side disappears.
    public mutating func setFraction(_ splitID: String, _ fraction: Double) {
        let clamped = min(max(fraction, 0.1), 0.9)
        func set(_ node: Node) -> Node {
            switch node {
            case .pane: return node
            case .split(let id, let axis, let old, let first, let second):
                return .split(id: id, axis: axis, fraction: id == splitID ? clamped : old, first: set(first), second: set(second))
            }
        }
        root = set(root)
    }

    /// Shows a pane alone, or all of them again.
    public mutating func toggleMaximized(_ paneID: String) {
        guard pane(paneID) != nil else { return }
        if maximized == paneID {
            maximized = nil
        } else if isSplit {
            maximized = paneID
            focused = paneID
        }
    }

    // MARK: Keeping up with the tabs that exist

    /// Drops tabs that are gone, puts new ones in the pane the keyboard is
    /// in, and orders each pane's tabs as `live` is. A pane left empty by a
    /// tab that went closes, unless it was split off to be given one or it
    /// is the only pane.
    public mutating func sync(with live: [String]) {
        let place = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = Set(allTabs)
        var emptied: [String] = []
        for pane in panes {
            let kept = pane.tabs.filter { place[$0] != nil }.sorted { place[$0]! < place[$1]! }
            if kept != pane.tabs {
                let wasFull = !pane.tabs.isEmpty
                update(pane.id) {
                    $0.tabs = kept
                    if let front = $0.front, !kept.contains(front) {
                        // The tab before the one that went, as a browser does.
                        let before = pane.tabs.prefix { $0 != front }.last { kept.contains($0) }
                        $0.front = before ?? kept.first
                    }
                }
                if kept.isEmpty, wasFull, !pane.keptEmpty { emptied.append(pane.id) }
            }
        }
        let new = live.filter { !placed.contains($0) }
        if !new.isEmpty {
            update(focused) {
                $0.tabs.append(contentsOf: new)
                $0.tabs.sort { place[$0]! < place[$1]! }
                if $0.front == nil { $0.front = new.first }
                $0.keptEmpty = false
            }
        }
        for id in emptied where pane(id)?.tabs.isEmpty == true { close(id) }
    }

    // MARK: The tree

    private mutating func update(_ paneID: String, _ change: (inout Pane) -> Void) {
        func apply(_ node: Node) -> Node {
            switch node {
            case .pane(var pane):
                if pane.id == paneID { change(&pane) }
                return .pane(pane)
            case .split(let id, let axis, let fraction, let first, let second):
                return .split(id: id, axis: axis, fraction: fraction, first: apply(first), second: apply(second))
            }
        }
        root = apply(root)
    }

    /// Takes a tab out of a pane; the pane's front falls back to the tab
    /// before it.
    private mutating func take(_ tab: String, from paneID: String) {
        update(paneID) { pane in
            guard let index = pane.tabs.firstIndex(of: tab) else { return }
            pane.tabs.remove(at: index)
            if pane.front == tab { pane.front = index > 0 ? pane.tabs[index - 1] : pane.tabs.first }
        }
    }

    private func replacing(_ paneID: String, in node: Node, with make: (Pane) -> Node) -> Node {
        switch node {
        case .pane(let pane): return pane.id == paneID ? make(pane) : node
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: fraction, first: replacing(paneID, in: first, with: make), second: replacing(paneID, in: second, with: make))
        }
    }

    /// The tree without a pane: its split gives way to the other side.
    /// `heir` is the pane of that side nearest to where it was.
    private func removing(_ paneID: String, from node: Node, heir: inout String?) -> Node? {
        switch node {
        case .pane(let pane):
            return pane.id == paneID ? nil : node
        case .split(let id, let axis, let fraction, let first, let second):
            if case .pane(let pane) = first, pane.id == paneID {
                heir = edge(of: second, facing: axis == .sideBySide ? .right : .down)
                return second
            }
            if case .pane(let pane) = second, pane.id == paneID {
                heir = edge(of: first, facing: axis == .sideBySide ? .left : .up)
                return first
            }
            if first.contains(paneID) {
                return .split(id: id, axis: axis, fraction: fraction, first: removing(paneID, from: first, heir: &heir) ?? first, second: second)
            }
            return .split(id: id, axis: axis, fraction: fraction, first: first, second: removing(paneID, from: second, heir: &heir) ?? second)
        }
    }
}

/// How an agent's own page and shells are laid out beside it in its tab
/// (#69, #76, #127): the agent on the left, its page on the right, its
/// shell under both, the full width; a part can be hidden. Which page and
/// which shell is picked in the row under the strip. Kept by the Mac app
/// for each agent's session.
public struct AgentArea: Codable, Equatable, Sendable {
    /// The agent's share of the width, beside its page.
    public var across: Double
    /// The share of the height above the shell.
    public var down: Double
    public var shellsHidden: Bool
    public var browserHidden: Bool
    /// The shell shown among the agent's shells, by its tab id.
    public var shellFront: String?
    /// The page shown among the agent's.
    public var browserFront: String?

    public init(across: Double = 0.5, down: Double = 0.64, shellsHidden: Bool = false, browserHidden: Bool = false, shellFront: String? = nil, browserFront: String? = nil) {
        self.across = across
        self.down = down
        self.shellsHidden = shellsHidden
        self.browserHidden = browserHidden
        self.shellFront = shellFront
        self.browserFront = browserFront
    }

    /// The shell shown among `shells` (tab ids in order): the one picked
    /// if it still runs, the last one otherwise.
    public func shownShell(among shells: [String]) -> String? {
        shellFront.flatMap { shells.contains($0) ? $0 : nil } ?? shells.last
    }

    public func shownBrowser(among tabs: [String]) -> String? {
        browserFront.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.last
    }
}

extension TabLayout {
    /// The strip of one pane: its tabs, in the order of the layout.
    public func strip(among tabs: Set<String>) -> [String] { order.filter(tabs.contains) }
}
