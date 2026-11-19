import Foundation

/// Something the user is told of without asking (#66, decided 2026-11-19):
/// an agent that asks, needs permission or is done, or a failure that
/// stopped work. The host makes each one once and tells every device; once
/// it is handled on one (answered, opened, dismissed) or its agent has
/// moved on, it is handled on all. The host keeps the last 30 days of them,
/// from which each device keeps an Inbox of its own.
public struct Notice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        /// An agent in this state: done, waiting for permission or asking.
        case agent(AgentState)
        /// A failure: a notification too when it stopped work (`alerts`).
        case failure(PartFailure)
    }

    public struct Handled: Codable, Equatable, Hashable, Sendable {
        public enum How: String, Codable, Equatable, Hashable, Sendable {
            /// A reply was typed into the session.
            case answered
            /// Its session was opened on a device.
            case opened
            /// Dismissed on a device, from a notification or the Inbox.
            case dismissed
            /// The agent works again, or asks something else, or the session ended.
            case movedOn
        }

        public var at: Date
        public var how: How

        public init(at: Date, how: How) {
            self.at = at
            self.how = how
        }
    }

    /// The host's own number for it, never used again.
    public var id: UInt64
    public var at: Date
    /// The session it is about; nil for a failure of the host.
    public var session: SessionID?
    /// The session's name in the lists, or the failure's part.
    public var name: String
    /// The folder the session runs in; empty for a failure.
    public var folder: String
    public var kind: Kind
    public var handled: Handled?

    public init(id: UInt64, at: Date, session: SessionID?, name: String, folder: String, kind: Kind, handled: Handled? = nil) {
        self.id = id
        self.at = at
        self.session = session
        self.name = name
        self.folder = folder
        self.kind = kind
        self.handled = handled
    }

    /// How long the host keeps them, and a device's Inbox too.
    public static let kept: TimeInterval = 30 * 24 * 3600

    /// What a notice about an agent says and offers: the words of #22.
    public var agentNotice: AgentNotice? {
        guard case .agent(let state) = kind, let session else { return nil }
        return AgentNotice(session: session, name: name, folder: folder, state: state)
    }

    public var state: AgentState? {
        if case .agent(let state) = kind { return state }
        return nil
    }

    /// Whether it is a notification too, or a banner and an Inbox item
    /// only: every agent's, and a failure that stopped work.
    public var alerts: Bool {
        switch kind {
        case .agent: return true
        case .failure(let failure): return Self.tells(failure)
        }
    }

    /// Whether a failure is told as a notification as well as in the banner
    /// and the Inbox: one that stopped work (the owner's decision,
    /// 2026-11-19). The others are banners and Inbox items only.
    public static func tells(_ failure: PartFailure) -> Bool {
        switch failure.part {
        case .host, .session, .schedule: return true
        default: return false
        }
    }

    // MARK: In words, the same on every device (principle 9)

    /// "Fix the build asks a question"; a failure's headline.
    public func title(on mac: String? = nil) -> String {
        switch kind {
        case .agent: return agentNotice.map { "\($0.name) \($0.why)" } ?? name
        case .failure(let failure): return failure.headline(on: mac)
        }
    }

    /// What the agent said or asks, without the choices; what a failure
    /// ended and why.
    public var body: String {
        switch kind {
        case .agent: return agentNotice?.words ?? ""
        case .failure(let failure): return failure.details
        }
    }

    /// "app on Studio": where it happened.
    public func place(macName: String) -> String {
        folder.isEmpty ? macName : "\((folder as NSString).lastPathComponent) on \(macName)"
    }

    /// What the Inbox says of how it was handled.
    public var handledWords: String? {
        guard let handled else { return nil }
        switch handled.how {
        case .answered: return "Answered"
        case .opened: return "Opened"
        case .dismissed: return "Dismissed"
        case .movedOn: return state == nil ? "Over" : "The agent moved on"
        }
    }
}

/// The words of the Inbox, the same on both apps.
public enum InboxWords {
    public static let deleteOne = "Delete"
    public static let deleteRead = "Delete Read"
    public static let deleteAll = "Delete All"
    public static let deleteAllQuestion = "Delete everything in the Inbox on this device?"
    public static let waitingCannotBeDeleted = "An agent still waits for an answer to this: it can be deleted once it is answered."
    public static let empty = "Nothing yet. What agents ask and finish, and what stops, is kept here for 30 days."
}

/// The words of the notifications' switches (#66).
public enum NoticeWords {
    public static let macToggle = "Notify when an agent is done or needs you"
    public static let macDetail = "A macOS notification while the app is not in front; a banner while it is."
    public static let macHelp =
        "Every paired device is told too. Answered, opened or dismissed on one, it goes from all of them. Each device keeps its own Inbox for 30 days."
}

/// What a host's `error` says, in the same words on both apps (#66: a
/// one-off error is always said, never only kept). Most are already
/// sentences for the user; these few are codes.
public enum HostErrorWords {
    public static let olderHost = "The AgentTerm on the Mac is from an older release and cannot do this. Update it, and restart its host."

    public static func words(for text: String) -> String {
        switch text {
        case "malformed message": return olderHost
        case "not allowed": return "Only the Mac's own app can do this."
        default: return text
        }
    }
}

/// The ongoing states both apps show, in the same words and with the same
/// buttons (#66, decided 2026-11-19): connecting, not reachable, another
/// release. Each app places them where its screen has room.
public enum StateWords {
    public static func connecting(to mac: String) -> String { "Connecting to \(mac)…" }
    public static func cantReach(_ mac: String) -> String { "Can't reach \(mac)" }
    public static func reachAdvice(_ mac: String) -> String {
        "Check that Tailscale is connected on this device and on \(mac), and that AgentTerm is open there."
    }
    public static let tryAgain = "Try Again"

    public static func versionTitle(_ match: ProtocolMatch, mac: String) -> String {
        match == .hostOlder ? "AgentTerm on \(mac) is from an older release" : "This app is older than AgentTerm on \(mac)"
    }

    public static func versionDetail(_ match: ProtocolMatch, mac: String) -> String {
        match == .hostOlder
            ? "Update AgentTerm on \(mac). If it was just updated, restart its host there. Until then some things will not work."
            : "Update this app to the release that goes with \(mac)'s. Until then some things will not work."
    }

    /// The button that takes back a session's size from another device.
    public static let useThisSize = "Use This Size"
}
