#if os(macOS)
import AgentTermProtocol
import Foundation

/// Lets AgentTerm see what Claude Code tells its status line.
///
/// Claude Code does not write the account's rate limits anywhere, but it
/// hands them to the status line command, with how full the context is. So
/// `agenttermd setup claude` puts a status line command of AgentTerm's own
/// in its settings (#129), `agenttermd statusline`. In a session of
/// AgentTerm's it saves what it is given in the file the session's
/// environment names, for the host to read; anywhere, it then runs the
/// status line the user had set up, if any, and passes on what that prints,
/// so theirs still shows.
public enum StatusLineRelay {

    /// Saves the status line's input in `file`, the session's, and returns
    /// what the user's own status line prints for it: the one `previous`
    /// keeps, which AgentTerm's took the place of (#129), or the one of the
    /// user's settings. Outside a session of AgentTerm's, nothing is saved.
    public static func run(
        input: Data, file: String?, previous: URL? = nil, home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        if object != nil, let file {
            let url = URL(fileURLWithPath: file)
            let problem = failureFile(for: file)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try input.write(to: url, options: .atomic)
                try? FileManager.default.removeItem(atPath: problem)
            } catch {
                // For the host, which reports it: nobody sees what a status
                // line command says when it fails.
                try? Data(error.localizedDescription.utf8).write(to: URL(fileURLWithPath: problem), options: .atomic)
            }
        }
        let project = (object?["workspace"] as? [String: Any])?["project_dir"] as? String ?? object?["cwd"] as? String
        let kept = previous.flatMap { FileManager.default.contents(atPath: $0.path) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Another build's relay, which this one took the place of (MCP-15),
        // is run once; a relay it runs runs only the user's, never a relay
        // again: two builds that keep each other's would run without end
        // (#259).
        let relayed = environment[relayedVariable] != nil
        let keptCommand = (kept?["command"] as? String).flatMap { $0.isEmpty || (relayed && isAgentTerms($0)) ? nil : $0 }
        guard let command = keptCommand ?? userCommand(project: project, home: home, environment: environment)
        else { return Data() }
        return pipe(input, through: command, relaying: isAgentTerms(command), environment: environment)
    }

    /// Set for a relay that another relay runs: it then runs no relay
    /// itself (#259). The one name every build reads, on purpose (the
    /// owner's decision, 2026-11-23): it is what stops two builds' relays
    /// running each other, and names nothing of either.
    public static let relayedVariable = "AGENTTERM_STATUS_LINE_RELAYED"

    /// Whether a status line command is AgentTerm's relay, of any build:
    /// `agenttermd … statusline`, with the file to save in after it or not.
    public static func isAgentTerms(_ command: String) -> Bool {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.contains("agenttermd") && (command.hasSuffix(" statusline") || command.contains(" statusline "))
    }

    /// Where the relay says why it could not save what it was given, next
    /// to the file it saves it in. Removed once it saves again.
    public static func failureFile(for file: String) -> String { file + ".failed" }

    /// The status line the user set up, looked for where Claude Code looks:
    /// the project's settings first, then their own.
    static func userCommand(project: String?, home: String, environment: [String: String]) -> String? {
        var files: [String] = []
        if let project {
            files += [project + "/.claude/settings.local.json", project + "/.claude/settings.json"]
        }
        let configuration = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        files.append(configuration + "/settings.json")
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let statusLine = settings["statusLine"] as? [String: Any],
                let command = statusLine["command"] as? String, !command.isEmpty
            else { continue }
            // Never ourselves: that would run without end.
            if isAgentTerms(command) { continue }
            return command
        }
        return nil
    }

    private static func pipe(_ input: Data, through command: String, relaying: Bool, environment: [String: String]) -> Data {
        var environment = environment
        if relaying { environment[relayedVariable] = "1" }
        // A status line that hangs must not hang Claude Code's: five seconds,
        // for the command and all it started (#261).
        return Subprocess.run("/bin/sh", ["-c", command], timeout: 5, environment: environment, input: input, forTheHost: false)?.output ?? Data()
    }

    /// What Claude Code told the status line, as usage.
    public static func usage(from data: Data) -> SessionUsage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var usage = SessionUsage()
        let model = object["model"] as? [String: Any]
        usage.model = model?["display_name"] as? String ?? model?["id"] as? String
        usage.effort = (object["effort"] as? [String: Any])?["level"] as? String
        if let context = object["context_window"] as? [String: Any] {
            usage.contextWindow = (context["context_window_size"] as? NSNumber)?.intValue
            if let current = context["current_usage"] as? [String: Any] {
                let sent = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((current[$1] as? NSNumber)?.intValue ?? 0) }
                if sent > 0 { usage.contextTokens = sent }
            }
            if usage.contextTokens == nil, let percent = (context["used_percentage"] as? NSNumber)?.doubleValue, let window = usage.contextWindow {
                usage.contextTokens = Int(percent / 100 * Double(window))
            }
        }
        if let limits = object["rate_limits"] as? [String: Any] {
            for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
                guard let limit = limits[key] as? [String: Any], let used = (limit["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                let resets = (limit["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                usage.limits.append(UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: resets))
            }
        }
        return usage.isEmpty ? nil : usage
    }
}
#endif
