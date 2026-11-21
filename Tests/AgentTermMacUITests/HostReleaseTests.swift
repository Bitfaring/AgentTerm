import AgentTermProtocol
import XCTest

/// HOST-12 (#121): a host left running when the app was updated is pointed
/// out when it was built from other sources than the host the app comes
/// with, whatever the protocol, and only then. In the app as it is shipped,
/// whose Info.plist names what its host is built from.
final class HostReleaseTests: MacUITestCase {
    private var launched = false

    /// What the bundle says its host is built from.
    private var bundleRevision: String {
        Self.testBundle.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "AgentTermHostRevision") as? String } ?? ""
    }

    /// The host the bundle comes with, as after an update in place (Homebrew
    /// replaces the app where it is): the app takes it for its own, by its
    /// path, whatever it says.
    override var hostExecutable: URL {
        Self.testBundle.map { $0.appendingPathComponent("Contents/MacOS/agenttermd") } ?? super.hostExecutable
    }

    /// The test's host says it is from an earlier release; built from other
    /// sources, or from the same ones, as the test's name says.
    override var hostArguments: [String] {
        // Of an earlier protocol too (#214): it refuses what came after it.
        if name.contains("EarlierProtocol") { return ["--protocol-version", "32"] }
        return ["--app-version", "0.0.1", "--host-revision", name.contains("SameSources") ? bundleRevision : "0000000000000000"]
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.testBundle != nil, "the app bundle is built by scripts/test-mac.sh")
        try super.setUpWithError()
    }

    override func launchApp() throws -> MacDriver {
        defer { launched = true }
        return try launchBundledApp(fresh: !launched)
    }

    override func tearDown() {
        super.tearDown()
        if let bundle = Self.testBundle { forgetBundlePreferences(bundle) }
    }

    func testAHostBuiltFromOtherSourcesIsPointedOut() throws {
        XCTAssertFalse(bundleRevision.isEmpty, "the bundle names no revision of its host")
        app.wait(for: .containing("The host that is running is from AgentTerm 0.0.1"), timeout: 20)
        shot("older-host")
        // Asked first, then the app's own host in its place: the banner goes.
        app.press(.button("Restart Host…"))
        app.press(.button("Restart Host"))
        app.waitGone(.containing("The host that is running is from AgentTerm"), timeout: 30)
        app.wait(for: .id("mac-switcher"))
    }

    /// HOST-14 (#214): the host left running by an update is of an earlier
    /// protocol. The banner says so, with Restart Host…; the app goes on
    /// with it meanwhile, and no notice says "from an older release" a
    /// second time; restarted, the banner goes.
    func testAHostOfAnEarlierProtocolIsSaidInTheBannerOnly() throws {
        app.wait(for: .containing("The host that is running is from an older version of AgentTerm."), timeout: 20)
        // Connected all the same: the project's folder is listed.
        app.wait(for: .id("folder-\(project.path)"), timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.exists(.containing(HostErrorWords.olderHost)), "the older host is said a second time, as a notice")
        shot("earlier-protocol")
        app.press(.button("Restart Host…"))
        app.press(.button("Restart Host"))
        app.waitGone(.containing("The host that is running is from"), timeout: 30)
        app.wait(for: .id("mac-switcher"))
    }

    func testAHostFromTheSameSourcesIsNotPointedOut() throws {
        // Connected: the project's folder is listed.
        app.wait(for: .id("folder-\(project.path)"), timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.exists(.containing("The host that is running is")), "a host built from the same sources is pointed out")
        XCTAssertFalse(app.exists(.button("Restart Host…")))
    }
}
