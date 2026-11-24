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
    /// Read on some device: read on every one. Nil while it is not.
    public var read: Bool?

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

    /// Whether being handled so makes it read: every way does (#321, the
    /// owner's decision of 2026-11-23), moving on too. An agent that
    /// waits goes on only once someone answered it, often in its session;
    /// one that asks something else has a notice of its own for that.
    public static func reads(_ how: Handled.How) -> Bool { true }

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
    /// How long an agent's notice waits before it is a notification, on
    /// the iPhone and the Mac (#322, the owner's decision of 2026-11-23):
    /// one the user acted on meanwhile is handled, and none is shown.
    public static let alertDelay: TimeInterval = 10

    /// Whether its notification waits `alertDelay`: an agent's does; a
    /// failure that stopped work, which nothing the user does takes away,
    /// is shown at once.
    public var waitsToAlert: Bool {
        if case .agent = kind { return true }
        return false
    }

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

    /// All of what the agent said or asks, its choices with a question's;
    /// what a failure ended and why: for the Inbox, which shows it whole
    /// on both apps (the owner's decision, 2026-11-21). `body` is a
    /// notification's: the last 300 characters (`AgentNotice.detailLength`)
    /// of what an agent said.
    public var fullBody: String {
        switch kind {
        case .agent: return agentNotice?.full?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    /// What the permission is for, in the Mac's Permissions and the
    /// iPhone's first screen (#180).
    public static let permissionTitle = "Know When an Agent Needs You"
    public static let permissionAllow = "Allow Notifications"
    public static let permissionNotNow = "Not Now"
    public static let permissionPurpose =
        "Tells you when an agent is done, asks something or needs your permission, on this device and your others at the same moment."
    public static let macDetail =
        "A macOS notification, with the app in front or not, at once and at the same moment as on the iPhone."
    public static let macHelp =
        "Every paired device is told too. Answered, opened, dismissed or read on one, it goes from all of them, and is read on all. Each device keeps its own Inbox for 30 days."
}

/// What a host's `error` says, in the same words on both apps (#66: a
/// one-off error is always said, never only kept). Most are already
/// sentences for the user; these few are codes.
public enum HostErrorWords {
    public static let olderHost = "The AgentTerm on the Mac is from an older release and cannot do this. Update it, and restart its host."
    /// What a client says, once a connection, when the host sent something
    /// it could not read (#292); it goes on with what it can.
    public static let unreadableMessage = "unreadable message"
    public static let unreadable = "Something the Mac sent could not be read, so what it said is not shown. Restart the host if something looks wrong."
    /// The host's answer to a message larger than it joins (#289).
    public static let tooLargeMessage = "message too large"
    public static let tooLarge = "What was sent to the Mac was larger than 64 MB, so it was not done. Send less at once: a smaller file or picture."

    public static func words(for text: String) -> String {
        switch text {
        case "malformed message": return olderHost
        case "not allowed": return "Only the Mac's own app can do this."
        case unreadableMessage: return unreadable
        case tooLargeMessage: return tooLarge
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
    /// A shell, an agent or anything else that starts a session asked for
    /// while the app is not connected to the host (#202): nothing is
    /// started, nothing waits, and this is said at once.
    public static func notStarted(_ mac: String) -> String {
        "Nothing was started: AgentTerm is not connected to the host on \(mac). Start it again once it is connected; the window says why it is not."
    }

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
