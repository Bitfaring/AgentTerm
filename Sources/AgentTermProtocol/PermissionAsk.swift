import Foundation

/// A permission the system asks the user for once, as iOS asks whether an
/// app may notify: what each caller that wants to know is to do.
///
/// The first caller has the system asked. Every caller that comes while
/// the system's question is open waits for its answer (#200): the
/// settings say "not determined" until the user has answered, and a
/// caller that read them then was told no although the user may be about
/// to allow. Once it is answered, the settings are read. While the app's
/// own switch is off nobody has the system asked (#195): each is told no.
/// `Done` is what a caller is told through.
public struct PermissionAsk<Done> {
    /// What to do for a caller.
    public enum Step: Equatable {
        /// Tell it no: the app's switch is off.
        case refuse
        /// Ask the system; the caller is kept, to be told its answer.
        case request
        /// Nothing yet: the caller is kept, to be told the answer of the
        /// question that is open.
        case wait
        /// Read what the system was told, and tell the caller.
        case readSettings
    }

    private enum State {
        case notAsked
        /// The system's question is open; who waits for its answer.
        case asking([Done])
        case answered
    }

    private var state = State.notAsked

    public init() {}

    /// One more caller, with whether the app's switch is on.
    public mutating func ask(_ done: Done, switchedOn: Bool) -> Step {
        guard switchedOn else { return .refuse }
        switch state {
        case .notAsked:
            state = .asking([done])
            return .request
        case .asking(let waiting):
            state = .asking(waiting + [done])
            return .wait
        case .answered:
            return .readSettings
        }
    }

    /// The system's question answered: who is to be told, first caller first.
    public mutating func answered() -> [Done] {
        guard case .asking(let waiting) = state else { return [] }
        state = .answered
        return waiting
    }
}
