import Foundation

/// An agent that finished its task or needs an instruction (#22): what the
/// apps tell the user of, once for each time it happens. Worked out by each
/// app from the states the host tells it (#3), so that the session on
/// screen, and a Mac that is in use, can be left out where it is shown.
public struct AgentNotice: Equatable, Sendable {
    public var session: SessionID
    /// The session's name in the lists.
    public var name: String
    /// The folder it runs in.
    public var folder: String
    /// What the agent asks, or that it is done: the state it is in. An
    /// answer names it, so that one that arrives after the agent moved on
    /// is not typed into whatever it asks next.
    public var state: AgentState

    public init(session: SessionID, name: String, folder: String, state: AgentState) {
        self.session = session
        self.name = name
        self.folder = folder
        self.state = state
    }

    /// Why it is told, in a few words: "is done", "needs permission".
    public var why: String {
        switch state {
        case .done: return "is done"
        case .waitingForPermission: return "needs permission"
        case .waitingForAnswer: return "asks a question"
        case .working: return "is working"
        }
    }

    /// What it said or asks, enough to decide without opening it.
    public var detail: String? {
        switch state {
        case .done(let said): return said.flatMap { $0.isEmpty ? nil : String($0.suffix(Self.detailLength)) }
        case .waitingForPermission(let question): return question.text.isEmpty ? nil : question.text
        case .waitingForAnswer(let question):
            return question.text + (question.choices.isEmpty ? "" : "\n" + question.choices.joined(separator: " · "))
        case .working: return nil
        }
    }

    /// How much of what an agent said at the end `detail` gives.
    public static let detailLength = 300

    /// All of what it said or asks, for where there is room to read it:
    /// the Mac's banner once it is opened out (#62). `detail` is the end of
    /// it, which is where an agent comes to the point.
    public var full: String? {
        switch state {
        case .done(let said): return said.flatMap { $0.isEmpty ? nil : $0 }
        case .waitingForPermission, .waitingForAnswer, .working: return detail
        }
    }

    /// Whether `detail` leaves out the beginning of what was said.
    public var detailIsCut: Bool { (full?.count ?? 0) > (detail?.count ?? 0) }

    /// What it said or asks, without the choices: a notification's body,
    /// of which iOS shows a few lines only. The choices are its buttons
    /// (#55), which a long question does not push out of sight.
    public var words: String? {
        switch state {
        case .waitingForAnswer(let question): return question.text.isEmpty ? nil : question.text
        case .done, .waitingForPermission, .working: return detail
        }
    }

    /// A choice of a question, as a button where it is told.
    public struct Button: Equatable, Sendable, Identifiable {
        /// Names the choice by its place among the question's.
        public var id: String
        /// The choice, in the agent's words.
        public var title: String
    }

    /// As many buttons as a notification takes with a text reply beside
    /// them: iOS shows ten actions at most.
    public static let mostButtons = 9

    /// A question's choices, the first `mostButtons` of them. None for a
    /// permission, which is answered in the session.
    public var buttons: [Button] {
        guard case .waitingForAnswer(let question) = state else { return [] }
        return question.choices.prefix(Self.mostButtons).enumerated().map { Button(id: "choice-\($0.offset)", title: $0.element) }
    }

    /// The choice a button stands for, or nil when it is none of this
    /// notice's.
    public func choice(ofButton id: String) -> String? { buttons.first { $0.id == id }?.title }

    /// Whether the user can answer it in a few words where it is told: a
    /// question, or a finished task's next instruction. A permission is
    /// answered in the session, whose choices the agents do not tell.
    public var takesAReply: Bool {
        switch state {
        case .done, .waitingForAnswer: return true
        case .waitingForPermission, .working: return false
        }
    }

    /// What to tell of: each session whose agent is done or waits, in a
    /// state it was not told in before (`told`, which the app keeps across
    /// connections and updates). An agent that becomes done or starts to
    /// wait is told once; one that asks again something else is told
    /// again; one that keeps waiting is not. On connecting, what waits or
    /// is done and was not told yet is told at once.
    public static func notices(in sessions: [SessionInfo], told: inout [SessionID: AgentState]) -> [AgentNotice] {
        var notices: [AgentNotice] = []
        for session in sessions {
            guard let state = session.state else {
                told[session.id] = nil
                continue
            }
            if case .working = state {
                // Working again: what it says next is new.
                told[session.id] = nil
                continue
            }
            guard told[session.id] != state else { continue }
            told[session.id] = state
            notices.append(AgentNotice(session: session.id, name: session.displayName, folder: session.cwd, state: state))
        }
        // Sessions that ended are forgotten.
        let running = Set(sessions.map(\.id))
        told = told.filter { running.contains($0.key) }
        return notices
    }
}

/// What the Live Activity shows (#24, #168): the host's state now, a count
/// of each kind, and the names of the sessions that wait or are done. Never
/// what an agent said: it is on the lock screen. The same struct is the
/// activity's content and what the host pushes for it.
public struct AgentsStatus: Codable, Hashable, Sendable {
    public var working: Int
    public var permission: Int
    public var asking: Int
    /// Done and not seen on any device (`SessionInfo.unseen`).
    public var done: Int
    /// The host or a session's program stopped, not dismissed yet.
    public var failed: Int
    /// The names of the sessions that wait, the first one's number.
    public var waiting: [String]
    public var firstWaiting: UInt32?
    public var doneNames: [String]

    public init(
        working: Int = 0, permission: Int = 0, asking: Int = 0, done: Int = 0, failed: Int = 0, waiting: [String] = [], firstWaiting: UInt32? = nil,
        doneNames: [String] = []
    ) {
        self.working = working
        self.permission = permission
        self.asking = asking
        self.done = done
        self.failed = failed
        self.waiting = waiting
        self.firstWaiting = firstWaiting
        self.doneNames = doneNames
    }

    public static func of(sessions: [SessionInfo], failures: [PartFailure]) -> AgentsStatus {
        let waiting = sessions.filter { $0.state?.isWaiting == true }
        let done = sessions.filter { session in
            if case .done = session.state { return session.unseen == true }
            return false
        }
        return AgentsStatus(
            working: sessions.filter { $0.state?.isWorking == true }.count,
            permission: sessions.filter { if case .waitingForPermission = $0.state { return true } else { return false } }.count,
            asking: sessions.filter { if case .waitingForAnswer = $0.state { return true } else { return false } }.count,
            done: done.count, failed: failures.filter { $0.part == .host || $0.part == .session }.count,
            waiting: Array(waiting.map(\.displayName).prefix(5)), firstWaiting: waiting.first?.id, doneNames: Array(done.map(\.displayName).prefix(5)))
    }

    /// An agent works or waits: it is shown.
    public var isActive: Bool { working + permission + asking > 0 }

    /// "2 working · 1 needs permission · 1 asks · 3 done · 1 stopped".
    public var summary: String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if permission > 0 { parts.append(permission == 1 ? "1 needs permission" : "\(permission) need permission") }
        if asking > 0 { parts.append(asking == 1 ? "1 asks" : "\(asking) ask") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) stopped") }
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    /// The words of its switch and of the activity (principle 9).
    public static let title = "Agents on"
    public static let toggle = "Live Activity of the Mac's agents"
    /// Beside the switch while iOS stops it (#212).
    public static let notAllowed = "Live Activities are turned off for AgentTerm in the iPhone's Settings."
}

/// When the iPhone shows the Live Activity of the agents on a Mac (#168,
/// decided 2026-11-19): while an agent works or waits, whether someone is
/// at the Mac or not, and whether the phone is connected or not, the host
/// keeping it true through Apple. One activity is kept between turns and
/// only updated (#180, decided 2026-11-20): with nothing working or
/// waiting it says so, and ends only once that has lasted `keptIdle`.
public enum LiveActivityRule {
    public enum Decision: Equatable, Sendable {
        /// Shown, or kept up to date.
        case show
        /// Ended at once: no one wants it.
        case endNow
        /// Every agent has been done for `keptIdle`: the last state may
        /// stay, since it stays true.
        case endShowingDone
    }

    /// How long it stays, updated, with nothing working or waiting.
    public static let keptIdle: TimeInterval = 15 * 60

    /// `idleSince`: when nothing has worked or waited since; nil while
    /// something does.
    public static func decide(
        enabled: Bool, status: AgentsStatus, idleSince: Date? = nil, now: Date = Date(), keptIdle: TimeInterval = keptIdle
    ) -> Decision {
        guard enabled else { return .endNow }
        if status.isActive { return .show }
        guard let idleSince, now.timeIntervalSince(idleSince) < keptIdle else { return .endShowingDone }
        return .show
    }
}
