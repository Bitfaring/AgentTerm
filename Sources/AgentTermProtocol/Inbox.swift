import Foundation

/// An item of a device's Inbox (#67; since #66 a history, `InboxBook`): the
/// Mac's Inbox, a place of its own in the window's rail, and the Inbox of
/// the iPhone's Sessions list. Worked out the same way by both apps.
public struct InboxItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An agent that waits for a permission or an answer, until it is
        /// answered; or one that is done, until a device shows its session.
        case session(SessionInfo)
        /// A part of AgentTerm that stopped, until it is dismissed.
        case failure(PartFailure)
        /// What was told and is over: an agent that moved on, a session
        /// that ended (#66).
        case notice(Notice)
    }

    public var kind: Kind
    /// The entry of the device's Inbox it stands for.
    public var entry: InboxBook.Entry?

    public init(_ kind: Kind, entry: InboxBook.Entry? = nil) {
        self.kind = kind
        self.entry = entry
    }

    public var id: String {
        if let entry { return "notice-\(entry.id)" }
        switch kind {
        case .session(let session): return "session-\(session.id)"
        case .failure(let failure): return "failure-\(failure.id)"
        case .notice(let notice): return "notice-\(notice.id)"
        }
    }

    public var read: Bool { entry?.read ?? false }

    /// What the agent asks, or that it is done, as the notices say it.
    public var notice: AgentNotice? {
        switch kind {
        case .session(let session):
            guard let state = session.state else { return nil }
            return AgentNotice(session: session.id, name: session.displayName, folder: session.cwd, state: state)
        case .notice(let notice): return notice.agentNotice
        case .failure: return nil
        }
    }

    /// Whether the item can be taken out: deleted from this device's Inbox,
    /// unless its agent still waits for an answer.
    public var canBeDismissed: Bool {
        if let entry { return entry.canBeDeleted }
        switch kind {
        case .session(let session): return session.state?.isWaiting != true
        case .failure, .notice: return true
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

    // MARK: A row of the list (#218)

    /// How many lines of what was said a row of the list shows: the end of
    /// it, with "…" in front when the beginning is left out. All of it is
    /// in the item's detail (the owner's decision, 2026-11-21, in place of
    /// the one of the same day that had a row show all of it).
    public static let rowLines = 3
    /// What marks the beginning that a row leaves out.
    public static let cutMark = "…"
    /// The most a row is given to show, in characters: more than three
    /// lines hold on either app.
    public static let rowLength = 300

    /// What a row may show of `full`, the longest first, for the app to
    /// take the first that fits in `rowLines` lines at the width it has:
    /// the whole of it when it is short, else its end, begun at a word,
    /// with `cutMark` in front. Line breaks become spaces, so that an
    /// answer's last paragraphs are not three short lines. Never empty
    /// unless `full` is, and no text is in it twice.
    public static func rowTexts(_ full: String) -> [String] {
        let text = full.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return [] }
        var texts: [String] = []
        // In steps small enough that the one taken about fills the lines:
        // the Mac's list holds some 27 letters a line, the iPhone's 45.
        for length in [rowLength, 260, 220, 190, 160, 140, 120, 105, 90, 80, 70, 60, 50, 40] {
            guard text.count > length else {
                if texts.isEmpty { texts.append(text) }
                continue
            }
            var end = text.suffix(length)
            // Begun at a word, when one begins in its first third.
            if let space = end.firstIndex(of: " "), end.distance(from: end.startIndex, to: space) < length / 3 {
                end = end[end.index(after: space)...]
            }
            // Two lengths may come to the same text once begun at a word:
            // it is given once, as the Mac's row names each by its text
            // and one given twice crashed the app (#240). The texts get
            // shorter, each the end of `text`, so the same one is the last.
            let cut = cutMark + end
            if texts.last != cut { texts.append(cut) }
        }
        return texts
    }

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

    /// A device's Inbox, newest first (#66): a notice whose agent still says
    /// it is shown with its session, where it is answered or continued; one
    /// whose failure is still reported, with the failure; the rest as they
    /// were told.
    public static func items(book: InboxBook, sessions: [SessionInfo], failures: [PartFailure]) -> [InboxItem] {
        book.entries.map { entry in
            let notice = entry.notice
            if notice.handled == nil, let session = notice.session, let info = sessions.first(where: { $0.id == session }), info.state == notice.state {
                return InboxItem(.session(info), entry: entry)
            }
            if case .failure(let failure) = notice.kind {
                return InboxItem(.failure(failures.first { $0.id == failure.id } ?? failure), entry: entry)
            }
            return InboxItem(.notice(notice), entry: entry)
        }
    }

    /// The item to go to after `current`: the next one, the first after the
    /// last, or the first when `current` is not in the list any more.
    public static func item(after current: String?, in items: [InboxItem]) -> InboxItem? {
        guard let current, let index = items.firstIndex(where: { $0.id == current }) else { return items.first }
        return items[(index + 1) % items.count]
    }
}
