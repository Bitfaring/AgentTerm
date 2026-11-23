import AgentTermClient
import AgentTermProtocol
import Darwin
import XCTest

@testable import AgentTermHost

/// #266 (review of 2026-11-22): what a peer that has not signed in can make
/// the host do. Each test says what should happen, and fails for as long as
/// the host does otherwise.
final class ReviewCoreUnsignedPeerTests: XCTestCase {
    private var folder: ReviewCore.Folder!
    private var server: HostServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        folder = try ReviewCore.Folder("unsigned")
        server = HostServer(configuration: folder.configuration())
        port = try server.start()
    }

    override func tearDown() {
        server.stop()
        folder.remove()
    }

    /// A peer that has not signed in and sends something that is no message
    /// is let go at once: told why once (principle 3), and not kept to send
    /// more.
    func testAPeerThatHasNotSignedInIsLetGoAtItsFirstFrameThatIsNoMessage() {
        let peer = ReviewCore.RawSocket(port: port)
        defer { peer.close() }
        XCTAssertTrue(ReviewCore.spin { peer.isReady }, "the peer did not connect")
        peer.send(text: Data("this is not a message".utf8))
        // Time enough for an answer and for a second frame to be taken.
        ReviewCore.spin(1.5) { peer.isClosed }
        peer.send(text: Data("nor is this".utf8))
        ReviewCore.spin(1.5) { peer.isClosed }
        XCTAssertLessThanOrEqual(peer.errors.count, 1, "the host answered a peer that had not signed in, once for each frame: \(peer.errors)")
        XCTAssertTrue(peer.isClosed, "3 seconds and two frames later the peer that never signed in is still connected")
    }

    /// The name a peer gives itself never writes a line of its own into the
    /// host's log, where the app later reads why the host stopped.
    func testTheNameOfAPeerThatWasRefusedWritesNoLineOfItsOwnInTheLog() throws {
        // What the host writes to its log (its standard error) goes to a
        // file of the test's for the time of the test.
        let log = folder.root.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        fflush(stderr)
        let kept = dup(STDERR_FILENO)
        let file = open(log.path, O_WRONLY | O_APPEND)
        dup2(file, STDERR_FILENO)
        var restored = false
        func restore() {
            guard !restored else { return }
            restored = true
            fflush(stderr)
            dup2(kept, STDERR_FILENO)
            close(kept)
            close(file)
        }
        defer { restore() }
        let forged = "agenttermd: a line the peer wrote"
        let peer = ReviewCore.RawSocket(port: port)
        defer { peer.close() }
        XCTAssertTrue(ReviewCore.spin { peer.isReady }, "the peer did not connect")
        // Refused, and in the moment before it is let go, a frame that is
        // no message: the log says who sent it.
        peer.send(.hello(token: "not the token", client: "x\n\(forged)"))
        peer.send(text: Data("{}".utf8))
        ReviewCore.spin(3) { peer.isClosed }
        restore()
        let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lines = written.split(separator: "\n").map(String.init)
        XCTAssertFalse(
            lines.contains { $0.hasPrefix(forged) }, "the log has a line that begins with what the peer called itself: \(lines.filter { $0.contains("could not be read") || $0.hasPrefix(forged) })")
    }

}
