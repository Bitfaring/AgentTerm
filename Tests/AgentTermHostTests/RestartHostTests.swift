import Darwin
import XCTest

@testable import AgentTermHost

/// HOST-17 (#306): what Restart Host does with what listens on the
/// port. Only a host is stopped, and only then is its death taken for a
/// stop that was asked for; otherwise nothing is stopped and the user is
/// told why. The button is offered only while the app's own host answers
/// on the port, so the other two cases come only from a race and are not
/// reached by a UI test.
final class RestartHostTests: XCTestCase {
    func testAHostIsStopped() {
        let restart = DaemonLauncher.restart(of: (pid: 4242, path: "/Applications/AgentTerm.app/Contents/MacOS/agenttermd"))
        XCTAssertEqual(restart, .stop(4242))
        XCTAssertNil(restart.refusal(port: 7840))
    }

    func testNothingOnThePortIsSaid() {
        let restart = DaemonLauncher.restart(of: nil)
        XCTAssertEqual(restart, .noHost)
        XCTAssertEqual(restart.refusal(port: 7840), "No host was found on port 7840, so nothing was stopped. AgentTerm starts its own when it connects again.")
    }

    /// Never stopped (#204), and said.
    func testAProgramThatIsNotAHostIsNotStoppedAndIsSaid() {
        let restart = DaemonLauncher.restart(of: (pid: 4243, path: "/usr/local/bin/tailscale-proxy"))
        XCTAssertEqual(restart, .notAHost(name: "tailscale-proxy"))
        XCTAssertEqual(restart.refusal(port: 7840), "Port 7840 is held by tailscale-proxy, which is not an AgentTerm host, so it was not stopped.")
    }
}
