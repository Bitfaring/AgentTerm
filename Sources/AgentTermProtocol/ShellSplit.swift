import Foundation

/// The parts of a split Shells tab (the owner's request, 2026-11-21): the
/// shell picked on the left, as an agent is in its area, a shell on the
/// right and one below, each turned on and off from the end of the row.
/// Shells only: the Browser tab is not split.
public enum ShellPart: String, Hashable, Sendable {
    case main, right, below
}

/// What a split Shells tab shows besides its shell picked, and the shares
/// its dividers give. The Mac app keeps one for each of the user's Shells
/// tabs; the iPhone has none.
///
/// Every answer takes the tab's shells (`members`, in the row's order) and
/// the one picked, which the left shows (`picked`, the Mac's `groupShown`).
/// A shell is never shown in two parts.
public struct ShellSplit: Equatable, Sendable {
    /// The shell on the right, by its tab id.
    public var right: String?
    /// The shell below the others.
    public var below: String?
    /// The left's share of the width, beside the right.
    public var across = 0.5
    /// The share of the height above the one below.
    public var down = 0.62
    /// Parts turned on while no shell was left to show: each waits for the
    /// shell launched for it, in the order they were turned on.
    public private(set) var waits: [Wait] = []

    /// A part waiting for the shell launched for it (#189), known by the
    /// number the launch was asked with (`CreateRequest.requestID`), which
    /// the host gives back with the session it made (`attached`) or with
    /// its refusal (`error`). A shell started elsewhere meanwhile (File >
    /// New Shell, the iPhone) is never the one it waits for.
    public struct Wait: Equatable, Sendable {
        public let part: ShellPart
        public let request: Int
        /// The shell made for it, by its tab id, once the host said which.
        public fileprivate(set) var shell: String?
    }

    /// What turning a part on did.
    public enum TurnedOn: Equatable, Sendable {
        /// It shows a shell that was not on show.
        case shown(String)
        /// None was left: it waits for the shell the caller launches with
        /// the request number it gave.
        case waiting
    }

    public init(right: String? = nil, below: String? = nil) {
        self.right = right
        self.below = below
    }

    /// The parts that show a shell: the left, and the right and the one
    /// below while they are turned on with a shell still there.
    public func parts(in members: [String]) -> [ShellPart] {
        var parts: [ShellPart] = [.main]
        if let right, members.contains(right) { parts.append(.right) }
        if let below, members.contains(below) { parts.append(.below) }
        return parts
    }

    /// The shell a part shows. The left's is the one picked, else the first
    /// not shown in another part: never one the right or below shows, even
    /// when none is left for it (#188).
    public func shell(in part: ShellPart, picked: String?, members: [String]) -> String? {
        switch part {
        case .right: return right.flatMap { members.contains($0) ? $0 : nil }
        case .below: return below.flatMap { members.contains($0) ? $0 : nil }
        case .main:
            let others = Set(parts(in: members).filter { $0 != .main }.compactMap { shell(in: $0, picked: nil, members: members) })
            if let picked, members.contains(picked), !others.contains(picked) { return picked }
            return members.first { !others.contains($0) }
        }
    }

    /// The shells on show, as the row marks them.
    public func onShow(picked: String?, members: [String]) -> Set<String> {
        Set(parts(in: members).compactMap { shell(in: $0, picked: picked, members: members) })
    }

    /// Shows a shell in a part, the part turned on if it was off. One shown
    /// in another part changes places with what the part showed; when that
    /// part was off (#188), the left it leaves takes the first shell not on
    /// show, and the right or below it leaves is turned off. False when it
    /// is refused, nothing changed: the left's shell, with none free to
    /// take its place (`ShellSplitWords.leftKeepsIt`).
    public mutating func show(_ item: String, in part: ShellPart, picked: inout String?, members: [String]) -> Bool {
        guard members.contains(item) else { return false }
        let before = shell(in: part, picked: picked, members: members)
        let from = parts(in: members).first { shell(in: $0, picked: picked, members: members) == item }
        if let from, from != part {
            if let before {
                set(from, before, picked: &picked)
            } else if from == .main {
                let shown = onShow(picked: picked, members: members)
                guard let free = members.first(where: { !shown.contains($0) }) else { return false }
                picked = free
            } else {
                set(from, nil, picked: &picked)
            }
        }
        set(part, item, picked: &picked)
        return true
    }

    /// Turns the right or the one below on, with a shell not on show; or,
    /// when none is left, has it wait for the new one the caller launches
    /// with `request`, a number of its own for each launch (#189).
    public mutating func turnOn(_ part: ShellPart, picked: String?, members: [String], request: Int) -> TurnedOn {
        if part == .main || parts(in: members).contains(part), let shown = shell(in: part, picked: picked, members: members) { return .shown(shown) }
        let shown = onShow(picked: picked, members: members)
        if let free = members.first(where: { !shown.contains($0) }) {
            var picked = picked
            set(part, free, picked: &picked)
            return .shown(free)
        }
        waits.removeAll { $0.part == part }
        waits.append(Wait(part: part, request: request))
        return .waiting
    }

    /// Turns the right or the one below off, its shell still running and
    /// still in the row; a part waiting for a new shell waits no more.
    public mutating func turnOff(_ part: ShellPart) {
        switch part {
        case .main: return
        case .right: right = nil
        case .below: below = nil
        }
        waits.removeAll { $0.part == part }
    }

    /// The host made the shell of a launch, and gave its request back
    /// (#189): the part waiting for it shows it once it is in the row.
    /// False when no part of this tab waits for that request.
    @discardableResult
    public mutating func launched(request: Int, shell: String) -> Bool {
        guard let index = waits.firstIndex(where: { $0.request == request && $0.shell == nil }) else { return false }
        waits[index].shell = shell
        return true
    }

    /// A shell put in front, or new in the row: the part waiting for it,
    /// the one it was launched for, shows it (#189). A shell launched for
    /// no part, new to the tab or not, is never taken. The part, or nil
    /// when none took it.
    public mutating func takeNew(_ item: String, picked: String?, members: [String]) -> ShellPart? {
        guard members.contains(item), !onShow(picked: picked, members: members).contains(item),
            let index = waits.firstIndex(where: { $0.shell == item })
        else { return nil }
        let part = waits.remove(at: index).part
        var picked = picked
        set(part, item, picked: &picked)
        return part
    }

    /// The launch asked with this request failed, said by the host's error
    /// for it: the part waiting for it waits no more, the others still do.
    public mutating func stopWaiting(request: Int) { waits.removeAll { $0.request == request } }

    /// No part waits any more: the connection to the host went.
    public mutating func stopWaiting() { waits = [] }

    /// After the tab's shells changed: a part whose shell ended closes; a
    /// part waiting takes the shell launched for it, put in front or not
    /// (#189), and waits no more when that shell is not in the tab (it
    /// ended before it was shown, or was started in another folder); and
    /// the left, its shell ended with every other one on show, takes the
    /// right's, else the one below, which closes (#188).
    public mutating func tidy(picked: inout String?, members: [String]) {
        if let right, !members.contains(right) { self.right = nil }
        if let below, !members.contains(below) { self.below = nil }
        for wait in waits { if let shell = wait.shell { _ = takeNew(shell, picked: picked, members: members) } }
        waits.removeAll { $0.shell.map { !members.contains($0) } ?? false }
        if shell(in: .main, picked: picked, members: members) == nil, let moved = right ?? below {
            set(moved == right ? .right : .below, nil, picked: &picked)
            picked = moved
        }
    }

    private mutating func set(_ part: ShellPart, _ shell: String?, picked: inout String?) {
        switch part {
        case .main: picked = shell
        case .right: right = shell
        case .below: below = shell
        }
        waits.removeAll { $0.part == part }
    }
}

/// What a shell's menu in the row of a Shells tab says, and why a move it
/// asks for is refused (principle 9).
public enum ShellSplitWords {
    public static let left = "Show on the Left"
    public static let right = "Show on the Right"
    public static let below = "Show Below"
    /// The left's shell asked to move to a part that was off, with no other
    /// shell free to take its place on the left (#188).
    public static let leftKeepsIt = "The left always shows a shell, and this tab has none free to take this one's place. Open another shell first."
}
