import AgentTermProtocol
import XCTest

/// A host that is not the app's own.
final class OtherCopysHostTests: MacUITestCase {
    /// The same program from somewhere else: to the app it is the host of
    /// another copy of AgentTerm, an older one for all it knows.
    override var hostExecutable: URL {
        let copy = root.appendingPathComponent("another-copy/agenttermd")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: products.appendingPathComponent("agenttermd"), to: copy)
        }
        return copy
    }

    func testAHostFromAnotherCopyOfTheAppIsNamedAndCanBeReplaced() throws {
        // HOST-1: the banner names the other host by where it is.
        app.wait(for: .containing("held by the host of another copy"), timeout: 15)
        app.wait(for: .containing("another-copy/agenttermd"))
        // It offers this app's own host, after asking: the sessions of the other end with it.
        app.press(.button("Use This App's Host…"))
        app.press(.button("Restart Host"))
        app.waitGone(.containing("held by the host of another copy"), timeout: 30)
        // Connected again, to a host that is the app's own.
        app.wait(for: .button("Shell"), timeout: 30)
        app.wait(for: .text("project, folder"), timeout: 15)
    }
}

/// HOST-13 (#204): what listens on the app's port is a program that is not
/// an AgentTerm host, a proxy in front of the host (this test runner
/// itself, through its `SlowProxy`).
final class PortInUseTests: MacUITestCase {
    private var proxy: SlowProxy!
    private var proxyPort: UInt16 = 0
    override var appPort: UInt16 { proxyPort }

    override func beforeTheAppStarts() throws {
        proxy = try SlowProxy(to: port, bytesPerSecond: 50_000_000)
        proxyPort = proxy.start()
    }

    override func tearDown() {
        // The app quits first (#203, TEST-9).
        super.tearDown()
        proxy?.stop()
    }

    func testAProgramThatIsNotAHostOnThePortIsNamedAndNotOfferedToBeStopped() throws {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)), 0)
        let program = (String(cString: buffer) as NSString).lastPathComponent
        // Said by name, in the words both apps take theirs from.
        app.wait(for: .containing(PortWords.inUse(port: proxyPort, by: program)), timeout: 15)
        // Not another copy's host, and nothing offers to stop it.
        XCTAssertFalse(app.exists(.containing("held by the host of another copy")))
        XCTAssertFalse(app.exists(.button("Use This App's Host…")))
        XCTAssertFalse(app.exists(.button("Restart Host…")))
        // The app works through it all the same.
        app.wait(for: .button("Shell"), timeout: 15)
        shot("banner")
    }
}

/// A link to the host that is slow, to see what the app shows while it waits.
final class WaitingTests: MacUITestCase {
    private var proxy: SlowProxy!
    private var proxyPort: UInt16 = 0
    override var appPort: UInt16 { proxyPort }

    override func beforeTheAppStarts() throws {
        // A session with thousands of long lines above its screen, which
        // the app is sent when it opens: most of a megabyte.
        let phone = try device()
        let line = "%06g-" + String(repeating: "x", count: 60)
        phone.send(.create(CreateRequest(command: "seq -f '\(line)' 1 12000; sleep 600", cwd: project.path, title: "long", size: .default)))
        wait("the session's output", timeout: 30) { (phone.sessions.first.map { phone.text($0.id).utf8.count } ?? 0) > 600_000 }
        proxy = try SlowProxy(to: port, bytesPerSecond: 20_000)
        proxyPort = proxy.start()
    }

    override func tearDown() {
        // The app quits first: with the proxy gone under it, it started a
        // host of its own on the proxy's port, which outlived the test
        // (#203, TEST-9).
        super.tearDown()
        proxy?.stop()
    }

    func testWhileASessionLoadsTheAppSaysSoAndThenThatItTakesLong() throws {
        // LOAD-1: what is being waited for is said.
        app.wait(for: .containing("Loading the session…"), timeout: 20)
        XCTAssertTrue(app.exists(.id("loading")))
        // LOAD-2: and that it is taking long, once it does.
        app.wait(for: .containing("This is taking longer than usual"), timeout: 20)
        // When it has all arrived, the word goes.
        app.waitGone(.containing("Loading the session…"), timeout: 90)
    }
}

final class DiffPlaceTests: MacUITestCase {
    override func makeFixtures() throws {
        try super.makeFixtures()
        // A change far longer than the window is high.
        try write((1...600).map { "changed line \($0)" }.joined(separator: "\n") + "\n", to: "notes.txt")
    }

    func testADiffThatChangesStaysWhereItWasScrolledTo() throws {
        app.press(.button("Git"))
        app.press(.id("change-notes.txt"), timeout: 15)
        app.wait(for: .containing("+changed line 1"), timeout: 15)
        // Scrolled half way down.
        let bars = app.all(.role(kAXScrollBarRole as String))
        for bar in bars { AXUIElementSetAttributeValue(bar.element, kAXValueAttribute as CFString, NSNumber(value: 0.5)) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = app.all(.role(kAXScrollBarRole as String)).map { Double($0.value) ?? 0 }
        try XCTSkipIf(!before.contains { abs($0 - 0.5) < 0.1 }, "this window's scroll bars cannot be moved through accessibility")
        // GIT-13: the file changes under the reader, as an agent keeps editing.
        try write((1...600).map { "changed line \($0)" }.joined(separator: "\n") + "\none more line\n", to: "notes.txt")
        app.press(.button("Refresh"))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let after = app.all(.role(kAXScrollBarRole as String)).map { Double($0.value) ?? 0 }
        XCTAssertEqual(before.count, after.count)
        for (was, now) in zip(before, after) where abs(was - 0.5) < 0.1 {
            XCTAssertEqual(now, was, accuracy: 0.1, "the diff jumped away from where it was scrolled to")
        }
    }
}

/// HOST-16 (#273) on the screen: a schedules file the host cannot read is
/// put aside, and the banner says so, with its name.
final class UnreadableStateTests: MacUITestCase {
    override func makeFixtures() throws {
        try super.makeFixtures()
        // JSON, but not of a shape this build knows.
        try #"{"paused":false,"schedules":[{"id":"x","shape":"of another build"}]}"#.write(
            to: state.appendingPathComponent("schedules.json"), atomically: true, encoding: .utf8)
    }

    func testAStateFileTheHostCannotReadIsSaidInTheBanner() throws {
        app.wait(for: .containing("could not read its schedules"), timeout: 20)
        shot("unreadable-state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("schedules.json.unreadable").path), "the file that could not be read was not put aside")
    }
}
