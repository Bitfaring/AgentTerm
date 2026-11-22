import AgentTermProtocol
import Foundation

/// Tells the devices that are away through Apple (#66).
///
/// A device that registers hands the host its device token, a key and its
/// own name for this Mac. The host has the relay sign a ticket for the
/// token, and from then on, while that device is not connected, each notice
/// (`NoticeCenter`) is encrypted with its key and sent to the relay, which
/// passes it on to APNs; one handled elsewhere is taken back the same way.
///
/// Not thread-safe: the host calls it from its queue, and `transport`
/// answers on whatever queue it likes; `HostServer` brings it back.
public final class PushCenter {
    /// What is kept for one device.
    struct Target: Codable, Equatable {
        var token: String
        var key: Data
        var mac: String
        var ticket: String
        var expires: Int
        /// The push token of its Live Activity, and the one that starts
        /// one (#168).
        var activity: String?
        var activityStart: String?
        /// An activity was started through Apple whose token the device
        /// has not given yet (#194): not started again meanwhile, which
        /// would show a second one.
        var activityStarted: Bool?
    }

    /// One request to the relay: its path, the JSON body; answers with the
    /// HTTP status (0 when it was not reached) and the body.
    public typealias Transport = (_ url: URL, _ body: Data, _ done: @escaping (Int, Data?) -> Void) -> Void

    let relay: URL?
    private let file: URL?
    private let transport: Transport
    private(set) var targets: [String: Target] = [:]

    init(relay: URL?, file: URL?, transport: Transport? = nil) {
        self.relay = relay
        self.file = file
        self.transport = transport ?? Self.urlSession
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Target].self, from: data) {
            targets = saved
        }
    }

    // MARK: Registering

    /// What a device that asks is told, before the relay answered.
    var unavailableReason: String? {
        guard relay != nil else { return AppChannel.current == .release ? PushWords.relayNotSetUp : PushWords.notInThisBuild }
        return nil
    }

    func state(of device: String) -> PushState {
        if let reason = unavailableReason { return targets[device] == nil ? .off : .unavailable(reason: reason) }
        return targets[device] == nil ? .off : .on
    }

    /// Has the relay sign a ticket for the device's token, then keeps it.
    func register(_ registration: PushRegistration, device: String, done: @escaping (PushState) -> Void) {
        guard let relay else { return done(.unavailable(reason: unavailableReason ?? PushWords.relayNotSetUp)) }
        guard registration.key.count == 32, !registration.mac.isEmpty else {
            return done(.unavailable(reason: PushWords.registrationFailed("the iPhone's key is not one")))
        }
        let body = try! JSONSerialization.data(withJSONObject: ["token": registration.token])
        transport(relay.appendingPathComponent("v1/register"), body) { [weak self] status, data in
            guard let self else { return }
            guard status == 200, let data, let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ticket = answer["ticket"] as? String, let expires = answer["expires"] as? Int
            else {
                return done(.unavailable(reason: PushWords.registrationFailed(Self.reason(status: status, data: data))))
            }
            self.targets[device] = Target(token: registration.token.lowercased(), key: registration.key, mac: registration.mac, ticket: ticket, expires: expires)
            self.save()
            done(.on)
        }
    }

    /// The Live Activity's tokens of a registered device (#168).
    func setActivity(device: String, token: String?, start: String?) {
        guard var target = targets[device] else { return }
        target.activity = token?.lowercased()
        target.activityStart = start?.lowercased()
        // What it has now is known: what was started is in `token`, or
        // gone.
        target.activityStarted = nil
        targets[device] = target
        save()
    }

    /// The devices whose Live Activity is kept true through Apple.
    var activityDevices: [String] { targets.filter { $0.value.activity != nil || $0.value.activityStart != nil }.map(\.key) }

    /// An update of a device's Live Activity: the host's state now, to its
    /// activity's token, or its end (`end`), after which the token is
    /// forgotten, the activity being gone (#194); or, with none, one that
    /// starts it, when an agent works or waits, once until the device gives
    /// the new activity's token (`setActivity`). Nil when there is nothing
    /// to send. `priority` says how soon Apple is to show it (#233): sent
    /// as `urgent`, which a relay of an earlier release does not read and
    /// sends at 5 as it always did; a start is always high.
    func activity(_ status: AgentsStatus, end: Bool, priority: PushPriority, mac: String, to device: String) -> Push? {
        guard relay != nil, var target = targets[device] else { return nil }
        guard let state = try? JSONSerialization.jsonObject(with: MessageCoding.encode(status)) else { return nil }
        if let token = target.activity {
            let event = end ? "end" : "update"
            if end {
                target.activity = nil
                targets[device] = target
                save()
            }
            let fields: [String: Any] = ["token": token, "event": event, "state": state, "mac": mac, "urgent": priority == .high]
            return request(target, device: device, kind: "activity \(event)", priority: priority, ["activity": fields])
        }
        guard status.isActive, let start = target.activityStart, target.activityStarted != true else { return nil }
        target.activityStarted = true
        targets[device] = target
        save()
        let fields: [String: Any] = ["token": start, "event": "start", "state": state, "mac": mac, "urgent": true]
        return request(target, device: device, kind: "activity start", priority: .high, ["activity": fields])
    }

    func unregister(device: String) {
        guard targets.removeValue(forKey: device) != nil else { return }
        save()
    }

    // MARK: Telling

    /// A push to send: the device, and the request to the relay; what it
    /// is and how soon it is asked to be shown, for the host's log (#233).
    struct Push: Equatable {
        var device: String
        var body: Data
        var kind: String
        /// Nil where the relay alone decides: a notification taken back.
        var priority: PushPriority?
    }

    /// A notice for one device, encrypted with its key; nil when the
    /// device is not registered or there is no relay. Every notice pushed
    /// is one of the high kinds (#233): an agent that asks or is done, a
    /// failure that stopped work (`Notice.alerts`); the relay sends it at
    /// once, with sound, time-sensitive.
    func push(_ notice: Notice, to device: String) -> Push? {
        guard relay != nil, let target = targets[device] else { return nil }
        let identifier = PushNotice.identifier(mac: target.mac, notice: notice.id)
        guard let sealed = try? PushSeal.seal(PushNotice(notice), identifier: identifier, key: target.key) else { return nil }
        return request(target, device: device, kind: "notification", priority: .high, ["payload": sealed, "collapse": identifier])
    }

    /// Takes a notice back from a device it reached through Apple: the
    /// relay wakes the app to take it away (a background push), and, once
    /// the app has the entitlement that lets it, its extension takes it
    /// away without showing anything.
    func takeBack(_ notice: UInt64, from device: String) -> Push? {
        guard relay != nil, let target = targets[device] else { return nil }
        return request(target, device: device, kind: "take back", priority: nil, ["gone": PushNotice.identifier(mac: target.mac, notice: notice)])
    }

    private func request(_ target: Target, device: String, kind: String, priority: PushPriority?, _ fields: [String: Any]) -> Push? {
        var body: [String: Any] = ["token": target.token, "ticket": target.ticket, "expires": target.expires]
        body.merge(fields) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return Push(device: device, body: data, kind: kind, priority: priority)
    }

    /// The line the host's log gets for a push (#233): the device's id cut
    /// short, what it is, how soon; never what it says.
    static func logLine(_ push: Push) -> String {
        let level = push.priority.map { ", \($0.rawValue) (\($0.apns))" } ?? ""
        return "agenttermd: push to \(push.device.prefix(8)): \(push.kind)\(level)\n"
    }

    /// Sends one; `failed` gets the reason in words when it did not go.
    /// A token APNs no longer knows is forgotten: the device registers
    /// again when it comes back.
    func send(_ push: Push, failed: @escaping (_ reason: String, _ forgotten: Bool) -> Void) {
        guard let relay else { return }
        transport(relay.appendingPathComponent("v1/push"), push.body) { [weak self] status, data in
            guard status != 200 else { return }
            let forgotten = status == 410 || status == 401
            if forgotten, let self {
                self.targets[push.device] = nil
                self.save()
            }
            failed(Self.reason(status: status, data: data), forgotten)
        }
    }

    // MARK: Helpers

    static func reason(status: Int, data: Data?) -> String {
        let said = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
        if status == 0 { return said ?? "the relay could not be reached" }
        return said.map { "\($0) (HTTP \(status))" } ?? "HTTP \(status)"
    }

    private func save() {
        guard let file else { return }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(targets) else { return }
        // The keys are secrets: the file is the user's alone.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func urlSession(_ url: URL, _ body: Data, _ done: @escaping (Int, Data?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 0, let error {
                done(0, try? JSONSerialization.data(withJSONObject: ["reason": error.localizedDescription]))
            } else {
                done(status, data)
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }
}
