#if os(macOS)
import AgentTermProtocol
import Foundation

/// How the host learns what the agent in a session is doing (#3): from the
/// agent itself, through its hooks, never from what is on the screen.
///
/// AgentTerm gives an agent nothing on its command line (#129): the hooks
/// are in the agent's own configuration, which `agenttermd setup` adds to
/// when the user asks (`AgentSetup`), and run in every session of that
/// agent. Each runs `agenttermd hook <agent> <event>`, which saves what it is
/// told in the file the session's environment names
/// (`AppChannel.eventsVariable`), and does nothing outside a session of
/// this build of AgentTerm.
public enum AgentHooks {
    /// The variable that names the file a session's hooks write to.
    public static var eventsVariable: String { AppChannel.current.eventsVariable }

    static let claudeEvents = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop"]
    static let codexEvents = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
    static let copilotEvents = ["userPromptSubmitted", "preToolUse", "permissionRequest", "postToolUse", "postToolUseFailure", "agentStop"]
    static let antigravityEvents = ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"]

    /// AgentTerm's MCP server, as a session's agent is given it: its name,
    /// the build's (`AppChannel.mcpServerName`), and the host's program,
    /// which it runs as `<tool> mcp`.
    public struct Server: Equatable, Sendable {
        public var name: String
        public var tool: String

        public init(name: String, tool: String) {
            self.name = name
            self.tool = tool
        }
    }

    /// What a hook runs.
    static func command(tool: String, agent: String, event: String) -> String {
        Handoff.shellQuote(tool) + " hook " + agent + " " + event
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// What a schedule's run of Antigravity is started with (#11): the
    /// schedule's folders trusted for that run, next to those the user
    /// trusts already, read from their settings and not changed:
    /// `--settings` is for this session only.
    public static func antigravityTrust(_ folders: [String], home: String) -> String? {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let own = FileManager.default.contents(atPath: file.path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var trusted = own?["trustedWorkspaces"] as? [String] ?? []
        for path in folders where !trusted.contains(path) { trusted.append(path) }
        guard let settings = try? JSONSerialization.data(withJSONObject: ["trustedWorkspaces": trusted], options: [.sortedKeys]) else { return nil }
        return " --settings " + Handoff.shellQuote(String(decoding: settings, as: UTF8.self))
    }

    /// What an agent's environment is given besides: for Copilot CLI, the
    /// folder of instructions it is told to run its commands in shells the
    /// user sees, next to any its own environment names (MCP-13).
    public static func instructionsEnvironment(agent: String, directory: URL?, prompt: String?, current: [String: String]) throws -> [String: String] {
        guard agent == "copilot", let prompt, let directory else { return [:] }
        let folder = directory.appendingPathComponent("copilot-instructions", isDirectory: true)
        let file = folder.appendingPathComponent("instructions/agentterm.instructions.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeText("---\napplyTo: \"**\"\n---\n" + prompt + "\n", to: file)
        let name = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        let theirs = current[name].flatMap { $0.isEmpty ? nil : $0 }
        return [name: [theirs, folder.path].compactMap { $0 }.joined(separator: ",")]
    }

    private static func writeText(_ text: String, to file: URL) throws {
        if FileManager.default.contents(atPath: file.path) == Data(text.utf8) { return }
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    // MARK: What a hook does

    /// Saves what a hook was told, for the host: the latest event only,
    /// since the state follows from it.
    public static func save(_ input: Data, agent: String, event: String, to file: String, now: Date = Date()) {
        let told = (try? JSONSerialization.jsonObject(with: input)) ?? [:]
        let record: [String: Any] = ["agent": agent, "event": event, "at": now.timeIntervalSince1970, "input": told]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// What a hook prints back to its agent. Antigravity asks every
    /// `PreToolUse` hook for a decision; "allow" leaves it to its own rules
    /// (it asks the user as it would without the hook). The others need
    /// nothing.
    public static func reply(agent: String, event: String) -> String? {
        guard agent == "agy" else { return nil }
        return event == "PreToolUse" ? #"{"decision":"allow"}"# : "{}"
    }

    // MARK: What the host makes of it

    public enum Change: Equatable {
        /// The session's state becomes this (nil: not known).
        case set(AgentState?)
        /// The event says nothing new.
        case keep
    }

    /// The state an event puts a session in, from what each agent was seen
    /// to tell its hooks.
    public static func change(agent: String, event: String, input: [String: Any], now: Date = Date()) -> Change {
        switch agent {
        case "claude": return claude(event, input, now)
        case "codex": return codex(event, input, now)
        case "copilot": return copilot(event, input, now)
        case "agy": return antigravity(event, input, now)
        default: return .keep
        }
    }

    private static func claude(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        let tool = input["tool_name"] as? String
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        switch event {
        case "UserPromptSubmit", "PostToolUse": return .set(.working(since: now))
        case "PreToolUse", "PermissionRequest":
            if tool == "AskUserQuestion", let question = claudeQuestion(toolInput) { return .set(.waitingForAnswer(question)) }
            if event == "PreToolUse" { return .set(.working(since: now)) }
            return .set(.waitingForPermission(AgentQuestion(text: describe(tool: tool, input: toolInput))))
        case "Notification":
            guard input["notification_type"] as? String == "elicitation_dialog" else { return .keep }
            return .set(.waitingForAnswer(AgentQuestion(text: input["message"] as? String ?? "")))
        case "Stop": return .set(.done(said: input["last_assistant_message"] as? String))
        default: return .keep
        }
    }

    private static func claudeQuestion(_ input: [String: Any]) -> AgentQuestion? {
        guard let first = (input["questions"] as? [[String: Any]])?.first, let text = first["question"] as? String else { return nil }
        let choices = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return AgentQuestion(text: text, choices: choices)
    }

    private static func codex(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .set(.working(since: now))
        case "PermissionRequest":
            let toolInput = input["tool_input"] as? [String: Any] ?? [:]
            let text = (toolInput["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? describe(tool: input["tool_name"] as? String, input: toolInput)
            return .set(.waitingForPermission(AgentQuestion(text: text)))
        case "Stop": return .set(.done(said: input["last_assistant_message"] as? String))
        // The user stopped the turn: what comes next is not known.
        case "Interrupt": return .set(nil)
        default: return .keep
        }
    }

    private static func copilot(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        let tool = input["toolName"] as? String
        switch event {
        case "userPromptSubmitted", "postToolUse", "postToolUseFailure": return .set(.working(since: now))
        case "preToolUse":
            if tool == "ask_user", let args = input["toolArgs"] as? [String: Any] {
                let properties = (args["requestedSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
                let choices = properties.values.compactMap { ($0 as? [String: Any])?["enum"] as? [String] }.first ?? []
                return .set(.waitingForAnswer(AgentQuestion(text: args["message"] as? String ?? "", choices: choices)))
            }
            return .set(.working(since: now))
        case "permissionRequest":
            let toolInput = input["toolInput"] as? [String: Any] ?? [:]
            return .set(.waitingForPermission(AgentQuestion(text: describe(tool: tool, input: toolInput))))
        case "agentStop": return .set(.done(said: nil))
        default: return .keep
        }
    }

    /// Antigravity says nothing when it waits for permission: its question
    /// comes after `PreToolUse`, with nothing in between. So while a tool
    /// runs, its state is not known: running and waiting look the same.
    private static func antigravity(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        switch event {
        case "PreInvocation", "PostToolUse": return .set(.working(since: now))
        case "PreToolUse":
            let call = input["toolCall"] as? [String: Any] ?? [:]
            if call["name"] as? String == "ask_question",
                let first = ((call["args"] as? [String: Any])?["questions"] as? [[String: Any]])?.first,
                let text = first["question"] as? String
            {
                return .set(.waitingForAnswer(AgentQuestion(text: text, choices: first["options"] as? [String] ?? [])))
            }
            return .set(nil)
        case "Stop":
            // Background work of its own may still run.
            guard input["fullyIdle"] as? Bool != false else { return .keep }
            return .set(.done(said: nil))
        default: return .keep
        }
    }

    /// The tool of AgentTerm's own MCP server that Antigravity says it is
    /// about to call, as Antigravity names it in its question
    /// (`<server>/<tool>`); nil for any other event or tool.
    ///
    /// Antigravity 1.5.10 has no hook for the leave it asks ("Allow calling
    /// this tool?"), and says nothing while it waits (tried 2026-11-18): its
    /// `PreToolUse` comes, with `toolCall` `call_mcp_tool` and the server's
    /// and the tool's names in `args`, then nothing until it is answered.
    /// But a call of AgentTerm's own tool, once made, reaches AgentTerm's
    /// server: one that was announced and does not come is held, which
    /// Antigravity does for nothing but that question (#141).
    public static func ownToolCall(agent: String, event: String, input: [String: Any], server: String) -> String? {
        guard agent == "agy", event == "PreToolUse", let call = input["toolCall"] as? [String: Any], call["name"] as? String == "call_mcp_tool",
            let args = call["args"] as? [String: Any], args["ServerName"] as? String == server, let tool = args["ToolName"] as? String, !tool.isEmpty
        else { return nil }
        return server + "/" + tool
    }

    /// What a tool wants to do, in a line: the command it runs, the file it
    /// changes, else its name.
    static func describe(tool: String?, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return tool ?? "a tool"
    }

    // MARK: Notes

    /// What is said of a session whose agent's state cannot all be known,
    /// before it said anything (`beforeAnyEvent`) and after.
    ///
    /// Codex 0.169 asks to review hooks that are new or changed when its
    /// session starts, and runs none of them when told to go on without:
    /// it keeps one trusted hash for each place a hook is given in, so the
    /// first session after AgentTerm is installed asks, and so does each
    /// after the released and dev builds took turns (tried 2026-11-15; the
    /// trial of #59 had them trusted already). Until its hooks first report,
    /// a Codex session says so, and what to do.
    public static func note(agent: String?, beforeAnyEvent: Bool) -> String? {
        switch agent {
        case "agy":
            return "Antigravity does not say when it waits for permission. For AgentTerm's own tools it is known; while it runs any other tool, its state is not shown."
        case "codex" where beforeAnyEvent:
            return "Codex shows its state once AgentTerm's hooks run. If it asks to review hooks, choose “Trust all and continue”; without them its state is not known."
        default:
            return nil
        }
    }

    /// Input that may have stopped a turn: Escape alone, or Control C.
    /// After it the state is not known until the agent says more.
    public static func mayStopATurn(_ input: Data) -> Bool {
        input == Data([0x1b]) || input.contains(0x03)
    }
}
#endif
