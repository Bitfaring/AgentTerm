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
///   between marks, as Codex takes hooks nowhere else (`plugin_hooks` was
///   removed from it), and asks the user to review them.
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
            state.hooks = Self.block(in: (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "", marks: codexMarks) != nil
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
            return "Codex keeps hooks only in its config.toml, where they are added between marks, and asks to review them the next time it starts: trust them there."
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

    var codexMarks: (start: String, end: String) { ("# >>> AgentTerm's hooks (\(name))", "# <<< AgentTerm's hooks (\(name))") }

    /// The lines between the marks, the marks included, if they are there.
    static func block(in text: String, marks: (start: String, end: String)) -> Range<String.Index>? {
        guard let start = text.range(of: marks.start), let end = text.range(of: marks.end, range: start.upperBound..<text.endIndex) else { return nil }
        let lineEnd = text[end.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
        return start.lowerBound..<lineEnd
    }

    static func without(_ marks: (start: String, end: String), in text: String) -> String {
        guard let range = block(in: text, marks: marks) else { return text }
        var rest = text
        rest.removeSubrange(range)
        while rest.hasSuffix("\n\n") { rest.removeLast() }
        return rest
    }

    func addCodexHooks(path: String) throws {
        let file = codexConfig
        let before = try? String(contentsOf: file, encoding: .utf8)
        var text = Self.without(codexMarks, in: before ?? "")
        var block = [codexMarks.start + ", added by `\(Self.command(tool: tool, agent: "codex"))`; `--remove` takes them out."]
        for event in Self.events(of: "codex") {
            block.append("[[hooks.\(event)]]")
            block.append("hooks = [{ type = \"command\", command = \(AgentHooks.tomlString(AgentHooks.command(tool: tool, agent: "codex", event: event))) }]")
        }
        block.append(codexMarks.end)
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
        guard let text = try? String(contentsOf: file, encoding: .utf8), Self.block(in: text, marks: codexMarks) != nil else { return }
        try Data(Self.without(codexMarks, in: text).utf8).write(to: file, options: .atomic)
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
