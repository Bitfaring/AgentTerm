import Foundation
import Network

/// Stands between the app and the host and lets what the host sends
/// through a little at a time, as a weak link would; or, held, not at all
/// until let go, while what the app sends still goes through.
final class SlowProxy {
    private let listener: NWListener
    private let target: UInt16
    private let queue = DispatchQueue(label: "agentterm.test.proxy")
    private var connections: [NWConnection] = []
    private let piece: Int
    private let pause: TimeInterval = 0.02
    private var held = false

    init(to target: UInt16, bytesPerSecond: Int) throws {
        self.target = target
        piece = max(1, Int(Double(bytesPerSecond) * pause))
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
    }

    func start() -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue ?? 0
    }

    /// Holds what the host sends, or lets it go again, in the order sent.
    func hold(_ on: Bool) { queue.sync { held = on } }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func accept(_ client: NWConnection) {
        let host = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
        connections += [client, host]
        client.start(queue: queue)
        host.start(queue: queue)
        pump(from: client, to: host, piece: 65536, pause: 0)
        pump(from: host, to: client, piece: piece, pause: pause, holdable: true)
    }

    private func pump(from: NWConnection, to: NWConnection, piece: Int, pause: TimeInterval, holdable: Bool = false) {
        if holdable, held {
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pump(from: from, to: to, piece: piece, pause: pause, holdable: holdable) }
            return
        }
        from.receive(minimumIncompleteLength: 1, maximumLength: piece) { [weak self] data, _, complete, error in
            guard let self, let data, !data.isEmpty else {
                if complete || error != nil { to.cancel() }
                return
            }
            // A receive asked for before the hold, while the link was idle,
            // ends with the first answer after it: that answer waits too,
            // or the hold lets one through (#189's test met it).
            self.send(data, from: from, to: to, piece: piece, pause: pause, holdable: holdable)
        }
    }

    private func send(_ data: Data, from: NWConnection, to: NWConnection, piece: Int, pause: TimeInterval, holdable: Bool) {
        if holdable, held {
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.send(data, from: from, to: to, piece: piece, pause: pause, holdable: holdable) }
            return
        }
        to.send(
            content: data,
            completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + pause) { self.pump(from: from, to: to, piece: piece, pause: pause, holdable: holdable) }
            })
    }
}
