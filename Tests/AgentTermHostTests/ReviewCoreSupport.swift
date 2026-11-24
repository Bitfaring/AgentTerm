import AgentTermClient
import AgentTermProtocol
import Darwin
import Foundation
import Network
import XCTest

@testable import AgentTermHost

/// What the tests of the review of 2026-11-22 (milestone 0.15.1) share: a
/// host of their own, a client that says what it is told to, and a way to
/// run a test that stops its process without stopping the others.
enum ReviewCore {
    static let token = "review-token-0123456789abcdef0123456789"

    /// Spins the main run loop, where the clients' callbacks arrive, until
    /// `condition` holds or the time is up; says whether it held.
    @discardableResult
    static func spin(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// A folder of the test's own, with the state folder the host's static
    /// paths read (`AGENTTERM_STATE_DIR`) inside it: a host started by a
    /// test must never read or remove what a build on this Mac keeps (#269).
    final class Folder {
        let root: URL
        private let stateBefore: String?

        init(_ name: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-\(name)-\(UUID().uuidString.prefix(8))").standardizedFileURL
            try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
            stateBefore = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
            setenv("AGENTTERM_STATE_DIR", root.appendingPathComponent("state").path, 1)
        }

        func remove() {
            if let stateBefore { setenv("AGENTTERM_STATE_DIR", stateBefore, 1) } else { unsetenv("AGENTTERM_STATE_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        /// A host's configuration that keeps what it keeps in this folder.
        func configuration(agents: [AgentInfo] = []) -> HostServer.Configuration {
            HostServer.Configuration(
                port: 0, token: ReviewCore.token, listenOnTailscale: false, detectAgents: { agents },
                foldersFile: root.appendingPathComponent("state/folders.json"), home: root.path, statusLineTool: "/usr/bin/true",
                usageDirectory: root.appendingPathComponent("usage"))
        }
    }

    /// A client as the apps are, that keeps what it was sent.
    final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []
        var state: AgentTermConnection.State = .connecting

        init(port: UInt16, credential: AgentTermConnection.Credential = .token(ReviewCore.token), name: String, kind: DeviceKind? = nil) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: credential, clientName: name, kind: kind)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.onState = { [weak self] in self?.state = $0 }
            connection.connect()
        }

        var welcomed: Bool { messages.contains { if case .welcome = $0 { return true } else { return false } } }
        var isClosed: Bool { if case .closed = state { return true } else { return false } }
        var errors: [String] { messages.compactMap { if case .error(let text, _) = $0 { return text } else { return nil } } }
        var sessions: [SessionInfo]? { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last }
        var attached: SessionInfo? { messages.compactMap { if case .attached(let info, _) = $0 { return info } else { return nil } }.last }
        var failures: [PartFailure] { messages.compactMap { if case .failures(let list) = $0 { return list } else { return nil } }.last ?? [] }
    }

    /// A WebSocket that sends exactly the frames it is given, signed in or
    /// not, and reads only when asked to.
    final class RawSocket {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "review.raw")
        private let lock = NSLock()
        private var texts: [Data] = []
        private var closed = false
        private var ready = false

        init(port: UInt16, reads: Bool = true) {
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            webSocket.maximumMessageSize = 16 * 1024 * 1024
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            // A URL, as the apps' client gives: the handshake needs its host and path.
            connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                switch state {
                case .ready: self.ready = true
                case .failed, .cancelled: self.closed = true
                default: break
                }
                self.lock.unlock()
            }
            connection.start(queue: queue)
            if reads { receive() }
        }

        private func receive() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                self.lock.lock()
                if error != nil || metadata?.opcode == .close { self.closed = true }
                if let data, metadata?.opcode == .text { self.texts.append(data) }
                let over = self.closed
                self.lock.unlock()
                if !over { self.receive() }
            }
        }

        var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        /// What the host said, as messages; one it sent in parts is not joined.
        var messages: [ServerMessage] {
            lock.lock()
            defer { lock.unlock() }
            return texts.compactMap { MessageCoding.decode(ServerMessage.self, from: $0) }
        }
        var errors: [String] { messages.compactMap { if case .error(let text, _) = $0 { return text } else { return nil } } }

        func send(text data: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: data, contentContext: context, completion: .idempotent)
        }

        func send(_ message: ClientMessage) { send(text: MessageCoding.encode(message)) }
        func close() { connection.cancel() }
    }

    /// Runs one test of `ReviewCoreTrapCases` in a process of its own, as
    /// `swift test` would, and says how that process ended and what it
    /// wrote: a fault that stops the process it happens in (a Swift trap)
    /// then fails one test and no more.
    static func runAlone(_ test: String, in case: AnyClass) throws -> (status: Int32, crashed: Bool, said: String) {
        let bundle = Bundle(for: `case`).bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "AgentTermHostTests.\(String(describing: `case`))/\(test)", bundle]
        var environment = OwnEnvironment.withoutAgentTerms
        environment[trapsVariable] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var output = Data()
        let reader = DispatchQueue(label: "review.alone")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        process.waitUntilExit()
        _ = read.wait(timeout: .now() + 10)
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal, String(decoding: output, as: UTF8.self))
    }

    static let trapsVariable = "AGENTTERM_REVIEW_TRAPS"
    static var runsTraps: Bool { ProcessInfo.processInfo.environment[trapsVariable] == "1" }

    /// The lines of what a process wrote that say where it stopped.
    static func crashLines(_ said: String) -> String {
        said.split(separator: "\n").filter { $0.contains("Fatal error") || $0.contains("error:") || $0.contains("failed") }.suffix(6).joined(separator: "\n")
    }
}
