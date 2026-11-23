import CryptoKit
import Foundation

// Notices through Apple's push service while the iPhone app is not running
// (#66). The host encrypts each notice for one device with a key that device
// gave it, a relay that holds the APNs key passes it on to Apple, and the
// iPhone's notification service extension decrypts it. Neither the relay nor
// Apple can read it.

/// What a device hands its host to be told through Apple.
public struct PushRegistration: Codable, Equatable, Sendable {
    /// The device token APNs gave the app, in hex.
    public var token: String
    /// The key notices for this device are encrypted with (AES-256-GCM),
    /// made by the device for this Mac alone.
    public var key: Data
    /// The device's own name for this Mac (its `SavedHost.id`), by which
    /// its extension finds the key and the Mac's name.
    public var mac: String

    public init(token: String, key: Data, mac: String) {
        self.token = token
        self.key = key
        self.mac = mac
    }
}

/// Whether a device is told through Apple while its app is closed, as the
/// host it registered with sees it.
public enum PushState: Codable, Equatable, Sendable {
    /// Not asked for.
    case off
    /// Registered: notices go through Apple while the device is away.
    case on
    /// It cannot be, for `reason`, in words for the user.
    case unavailable(reason: String)

    /// The words of the switch's footnote, the same on both apps.
    public var footnote: String? {
        switch self {
        case .off: return nil
        case .on: return PushWords.on
        case .unavailable(let reason): return reason
        }
    }
}

/// The sentences about push the apps show (principle 9).
public enum PushWords {
    public static let toggle = "Also While the App Is Closed"
    public static let on =
        "Told through Apple's push service while the app is closed. What it says is encrypted on the Mac for this iPhone; Apple and AgentTerm's relay see that a notification was sent, when, and its size, not what it says."
    public static let notInThisBuild = "This build has no push: it comes only with the released app."
    public static let relayNotSetUp = "The Mac's host has no push relay set up."
    public static let notAllowed = "Notifications are turned off for AgentTerm in the iPhone's Settings."
    public static func registrationFailed(_ reason: String) -> String {
        "The push relay could not be reached: \(reason). Notifications come only while the app runs."
    }
    public static func tokenRefused(_ reason: String) -> String { "iOS gave this iPhone no push token: \(reason)" }
    public static let keyNotKept = "This build cannot keep the key its notification extension needs."
    /// A reply from a notification to an agent that asks something else by now.
    public static let movedOn = "The agent has moved on since: the reply was not sent."
    public static let sessionEnded = "That session has ended."
    public static let macForgotten = "That notification is from a Mac this iPhone is no longer paired with."
    /// What a notification says when it cannot be decrypted.
    public static let fallbackTitle = "AgentTerm"
    public static let fallbackBody = "An agent needs you"
}

/// A notice as it travels encrypted: what the extension shows. A push holds
/// 4 KB, so what the agent said or asks is shortened to what a
/// notification shows; `stateDigest` names the whole of it, by which a
/// reply from the notification is sent only while the agent still says
/// exactly that.
public struct PushNotice: Codable, Equatable, Sendable {
    /// The host's number for the notice (`Notice.id`).
    public var id: UInt64
    public var session: SessionID?
    public var name: String
    public var folder: String
    /// The state, shortened (`shortened`); nil for a failure.
    public var state: AgentState?
    public var stateDigest: String?
    /// A failure's headline and what it ended.
    public var title: String?
    public var body: String?

    public init(_ notice: Notice) {
        id = notice.id
        session = notice.session
        name = String(notice.name.prefix(100))
        folder = String(notice.folder.suffix(200))
        state = notice.state.map(Self.shortened)
        stateDigest = notice.state.map(Self.digest)
        if case .failure(let failure) = notice.kind {
            title = String(failure.headline().prefix(200))
            body = String(failure.details.prefix(600))
        }
        fitInAPush()
    }

    /// How many bytes of JSON a notice may be: sealed (a nonce and a tag
    /// of 28 bytes) and in base64, at most the relay's 3,000 characters.
    public static let mostBytes = 2_200

    /// Shortens what it says until it is no more than `mostBytes` of JSON
    /// (#294): the lengths above are in characters, and a character of
    /// Japanese or Chinese is three bytes. Each round keeps of every text
    /// the share that would fit, so none is cut much more than the others.
    private mutating func fitInAPush() {
        for _ in 0..<8 {
            guard let size = try? JSONEncoder().encode(self).count, size > Self.mostBytes else { return }
            let share = Double(Self.mostBytes) / Double(size) * 0.95
            func cut(_ text: String) -> String { String(text.prefix(Int(Double(text.count) * share))) }
            name = cut(name)
            folder = String(folder.suffix(Int(Double(folder.count) * share)))
            title = title.map(cut)
            body = body.map(cut)
            if let shortened = state {
                func question(_ asked: AgentQuestion) -> AgentQuestion { AgentQuestion(text: cut(asked.text), choices: asked.choices.map(cut)) }
                switch shortened {
                case .done(let said): state = .done(said: said.map { String($0.suffix(Int(Double($0.count) * share))) })
                case .waitingForPermission(let asked): state = .waitingForPermission(question(asked))
                case .waitingForAnswer(let asked): state = .waitingForAnswer(question(asked))
                case .working: break
                }
            }
        }
    }

    /// What an agent's notice says and offers, with the shortened state;
    /// nil for a failure, whose `title` and `body` are said instead.
    public var agentNotice: AgentNotice? {
        guard let state, let session else { return nil }
        return AgentNotice(session: session, name: name, folder: folder, state: state)
    }

    /// As much of a state as a notification shows.
    public static func shortened(_ state: AgentState) -> AgentState {
        func cut(_ question: AgentQuestion) -> AgentQuestion {
            AgentQuestion(text: String(question.text.prefix(500)), choices: question.choices.prefix(AgentNotice.mostButtons).map { String($0.prefix(80)) })
        }
        switch state {
        case .done(let said): return .done(said: said.map { String($0.suffix(AgentNotice.detailLength)) })
        case .waitingForPermission(let question): return .waitingForPermission(cut(question))
        case .waitingForAnswer(let question): return .waitingForAnswer(cut(question))
        case .working: return state
        }
    }

    /// Names a state, the same on every device.
    public static func digest(_ state: AgentState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(state)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The name APNs gives the notification (`apns-collapse-id`), the same
    /// the app gives one it makes itself, so that one replaces the other
    /// rather than showing twice. It is not secret: the device's own name
    /// for the Mac, and the notice's number.
    public static func identifier(mac: String, notice: UInt64) -> String { "\(mac)-\(notice)" }

    /// The Mac's name and the notice back from an identifier.
    public static func parse(identifier: String) -> (mac: String, notice: UInt64)? {
        guard let dash = identifier.lastIndex(of: "-"), let notice = UInt64(identifier[identifier.index(after: dash)...]) else { return nil }
        let mac = String(identifier[..<dash])
        return mac.isEmpty ? nil : (mac, notice)
    }
}

public enum PushSeal {
    public enum Failure: Error, Equatable {
        case badKey
        case unreadable
    }

    /// A new key for one device and one Mac.
    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// The notice encrypted for the device with `key`, in base64, bound to
    /// its identifier: one moved to another notification does not open.
    public static func seal(_ notice: PushNotice, identifier: String, key: Data) throws -> String {
        guard key.count == 32 else { throw Failure.badKey }
        let plain = try JSONEncoder().encode(notice)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: Data(identifier.utf8))
        guard let combined = box.combined else { throw Failure.unreadable }
        return combined.base64EncodedString()
    }

    public static func open(_ sealed: String, identifier: String, key: Data) throws -> PushNotice {
        guard key.count == 32 else { throw Failure.badKey }
        guard let data = Data(base64Encoded: sealed), let box = try? AES.GCM.SealedBox(combined: data),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(identifier.utf8)),
            let notice = try? JSONDecoder().decode(PushNotice.self, from: plain)
        else { throw Failure.unreadable }
        return notice
    }
}

/// The relay of each build. The development build has none (principle 7,
/// and #66: push is tried on TestFlight builds only).
public enum PushRelay {
    /// Where the released host sends pushes: the relay deployed on
    /// 2026-11-19 (relay/README.md).
    public static let release: URL? = URL(string: "https://agentterm-push.agentterm.workers.dev")

    public static func url(for channel: AppChannel) -> URL? { channel == .release ? release : nil }
}
