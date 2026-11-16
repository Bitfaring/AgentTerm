#if os(macOS)
import AgentTermProtocol
import Foundation

/// The MCP server an agent is given (#10): `agenttermd mcp`, which speaks MCP
/// as JSON-RPC, one message to a line, on standard input and output, and
/// asks the running host for what an agent's tools do.
///
/// It offers its tools only inside a session of an agent its own build of
/// AgentTerm started, whose environment names the host's port, the
/// session's key and the build (`HostServer.agentShellsVariable`).
/// Elsewhere, in a terminal of another app or in a session of the other
/// build (#57), it offers none.
public final class AgentShellsMCP {
    /// Asks the host, and waits for its answer.
    public typealias Ask = (AgentShellRequest) -> AgentShellResult
    /// Asks the browser, through the host (#76), and waits for its answer.
    public typealias AskBrowser = (BrowserRequest) -> BrowserResult

    /// What a session's variable tells its agent's server: the host to ask,
    /// as which session, and whether the agent is to run its commands in
    /// the shells. Written as `<port> <key> <channel> [use]`.
    public struct Session: Equatable {
        public var port: UInt16
        public var key: String
        public var useShells: Bool
        /// The agent the session is of, whose instructions the server gives.
        public var agent: String?

        public init(port: UInt16, key: String, useShells: Bool, agent: String? = nil) {
            self.port = port
            self.key = key
            self.useShells = useShells
            self.agent = agent
        }

        /// The variable's value, for a session of the build `channel`.
        public func variable(channel: AppChannel = .current) -> String {
            "\(port) \(key) \(channel.rawValue)" + (useShells ? " use" : "") + (agent.map { " agent:" + $0 } ?? "")
        }

        /// What the variable says, or nil when it names no session, or one
        /// of another build than `channel`: that build's host has a token
        /// of its own, and its own server is the one to answer there. A
        /// variable that names no build is from before the builds had a
        /// server each, when only the released one was meant to.
        public init?(variable: String?, channel: AppChannel = .current) {
            let words = variable?.split(separator: " ").map(String.init) ?? []
            guard words.count >= 2, let port = UInt16(words[0]) else { return nil }
            let rest = words.dropFirst(2)
            let named = rest.compactMap(AppChannel.init(rawValue:)).first ?? .release
            guard named == channel else { return nil }
            let agent = rest.first { $0.hasPrefix("agent:") }.map { String($0.dropFirst(6)) }
            self.init(port: port, key: words[1], useShells: rest.contains("use"), agent: agent)
        }
    }

    private let ask: Ask?
    private let askBrowser: AskBrowser?
    /// For the browser's tools, in their own file.
    var browserAsker: AskBrowser? { askBrowser }
    private let name: String
    private let version: String
    /// The agent is to run its commands in these shells.
    private let useShells: Bool
    /// How long `wait` looks between two reads of the screen.
    var pollInterval: TimeInterval = 0.2

    /// Tool calls are answered side by side (#64): one that takes long, a
    /// `wait`, does not hold up the others of the same agent.
    private let calls = DispatchQueue(label: "agentterm.mcp.calls", attributes: .concurrent)
    private let lock = NSLock()
    /// The calls going on, by their request's id, and those of them that
    /// were cancelled: a cancelled one ends, and is not answered.
    private var running: Set<String> = []
    private var cancelled: Set<String> = []
    /// The commands `shell_run` left running, by shell: what a later
    /// `shell_wait` tells the end of, also when it ended in between. The
    /// number is the count of commands started before it.
    private var unfinished: [SessionID: Int] = [:]

    private func unfinished(_ session: SessionID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return unfinished[session]
    }

    private func setUnfinished(_ session: SessionID, _ after: Int?) {
        lock.lock()
        unfinished[session] = after
        lock.unlock()
    }

    /// A request's id as the key it is kept under: a number or a string.
    private static func key(_ id: Any) -> String { id is String ? "s:\(id)" : "n:\(id)" }

    private func isCancelled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(key)
    }

    /// - Parameters:
    ///   - ask: Nil outside a session of this build of AgentTerm: no tools then.
    ///   - name: The server's name in the agents' configuration.
    /// What the user wrote in Settings for the agent, or the default the
    /// host worked out, as the host left it for the agent's server: given
    /// as the server's instructions in place of its own.
    private let instructions: String?

    public init(
        ask: Ask?, askBrowser: AskBrowser? = nil, name: String = AppChannel.current.mcpServerName, version: String, useShells: Bool = false,
        instructions: String? = nil
    ) {
        self.ask = ask
        self.askBrowser = askBrowser
        self.instructions = instructions
        self.name = name
        self.version = version
        self.useShells = useShells
    }

    /// Takes one line, a JSON-RPC message, and hands its answer to `reply`
    /// (#64): at once for most, and for a tool call when the tool is done,
    /// which for a `wait` may be long after later lines were answered. Each
    /// request is answered once, by its id. A notification is not
    /// answered, and neither is a call that was cancelled meanwhile
    /// (`notifications/cancelled`), which ends there.
    public func handle(_ line: String, reply: @escaping (String) -> Void) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            if let answer = handle(line) { reply(answer) }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        if message["method"] as? String == "notifications/cancelled", let id = params["requestId"] {
            lock.lock()
            if running.contains(Self.key(id)) { cancelled.insert(Self.key(id)) }
            lock.unlock()
            return
        }
        guard message["method"] as? String == "tools/call", let id = message["id"] else {
            if let answer = handle(line) { reply(answer) }
            return
        }
        let key = Self.key(id)
        lock.lock()
        running.insert(key)
        lock.unlock()
        calls.async { [self] in
            let answer = answer(message, isCancelled: { self.isCancelled(key) })
            lock.lock()
            running.remove(key)
            let dropped = cancelled.remove(key) != nil
            lock.unlock()
            if !dropped, let answer { reply(answer) }
        }
    }

    /// Answers one line, a JSON-RPC message, and returns when it is
    /// answered. Nil for a notification, which is not answered.
    public func handle(_ line: String) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        return answer(message, isCancelled: { false })
    }

    private func answer(_ message: [String: Any], isCancelled: @escaping () -> Bool) -> String? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> String? { Self.encode(["jsonrpc": "2.0", "id": id, "result": value]) }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": name, "version": version],
                "instructions": ask == nil
                    ? "Not in a session of AgentTerm: no tools."
                    : instructions
                        ?? (useShells
                            ? AgentShellsInstructions.useShells(server: name)
                            : "Open shells the user can see in AgentTerm, next to your session, and work in them: shell_open, then shell_run for each command, which returns its exit code and output once it ends. Use them for what keeps running or what the user should watch: an SSH session, a dev server, a REPL. You see and use only the shells you opened: shell_list lists them.")
                            + (askBrowser == nil ? "" : "\n\n" + AgentShellsInstructions.browser(server: name))
                    ,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": ask == nil ? [] : Self.tools + (askBrowser == nil ? [] : Self.browserTools)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if name.hasPrefix("browser_") {
                let (content, failed) = callBrowser(name, arguments)
                return result(["content": content, "isError": failed])
            }
            let (text, failed) = call(name, arguments, isCancelled: isCancelled)
            return result(["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: The tools

    /// The shells' tools, named alike as the browser's are, so that an agent
    /// that looks its tools up by name finds them together.
    static let tools: [[String: Any]] = [
        tool(
            "shell_open",
            "Opens a shell in a new AgentTerm tab, in your folder, that the user sees and can type in, and returns its number once it is ready. Without a command it is a login shell, to run commands in with shell_run; with one (`npm run dev`, `ssh build-server`) it runs that program, to type into with shell_send. Starting an agent is refused.",
            ["command": string("A program to run instead of a shell prompt; none for a shell"), "title": string("The tab's name")], required: [],
            title: "Open a shell"),
        tool(
            "shell_run",
            "Runs a command in a shell you opened, as typed at its prompt, waits until it ends, and returns its exit code and its output, only what it wrote. A command still running when the time is up keeps running: shell_wait waits for it to end, shell_stop stops it. For a program that asks questions or keeps running (a REPL, a dev server), type into it with shell_send instead.",
            [
                "session": integer("The shell's number"), "command": string("The command, as typed at the prompt; several lines are one command"),
                "timeout_seconds": number("At most this long; 60 by default"),
            ],
            required: ["session", "command"], title: "Run a command"),
        tool(
            "shell_list",
            "The shells you opened that are still open, with their numbers and folders. Another agent's, and the user's own, you do not see.",
            [:], required: [], title: "List your shells", readOnly: true),
        tool(
            "shell_read", "The screen as text of a shell you opened, with lines above it when asked.",
            ["session": integer("The shell's number"), "lines_above": integer("How many lines above the screen to include; 0 by default")],
            required: ["session"], title: "Read a shell's screen", readOnly: true),
        tool(
            "shell_send",
            "Types into a shell you opened: text, then keys by name, as a person would, without waiting. For a program that asks something, a REPL, or to stop a command with Control C. Keys: Return, Tab, Escape, Backspace, Up, Down, Left, Right, Home, End, Page Up, Page Down, Delete, Control A to Control Z.",
            ["session": integer("The shell's number"), "text": string("Text to type"), "keys": ["type": "array", "items": ["type": "string"], "description": "Keys to press after the text"]],
            required: ["session"], title: "Type into a shell"),
        tool(
            "shell_wait",
            "Waits, and returns what came of it. With a text, until it is on the screen. Without, until the command running in the shell ends, with its exit code and output; when none runs, until the screen has been still for a moment.",
            [
                "session": integer("The shell's number"), "until_text": string("Wait until this text is on the screen"),
                "quiet_seconds": number("How long the screen must stay the same, when no command is waited for; 1 by default"),
                "timeout_seconds": number("At most this long; 60 by default"),
            ],
            required: ["session"], title: "Wait on a shell", readOnly: true),
        tool(
            "shell_stop",
            "Stops what runs in a shell you opened, as Control C does, and says how it ended, with its exit code and output. The shell stays open for the next command. When nothing runs, it says so.",
            ["session": integer("The shell's number"), "timeout_seconds": number("How long to wait for it to end; 5 by default")],
            required: ["session"], title: "Stop a command"),
        tool(
            "shell_close", "Ends a shell you opened, when you no longer need it.", ["session": integer("The shell's number")], required: ["session"],
            title: "Close a shell", destructive: true),
    ]

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any], required: [String], title: String, readOnly: Bool = false,
        destructive: Bool = false
    ) -> [String: Any] {
        var annotations: [String: Any] = ["title": title, "readOnlyHint": readOnly, "openWorldHint": false]
        if !readOnly { annotations["destructiveHint"] = destructive }
        return [
            "name": name, "title": title, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": annotations,
        ]
    }
    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

    /// What a tool returns, and whether it failed.
    private func call(_ name: String, _ arguments: [String: Any], isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("Not in a session of AgentTerm: there are no shells to open.", true) }
        let session = (arguments["session"] as? NSNumber).map { SessionID(truncatingIfNeeded: $0.intValue) }
        func needsSession() -> (String, Bool) { ("Which shell: give its number as `session`.", true) }
        let result: AgentShellResult
        let timeout = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 60
        switch name {
        case "shell_open":
            let command = (arguments["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result = ask(.open(command: command, title: arguments["title"] as? String))
            if case .opened(let shell) = result {
                guard command == nil else { return (Self.words(result).0 + " It runs that program: type into it with shell_send.", false) }
                ready(shell.id, isCancelled: isCancelled)
                return (Self.words(result).0 + " Run commands in it with shell_run.", false)
            }
        case "shell_run":
            guard let session else { return needsSession() }
            guard let command = arguments["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("Which command: give it as `command`.", true)
            }
            return run(command, in: session, timeout: timeout, isCancelled: isCancelled)
        case "shell_list":
            result = ask(.list)
        case "shell_read":
            guard let session else { return needsSession() }
            result = ask(.read(session: session, linesAbove: (arguments["lines_above"] as? NSNumber)?.intValue ?? 0))
        case "shell_send":
            guard let session else { return needsSession() }
            result = ask(.send(session: session, text: arguments["text"] as? String, keys: arguments["keys"] as? [String] ?? []))
        case "shell_wait":
            guard let session else { return needsSession() }
            let until = (arguments["until_text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let quiet = (arguments["quiet_seconds"] as? NSNumber)?.doubleValue
            // The command shell_run left running, also once it ended, or
            // the one that runs, when nothing else is asked for.
            if until == nil, quiet == nil {
                if let after = unfinished(session) {
                    return awaitCommand(in: session, after: after, timeout: timeout, isCancelled: isCancelled)
                }
                if case .command(let state) = ask(.command(session: session, lines: 0)), state.integrated, state.running {
                    return awaitCommand(in: session, after: state.started - 1, timeout: timeout, isCancelled: isCancelled)
                }
            }
            return wait(session: session, until: until, quiet: quiet ?? 1, timeout: timeout, isCancelled: isCancelled)
        case "shell_stop":
            guard let session else { return needsSession() }
            return stop(session, timeout: (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 5, isCancelled: isCancelled)
        case "shell_close":
            guard let session else { return needsSession() }
            result = ask(.close(session: session))
        default:
            return ("There is no tool called \(name).", true)
        }
        return Self.words(result)
    }

    /// Stops what runs in a shell, as Control C typed in it does, and waits
    /// for it to end: what an agent is asked to do when the user says stop.
    private func stop(_ session: SessionID, timeout: TimeInterval, isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("", true) }
        let asked = ask(.command(session: session, lines: 0))
        guard case .command(let before) = asked else { return Self.words(asked) }
        // A shell that says when its commands end, and none runs.
        if before.integrated, !before.running {
            setUnfinished(session, nil)
            return ("Nothing runs in shell \(session): it is at its prompt.", false)
        }
        let sent = ask(.send(session: session, text: nil, keys: ["Control C"]))
        guard case .done = sent else { return Self.words(sent) }
        guard before.integrated else {
            // A program, or a shell that does not say: its screen tells.
            Thread.sleep(forTimeInterval: min(max(pollInterval * 3, 0.3), 1))
            let screen = Self.words(ask(.read(session: session, linesAbove: 0))).0
            return ("Control C was typed in shell \(session), which does not say when a command ends. Its screen:\n\n\(screen)", false)
        }
        let started = Date()
        while true {
            if isCancelled() { return ("Cancelled.", true) }
            let now = ask(.command(session: session, lines: Self.outputLines))
            guard case .command(let state) = now else {
                setUnfinished(session, nil)
                return Self.words(now)
            }
            if !state.running {
                setUnfinished(session, nil)
                return ("Stopped. " + Self.ended(state), false)
            }
            if Date().timeIntervalSince(started) >= timeout {
                return (
                    "Control C was typed, and the command still runs after \(Self.seconds(timeout)): it may take it as input, or ignore it. "
                        + "Look with shell_read, stop it again, or end the shell with shell_close.", true
                )
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// How many lines of a command's output are given, its last.
    static let outputLines = 300

    /// Until a shell that was set up to say when its commands end has shown
    /// its first prompt, or, for one that says nothing, its screen is still:
    /// a command typed sooner is still run, but would not be known to start.
    private func ready(_ session: SessionID, isCancelled: () -> Bool) {
        let started = Date()
        while Date().timeIntervalSince(started) < 15, !isCancelled() {
            guard case .command(let state) = ask?(.command(session: session, lines: 0)) else { return }
            if state.integrated { return }
            if !state.prepared {
                _ = wait(session: session, until: nil, quiet: 0.5, timeout: 5, isCancelled: isCancelled)
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Types a command and waits for it to end: its exit code and output,
    /// or, from a shell that does not say when its commands end, its screen
    /// once it is still.
    private func run(_ command: String, in session: SessionID, timeout: TimeInterval, isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("", true) }
        // A shell still starting says nothing yet: it is waited for.
        if case .command(let state) = ask(.command(session: session, lines: 0)), state.prepared, !state.integrated {
            ready(session, isCancelled: isCancelled)
        }
        let typed = ask(.run(session: session, command: command))
        guard case .ran(let before) = typed else { return Self.words(typed) }
        guard before.integrated else {
            let (screen, failed) = wait(session: session, until: nil, quiet: 1, timeout: timeout, isCancelled: isCancelled)
            return (
                "This shell does not say when a command ends, nor its exit code (it is not zsh, or it runs a program): its screen once it was still.\n\n"
                    + screen, failed
            )
        }
        return awaitCommand(in: session, after: before.started, timeout: timeout, isCancelled: isCancelled)
    }

    /// Waits until a command after the `after`th has started and ended.
    private func awaitCommand(in session: SessionID, after: Int, timeout: TimeInterval, isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("", true) }
        let started = Date()
        while true {
            if isCancelled() { return ("Cancelled.", true) }
            let asked = ask(.command(session: session, lines: Self.outputLines))
            guard case .command(let state) = asked else {
                setUnfinished(session, nil)
                return Self.words(asked)
            }
            if state.started > after, !state.running {
                setUnfinished(session, nil)
                return (Self.ended(state), false)
            }
            if Date().timeIntervalSince(started) >= timeout {
                setUnfinished(session, after)
                guard state.started > after else {
                    let screen = Self.words(ask(.read(session: session, linesAbove: 0))).0
                    return (
                        "No command started in \(Self.seconds(timeout)): the shell may be in a program that waits for input. Its screen:\n\n\(screen)",
                        false
                    )
                }
                return (
                    "Still running after \(Self.seconds(Date().timeIntervalSince(started))). "
                        + Self.output(state, empty: "No output yet.", heading: "The output so far")
                        + "\n\nWait for it to end with shell_wait, or stop it with shell_stop.", false
                )
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// A command that ended, in words for the agent.
    static func ended(_ state: AgentCommand) -> String {
        "Exit code \(state.exitCode.map(String.init) ?? "not known")." + " " + output(state, empty: "No output.", heading: "Its output")
    }

    private static func output(_ state: AgentCommand, empty: String, heading: String) -> String {
        guard !state.output.isEmpty else { return empty }
        let lines = state.output.split(separator: "\n", omittingEmptySubsequences: false).count
        let left = state.linesLeftOut > 0 ? ", its last \(lines) of \(lines + state.linesLeftOut) lines (shell_read with lines_above shows more)" : ""
        return "\(heading)\(left):\n\n\(state.output)"
    }

    /// Reads the screen until it says `until`, or has stayed the same for
    /// `quiet` seconds, or `timeout` seconds have passed.
    private func wait(session: SessionID, until: String?, quiet: TimeInterval, timeout: TimeInterval, isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("", true) }
        let started = Date()
        var last: String?
        var stillSince = Date()
        while true {
            // Nobody listens any more: it ends here, and is not answered.
            if isCancelled() { return ("Cancelled.", true) }
            guard case .screen(let screen) = ask(.read(session: session, linesAbove: 0)) else {
                return Self.words(ask(.read(session: session, linesAbove: 0)))
            }
            if let until, !until.isEmpty, screen.contains(until) { return ("“\(until)” is on the screen:\n\n\(screen)", false) }
            if screen != last {
                last = screen
                stillSince = Date()
            } else if until == nil || until?.isEmpty == true, Date().timeIntervalSince(stillSince) >= quiet {
                return ("The screen has been still for \(Self.seconds(quiet)):\n\n\(screen)", false)
            }
            if Date().timeIntervalSince(started) >= timeout {
                return ("Still waiting after \(Self.seconds(timeout)); the screen now:\n\n\(screen)", false)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    /// A result in words for the agent.
    static func words(_ result: AgentShellResult) -> (String, Bool) {
        switch result {
        case .opened(let shell): return ("Opened shell \(shell.id), “\(shell.title)”, in \(shell.cwd).", false)
        case .shells(let list):
            if list.isEmpty { return ("You have no shell open: open one with shell_open.", false) }
            return (list.map { "\($0.id): \($0.title), in \($0.cwd)" }.joined(separator: "\n"), false)
        case .screen(let text): return (text, false)
        case .done: return ("Done.", false)
        case .refused(let why): return (why, true)
        case .ran: return ("Typed.", false)
        case .command(let state): return (state.running ? output(state, empty: "Running, no output yet.", heading: "Running; its output") : ended(state), false)
        }
    }

    private static func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}
#endif
