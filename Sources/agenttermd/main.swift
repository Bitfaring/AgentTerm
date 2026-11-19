import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Foundation

// agenttermd: the AgentTerm host daemon. It owns the terminal sessions so they
// keep running when the app window is closed.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

var port = agenttermDefaultPort
var listenOnTailscale = true
var askServices = true
var protocolVersion = agenttermProtocolVersion
var release = AppVersion.current
var revision = AppVersion.hostRevision
var home = NSHomeDirectory()
var agentsDirectory: String?
var arguments = CommandLine.arguments.dropFirst()

/// Where `agenttermd setup` keeps the plugins it gives the agents (#129).
var setupDirectory: URL { HostEnvironment.supportDirectory.appendingPathComponent("agent-setup", isDirectory: true) }

enum StartedBy {
    /// Whether the agent that started this program runs in no terminal
    /// (#140), as Codex's shared app server does. Looked at once, when it
    /// is first asked.
    static let anAgentInNoTerminal = ProcessNames.agentInNoTerminal(startedBy: getppid(), known: { SessionSummaries.agent(forCommand: $0) }) != nil
}

/// What the environment says of the session this was started in, by the
/// name of a variable: nothing when the agent that started it runs in no
/// terminal (#140). Codex's shared app server has the environment of the
/// session that started it, not of the session it works for. A hook, the
/// MCP server and the status line then do as they do outside AgentTerm.
/// See `ProcessNames.agentInNoTerminal`.
func sessionEnvironment(_ name: String) -> String? {
    guard !StartedBy.anAgentInNoTerminal else { return nil }
    return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

// `agenttermd statusline` is Claude Code's status line, once
// `agenttermd setup claude` put it in its settings (#129): it saves what it
// is given in the file its session names, then runs the status line the
// user had before. See StatusLineRelay.
if arguments.first == "statusline" {
    arguments.removeFirst()
    let file = arguments.popFirst() ?? sessionEnvironment(AppChannel.current.usageVariable)
    let output = StatusLineRelay.run(
        input: FileHandle.standardInput.readDataToEndOfFile(), file: file, previous: AgentSetup.previousStatusLine(in: setupDirectory))
    FileHandle.standardOutput.write(output)
    exit(0)
}

// `agenttermd setup [claude|codex|copilot|agy|all] [--remove]` adds to the
// agents' own configuration what they have no command of their own for:
// their hooks, Claude Code's status line, and for Codex the session's
// variable its server needs; or takes that out. AgentTerm's MCP server is
// added with each agent's own command (`claude mcp add …`), which this
// says when the server is missing; `setup status` says what each has
// (#129). Only when the user runs it: Install in Settings > Hooks & MCP
// runs the agents' commands and this.
if arguments.first == "setup" {
    arguments.removeFirst()
    var agent: String?
    var remove = false
    var statusOnly = false
    while let argument = arguments.popFirst() {
        switch argument {
        case "--remove": remove = true
        case "status": statusOnly = true
        case "all": agent = nil
        case let name where AgentDetector.known.contains { $0.id == name }: agent = name
        default: fail("setup: \(argument) is no agent; name claude, codex, copilot or agy, all, or status, and --remove to take them out", status: 2)
        }
    }
    guard let tool = Bundle.main.executablePath else { fail("setup: the path of this program is not known", status: 1) }
    let setup = AgentSetup(directory: setupDirectory, tool: tool)
    if !statusOnly {
        let agents = agent.map { [$0] } ?? setup.report().agents.filter(\.installed).map(\.agent)
        for each in agents {
            print((remove ? "Removing from " : "Setting up ") + (AgentDetector.known.first { $0.id == each }?.name ?? each) + "…")
            if remove { setup.remove(each, .own) } else { setup.install(each, .own) }
        }
    }
    var failed = false
    for state in setup.report().agents where agent == nil || state.agent == agent {
        guard state.installed else {
            print("\(state.name): not installed")
            continue
        }
        func mark(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "not known" }
        var line = "\(state.name): hooks \(mark(state.hooks)), MCP server \(mark(state.mcp))"
        if let statusLine = state.statusLine { line += ", status line " + (statusLine ? "yes" : "no") }
        if let off = state.sharedServerOff { line += ", " + AgentSetupWords.sharedServer(off: off).lowercased() }
        print(line)
        if let problem = state.problem {
            print("  " + problem)
            failed = true
        }
        // What is still to add, with the agent's own command: every step
        // but the last, which is this program's.
        if !remove {
            var missing: [AgentSetupStep] = []
            // Not for Codex's, added and given nothing of its session: this
            // program names the variable, as its problem says.
            if state.mcp == false, state.problem != AgentSetupWords.codexVariableMissing, let server = state.steps.first { missing.append(server) }
            // Not for one that is off and still runs: its problem says what to do.
            if state.sharedServerOff == false, state.problem != AgentSetupWords.sharedServerRunning, state.steps.count > 2 { missing.append(state.steps[1]) }
            for step in missing {
                print("  " + step.title)
                print("    " + step.command)
            }
        }
        if let note = state.note, !remove, !statusOnly { print("  " + note) }
    }
    exit(failed ? 1 : 0)
}

// `agenttermd hook <agent> <event>` is what the hooks of an agent started by
// AgentTerm run: it saves what the agent tells it for the host, in the file
// AGENTTERM_EVENTS names. It never fails the agent's hook. See AgentHooks.
if arguments.first == "hook" {
    arguments.removeFirst()
    let agent = arguments.popFirst() ?? ""
    let event = arguments.popFirst() ?? ""
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let file = sessionEnvironment(AppChannel.current.eventsVariable) {
        AgentHooks.save(input, agent: agent, event: event, to: file)
    }
    if let reply = AgentHooks.reply(agent: agent, event: event) { print(reply) }
    exit(0)
}

// `agenttermd mcp` is AgentTerm's MCP server, which `agenttermd setup` adds to
// the agents' own configuration (#10, #129). Inside a session of this build
// of AgentTerm, an agent's or a shell's an agent was typed in, it asks the
// host on this Mac, as that session, for what the agent's tools do, and says
// it started; elsewhere, a session of the other build included (#57), it
// offers no tools. Nor does it when the agent that started it runs in no
// terminal (#140): it cannot be any one session's.
if arguments.first == "mcp" {
    var ask: AgentShellsMCP.Ask?
    var askBrowser: AgentShellsMCP.AskBrowser?
    let session = AgentShellsMCP.Session(variable: sessionEnvironment(HostServer.agentShellsVariable))
    // The agent it serves: the session's, or the one that started it, for
    // one typed in a shell.
    let agent = session?.agent ?? ProcessNames.agent(above: getppid(), known: { SessionSummaries.agent(forCommand: $0) })
    if let session, let token = try? HostEnvironment.loadOrCreateToken() {
        let link = AgentShellsLink(port: session.port, key: session.key, token: token)
        link.start()
        link.announce(agent: agent)
        ask = link.ask
        askBrowser = link.askBrowser
    }
    // What the host worked out for this session's agent, the user's words
    // in Settings or the default: the server's instructions.
    let instructions = session == nil ? nil : agent.flatMap { AgentSetup.savedPrompt($0) }
    let server = AgentShellsMCP(
        ask: ask, askBrowser: askBrowser, version: AppChannel.current.appName, useShells: session?.useShells ?? false, instructions: instructions)
    // Lines are read in turn, off the main queue, where the connection's
    // answers arrive. Each is answered when its answer is there (#64): a
    // tool that takes long, a `wait`, does not hold up the lines after it.
    // An answer is one line, written whole.
    let output = NSLock()
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            server.handle(line) { reply in
                output.lock()
                print(reply)
                fflush(stdout)
                output.unlock()
            }
        }
        exit(0)
    }
    dispatchMain()
}

// `agenttermd pairing-link` asks the running daemon for a pairing code and
// prints the link an iPhone can pair with. Meant for the iOS Simulator, which
// has no camera, and for tests.
if arguments.first == "pairing-link" {
    arguments.removeFirst()
    var host: String?
    var name: String?
    while let argument = arguments.popFirst() {
        switch argument {
        case "--name":
            guard let value = arguments.popFirst() else { fail("--name needs a name", status: 2) }
            name = value
        case "--port":
            guard let value = arguments.popFirst().flatMap(UInt16.init) else { fail("--port needs a number", status: 2) }
            port = value
        case "--host":
            guard let value = arguments.popFirst() else { fail("--host needs a name or address", status: 2) }
            host = value
        default:
            fail("unknown option \(argument)", status: 2)
        }
    }
    printPairingLink(port: port, host: host, name: name)
}

// `agenttermd take-control` plays a Mac that starts using a session: it
// waits for the daemon's first session, types a command in it at a size of
// its own, and stays attached for a while. For testing what a phone shows
// while the Mac has a session. Not in the help.
if arguments.first == "take-control" {
    arguments.removeFirst()
    var size = TermSize(cols: 150, rows: 45)
    var hold: TimeInterval = 30
    var wait: TimeInterval = 0
    var typed = ""
    while let argument = arguments.popFirst() {
        switch argument {
        case "--port":
            guard let value = arguments.popFirst().flatMap(UInt16.init) else { fail("--port needs a number", status: 2) }
            port = value
        case "--cols":
            guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--cols needs a number", status: 2) }
            size.cols = value
        case "--rows":
            guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--rows needs a number", status: 2) }
            size.rows = value
        case "--hold":
            guard let value = arguments.popFirst().flatMap(TimeInterval.init) else { fail("--hold needs seconds", status: 2) }
            hold = value
        case "--after":
            guard let value = arguments.popFirst().flatMap(TimeInterval.init) else { fail("--after needs seconds", status: 2) }
            wait = value
        case "--type":
            guard let value = arguments.popFirst() else { fail("--type needs text", status: 2) }
            typed = value
        default:
            fail("unknown option \(argument)", status: 2)
        }
    }
    takeControl(port: port, size: size, after: wait, typing: typed, hold: hold)
}

while let argument = arguments.popFirst() {
    switch argument {
    case "--port":
        guard let value = arguments.popFirst().flatMap(UInt16.init) else {
            FileHandle.standardError.write(Data("agenttermd: --port needs a number\n".utf8))
            exit(2)
        }
        port = value
    case "--local-only":
        listenOnTailscale = false
    case "--no-account-usage":
        askServices = false
    case "--protocol-version":
        // For testing the apps against a host of another release. Not in the help.
        guard let value = arguments.popFirst().flatMap(Int.init) else { fail("--protocol-version needs a number", status: 2) }
        protocolVersion = value
    case "--app-version":
        // For testing the Mac against a host left from another release (#121). Not in the help.
        guard let value = arguments.popFirst() else { fail("--app-version needs a version", status: 2) }
        release = value
    case "--host-revision":
        // For testing the Mac against a host built from other sources (#121). Not in the help.
        guard let value = arguments.popFirst() else { fail("--host-revision needs a value", status: 2) }
        revision = value
    case "--home":
        guard let value = arguments.popFirst() else { fail("--home needs a folder", status: 2) }
        home = value
    case "--agents":
        guard let value = arguments.popFirst() else { fail("--agents needs a folder", status: 2) }
        agentsDirectory = value
    case "--help", "-h":
        print(
            """
            Usage: agenttermd [--port N] [--local-only]
                   agenttermd pairing-link [--port N] [--host NAME] [--name LABEL]

              --port N       TCP port to listen on, or of the daemon to ask (default \(agenttermDefaultPort))
              --local-only   Listen on 127.0.0.1 only, not on the Tailscale address
              --no-account-usage
                             Do not ask the agents' services what their accounts
                             have left. Their sign-ins are then never read.
              --home DIR     Read agent history from DIR instead of the home folder,
                             and start the folder picker there (for tests)
              --agents DIR   Take the agents' programs from DIR only, instead of
                             looking for the installed ones (for tests)

            pairing-link prints a link that pairs one device with the running
            daemon. It works once and for five minutes. --host sets the name the
            device should connect to (default: this Mac's Tailscale name, or
            127.0.0.1 when Tailscale is not connected). --name sets what the device
            calls this Mac (default: the Mac's name).
            """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("agenttermd: unknown option \(argument)\n".utf8))
        exit(2)
    }
}
// The host that an app started for a test starts listens on 127.0.0.1
// only, as the tests' own hosts do (`--local-only`): the app is given
// this, and its host has the app's environment (#179).
if ProcessInfo.processInfo.environment["AGENTTERM_LOCAL_ONLY"] == "1" { listenOnTailscale = false }

let server: HostServer
do {
    let token = try HostEnvironment.loadOrCreateToken()
    var configuration = HostServer.Configuration(
        port: port, token: token, listenOnTailscale: listenOnTailscale, foldersFile: HostEnvironment.foldersFile, devicesFile: HostEnvironment.devicesFile, home: home,
        statusLineTool: Bundle.main.executablePath, usageDirectory: HostEnvironment.usageDirectory, fetchAccountUsage: askServices ? { AccountUsageFetcher.fetch(agent: $0) } : nil)
    configuration.protocolVersion = protocolVersion
    configuration.release = release
    configuration.revision = revision
    configuration.hooksDirectory = HostEnvironment.supportDirectory.appendingPathComponent("hooks", isDirectory: true)
    // Notices through Apple for the devices that are away (#66): the
    // released host's relay, none for a development build. A test names a
    // stand-in of its own. Not in the help.
    configuration.pushRelay = ProcessInfo.processInfo.environment["AGENTTERM_PUSH_RELAY"].flatMap(URL.init(string:)) ?? PushRelay.url(for: AppChannel.current)
    configuration.pushesFile = HostEnvironment.pushesFile
    configuration.noticesFile = HostEnvironment.noticesFile
    // For the tests of the apps, which do not wait the whole grace. Not in the help.
    if let grace = ProcessInfo.processInfo.environment["AGENTTERM_LINK_GRACE"].flatMap(TimeInterval.init) { configuration.linkGrace = grace }
    // Gives the agents' sessions the MCP server, and takes out what earlier
    // builds put in the agents' own configuration, for this Mac's host
    // only: not for one with a state folder of its own (a test, a trial
    // run), which must leave the user's agents alone.
    if (ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"] ?? "").isEmpty, agentsDirectory == nil, let tool = Bundle.main.executablePath {
        configuration.agentShells = AgentShellsSetup(directory: HostEnvironment.supportDirectory, tool: tool)
        // Sets the agents up when the user asks, in Settings > Hooks & MCP.
        configuration.agentSetup = AgentSetup(directory: setupDirectory, tool: tool)
    } else if let agentsDirectory, let tool = Bundle.main.executablePath {
        // A test's: its stand-in agents, in its own home, and nothing of
        // the user's.
        configuration.agentSetup = AgentSetup(
            directory: setupDirectory, tool: tool, home: home, environment: [:], locate: { AgentDetector.detect(in: agentsDirectory) },
            run: { AgentSetup.direct($0, home: home) })
    }
    // Notes that it runs, so the next host knows whether this one died.
    configuration.stateDirectory = HostEnvironment.supportDirectory
    if let agentsDirectory {
        configuration.detectAgents = { AgentDetector.detect(in: agentsDirectory) }
        configuration.agentsDirectory = agentsDirectory
    }
    // Started at login, when the user asked for that. The app may have been
    // moved since: launchd has to start the host of the app that is here now.
    configuration.loginItem = LoginItem.forThisHost()
    configuration.loginItem?.refresh()
    server = HostServer(configuration: configuration)
    let bound = try server.start()
    print("agenttermd listening on 127.0.0.1:\(bound)")
} catch HostServer.StartError.keepsDying(let count) {
    // With status 0, so that launchd does not start it again: it is broken
    // until the user asks for it. The next host reports it.
    FileHandle.standardError.write(Data("agenttermd: \(HostServer.StartError.keepsDying(count))\n".utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("agenttermd: \(error)\n".utf8))
    exit(1)
}

// Hang up every session on shutdown, like closing a terminal window does.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agenttermd: \(message)\n".utf8))
    exit(status)
}

func takeControl(port: UInt16, size: TermSize, after wait: TimeInterval, typing typed: String, hold: TimeInterval) -> Never {
    guard let token = try? HostEnvironment.loadOrCreateToken() else { fail("could not read this Mac's token") }
    let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac (test)")
    var taken = false
    connection.onMessage = { message in
        switch message {
        case .sessions(let list):
            // The first session, once, some time after it appeared: a
            // phone that opens it takes its size first.
            guard !taken, let session = list.first else { return }
            taken = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                connection.send(.attach(session: session.id, size: size))
                connection.send(.takeControl(session: session.id, size: size))
                if !typed.isEmpty { connection.sendInput(Data((typed + "\r").utf8), to: session.id) }
                print("took session \(session.id) at \(size.cols)x\(size.rows)")
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(0) }
            }
        case .error(let text):
            fail(text)
        default:
            break
        }
    }
    connection.onState = { state in
        if case .closed(let reason) = state { fail("no daemon answered on port \(port)" + (reason.map { ": \($0)" } ?? "")) }
    }
    connection.connect()
    dispatchMain()
}

func printPairingLink(port: UInt16, host: String?, name: String?) -> Never {
    guard let token = try? HostEnvironment.loadOrCreateToken() else { fail("could not read this Mac's token") }
    var target = host
    if target == nil, case .ready(let name) = Tailscale.status() { target = name }
    let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "agenttermd")
    connection.onMessage = { message in
        switch message {
        case .welcome:
            connection.send(.createPairingCode)
        case .pairingCode(let code, _):
            let info = PairingInfo(host: target ?? "127.0.0.1", port: port, code: code, name: name ?? Host.current().localizedName ?? "Mac")
            print(info.url.absoluteString)
            exit(0)
        case .error(let text):
            fail(text)
        default:
            break
        }
    }
    connection.onState = { state in
        if case .closed(let reason) = state { fail("no daemon answered on port \(port)" + (reason.map { ": \($0)" } ?? "")) }
    }
    connection.connect()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { fail("timed out waiting for the daemon on port \(port)") }
    dispatchMain()
}
