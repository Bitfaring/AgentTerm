import Foundation

/// What an agent asks of the shells it opened through MCP (#10), sent by
/// `agenttermd mcp` on its behalf with the key of its session. An agent
/// sees, reads, types into and closes only the shells it opened itself; it
/// never reaches another agent's, nor the user's own sessions, and opens
/// shells only, never another agent.
public enum AgentShellRequest: Codable, Equatable, Sendable {
    /// Starts a shell in the agent's folder, running `command` when given.
    case open(command: String?, title: String?)
    /// The shells this agent opened that still run.
    case list
    /// The screen as text, with as many lines above it as asked for. Of a
    /// shell this agent opened only.
    case read(session: SessionID, linesAbove: Int)
    /// Text, then keys by name ("Return", "Control C", "Up"), as typed.
    /// Into a shell this agent opened only.
    case send(session: SessionID, text: String?, keys: [String])
    /// Ends a shell this agent opened.
    case close(session: SessionID)
    /// Types a command at the shell's prompt and Return, as a paste when
    /// the shell takes one so that a command of many lines is one command.
    /// Refused while a command the shell said started has not ended.
    /// Answered with `ran`, the commands as they stood before it.
    case run(session: SessionID, command: String)
    /// The commands of the shell as they stand, with the output of the
    /// running or last one, at most its last `lines` lines.
    case command(session: SessionID, lines: Int)
    /// Said once by the server as it starts (#129): the host learns that
    /// the session's agent has AgentTerm's MCP server, one typed by hand in
    /// a shell included, which the server names: the agent it was started
    /// by, when it is one of the four. Answered with `done`.
    case started(agent: String?)
}

public enum AgentShellResult: Codable, Equatable, Sendable {
    case opened(SessionInfo)
    /// The shells the asking agent opened.
    case shells([SessionInfo])
    case screen(String)
    case done
    /// Not done, and why, in words for the agent.
    case refused(String)
    /// A command was typed; the commands as they stood before it.
    case ran(AgentCommand)
    case command(AgentCommand)
}

/// What a shell said of its commands (OSC 133), as the host saw it.
public struct AgentCommand: Codable, Equatable, Sendable {
    /// The shell says when its commands start and end.
    public var integrated: Bool
    /// It was set up to say so (`ShellIntegration`), whether it has said
    /// anything yet or not: a shell still starting has not.
    public var prepared: Bool
    /// How many commands have started.
    public var started: Int
    public var running: Bool
    /// The last command's exit code, once it ended.
    public var exitCode: Int32?
    /// The running or last command's output, its last lines.
    public var output: String
    /// How many lines before those were left out.
    public var linesLeftOut: Int

    public init(
        integrated: Bool = false, prepared: Bool = false, started: Int = 0, running: Bool = false, exitCode: Int32? = nil, output: String = "",
        linesLeftOut: Int = 0
    ) {
        self.integrated = integrated
        self.prepared = prepared
        self.started = started
        self.running = running
        self.exitCode = exitCode
        self.output = output
        self.linesLeftOut = linesLeftOut
    }
}

extension SessionInfo {
    /// Whose shell this is, for the lists: the name of the session of the
    /// agent that opened it, or that its agent has ended. Nil for a session
    /// no agent opened. Only that agent sees it and types into it (#61).
    public func openedByName(among sessions: [SessionInfo]) -> String? {
        guard let openedBy else { return nil }
        return sessions.first { $0.id == openedBy }?.displayName ?? "an agent that has ended"
    }
}

/// Something wrong with AgentTerm's MCP server in the agents (#58). The
/// host tells every client, for as long as it lasts, and the apps warn of it
/// in their top banner: without it, the agents could not open shells, or
/// keep a server of an earlier build, and nobody would know.
public struct AgentShellsFault: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// What is wrong. Text rather than a closed list, so that a client
    /// still reads a cause that was added after it was built.
    public struct Cause: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// An agent's server was refused when it signed in to the host.
        public static let signIn = Cause(rawValue: "signIn")
    }

    public var cause: Cause
    /// The agents it is about, by name ("Claude Code"); none when the host
    /// cannot tell which.
    public var agents: [String]

    public init(cause: Cause, agents: [String] = []) {
        self.cause = cause
        self.agents = agents
    }

    public var id: String { ([cause.rawValue] + agents).joined(separator: "|") }

    /// What is wrong, in one sentence, the same on the Mac and the iPhone.
    /// `mac` names the Mac the host is on when the app runs on another.
    public func headline(on mac: String? = nil) -> String {
        let onMac = mac.map { " on \($0)" } ?? ""
        switch cause {
        case .signIn:
            return "An agent's MCP server was refused by the AgentTerm host\(onMac)."
        default:
            return "Agents cannot open shells you see\(onMac) (\(cause.rawValue))."
        }
    }

    /// What follows from it and what to do about it.
    public var advice: String {
        switch cause {
        case .signIn:
            return "Its agent cannot open shells you see: it was started by another copy of AgentTerm, or before the host was set up again. Start that agent's session again."
        default:
            return "Start the agent's session again; if it stays, a newer AgentTerm says more."
        }
    }

    /// "Codex", "Codex and Copilot CLI", "Codex, Copilot CLI and Antigravity".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

/// Keys an agent may send by name, as the bytes a terminal sends for them.
public enum TerminalKeys {
    public static func bytes(for name: String) -> String? {
        let named: [String: String] = [
            "return": "\r", "enter": "\r", "tab": "\t", "escape": "\u{1b}", "esc": "\u{1b}", "backspace": "\u{7f}", "space": " ",
            "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C", "left": "\u{1b}[D",
            "home": "\u{1b}[H", "end": "\u{1b}[F", "page up": "\u{1b}[5~", "page down": "\u{1b}[6~", "delete": "\u{1b}[3~",
        ]
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let bytes = named[key] { return bytes }
        // "Control C", "Ctrl-C", "C-c".
        for prefix in ["control ", "control-", "ctrl ", "ctrl-", "ctrl+", "c-"] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard rest.count == 1, let letter = rest.unicodeScalars.first, ("a"..."z").contains(Character(letter)) else { return nil }
            return String(UnicodeScalar(UInt8(letter.value - 96)))
        }
        return nil
    }
}

/// What the agents are told when they are to run their commands in shells
/// the user sees (#10): in the MCP server's instructions, and in Claude
/// Code's system prompt.
public enum AgentShellsInstructions {
    /// As this build says it, naming its own server.
    public static var useShells: String { useShells(server: AppChannel.current.mcpServerName) }

    /// - Parameter server: The name the MCP server has in the agent's
    ///   configuration, which differs between the builds (#57).
    public static func useShells(server: String) -> String {
        "You run inside AgentTerm, where the user watches what you do. Run shell commands in a shell of the \(server) MCP server rather than with your own command tool. Open a shell of your own with shell_open, and keep using it: run each command with shell_run, which waits until it ends and returns its exit code and its output. For a command still running when shell_run returns, wait with shell_wait or stop it with shell_stop, and stop it at once when the user says to stop; for a program that asks questions or keeps running (a REPL, a dev server), type into it with shell_send and look with shell_read. You see and use only the shells you opened: shell_list lists them. Open another of your own only while yours runs something that keeps running, such as a dev server. Leave a shell open for the next task rather than close it, unless it runs something that should end."
    }

    /// What the agents are told of AgentTerm's browser (#76), as this
    /// build says it. Said plainly, because an agent is often given other
    /// ways to a browser too (an extension that drives the user's Chrome, a
    /// headless browser) and took one of those when the user said
    /// "browser" or "Chrome" (seen on 2026-11-15).
    public static var browser: String { browser(server: AppChannel.current.mcpServerName) }

    public static func browser(server: String) -> String {
        "AgentTerm has a browser of its own, Chromium, whose pages you open are in your tab, where the user sees them. When the user asks you to open, look at, use or test anything in a browser (a web page, a site, a URL, localhost or a development server, \"the browser\", \"Chrome\" or \"Chromium\"), use AgentTerm's browser through the browser_ tools of the \(server) MCP server: browser_open to open a tab of your own, browser_snapshot to read the page and get the refs of what you can act on, browser_click, browser_type, browser_select and browser_press to act, browser_screenshot to look, browser_console and browser_network for errors. You see and use only the tabs you opened, not the user's. When browser_open says there are several profiles, ask the user which one to use and open it with that profile; for a clean session with none of the user's sign-ins, open a private tab. Do not use another browser tool, extension or MCP server for it (such as Claude in Chrome or a headless browser), nor `open`, curl or a script, unless the user names that other one. If the browser_ tools are not loaded yet, load them by name first. The user may take a tab over; then wait, or open another."
    }

    /// Everything an agent is told by AgentTerm, for its system prompt or
    /// its instructions files; nil when it is told nothing.
    public static func told(useShells: Bool, browser: Bool, server: String = AppChannel.current.mcpServerName) -> String? {
        let parts = (useShells ? [Self.useShells(server: server)] : []) + (browser ? [Self.browser(server: server)] : [])
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
