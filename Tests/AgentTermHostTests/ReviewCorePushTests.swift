import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// #267 (review of 2026-11-22): what the relay answers is put into the push
/// targets where the answer arrives, not on the host's queue, and without
/// looking whether the device is still wanted. The relay here is a stand-in:
/// nothing is sent to the network.
final class ReviewCorePushTests: XCTestCase {
    private let relay = URL(string: "https://relay.invalid")!
    private let answer = try! JSONSerialization.data(withJSONObject: ["ticket": "t", "expires": 4_000_000_000])
    private func registration() -> PushRegistration { PushRegistration(token: String(repeating: "ab", count: 32), key: Data(repeating: 7, count: 32), mac: "mac-1") }

    /// A device taken off (revoked, or it unregistered) while the relay was
    /// still asked for its ticket is not registered by the answer that
    /// comes afterwards.
    func testADeviceTakenOffWhileTheRelayWasAskedIsNotRegisteredByTheLateAnswer() {
        var answerLater: ((Int, Data?) -> Void)?
        let center = PushCenter(relay: relay, file: nil, transport: { _, _, done in answerLater = done })
        var said: PushState?
        center.register(registration(), device: "phone") { said = $0 }
        XCTAssertNotNil(answerLater, "the relay was not asked")
        // What `revokeDevice` and `pushUnregister` do in the host.
        center.unregister(device: "phone")
        answerLater?(200, answer)
        XCTAssertEqual(center.state(of: "phone"), .off, "the device that was taken off is registered again, and would be sent every notice")
        XCTAssertNotEqual(said, .on, "and its app was told it is registered")
    }

    /// The host's process is not stopped by a relay that answers on a
    /// queue of its own while a device registers and unregisters. The case
    /// (`ReviewCorePushRaceCase`) runs in a process of its own: when the
    /// race is hit, it stops the process it happens in.
    func testARelayThatAnswersOnItsOwnQueueDoesNotStopTheHost() throws {
        let run = try ReviewCore.runAlone("testTheRelaysAnswersAndTheHostDoNotTouchThePushTargetsAtOnce", in: ReviewCorePushRaceCase.self)
        XCTAssertFalse(run.crashed, "the host's process was stopped (signal \(run.status)):\n\(ReviewCore.crashLines(run.said))")
        XCTAssertEqual(run.status, 0, ReviewCore.crashLines(run.said))
    }
}

/// The race of #267 itself, run alone by the test above or by hand with
/// `AGENTTERM_REVIEW_TRAPS=1`; skipped otherwise, since it stops the
/// process when it is hit.
final class ReviewCorePushRaceCase: XCTestCase {
    private let relay = URL(string: "https://relay.invalid")!
    private let answer = try! JSONSerialization.data(withJSONObject: ["ticket": "t", "expires": 4_000_000_000])
    private func registration() -> PushRegistration { PushRegistration(token: String(repeating: "ab", count: 32), key: Data(repeating: 7, count: 32), mac: "mac-1") }

    override func setUpWithError() throws {
        try XCTSkipUnless(ReviewCore.runsTraps, "stops the process when hit: #267, run alone with \(ReviewCore.trapsVariable)=1")
    }

    /// The host, with a relay that answers on a queue of its own as
    /// URLSession does: a paired device registers and unregisters many
    /// times. Run under the thread sanitizer
    /// (`AGENTTERM_REVIEW_TRAPS=1 swift test --sanitize=thread --filter ReviewCorePushRaceCase`),
    /// which says when the targets are written from two threads at once;
    /// without it, it only passes or stops the process.
    func testTheRelaysAnswersAndTheHostDoNotTouchThePushTargetsAtOnce() throws {
        let folder = try ReviewCore.Folder("push")
        defer { folder.remove() }
        var configuration = folder.configuration()
        configuration.pushRelay = relay
        configuration.pushesFile = folder.root.appendingPathComponent("state/pushes.json")
        let answers = DispatchQueue(label: "review.relay", attributes: .concurrent)
        let answer = self.answer
        configuration.pushTransport = { _, _, done in answers.async { done(200, answer) } }
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let mac = ReviewCore.Client(port: port, name: "mac")
        defer { mac.connection.close() }
        XCTAssertTrue(ReviewCore.spin { mac.welcomed })
        mac.connection.send(.createPairingCode)
        var code: String?
        XCTAssertTrue(
            ReviewCore.spin {
                code = mac.messages.compactMap { if case .pairingCode(let code, _) = $0 { return code } else { return nil } }.last
                return code != nil
            })
        let phone = ReviewCore.Client(port: port, credential: .pairingCode(try XCTUnwrap(code)), name: "phone", kind: .iphone)
        defer { phone.connection.close() }
        XCTAssertTrue(ReviewCore.spin { phone.welcomed }, "the phone was not paired")
        let rounds = 400
        for _ in 0..<rounds {
            phone.connection.send(.pushRegister(registration()))
            phone.connection.send(.pushUnregister)
        }
        phone.connection.send(.pushRegister(registration()))
        // Each unregister is answered off at once; a register taken off
        // before the relay answered gets no answer of its own (it would say
        // on after off), and the last one says on.
        func states() -> [PushState] { phone.messages.compactMap { if case .pushState(let state) = $0 { return state } else { return nil } } }
        XCTAssertTrue(ReviewCore.spin(30) { states().count >= rounds + 1 && states().last == .on }, "\(states().count) answers came, the last \(String(describing: states().last))")
    }
}
