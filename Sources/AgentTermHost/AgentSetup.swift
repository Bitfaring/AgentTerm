#if os(macOS)
import AgentTermProtocol
import Foundation

/// Adds what AgentTerm needs of each agent to the agent's own configuration
/// (#129), when the user asks: `agenttermd setup`, or Install in Settings >
/// Hooks & MCP. AgentTerm starts the agents with nothing of its own; this is
/// how they get its hooks, its MCP server, what it tells them, and for
/// Claude Code the status line it reads the usage from.
///
/// Each agent gets them through its own commands, found by running each,
/// at the version in use (2026-11-17, #129; `docs/AGENT-CLIS.md`):
///
/// - Claude Code: a plugin, from a marketplace in a folder of AgentTerm's
///   (`claude plugin marketplace add`, `claude plugin install`), with the
///   hooks and the server; the status line goes in its settings, the one
///   the user had kept and run after AgentTerm's (`StatusLineRelay`).
/// - Copilot CLI: a plugin the same way, in its own layout.
/// - Codex: a plugin with the server, which names the session's variable
///   in `env_vars`, as Codex passes no other; its hooks in `config.toml`,
///   each under a comment that says whose it is, as Codex takes hooks
///   nowhere else (`plugin_hooks` was removed from it), and asks the user
///   to review them. And the server
///   its sessions share turned off, with `codex features disable` (#140):
///   through it no hook and no server is any one session's.
/// - Antigravity: a plugin of its own layout (`agy plugin install`), with
///   the hooks, the server and the words it is told as a rule.
///
/// All of it at the user's scope, for every folder, never a project's
/// (decided by the owner on 2026-11-17): Claude Code's with `--scope user`,
/// the others' own configuration in the home folder, which is all they
/// write. Each build has its own names (`AppChannel.mcpServerName`) and
/// folder, and takes out only its own (principle 7).
public final class AgentSetup: @unchecked Sendable {
    /// Runs an agent's command line; its status and what it printed, nil
    /// when it could not be run.
    public typealias Run = (_ arguments: [String]) -> (status: Int32, output: String)?

    /// The host's program, which the hooks, the server and the status line run.
    public let tool: String
    /// The name of the plugins, the marketplaces and the server.
    public let name: String
    /// Where the plugins are kept: the build's state folder.
    let directory: URL
    /// The user's home, whose agents' configuration is written.
    let home: String
    let environment: [String: String]
    private let run: Run
    private let locate: () -> [AgentInfo]
    private let prompt: (String) -> String?
    private let lock = NSLock()
    private var problems: [String: String] = [:]

    /// - Parameters:
    ///   - directory: Where the plugins are written.
    ///   - tool: The host's program.
    ///   - locate: Finds the agents; a test stands its own in.
    ///   - prompt: What AgentTerm tells an agent, for Antigravity's rule.
    ///   - run: Runs an agent's command; through the user's login shell
    ///     unless a test stands in for it.
    public init(
        directory: URL, tool: String, home: String = HostEnvironment.homeDirectory, name: String = AppChannel.current.mcpServerName,
        environment: [String: String] = ProcessInfo.processInfo.environment, locate: @escaping () -> [AgentInfo] = AgentDetector.detect,
        prompt: @escaping (String) -> String? = AgentSetup.savedPrompt, run: Run? = nil
    ) {
        self.directory = directory
        self.tool = tool
        self.home = home
        self.name = name
        self.environment = environment
        self.locate = locate
        self.prompt = prompt
        self.run = run ?? { AgentSetup.throughLoginShell($0, home: home) }
    }

    // MARK: Asked

    /// The command that sets an agent up, or every installed one, as typed
    /// in a terminal.
    public static func command(tool: String, agent: String?, remove: Bool = false) -> String {
        Handoff.shellQuote(tool) + " setup " + (agent ?? "all") + (remove ? " --remove" : "")
    }

    /// What each known agent has of AgentTerm's, asked of the agents
    /// themselves. Blocks while they answer.
    public func report() -> AgentSetupReport {
        let found = locate()
        return AgentSetupReport(
            agents: AgentDetector.known.map { known in
                state(of: known.id, name: known.name, path: found.first { $0.id == known.id }?.path)
            })
    }

    func state(of agent: String, name agentName: String, path: String?) -> AgentSetupState {
        var state = AgentSetupState(
            agent: agent, name: agentName, installed: path != nil, command: Self.command(tool: tool, agent: agent),
            removeCommand: Self.command(tool: tool, agent: agent, remove: true), note: Self.note(for: agent), problem: problem(of: agent))
        guard let path else { return state }
        switch agent {
        case "claude":
            let plugin = Self.listed(run([path, "plugin", "list"])?.output, id: "\(name)@\(name)")
            state.hooks = plugin
            state.mcp = plugin
            state.statusLine = claudeStatusLineIsOurs()
        case "codex":
            state.mcp = Self.listed(run([path, "plugin", "list"])?.output, id: "\(name)@\(name)")
            state.hooks = codexHooksAreThere(in: (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "")
            // The server its sessions share (#140), in a Codex that has one:
            // out of the way once Codex does not start it by itself and it
            // does not run. Running, it is used whatever the setting says.
            if let startsItself = Self.feature(Self.codexSharedServer, in: run([path, "features", "list"])?.output) {
                var off = !startsItself
                if off, Self.sharedServerRuns(run([path, "app-server", "daemon", "version"])?.output) {
                    off = false
                    state.problem = state.problem ?? AgentSetupWords.sharedServerRunning
                }
                state.sharedServerOff = off
                state.note = [state.note, AgentSetupWords.sharedServerNote].compactMap { $0 }.joined(separator: " ")
            }
        case "copilot":
            let plugin = Self.listed(run([path, "plugin", "list"])?.output, id: "\(name)@\(name)")
            state.hooks = plugin
            state.mcp = plugin
        case "agy":
            let plugin = Self.listed(run([path, "plugin", "list"])?.output, id: "- \(name) (")
            state.hooks = plugin
            state.mcp = plugin
        default:
            break
        }
        return state
    }

    /// What else the user should know of an agent's setup.
    static func note(for agent: String) -> String? {
        switch agent {
        case "codex":
            return "Codex keeps hooks only in its config.toml, where each is added under a comment that says it is AgentTerm's, and asks to review them the next time it starts: trust them there."
        case "agy":
            return "Antigravity keeps a copy of what it is told: install again after changing the words in Settings > Agents."
        default:
            return nil
        }
    }

    /// Whether an agent's list of plugins has one, enabled: nil when the
    /// agent could not be asked.
    static func listed(_ output: String?, id: String) -> Bool? {
        guard let output else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(id) }) else { return false }
        // Its line, and the ones under it up to the next plugin.
        var block = [lines[index]]
        for line in lines[(index + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("❯") || trimmed.hasPrefix("•") || trimmed.hasPrefix("- ") || trimmed.contains("@") { break }
            block.append(line)
        }
        let text = block.joined(separator: " ").lowercased()
        if text.contains("not installed") || text.contains("disabled") { return false }
        return text.contains("enabled")
    }

    // MARK: Done

    /// Adds AgentTerm's to an agent's configuration. What did not work is
    /// kept for the report, in the agent's own words.
    public func install(_ agent: String) {
        guard let path = locate().first(where: { $0.id == agent })?.path else {
            return setProblem(agent, "It is not installed on this Mac.")
        }
        do {
            switch agent {
            case "claude":
                let market = try writeClaudeMarketplace()
                try step([path, "plugin", "marketplace", "add", market.path, "--scope", "user"], allowing: "already")
                _ = run([path, "plugin", "marketplace", "update", name])
                try step([path, "plugin", "install", "\(name)@\(name)", "--scope", "user"], allowing: "already")
                _ = run([path, "plugin", "update", "\(name)@\(name)", "--scope", "user"])
                try setClaudeStatusLine()
            case "codex":
                let market = try writeCodexMarketplace()
                try step([path, "plugin", "marketplace", "add", market.path], allowing: "already")
                // Codex keeps a copy of a plugin: the one of before goes.
                _ = run([path, "plugin", "remove", "\(name)@\(name)"])
                try step([path, "plugin", "add", "\(name)@\(name)"])
                try addCodexHooks(path: path)
                try turnCodexSharedServerOff(path: path)
            case "copilot":
                let market = try writeCopilotMarketplace()
                try step([path, "plugin", "marketplace", "add", market.path], allowing: "already")
                try step([path, "plugin", "install", "\(name)@\(name)"], allowing: "already")
            case "agy":
                let plugin = try writeAntigravityPlugin()
                // Antigravity keeps a copy too.
                _ = run([path, "plugin", "uninstall", name])
                try step([path, "plugin", "install", plugin.path])
            default:
                return
            }
            setProblem(agent, nil)
        } catch let failure as Failure {
            setProblem(agent, failure.text)
        } catch {
            setProblem(agent, error.localizedDescription)
        }
    }

    /// Takes AgentTerm's out of an agent's configuration, and only this
    /// build's: the user's own is left as it was.
    public func remove(_ agent: String) {
        guard let path = locate().first(where: { $0.id == agent })?.path else {
            return setProblem(agent, "It is not installed on this Mac.")
        }
        do {
            switch agent {
            case "claude":
                _ = run([path, "plugin", "uninstall", "\(name)@\(name)", "--scope", "user"])
                _ = run([path, "plugin", "marketplace", "remove", name])
                try restoreClaudeStatusLine()
            case "codex":
                _ = run([path, "plugin", "remove", "\(name)@\(name)"])
                _ = run([path, "plugin", "marketplace", "remove", name])
                try removeCodexHooks()
                turnCodexSharedServerOnAgain(path: path)
            case "copilot":
                _ = run([path, "plugin", "uninstall", "\(name)@\(name)"])
                _ = run([path, "plugin", "marketplace", "remove", name])
            case "agy":
                _ = run([path, "plugin", "uninstall", name])
            default:
                return
            }
            setProblem(agent, nil)
        } catch let failure as Failure {
            setProblem(agent, failure.text)
        } catch {
            setProblem(agent, error.localizedDescription)
        }
    }

    struct Failure: Error {
        let text: String
    }

    /// Runs an agent's command, which has to work; one that says
    /// `allowing` (it is there already) is taken to have.
    private func step(_ arguments: [String], allowing: String? = nil) throws {
        guard let result = run(arguments) else { throw Failure(text: "`\(arguments.dropFirst().joined(separator: " "))` could not be run.") }
        guard result.status != 0 else { return }
        if let allowing, result.output.lowercased().contains(allowing) { return }
        let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure(text: "`\((arguments.first as NSString?)?.lastPathComponent ?? "") \(arguments.dropFirst().joined(separator: " "))` failed" + (said.isEmpty ? "." : ": " + said))
    }

    private func problem(of agent: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return problems[agent]
    }

    private func setProblem(_ agent: String, _ text: String?) {
        lock.lock()
        problems[agent] = text
        lock.unlock()
    }

    // MARK: The plugins

    private var version: String { AppVersion.current == "dev" ? "0.0.0-dev" : AppVersion.current }
    private let summary = "Tells AgentTerm what the agent is doing, and gives it shells and pages the user sees"

    /// The hooks an agent is given: the one of its start, which says at once
    /// that they are there, and those that say what it is doing.
    static func events(of agent: String) -> [String] {
        switch agent {
        case "claude": return ["SessionStart"] + AgentHooks.claudeEvents
        case "codex": return ["SessionStart"] + AgentHooks.codexEvents
        case "copilot": return ["sessionStart"] + AgentHooks.copilotEvents
        case "agy": return ["SessionStart"] + AgentHooks.antigravityEvents
        default: return []
        }
    }

    /// A marketplace of Claude Code's layout, which Codex and Copilot CLI
    /// read too, with one plugin in `plugin`.
    private func writeMarketplace(for agent: String) throws -> (root: URL, plugin: URL) {
        let root = directory.appendingPathComponent(agent, isDirectory: true)
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        try? FileManager.default.removeItem(at: plugin)
        try Self.write(
            ["name": name, "owner": ["name": "AgentTerm"], "plugins": [["name": name, "source": "./plugin", "description": summary]]],
            to: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        return (root, plugin)
    }

    func writeClaudeMarketplace() throws -> URL {
        let (root, plugin) = try writeMarketplace(for: "claude")
        try Self.write(["name": name, "version": version, "description": summary], to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        var hooks: [String: Any] = [:]
        for event in Self.events(of: "claude") {
            hooks[event] = [["hooks": [["type": "command", "command": AgentHooks.command(tool: tool, agent: "claude", event: event)]]]]
        }
        try Self.write(["hooks": hooks], to: plugin.appendingPathComponent("hooks/hooks.json"))
        try Self.write(["mcpServers": [name: ["command": tool, "args": ["mcp"]]]], to: plugin.appendingPathComponent(".mcp.json"))
        return root
    }

    func writeCodexMarketplace() throws -> URL {
        let (root, plugin) = try writeMarketplace(for: "codex")
        try Self.write(["name": name, "version": version, "description": summary], to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        let server: [String: Any] = ["command": tool, "args": ["mcp"], "env_vars": [HostServer.agentShellsVariable]]
        try Self.write(["mcpServers": [name: server]], to: plugin.appendingPathComponent(".mcp.json"))
        return root
    }

    func writeCopilotMarketplace() throws -> URL {
        let (root, plugin) = try writeMarketplace(for: "copilot")
        try Self.write(["name": name, "version": version, "description": summary], to: plugin.appendingPathComponent("plugin.json"))
        var hooks: [String: Any] = [:]
        for event in Self.events(of: "copilot") {
            hooks[event] = [["type": "command", "bash": AgentHooks.command(tool: tool, agent: "copilot", event: event), "timeoutSec": 10]]
        }
        try Self.write(["version": 1, "hooks": hooks], to: plugin.appendingPathComponent("hooks.json"))
        try Self.write(
            ["mcpServers": [name: ["type": "local", "command": tool, "args": ["mcp"], "tools": ["*"]]]], to: plugin.appendingPathComponent(".mcp.json"))
        return root
    }

    func writeAntigravityPlugin() throws -> URL {
        let plugin = directory.appendingPathComponent("agy/plugin", isDirectory: true)
        try? FileManager.default.removeItem(at: plugin)
        try Self.write(["name": name, "version": version, "description": summary], to: plugin.appendingPathComponent("plugin.json"))
        var events: [String: Any] = [:]
        for event in Self.events(of: "agy") {
            let hook: [String: Any] = ["type": "command", "command": AgentHooks.command(tool: tool, agent: "agy", event: event), "timeout": 10]
            events[event] = event.hasSuffix("ToolUse") ? [["matcher": "*", "hooks": [hook]]] : [hook]
        }
        try Self.write([name: events], to: plugin.appendingPathComponent("hooks.json"))
        try Self.write(["mcpServers": [name: ["command": tool, "args": ["mcp"]]]], to: plugin.appendingPathComponent("mcp_config.json"))
        // It takes no MCP server's instructions: what it is told is a rule,
        // which it reads everywhere, so it says when it holds: in AgentTerm,
        // where the server has tools; outside, it has none.
        if let words = prompt("agy") {
            let rule = plugin.appendingPathComponent("rules/\(name).md")
            try FileManager.default.createDirectory(at: rule.deletingLastPathComponent(), withIntermediateDirectories: true)
            let when = "Only when the \(name) MCP server offers you its tools, which it does inside AgentTerm and nowhere else:\n\n"
            try Data(("---\ntrigger: always_on\n---\n" + when + words + "\n").utf8).write(to: rule, options: .atomic)
        }
        return plugin
    }

    // MARK: Claude Code's status line

    private var claudeSettings: URL {
        let configuration = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        return URL(fileURLWithPath: configuration).appendingPathComponent("settings.json")
    }

    /// The status line the user had before AgentTerm's, which AgentTerm's
    /// runs after it and puts back when it is removed.
    public static func previousStatusLine(in directory: URL) -> URL { directory.appendingPathComponent("claude/previous-status-line.json") }

    /// AgentTerm's status line command: it finds the file of its session
    /// in the session's environment (`AppChannel.usageVariable`).
    public var statusLineCommand: String { Handoff.shellQuote(tool) + " statusline" }

    /// Whether Claude Code's status line is AgentTerm's: nil when it is
    /// another build's, which runs the one it took the place of after its
    /// own, this build's maybe: Claude Code has one status line, the build
    /// set up last has it.
    private func claudeStatusLineIsOurs() -> Bool? {
        guard let settings = try? Self.readJSON(claudeSettings), let line = settings["statusLine"] as? [String: Any],
            let command = line["command"] as? String
        else { return false }
        if command == statusLineCommand { return true }
        return command.hasSuffix(" statusline") && command.contains("agenttermd") ? nil : false
    }

    func setClaudeStatusLine() throws {
        // Settings that are not plain JSON are not rewritten.
        var settings = try Self.readJSON(claudeSettings) ?? [:]
        if let current = settings["statusLine"] as? [String: Any], (current["command"] as? String) != statusLineCommand {
            try Self.write(current, to: Self.previousStatusLine(in: directory))
        }
        settings["statusLine"] = ["type": "command", "command": statusLineCommand]
        try Self.write(settings, to: claudeSettings)
    }

    func restoreClaudeStatusLine() throws {
        guard var settings = try Self.readJSON(claudeSettings), let current = settings["statusLine"] as? [String: Any],
            (current["command"] as? String) == statusLineCommand
        else { return }
        let previous = Self.previousStatusLine(in: directory)
        settings["statusLine"] = try? Self.readJSON(previous)
        try Self.write(settings, to: claudeSettings)
        try? FileManager.default.removeItem(at: previous)
    }

    // MARK: Codex's hooks

    var codexConfig: URL {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: home).appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("config.toml")
    }

    /// How the comment over each hook of this build's begins: it names the
    /// build, and by it a hook is this build's, wherever the host's
    /// program is now. Over each hook, not around them all: Codex keeps
    /// the comments a file ends with at its end, and writes a table it
    /// adds above them, so a closing mark took in what Codex added after,
    /// the user's own, and Remove took that out with the hooks (#142; seen
    /// with Codex 0.169.1, `[features]`). A comment over a table stays
    /// with it.
    var codexHookMark: String { "# AgentTerm's hook (\(name))" }

    /// The marks builds before #142 wrote around the hooks.
    var codexMarks: (start: String, end: String) { ("# >>> AgentTerm's hooks (\(name))", "# <<< AgentTerm's hooks (\(name))") }

    /// The three lines of a hook of this build's: the comment that says
    /// so, its table, and its command.
    func codexHook(_ event: String) -> [String] {
        [
            codexHookMark + ", added by `\(Self.command(tool: tool, agent: "codex"))`; `--remove` takes it out.",
            "[[hooks.\(event)]]",
            "hooks = [{ type = \"command\", command = \(AgentHooks.tomlString(AgentHooks.command(tool: tool, agent: "codex", event: event))) }]",
        ]
    }

    /// The event of a hook AgentTerm wrote, of which `table` and `command`
    /// are the two lines, whichever build's program the command runs; nil
    /// for any other two lines.
    static func codexHookEvent(table: String, command: String) -> String? {
        guard table.hasPrefix("[[hooks."), table.hasSuffix("]]") else { return nil }
        let event = String(table.dropFirst(8).dropLast(2))
        guard !event.isEmpty, event.allSatisfy(\.isLetter), command.hasPrefix("hooks = [{ type = \"command\", command = \""),
            command.hasSuffix(" hook codex \(event)\" }]")
        else { return nil }
        return event
    }

    /// Whether every hook this build gives Codex is in its configuration,
    /// with the command it has now.
    func codexHooksAreThere(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        return Self.events(of: "codex").allSatisfy { event in
            let hook = codexHook(event)
            return lines.indices.dropFirst().contains { lines[$0] == hook[2] && lines[$0 - 1] == hook[1] }
        }
    }

    /// Codex's configuration without this build's hooks. Each is taken out
    /// by its own lines: the comment that names the build, with the table
    /// and the command under it, wherever Codex has them now. Between the
    /// marks of a build before #142, the hooks and the marks go, and what
    /// Codex put between them stays. Nothing else is taken out.
    func withoutCodexHooks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var gone = IndexSet()
        // Under the opening mark of a build before #142, as far as the
        // hooks follow one another.
        var between = false
        for index in lines.indices where !gone.contains(index) {
            let line = lines[index]
            if line.hasPrefix(codexMarks.start) {
                between = true
                gone.insert(index)
            } else if line == codexMarks.end {
                between = false
                gone.insert(index)
            } else if index + 1 < lines.count, Self.codexHookEvent(table: line, command: lines[index + 1]) != nil,
                between || (index > 0 && lines[index - 1].hasPrefix(codexHookMark + ","))
            {
                gone.formUnion(IndexSet(integersIn: index...(index + 1)))
                if !between { gone.insert(index - 1) }
            } else {
                between = false
            }
        }
        // The empty line that set them apart goes with them.
        for index in lines.indices where lines[index].isEmpty && !gone.contains(index) {
            guard let next = lines.indices.first(where: { $0 > index && !gone.contains($0) }) else { continue }
            if next > index + 1, lines[next].isEmpty { gone.insert(index) }
        }
        lines = lines.indices.filter { !gone.contains($0) }.map { lines[$0] }
        var rest = lines.joined(separator: "\n")
        while rest.hasSuffix("\n\n") { rest.removeLast() }
        return rest
    }

    func addCodexHooks(path: String) throws {
        let file = codexConfig
        let before = try? String(contentsOf: file, encoding: .utf8)
        var text = withoutCodexHooks(before ?? "")
        let block = Self.events(of: "codex").flatMap(codexHook)
        if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
        text += block.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        // Read by Codex as it reads its own, or put back as it was.
        if let checked = run([path, "features", "list"]), checked.status != 0 {
            if let before { try? Data(before.utf8).write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            throw Failure(text: "Codex could not read its configuration with AgentTerm's hooks in it, so it was left as it was: " + checked.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func removeCodexHooks() throws {
        let file = codexConfig
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let rest = withoutCodexHooks(text)
        guard rest != text else { return }
        try Data(rest.utf8).write(to: file, options: .atomic)
    }

    // MARK: Codex's shared server (#140)

    /// The feature of Codex that has it start, by itself, the background
    /// server its sessions share (`codex app-server`). Tried with Codex
    /// 0.169.1 on 2026-11-18, in a home of the trial's own
    /// (`docs/AGENT-CLIS.md`): that server starts each session's hooks and
    /// MCP server in the environment of the session that started it, so
    /// AgentTerm cannot tell which session they are of. With the feature
    /// off and no such server running, each session runs by itself, and its
    /// hooks and server are its own. A server that runs is used whatever
    /// the feature says, and stopping it leaves the sessions that use it
    /// waiting ("Reconnecting to server…"): that is left to the user, and
    /// said.
    static let codexSharedServer = "daemon_auto_start"

    /// Kept while this build turned the feature off, for Remove to turn it
    /// on again: one the user had off is left off.
    var codexSharedServerWasOn: URL { directory.appendingPathComponent("codex/shared-server-was-on") }

    /// Whether a feature is on, in what `codex features list` printed: its
    /// name, its stage, and `true` or `false` last. Nil when it is not
    /// listed, as in a Codex that has no such feature, or when Codex could
    /// not be asked.
    static func feature(_ name: String, in output: String?) -> Bool? {
        for line in (output ?? "").components(separatedBy: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first.map(String.init) == name, let last = words.last else { continue }
            if last == "true" { return true }
            if last == "false" { return false }
        }
        return nil
    }

    /// Whether the shared server runs, in what
    /// `codex app-server daemon version` printed: a line of JSON whose
    /// status is "running"; an error when there is none.
    static func sharedServerRuns(_ output: String?) -> Bool {
        for line in (output ?? "").components(separatedBy: "\n") {
            guard let start = line.firstIndex(of: "{"),
                let said = (try? JSONSerialization.jsonObject(with: Data(line[start...].utf8))) as? [String: Any], let status = said["status"] as? String
            else { continue }
            return status == "running"
        }
        return false
    }

    /// Turns the feature off with Codex's own command, when it is on.
    func turnCodexSharedServerOff(path: String) throws {
        guard Self.feature(Self.codexSharedServer, in: run([path, "features", "list"])?.output) == true else { return }
        try step([path, "features", "disable", Self.codexSharedServer])
        try FileManager.default.createDirectory(at: codexSharedServerWasOn.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: codexSharedServerWasOn)
    }

    /// Turns it on again with Codex's own command, when this build turned
    /// it off, and no other build of AgentTerm is still set up in Codex:
    /// that one needs it off as much. (Then it stays off when that other
    /// build is taken out later, which did not turn it off: with both
    /// builds on one Mac, `codex features enable daemon_auto_start` puts it
    /// back.)
    func turnCodexSharedServerOnAgain(path: String) {
        guard FileManager.default.fileExists(atPath: codexSharedServerWasOn.path) else { return }
        let plugins = run([path, "plugin", "list"])?.output
        let others = [AppChannel.release, .dev].map(\.mcpServerName).filter { $0 != name }
        guard !others.contains(where: { Self.listed(plugins, id: "\($0)@\($0)") == true }) else { return }
        if Self.feature(Self.codexSharedServer, in: run([path, "features", "list"])?.output) == false {
            _ = run([path, "features", "enable", Self.codexSharedServer])
        }
        try? FileManager.default.removeItem(at: codexSharedServerWasOn)
    }

    // MARK: Files

    static func readJSON(_ file: URL) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(text: "\(file.path) is not a JSON object, so it was not changed.")
        }
        return object
    }

    static func write(_ object: Any, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// What AgentTerm tells an agent, as the host wrote it for the servers.
    public static func savedPrompt(_ agent: String) -> String? {
        (try? String(contentsOf: HostServer.promptFile(for: agent), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Runs a program by itself, for a test's stand-in agents.
    public static func direct(_ arguments: [String], home: String) -> (status: Int32, output: String)? {
        guard let program = arguments.first,
            let result = Subprocess.run(program, Array(arguments.dropFirst()), cwd: home, timeout: 30, mergeErrors: true, environment: ["HOME": home, "PATH": "/usr/bin:/bin"])
        else { return nil }
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }

    /// As in a terminal: the agents find their sign-in and their PATH there.
    private static func throughLoginShell(_ arguments: [String], home: String) -> (status: Int32, output: String)? {
        let line = arguments.map(Handoff.shellQuote).joined(separator: " ")
        guard let result = Subprocess.run(HostEnvironment.shell, ["-l", "-i", "-c", line], cwd: home, timeout: 120, mergeErrors: true) else { return nil }
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }
}
#endif
