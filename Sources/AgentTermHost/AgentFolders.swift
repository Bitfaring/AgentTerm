#if os(macOS)
import Foundation

/// Where each agent keeps its configuration and its conversations, in one
/// place for setup, schedules, history and delete alike (#264).
///
/// Claude Code moves all of it with `CLAUDE_CONFIG_DIR`, `.claude.json`
/// too, and Codex with `CODEX_HOME`: tried with Claude Code 2.1.330 and
/// Codex 0.171.0 on 2026-11-23, in a home of the trial's own, where
/// `.claude.json`, `projects/` and `sessions/` were written into the folder
/// the variable named and nothing into the home.
public struct AgentFolders: Equatable, Sendable {
    /// Claude Code's: `settings.json`, `projects/`, `.credentials.json`.
    public let claude: String
    /// Claude Code's `.claude.json`: what folders are trusted.
    public let claudeState: String
    /// Codex's: `config.toml`, `sessions/`, `history.jsonl`.
    public let codex: String
    /// Copilot CLI's: `config.json`, `session-state/`.
    public let copilot: String

    /// The variables that move them, asked of the login shell too.
    static let variables = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]

    public init(home: String, environment: [String: String]) {
        func given(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        }
        let claudeFolder = given("CLAUDE_CONFIG_DIR")
        claude = claudeFolder ?? home + "/.claude"
        claudeState = claudeFolder.map { $0 + "/.claude.json" } ?? home + "/.claude.json"
        codex = given("CODEX_HOME") ?? home + "/.codex"
        copilot = home + "/.copilot"
    }

    /// The user's: what the host's own environment says, and where it says
    /// nothing, what their login shell does. A host started by the app or
    /// at login has none of what `.zshrc` exports, while the agents, started
    /// through that shell, have it.
    public static func of(home: String, own: [String: String] = ProcessInfo.processInfo.environment) -> AgentFolders {
        of(home: home, own: own, shell: .shared)
    }

    static func of(home: String, own: [String: String], shell: LoginShellPath) -> AgentFolders {
        var environment = shell.variables()
        for name in variables { if let value = own[name], !value.isEmpty { environment[name] = value } }
        return AgentFolders(home: home, environment: environment)
    }
}
#endif
