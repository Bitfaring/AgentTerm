import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What a host does to the files of its state folder (review of
/// 2026-11-22): a test's host and the instructions kept for the agents
/// (#269), and a state file that cannot be read (#273). Everything is in a
/// folder of the test's own; nothing under the real Application Support is
/// read, written or removed here.
final class ReviewSubHostStateTests: XCTestCase {
    private var root: URL!
    private var server: HostServer?
    /// `AGENTTERM_STATE_DIR` as the tests were run with it.
    private var given: String?

    /// Every host started here has the test's folder for its state folder,
    /// so that none of them does to the build's own what #269 is about.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-state-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        given = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
        setenv("AGENTTERM_STATE_DIR", root.path, 1)
    }

    override func tearDown() {
        server?.stop()
        if let given { setenv("AGENTTERM_STATE_DIR", given, 1) } else { unsetenv("AGENTTERM_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }

    /// Whether a file of the folder still holds these bytes: the file
    /// itself, or a copy the host put aside.
    private func kept(_ data: Data, in folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { FileManager.default.contents(atPath: folder.appendingPathComponent($0).path) == data }
    }

    // MARK: #269

    /// #269: a host started as most of the host's tests start one (a port,
    /// a token, no file of its own named) removes nothing from the state
    /// folder of the build. The folder is stood in for by one of the
    /// test's, through `AGENTTERM_STATE_DIR`, for this test only: where a
    /// run of the tests without that variable looks is said by
    /// `testWhereAHostOfTheTestsKeepsTheInstructions`.
    func testAHostOfATestRemovesNoInstructionsOfTheBuild() throws {
        let prompt = HostServer.promptFile(for: "claude")
        XCTAssertTrue(prompt.path.hasPrefix(root.path), "not in the test's folder: nothing is done")
        guard prompt.path.hasPrefix(root.path) else { return }
        try FileManager.default.createDirectory(at: prompt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Run your commands in AgentTerm's shells.".write(to: prompt, atomically: true, encoding: .utf8)

        let host = HostServer(configuration: HostServer.Configuration(port: 0, token: "review-token-0123456789abcdef0123456789", listenOnTailscale: false, detectAgents: { [] }))
        server = host
        _ = try host.start()
        host.stop()
        server = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: prompt.path), "the host of a test removed the instructions kept for Claude Code's server")
    }

    /// #269: a host is given where to keep the instructions; one given
    /// none (as a test's) neither reads nor writes any.
    func testAHostGivenNoFolderForTheInstructionsKeepsNone() {
        XCTAssertNil(HostServer.Configuration(port: 0, token: "t", listenOnTailscale: false, detectAgents: { [] }).promptsDirectory)
    }

    // MARK: #273

    /// #273: a `schedules.json` the host cannot read is not written over
    /// with no schedules: it is left as it was, or kept aside.
    func testSchedulesThatCannotBeReadAreNotWrittenOver() throws {
        let file = root.appendingPathComponent("schedules.json")
        let theirs = Data(#"{"schedules":[{"id":"s1","name":"Nightly","agent":"claude","when":{"kindOfALaterBuild":true}}]}"#.utf8)
        try theirs.write(to: file)
        var configuration = HostServer.Configuration(
            port: 0, token: "review-token-0123456789abcdef0123456789", listenOnTailscale: false, detectAgents: { [] },
            foldersFile: root.appendingPathComponent("folders.json"), devicesFile: root.appendingPathComponent("devices.json"), home: root.path)
        configuration.scheduleInterval = 0.2
        let host = HostServer(configuration: configuration)
        server = host
        _ = try host.start()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, FileManager.default.contents(atPath: file.path) == theirs { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.stop()
        server = nil
        let now = String(decoding: FileManager.default.contents(atPath: file.path) ?? Data(), as: UTF8.self)
        XCTAssertTrue(kept(theirs, in: root), "the schedules that could not be read are gone; the file now holds: \(now.prefix(200))")
    }

    /// #273: a `devices.json` the host cannot read is not written over when
    /// the next device is paired.
    func testPairedDevicesThatCannotBeReadAreNotWrittenOver() throws {
        let file = root.appendingPathComponent("devices.json")
        let theirs = Data(#"[{"id":"d1","name":"iPhone","tokenHash":"abc","pairedAt":"of a later build"}]"#.utf8)
        try theirs.write(to: file)
        let registry = DeviceRegistry(localToken: "review-token-0123456789abcdef0123456789", file: file)
        let code = registry.createCode().code
        XCTAssertNotNil(registry.redeem(code: code, deviceName: "iPad"))
        let now = String(decoding: FileManager.default.contents(atPath: file.path) ?? Data(), as: UTF8.self)
        XCTAssertTrue(kept(theirs, in: root), "the paired devices that could not be read are gone; the file now holds \(now.count) bytes without “iPhone”: \(!now.contains("iPhone"))")
    }
}
