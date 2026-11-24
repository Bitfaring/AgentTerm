import AgentTermClient
import AgentTermProtocol
import Foundation
import XCTest

/// A Mac app and a host of their own, in folders of their own, for one test.
///
/// Nothing here is the user's: the host keeps its state in a scratch
/// folder, listens on a port of its own, reads history and the SSH
/// configuration from a scratch home, and finds stand-in agents, small
/// scripts, instead of the installed ones.
///
/// These tests press the app's buttons through accessibility, which macOS
/// only lets a trusted process do, so they are skipped unless asked for:
/// `scripts/test-mac.sh` sets `AGENTTERM_MAC_UI`.
class MacUITestCase: XCTestCase {
    private(set) var root: URL!
    private(set) var project: URL!
    private(set) var remote: URL!
    private(set) var home: URL!
    private(set) var state: URL!
    private(set) var port: UInt16 = 0
    private(set) var app: MacDriver!
    private var host: Process?
    private var others: [Process] = []
    /// Every app the test started, kept from the moment it starts: one whose
    /// window never came stopped the set-up before it was the test's `app`,
    /// and was left running; losing its host, it started one of its own
    /// (#185).
    private var launched: [MacDriver] = []
    var clients: [AgentTermConnection] = []

    /// A port nothing else in a run uses.
    private static var nextPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["AGENTTERM_MAC_UI_PORT"] ?? "") ?? 7840

    private static let appName = "AgentTermMacUITest"

    /// Throws away what the app under test remembered, so each test starts
    /// from the app as it is when first opened.
    private func forgetPreferences() {
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", Self.appName]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        try? defaults.run()
        defaults.waitUntilExit()
    }

    var products: URL { Bundle(for: MacUITestCase.self).bundleURL.deletingLastPathComponent() }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_MAC_UI"] != nil, "run through scripts/test-mac.sh")
        try XCTSkipUnless(MacDriver.isAllowed, "allow this terminal under System Settings > Privacy & Security > Accessibility")
        continueAfterFailure = false
        // As the host names it: it reads history by the folder's name, and
        // would not find it under the name with its symbolic links resolved.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-mac-ui-\(UUID().uuidString.prefix(8))").standardizedFileURL
        project = root.appendingPathComponent("project")
        remote = root.appendingPathComponent("remote.git")
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        try makeFixtures()
        try beforeTheHostStarts()
        port = Self.nextPort
        Self.nextPort += 1
        host = try startHost(state: state, home: hostHome, port: port, extra: hostArguments)
        forgetPreferences()
        try beforeTheAppStarts()
        app = try launchApp()
    }

    override func tearDown() {
        // A failure here does not stop the tearing down half way, nor that
        // of a subclass after it: what it started would be left running.
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        let wanted = (testRun?.failureCount ?? 0) > 0 || environment["AGENTTERM_SHOT_ALWAYS"] != nil
        if wanted, let folder = environment["AGENTTERM_SHOT_DIR"], let app {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            app.capture(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber }).png"))
        }
        clients.forEach { $0.close() }
        clients = []
        app?.quit()
        launched.forEach { $0.quit() }
        launched = []
        // A host the app started by itself is not a child of this test.
        stopWhateverListens(on: port)
        for process in [host].compactMap({ $0 }) + others where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let left = endWhatOutlivedTheTest()
        if let root { try? FileManager.default.removeItem(at: root) }
        if app != nil { forgetPreferences() }
        if !left.isEmpty { XCTFail("the test left these running, now ended: " + left.joined(separator: "; ")) }
    }

    /// TEST-9 (#203): nothing of a test outlives it. Once everything it
    /// started was stopped, any program of this build still running with
    /// the test's state folder is a fault of the test: most often a host the
    /// app started by itself, on a port no one stops, because what the app
    /// was connected to (a `SlowProxy`) was stopped before the app quit.
    /// It is ended, and named for the test to fail.
    private func endWhatOutlivedTheTest() -> [String] {
        guard let root else { return [] }
        var left = programsOfThisTest(root)
        let deadline = Date().addingTimeInterval(10)
        // What was just told to stop takes a moment to go.
        while !left.isEmpty, Date() < deadline {
            usleep(100_000)
            left = programsOfThisTest(root)
        }
        guard !left.isEmpty else { return [] }
        for program in left { kill(program.pid, SIGTERM) }
        let killed = Date().addingTimeInterval(3)
        while !programsOfThisTest(root).isEmpty, Date() < killed { usleep(100_000) }
        for program in programsOfThisTest(root) { kill(program.pid, SIGKILL) }
        return left.map { "\($0.pid) \($0.command)" }
    }

    /// The programs of this build (the folder `.build` the tests run from,
    /// or the test's own folder) whose state folder is the test's. Nothing
    /// else is looked into: the installed app and its host are not of this
    /// build.
    private func programsOfThisTest(_ root: URL) -> [(pid: pid_t, command: String)] {
        let resolvedProducts = products.resolvingSymlinksInPath().path
        let build = resolvedProducts.range(of: "/.build/").map { String(resolvedProducts[..<$0.upperBound]) } ?? resolvedProducts + "/"
        let places = [build, root.resolvingSymlinksInPath().path + "/"]
        let mark = root.lastPathComponent
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var programs: [(pid: pid_t, command: String)] = []
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 && pid != getpid() {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard places.contains(where: { path.hasPrefix($0) }), let (arguments, environment) = Self.argumentsAndEnvironment(of: pid),
                environment["AGENTTERM_STATE_DIR"]?.contains(mark) == true
            else { continue }
            programs.append((pid, ([path] + arguments.dropFirst()).joined(separator: " ")))
        }
        return programs
    }

    /// What a program was started with, as the kernel keeps it.
    static func argumentsAndEnvironment(of pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        // The executable's path, then the zeros that pad it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        func next() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        var arguments: [String] = []
        for _ in 0..<argc { guard let argument = next() else { break }; arguments.append(argument) }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    /// A picture of the window in the middle of a test, with `ALL_SHOTS`.
    func shot(_ name: String, topmost: Bool = false) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTTERM_SHOT_ALWAYS"] != nil, let folder = environment["AGENTTERM_SHOT_DIR"], let app else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        app.capture(to: URL(fileURLWithPath: folder).appendingPathComponent("\(self.name.filter { $0.isLetter || $0.isNumber })-\(name).png"), topmost: topmost)
    }

    /// Stops the program that listens on a port: a host the app started.
    func stopWhateverListens(on port: UInt16, signal: Int32 = SIGTERM) {
        for pid in listeners(on: port) { kill(pid, signal) }
    }

    /// Kills the host on one of the test's ports as a crash or macOS would:
    /// it gets no chance to stop as it does when asked. Only ever a host of
    /// this test, started by it or by the app under test.
    func killHost(on port: UInt16) {
        let killed = listeners(on: port)
        XCTAssertFalse(killed.isEmpty, "no host listens on \(port)")
        for pid in killed { kill(pid, SIGKILL) }
        wait("the host to be gone") { Set(self.listeners(on: port)).isDisjoint(with: killed) }
    }

    /// The programs that listen on a port, this test aside.
    func listeners(on port: UInt16) -> [pid_t] {
        guard port != 0 else { return [] }
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        find.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        find.standardOutput = pipe
        find.standardError = FileHandle.nullDevice
        try? find.run()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        find.waitUntilExit()
        return found.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.filter { $0 != ProcessInfo.processInfo.processIdentifier }
    }

    /// The host's program. A test of what the app makes of a host that is
    /// not its own gives another.
    var hostExecutable: URL { products.appendingPathComponent("agenttermd") }

    /// The port the app is told to connect to. A test that puts something
    /// between the app and the host gives that thing's port.
    var appPort: UInt16 { port }

    /// Called with the host running and the app not started yet.
    func beforeTheAppStarts() throws {}

    /// Called with the fixtures made and the host not started yet.
    func beforeTheHostStarts() throws {}

    /// The home folder the test's host is given: the test's own. Only the
    /// test of the real agents, run by hand, gives the user's, so that the
    /// agents are signed in.
    var hostHome: URL { home }

    /// More arguments for the test's host, which a test class may give.
    var hostArguments: [String] { [] }

    // MARK: The app as it is shipped

    /// The app bundle `scripts/test-mac.sh` builds, under an identifier of
    /// its own, for the tests that need the app as it is shipped: Chromium,
    /// the Info.plist.
    static var testBundle: URL? {
        ProcessInfo.processInfo.environment["AGENTTERM_TEST_BUNDLE"].map { URL(fileURLWithPath: $0) }
    }

    /// Starts the bundle with the test's home, state and port, as the
    /// unbundled app is started otherwise. Its preferences are forgotten
    /// first when `fresh`.
    func launchBundledApp(fresh: Bool) throws -> MacDriver {
        let bundle = try XCTUnwrap(Self.testBundle)
        if fresh { forgetBundlePreferences(bundle) }
        var environment = Self.ownHome(home)
        environment.merge(appEnvironment) { _, own in own }
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["AGENTTERM_PORT"] = String(appPort)
        environment["CFFIXED_USER_HOME"] = home.path
        let driver = try startDriver(executable: bundle.appendingPathComponent("Contents/MacOS/AgentTerm"), environment: environment)
        driver.wait(for: .id("mac-switcher"), timeout: 30)
        return driver
    }

    /// Starts an app, kept to be quit when the test ends however it ends.
    func startDriver(executable: URL, environment: [String: String]) throws -> MacDriver {
        let driver = try MacDriver(executable: executable, environment: environment)
        launched.append(driver)
        return driver
    }

    func forgetBundlePreferences(_ bundle: URL) {
        guard let identifier = Bundle(url: bundle)?.bundleIdentifier, identifier.contains("uitest") else { return }
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", identifier]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        try? defaults.run()
        defaults.waitUntilExit()
    }

    // MARK: What the host has to show

    @discardableResult
    func git(_ arguments: String..., in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ text: String, to path: String, in directory: URL? = nil) throws {
        let url = (directory ?? project).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in directory: URL? = nil) -> String {
        (try? String(contentsOf: (directory ?? project).appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    /// A project with a remote, a committed file and changes not yet
    /// committed; a home with an SSH configuration, a conversation an agent
    /// had in the project and folders to browse; and the stand-in agents.
    func makeFixtures() throws {
        let manager = FileManager.default
        for folder in [project!, home!, state!] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try makeRepository(project, remote: remote)
        try write("first line\nsecond line\n", to: "notes.txt")
        try write("# Guide\n\nSome words.\n", to: "docs/guide.md")
        try write("a file that is new\n", to: "new.txt")

        try manager.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "Host build-server\n  HostName 127.0.0.1\nHost *.internal\n".write(
            to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: home.appendingPathComponent("Projects/demo"), withIntermediateDirectories: true)
        let history = home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(project.path)","message":{"role":"user","content":"write tests for the parser"}}"#.appending("\n").write(
            to: history.appendingPathComponent("c-1.jsonl"), atomically: true, encoding: .utf8)

        try makeAgents(root.appendingPathComponent("agents"))
        try JSONEncoder().encode([project.path]).write(to: state.appendingPathComponent("folders.json"))
    }

    func makeRepository(_ directory: URL, remote: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        try write("first line\n", to: "notes.txt", in: directory)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)
        if let remote {
            git("init", "-q", "--bare", "-b", "main", remote.path, in: directory)
            git("remote", "add", "origin", remote.path, in: directory)
            git("push", "-q", "-u", "origin", "main", in: directory)
        }
    }

    /// Whether the app is the one in front of every other.
    var appIsInFront: Bool { NSRunningApplication(processIdentifier: app.pid)?.isActive == true }

    /// Through accessibility, as the rest is done: macOS does not let a
    /// program that is not in front itself put another one there. For what
    /// the app does only while it is in front: a banner seen (NOTE-9), the
    /// remotes asked by itself (GIT-77).
    func bringAppToFront() {
        if !appIsInFront {
            NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        wait("the app in front") { appIsInFront }
    }

    /// The addresses something listens on at a port, as `lsof` gives them:
    /// "127.0.0.1:7842", "100.64.0.1:7842".
    func listeningAddresses(on port: UInt16) -> [String] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        return said.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// The file a remote made slow by `makeSlowRepository` writes when it is
    /// asked for what is new: the second it was asked at.
    func fetchAsked(of repository: URL) -> URL {
        repository.deletingLastPathComponent().appendingPathComponent(repository.lastPathComponent + "-fetch-asked")
    }

    static let slowRemoteSeconds = 5
    static let commitBeforeTheFetch = "feat: made before the fetch"

    /// A repository apart from the test's own, with a commit its remote
    /// does not have, and a remote that takes five seconds to answer a
    /// fetch and says when it was asked. For what happens while the app
    /// asks the remotes by itself (#116), which it does once for a folder,
    /// within three seconds of its changes being shown with the app in
    /// front: this one's are not shown until the test picks it. A push is
    /// not slowed.
    func makeSlowRepository(named name: String, under parent: URL) throws -> (folder: URL, remote: URL) {
        let folder = parent.appendingPathComponent(name), remote = parent.appendingPathComponent(name + ".git")
        try makeRepository(folder, remote: remote)
        try write("first line\nsecond line\n", to: "notes.txt", in: folder)
        git("commit", "-q", "-am", Self.commitBeforeTheFetch, in: folder)
        let program = parent.appendingPathComponent(name + "-slow-upload-pack")
        try """
        #!/bin/sh
        date +%s > '\(fetchAsked(of: folder).path)'
        sleep \(Self.slowRemoteSeconds)
        exec git upload-pack "$@"

        """.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        git("config", "remote.origin.uploadpack", program.path, in: folder)
        return (folder, remote)
    }

    /// With the folder of `makeSlowRepository` just picked and its changes
    /// on show: waits for the app's own fetch to be under way, checks that
    /// no button waits on it, presses Push, and checks that the push is
    /// made, and only once the fetch is over (GIT-77, REMOTE-21).
    func pushWhileTheAppFetchesByItself(_ slow: (folder: URL, remote: URL), file: StaticString = #filePath, line: UInt = #line) {
        let asked = fetchAsked(of: slow.folder)
        // The app asks the remotes by itself only while it is in front.
        bringAppToFront()
        wait("the app's own fetch to be under way", timeout: 20, file: file, line: line) { FileManager.default.fileExists(atPath: asked.path) }
        let began =
            (try? String(contentsOf: asked, encoding: .utf8)).flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        // No button waits on it. Looked at as they are now, without
        // waiting: held, Fetch turns and is no button to be found.
        for name in ["Fetch", "Pull", "Push, 1 commit"] {
            XCTAssertEqual(app.first(.button(name))?.enabled, true, "\(name) is held while the app fetches by itself", file: file, line: line)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(began), TimeInterval(Self.slowRemoteSeconds) - 1.5, "the fetch may have been over when the buttons were looked at", file: file,
            line: line)
        app.press(.button("Push, 1 commit"), file: file, line: line)
        wait("the remote to have the commit", timeout: 40, file: file, line: line) {
            self.git("log", "-1", "--format=%s", "main", in: slow.remote) == Self.commitBeforeTheFetch
        }
        // Not beside the fetch: after it.
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(began), TimeInterval(Self.slowRemoteSeconds) - 1, "the push was made while the fetch was under way", file: file, line: line)
        app.wait(for: .button("Push"), timeout: 15, file: file, line: line)
    }

    /// Small programs under the agents' names. Asked for one answer (`-p`,
    /// `exec`), they give a commit message; started in a terminal, they say
    /// so, write down what they were started with (`agentStarts`), and then
    /// repeat what they are told, as `cat` does.
    func makeAgents(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            // Asked of its plugins (#129), as the real one answers: in a
            // folder of its own, what it was given and how it was asked.
            let plugins = directory.appendingPathComponent("plugins-\(name)").path
            let listed = name == "claude" ? #"printf '  ❯ %s\n    Status: ✔ enabled\n' "$n""# : #"printf '%s  installed, enabled  1.0\n' "$n""#
            // Codex's is asked of the server its sessions share too (#140),
            // once a test gave it one (`shared-server`: whether it starts
            // it by itself; `server-running`: one runs), and answers as
            // Codex 0.169.1 does.
            // Asked of AgentTerm's MCP server with its own command, each
            // answers as the real one was seen to (2026-11-18): Claude Code
            // keeps it by name and refuses one it has; Codex writes a table
            // into its config.toml, which AgentTerm adds a line to.
            let servers =
                name == "claude"
                ? """
                      "mcp add")
                        shift 2; while [ "$1" = "--scope" ]; do shift 2; done; n=$1; shift; [ "$1" = "--" ] && shift
                        if [ -e '\(plugins)'/server-"$n" ]; then echo "MCP server $n already exists in user config"; exit 1; fi
                        printf '%s\\n' "$1" > '\(plugins)'/server-"$n"; echo "Added stdio MCP server $n to user config" ;;
                      "mcp get")
                        if [ ! -e '\(plugins)'/server-"$3" ]; then echo "No MCP server named \\"$3\\". Run \\`claude mcp add\\` to add one."; exit 1; fi
                        printf '%s:\\n  Scope: User config (available in all your projects)\\n  Status: ✔ Connected\\n  Type: stdio\\n  Command: %s\\n  Args: mcp\\n' "$3" "$(cat '\(plugins)'/server-"$3")" ;;
                      "mcp remove")
                        shift 2; while [ "$1" = "--scope" ]; do shift 2; done
                        if [ ! -e '\(plugins)'/server-"$1" ]; then echo "No MCP server named \\"$1\\" in user scope"; exit 1; fi
                        rm -f '\(plugins)'/server-"$1"; echo "Removed MCP server $1 from user config" ;;
                """
                : """
                      "mcp add")
                        n=$3; shift 3; [ "$1" = "--" ] && shift
                        mkdir -p "$HOME/.codex"; rest=$(without "$n")
                        { [ -z "$rest" ] || printf '%s\\n\\n' "$rest"; printf '[mcp_servers.%s]\\ncommand = "%s"\\nargs = ["mcp"]\\n' "$n" "$1"; } > "$conf.new"; mv "$conf.new" "$conf"
                        echo "Added global MCP server '$n'." ;;
                      "mcp get")
                        body=$(table "$3")
                        if [ -z "$body" ]; then echo "Error: No MCP server named '$3' found."; exit 1; fi
                        printf '{"name": "%s", "enabled": true, "transport": {"type": "stdio", "command": "%s", "args": ["mcp"], "env": null, "env_vars": [%s], "cwd": null}}\\n' "$3" "$(printf '%s\\n' "$body" | sed -n 's/^command = "\\(.*\\)"$/\\1/p')" "$(printf '%s\\n' "$body" | sed -n 's/^env_vars = \\[\\(.*\\)\\]$/\\1/p')" ;;
                      "mcp remove")
                        if [ -n "$(table "$3")" ]; then without "$3" > "$conf.new"; mv "$conf.new" "$conf"; echo "Removed global MCP server '$3'."; else echo "No MCP server named '$3' found."; fi ;;
                """
            let script = """
                #!/bin/sh
                conf="$HOME/.codex/config.toml"
                table() { awk -v h="[mcp_servers.$1]" '$0==h{on=1;next} on&&(/^\\[/||/^$/){on=0} on' "$conf" 2>/dev/null; }
                without() { awk -v h="[mcp_servers.$1]" '$0==h{skip=1;pend=0;next} skip&&(/^\\[/||/^$/){skip=0} skip{next} /^$/{pend++;next} {while(pend>0){print "";pend--} print}' "$conf" 2>/dev/null; }
                case "$1 $2" in
                  "plugin "*|"features "*|"app-server daemon"|"mcp "*)
                    mkdir -p '\(plugins)'
                    printf '%s\\n' "$*" >> '\(plugins).log'
                    case "$1 $2" in
                \(servers)
                      "plugin list") for f in '\(plugins)'/plugin-*; do [ -e "$f" ] || continue; n=${f##*/plugin-}; \(listed); done ;;
                      "plugin install"|"plugin add") touch '\(plugins)'/plugin-"$3" ;;
                      "plugin uninstall"|"plugin remove") rm -f '\(plugins)'/plugin-"$3" ;;
                      "features list") [ -e '\(plugins)/shared-server' ] && printf 'daemon_auto_start                        stable             %s\\n' "$(cat '\(plugins)/shared-server')" ;;
                      "features disable") [ -e '\(plugins)/shared-server' ] || exit 1; echo false > '\(plugins)/shared-server' ;;
                      "features enable") [ -e '\(plugins)/shared-server' ] || exit 1; echo true > '\(plugins)/shared-server' ;;
                      "app-server daemon")
                        if [ "$3" = stop ] && [ -e '\(plugins)/server-running' ]; then rm '\(plugins)/server-running'; echo '{"status":"stopped","backend":"pid"}'; exit 0; fi
                        if [ -e '\(plugins)/server-running' ]; then echo '{"status":"running","backend":"pid"}'; else echo "Error: failed to connect"; exit 1; fi ;;
                    esac
                    exit 0 ;;
                esac
                case " $* " in
                  *" -p "*) cat > /dev/null; echo "feat: written by the stand-in \(name)"; exit 0 ;;
                esac
                printf '%s: %s\\n' '\(name)' "$*" >> '\(directory.appendingPathComponent("started").path)'
                echo "stand-in \(name) started: $*"
                exec cat
                """
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    /// What each stand-in agent was started with, a line each, as
    /// `name: arguments`. Read from a file rather than from its terminal,
    /// where a long line is wrapped at the pane's width, and a device that
    /// attaches late is sent the screen as wrapped.
    func agentStarts() -> [String] {
        let file = root.appendingPathComponent("agents/started")
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: The host and the app

    /// What a test adds to its hosts' environment.
    var hostEnvironment: [String: String] = [:]

    @discardableResult
    func startHost(state: URL, home: URL, port: UInt16, extra: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = hostExecutable
        process.arguments =
            ["--port", String(port), "--local-only", "--no-account-usage", "--home", home.path, "--agents", root.appendingPathComponent("agents").path] + extra
        var environment = Self.ownHome(home)
        environment["AGENTTERM_STATE_DIR"] = state.path
        // An agent's hooks and MCP server are said missing after 3 seconds,
        // not 20 (#129), unless the test asks for longer.
        environment["AGENTTERM_LINK_GRACE"] = linkGrace
        environment.merge(hostEnvironment) { _, own in own }
        // What it throws away stays in the test's folder, also when its
        // home is the user's.
        if home != self.home { environment["AGENTTERM_TRASH_DIR"] = root.appendingPathComponent("trash").path }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if host != nil { others.append(process) }
        let token = state.appendingPathComponent("token")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: token.path) && Date() < deadline { usleep(50_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: token.path), "the host did not start")
        // The token is written a moment before the port is open.
        usleep(400_000)
        return process
    }

    /// This process's environment with none of AgentTerm's variables
    /// (TEST-11, #207): the tests may be run from a session of the
    /// installed app, whose own (its hooks' file, its MCP server's key) are
    /// in it. What a test starts gets the `AGENTTERM_` variables the test
    /// gives it, and no other.
    static var withoutAgentTerms: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENTTERM_") }
    }

    /// This process's environment, with `home` as the home folder: the
    /// login shells the host starts, for sessions and to find the user's
    /// PATH, read their startup files from there, and none of those of the
    /// person running the tests (TEST-1).
    static func ownHome(_ home: URL) -> [String: String] {
        var environment = withoutAgentTerms
        environment["HOME"] = home.path
        // zsh looks for its files here first, whatever HOME says.
        environment["ZDOTDIR"] = home.path
        // What the host and the app take for the home folder, and give
        // their sessions as HOME: NSHomeDirectory() follows this, not HOME.
        environment["CFFIXED_USER_HOME"] = home.path
        // What a test throws away goes here, never into the Trash of the
        // person running the tests.
        environment["AGENTTERM_TRASH_DIR"] = home.appendingPathComponent(".Trash-of-the-tests").path
        return environment
    }

    /// What a test has the app started with besides, when it starts it again.
    /// The onboarding is not shown, but in the test of it (#129): the
    /// stand-in agents are not set up, and it would cover the window.
    /// Nothing is posted into the user's Notification Center either, nor
    /// its question asked, which takes the app out of the front (#66).
    /// How long the host waits for an agent's hooks and MCP server before
    /// it says them missing, in seconds: set before `setUpWithError`.
    var linkGrace = "3"

    /// A host the app starts listens on 127.0.0.1 only, as the tests' own do (#179).
    var appEnvironment: [String: String] = ["AGENTTERM_NO_ONBOARDING": "1", "AGENTTERM_NO_SYSTEM_NOTIFICATIONS": "1", "AGENTTERM_LOCAL_ONLY": "1"]

    /// Starts the app on the test's host. Its preferences are its own too:
    /// with a home of its own it reads and writes none of the real app's.
    func launchApp() throws -> MacDriver {
        var environment = Self.ownHome(home)
        environment.merge(appEnvironment) { _, own in own }
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["AGENTTERM_PORT"] = String(appPort)
        // The home the host was given: on its own Mac the app reads
        // history from the home folder itself, not through the host.
        environment["CFFIXED_USER_HOME"] = home.path
        // Under a name of its own, the app keeps its preferences apart from
        // those of an AgentTerm someone runs from this build folder: macOS
        // files the preferences of a program without a bundle under its name.
        // A release build of the app, for figures of the build users run
        // (`RELEASE_APP=1 scripts/test-mac.sh`, #178): built beside the
        // debug one, the host and the tests staying the debug build's.
        let appProducts = ProcessInfo.processInfo.environment["AGENTTERM_RELEASE_APP"] != nil ? products.deletingLastPathComponent().appendingPathComponent("Release") : products
        let executable = appProducts.appendingPathComponent(Self.appName)
        if !FileManager.default.fileExists(atPath: executable.path) {
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: appProducts.appendingPathComponent("AgentTermMac"))
        }
        let driver = try startDriver(executable: executable, environment: environment)
        driver.wait(for: .id("mac-switcher"), timeout: 20)
        return driver
    }

    /// Quits the app and opens it again, on the same host.
    func relaunchApp(whileClosed: () -> Void = {}) throws {
        app.quit()
        whileClosed()
        app = try launchApp()
    }

    /// A link that pairs one device with a host, as its pairing window shows.
    func pairingLink(state: URL, port: UInt16, name: String) -> String {
        let process = Process()
        process.executableURL = products.appendingPathComponent("agenttermd")
        process.arguments = ["pairing-link", "--port", String(port), "--host", "127.0.0.1", "--name", name]
        var environment = Self.withoutAgentTerms
        environment["AGENTTERM_STATE_DIR"] = state.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Another device on the same host, a phone say, to see what the Mac
    /// app did and to do things the Mac app has to show.
    final class Device {
        let connection: AgentTermConnection
        private(set) var messages: [ServerMessage] = []
        private(set) var output: [SessionID: Data] = [:]

        init(port: UInt16, token: String, name: String) {
            // Says what it is, so that it is told the notices (#66).
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: name, kind: .iphone)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.onOutput = { [weak self] id, data in self?.output[id, default: Data()].append(data) }
            connection.connect()
        }

        func last<Value>(_ pick: (ServerMessage) -> Value?) -> Value? { messages.compactMap(pick).last }

        /// The Inbox row of the last notice of a session (#66).
        func inboxRow(_ session: SessionID) -> String {
            let notice = messages.compactMap { message -> Notice? in
                if case .notice(let notice) = message, notice.session == session { return notice }
                return nil
            }.last
            return "inbox-notice-\(notice?.id ?? 0)"
        }
        var sessions: [SessionInfo] { last { if case .sessions(let list) = $0 { return list } else { return nil } } ?? [] }
        var folders: [String] { last { if case .folders(let list) = $0 { return list } else { return nil } } ?? [] }
        var tabLayout: TabLayout? { last { if case .tabLayout(let layout) = $0 { return layout } else { return nil } } }
        var keepAwake: Bool? { last { if case .keepAwake(let on) = $0 { return on } else { return nil } } }
        var display: DisplaySettings? { last { if case .displaySettings(let settings) = $0 { return settings } else { return nil } } ?? nil }
        var commitWriter: CommitWriterSettings? { last { if case .commitWriter(let settings) = $0 { return settings } else { return nil } } }
        var failures: [PartFailure]? { last { if case .failures(let list) = $0 { return list } else { return nil } } }
        /// The size a session has now, as told to a device that is attached to it.
        func size(of session: SessionID) -> TermSize? {
            last { if case .resized(session, let size, _, _) = $0 { return size } else { return nil } }
        }
        func text(_ session: SessionID) -> String { String(decoding: output[session] ?? Data(), as: UTF8.self) }
        func send(_ message: ClientMessage) { connection.send(message) }
    }

    func device(_ name: String = "iPhone", state: URL? = nil, port: UInt16? = nil) throws -> Device {
        let token = try String(contentsOf: (state ?? self.state).appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Device(port: port ?? self.port, token: token, name: name)
        clients.append(device.connection)
        wait("the device to be welcomed") { device.messages.contains { if case .welcome = $0 { return true } else { return false } } }
        return device
    }

    /// Waits for something to hold, with the run loop turning: answers
    /// from the host arrive on it.
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)" + (app.map { ". On screen:\n\($0.screen())" } ?? ""), file: file, line: line)
    }
}
