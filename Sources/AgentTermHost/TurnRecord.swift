#if os(macOS)
import AgentTermProtocol
import Foundation

/// What the host gathers of an agent's turn (#71), from its start to its
/// end, to make its `TurnResult`: what the folder looked like when it
/// began, what its hooks said. Its `before` is only touched on the queue
/// the results are made on (`HostServer.turnQueue`); the rest on the host's.
final class TurnRecord {
    let startedAt: Date
    let directory: String
    /// The prompt, when the hooks told it.
    var request: String?
    /// The folder at the start, once it has been looked at.
    var before: GitSnapshot?
    /// Another agent's session worked in the same repository meanwhile.
    var shared = false

    init(startedAt: Date, directory: String, request: String?) {
        self.startedAt = startedAt
        self.directory = directory
        self.request = request
    }
}

/// A repository's uncommitted files at one moment, as `git status` and
/// `git diff --numstat` have them, with each file's size and when it was
/// last written: what tells a file that changed again from one that did
/// not.
struct GitSnapshot: Equatable {
    struct Entry: Equatable {
        var status: String
        var added: Int?
        var removed: Int?
        var size: Int?
        var modified: Date?
    }

    var top: String
    var files: [String: Entry]

    static func take(of directory: String, timeout: TimeInterval = 20) -> GitSnapshot? {
        func git(_ arguments: [String]) -> Data? {
            guard let result = Subprocess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout), result.status == 0 else { return nil }
            return result.output
        }
        guard let topData = git(["rev-parse", "--show-toplevel"]) else { return nil }
        let top = String(decoding: topData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty, let status = git(["-C", top, "status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
        var files: [String: Entry] = [:]
        var records = status.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            // A rename or a copy is followed by the name it had.
            if code.contains("R") || code.contains("C") { _ = records.popFirst() }
            files[path] = Entry(status: code.trimmingCharacters(in: .whitespaces))
        }
        // Lines against the last commit; none in a repository without one.
        if let numstat = git(["-C", top, "diff", "HEAD", "--numstat", "-z", "--no-renames"]) {
            for record in numstat.split(separator: 0, omittingEmptySubsequences: true) {
                let fields = String(decoding: record, as: UTF8.self).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { continue }
                let path = String(fields[2])
                files[path, default: Entry(status: "M")].added = Int(fields[0])
                files[path, default: Entry(status: "M")].removed = Int(fields[1])
            }
        }
        for (path, entry) in files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: (top as NSString).appendingPathComponent(path))
            var entry = entry
            entry.size = (attributes?[.size] as? NSNumber)?.intValue
            entry.modified = attributes?[.modificationDate] as? Date
            files[path] = entry
        }
        return GitSnapshot(top: top, files: files)
    }

    /// The files that are not as they were, from `before` to `after`: the
    /// ones whose status, lines, size or time of writing changed, and the
    /// ones that came or went.
    static func changes(from before: GitSnapshot, to after: GitSnapshot) -> [TurnResult.File] {
        let paths = Set(before.files.keys).union(after.files.keys).sorted()
        return paths.compactMap { path in
            let old = before.files[path], new = after.files[path]
            guard old != new else { return nil }
            return TurnResult.File(path: path, status: new?.status, added: new?.added, removed: new?.removed, changedBefore: old != nil ? true : nil)
        }
    }
}

/// What an agent's own record says of its last turn: the prompt, its last
/// answer, the commands it ran with their exit codes. Read from the file
/// its hooks name when the turn ends (`transcript_path`, `transcriptPath`),
/// each agent's as it was found written on 2026-11-17: Claude Code 2.1.326,
/// Codex 0.169.0, Copilot CLI 1.0.112, Antigravity 1.5.9.
enum TurnTranscript {
    struct Turn: Equatable {
        var request: String?
        var reply: String?
        var commands: [TurnResult.Command]
    }

    /// The end of the file is enough for one turn.
    static let tailBytes = 8 * 1024 * 1024

    static func read(agent: String, file: String, turnID: String? = nil) -> Turn? {
        let data = AgentHistory.read(URL(fileURLWithPath: file), tail: tailBytes)
        guard !data.isEmpty else { return nil }
        return parse(agent: agent, data: data, turnID: turnID)
    }

    static func parse(agent: String, data: Data, turnID: String? = nil) -> Turn? {
        let lines = data.split(separator: 0x0a).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard !lines.isEmpty else { return nil }
        // The prompt and the answers, as History and handoffs read them.
        let conversation = Conversation(agent: agent, sessionID: "", title: "", updatedAt: Date(), cwd: "")
        let messages = AgentHistory.transcript(of: conversation, data: data)
        let lastAsked = messages.lastIndex { $0.role == .user }
        let request = lastAsked.map { messages[$0].text }
        let reply = messages[(lastAsked.map { $0 + 1 } ?? 0)...].last { $0.role == .agent }?.text
        let commands: [TurnResult.Command]
        switch agent {
        case "claude": commands = claude(lines)
        case "codex": commands = codex(lines, turnID: turnID)
        case "copilot": commands = copilot(lines)
        case "agy": commands = antigravity(lines)
        default: return nil
        }
        return Turn(request: request, reply: reply, commands: commands)
    }

    /// The lines after the last one `isPrompt` holds for.
    private static func lastTurn(_ lines: [[String: Any]], isPrompt: ([String: Any]) -> Bool) -> ArraySlice<[String: Any]> {
        guard let start = lines.lastIndex(where: isPrompt) else { return lines[...] }
        return lines[(start + 1)...]
    }

    private static func exitCode(in text: String, after marker: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    /// `Bash` tool uses, and their results: an error says "Exit code N".
    private static func claude(_ lines: [[String: Any]]) -> [TurnResult.Command] {
        var order: [String] = [], commands: [String: TurnResult.Command] = [:]
        for line in lastTurn(lines, isPrompt: { AgentHistory.claudePrompt($0) != nil }) where line["isSidechain"] as? Bool != true {
            guard let parts = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for part in parts {
                if part["type"] as? String == "tool_use", part["name"] as? String == "Bash", let id = part["id"] as? String,
                    let command = (part["input"] as? [String: Any])?["command"] as? String
                {
                    order.append(id)
                    commands[id] = TurnResult.Command(command: command)
                } else if part["type"] as? String == "tool_result", let id = part["tool_use_id"] as? String, commands[id] != nil {
                    let text = (part["content"] as? String) ?? ((part["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
                    if part["is_error"] as? Bool == true {
                        if let code = exitCode(in: text, after: "Exit code ") { commands[id]?.exitCode = code } else { commands[id]?.failed = true }
                    } else {
                        commands[id]?.exitCode = 0
                    }
                }
            }
        }
        return order.compactMap { commands[$0] }
    }

    /// The commands of the turn (`turn_id`), as Codex records each one it
    /// finished: `item_completed` with a `CommandExecution`.
    private static func codex(_ lines: [[String: Any]], turnID: String?) -> [TurnResult.Command] {
        let turn =
            turnID.map { _ in lines[...] }
            ?? lastTurn(lines) { line in
                guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { return false }
                return payload["type"] as? String == "message" && payload["role"] as? String == "user"
            }
        return turn.compactMap { line in
            guard line["type"] as? String == "event_msg", let payload = line["payload"] as? [String: Any],
                payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
                item["type"] as? String == "CommandExecution"
            else { return nil }
            if let turnID, payload["turn_id"] as? String != turnID { return nil }
            let command = (item["command"] as? [String])?.last ?? (item["command"] as? String) ?? ""
            let code = item["exit_code"] as? Int
            return TurnResult.Command(command: command, exitCode: code, failed: code == nil && item["status"] as? String == "failed" ? true : nil)
        }
    }

    /// `tool.execution_start` of a shell, then `tool.execution_complete`
    /// with its `shellExecution.exitCode`.
    private static func copilot(_ lines: [[String: Any]]) -> [TurnResult.Command] {
        var order: [String] = [], commands: [String: TurnResult.Command] = [:]
        for line in lastTurn(lines, isPrompt: { $0["type"] as? String == "user.message" }) {
            guard let data = line["data"] as? [String: Any], let id = data["toolCallId"] as? String else { continue }
            switch line["type"] as? String {
            case "tool.execution_start":
                guard ["bash", "shell", "powershell"].contains(data["toolName"] as? String ?? ""),
                    let command = (data["arguments"] as? [String: Any])?["command"] as? String
                else { continue }
                order.append(id)
                commands[id] = TurnResult.Command(command: command)
            case "tool.execution_complete":
                guard commands[id] != nil else { continue }
                if let code = (data["shellExecution"] as? [String: Any])?["exitCode"] as? Int {
                    commands[id]?.exitCode = code
                } else if data["success"] as? Bool == false {
                    commands[id]?.failed = true
                }
            default:
                continue
            }
        }
        return order.compactMap { commands[$0] }
    }

    /// `run_command` calls of the model, each followed by a step that says
    /// "Command exited with code N".
    private static func antigravity(_ lines: [[String: Any]]) -> [TurnResult.Command] {
        var commands: [TurnResult.Command] = [], waiting: [Int] = []
        let turn = lastTurn(lines) { ($0["source"] as? String)?.hasPrefix("USER") == true && $0["type"] as? String == "USER_INPUT" }
        for line in turn {
            if let calls = line["tool_calls"] as? [[String: Any]] {
                for call in calls where call["name"] as? String == "run_command" {
                    guard let command = (call["args"] as? [String: Any])?["CommandLine"] as? String else { continue }
                    waiting.append(commands.count)
                    commands.append(TurnResult.Command(command: command))
                }
            } else if line["type"] as? String == "GENERIC", let content = line["content"] as? String, !waiting.isEmpty,
                let code = exitCode(in: content, after: "Command exited with code ")
            {
                commands[waiting.removeFirst()].exitCode = code
            }
        }
        return commands
    }
}
#endif
