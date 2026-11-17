import Foundation

/// What needs the user on the Mac on show (#67): the Mac's Inbox, a place of
/// its own in the window's rail, and the Inbox at the top of the iPhone's
/// Sessions list. Worked out the same way by both apps, from what the host
/// tells every device: the sessions, each done one with whether a device has
/// shown it since (`SessionInfo.unseen`), and the parts that stopped.
public struct InboxItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An agent that waits for a permission or an answer, until it is
        /// answered; or one that is done, until a device shows its session.
        case session(SessionInfo)
        /// A part of AgentTerm that stopped, until it is dismissed.
        case failure(PartFailure)
    }

    public var kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var id: String {
        switch kind {
        case .session(let session): return "session-\(session.id)"
        case .failure(let failure): return "failure-\(failure.id)"
        }
    }

    /// What the agent asks, or that it is done, as the notices say it.
    public var notice: AgentNotice? {
        guard case .session(let session) = kind, let state = session.state else { return nil }
        return AgentNotice(session: session.id, name: session.displayName, folder: session.cwd, state: state)
    }

    /// Whether the item can be dismissed: a done session, or a failure. A
    /// question stays until it is answered.
    public var canBeDismissed: Bool {
        switch kind {
        case .session(let session): return session.state?.isWaiting != true
        case .failure: return true
        }
    }
}

public enum Inbox {
    /// Its name, on both apps.
    public static let title = "Inbox"
    public static let empty = "Nothing needs you. An agent that waits for you, or is done, shows here."
    public static let next = "Next"
    public static let dismiss = "Dismiss"
    public static let open = "Open"
    /// Why a failure is in it.
    public static let stopped = "Stopped"
    /// The heading over what a done agent said, and over what one asks.
    public static let said = "What it said"
    public static let asks = "What it asks"
    public static let choices = "Its choices"
    public static let nothingSaid = "The agent did not say what it did."

    /// What needs the user, the most pressing first: the agents that wait,
    /// then what stopped, then the agents that are done and not looked at;
    /// each in the order the host lists them. An agent whose state is not
    /// known is not listed.
    public static func items(sessions: [SessionInfo], failures: [PartFailure]) -> [InboxItem] {
        let waiting = sessions.filter { $0.state?.isWaiting == true }
        let done = sessions.filter { session in
            guard case .done? = session.state else { return false }
            return session.unseen == true
        }
        return waiting.map { InboxItem(.session($0)) } + failures.map { InboxItem(.failure($0)) } + done.map { InboxItem(.session($0)) }
    }

    /// The item to go to after `current`: the next one, the first after the
    /// last, or the first when `current` is not in the list any more.
    public static func item(after current: String?, in items: [InboxItem]) -> InboxItem? {
        guard let current, let index = items.firstIndex(where: { $0.id == current }) else { return items.first }
        return items[(index + 1) % items.count]
    }
}
