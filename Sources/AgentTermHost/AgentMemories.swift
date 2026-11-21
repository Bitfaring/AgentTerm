#if os(macOS)
import AgentTermProtocol
import Foundation

/// The agents' memory (#220): the notes an agent saves by itself for a
/// folder and reads again in its later sessions there.
///
/// Only what was established of each agent at the version in use is here
/// (principle 5; `docs/DESIGN.md`, "The agents' memory", says how and with
/// which version): today that is Claude Code's notes. What another agent
/// keeps elsewhere, or is not known to keep, is not listed and not
/// guessed. An agent's instructions, which a person writes for it
/// (`CLAUDE.md`, `AGENTS.md`), are not its memory and are never listed,
/// read, written or deleted here.
///
/// Reading, writing and deleting take a path from a client, and do it only
/// to a file this lists itself.
public enum AgentMemories {
    /// No more notes of one folder than this.
    private static let maxFilesPerFolder = 200

    // MARK: Listing

    /// Every memory on the Mac, whatever folder it is about, as History
    /// lists every conversation. Blocks on file access, so call it off the
    /// main thread. `home` is replaceable for tests.
    public static func allMemories(home: String = NSHomeDirectory()) -> [AgentMemory] {
        claude(nil, URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL)
    }

    /// The memories of one folder: those its agent keeps under that
    /// folder's own name, as History's conversations of a folder are.
    public static func memories(of folder: String, home: String = NSHomeDirectory()) -> [AgentMemory] {
        claude(folder, URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL)
    }

    // MARK: Claude Code

    /// `~/.claude/projects/<project>/memory/*.md`: the notes Claude Code
    /// writes by itself for a folder, with their index `MEMORY.md` first
    /// (Claude Code 2.1.330). `<project>` is the folder with every
    /// character that is no letter or digit as "-", which cannot be turned
    /// back into a path: for a folder that is asked for, its own name is
    /// looked up; for every project (`folder` nil), the folder is the one a
    /// conversation of that project recorded (`cwd`), as History finds it,
    /// and is not known, nil, when none tells it.
    ///
    /// A note is given by its real path; one that a link leads out of the
    /// folder of notes is not this agent's memory and is left out, as are
    /// notes whose folder is a link to outside the home.
    private static func claude(_ folder: String?, _ home: URL) -> [AgentMemory] {
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let realHome = home.resolvingSymlinksInPath().path
        let names: [String]
        if let folder {
            names = [AgentHistory.claudeProjectName(for: URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path)]
        } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return names.flatMap { project -> [AgentMemory] in
            let notes = projects.appendingPathComponent(project + "/memory", isDirectory: true)
            let within = notes.resolvingSymlinksInPath().path
            guard within.hasPrefix(realHome.hasSuffix("/") ? realHome : realHome + "/") else { return [] }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [])
                .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .prefix(maxFilesPerFolder)
            // Only a project that has notes is looked into for its folder.
            guard !files.isEmpty else { return [] }
            let about = folder ?? claudeFolder(of: project, in: projects)
            let found = files.compactMap { name -> AgentMemory? in
                let file = notes.appendingPathComponent(name).resolvingSymlinksInPath()
                guard file.path.hasPrefix(within.hasSuffix("/") ? within : within + "/"),
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                    values.isRegularFile == true, let modified = values.contentModificationDate
                else { return nil }
                return AgentMemory(
                    path: file.path, name: name, agent: "claude", folder: about, project: project, modifiedAt: modified, size: values.fileSize ?? 0)
            }
            return found.filter { $0.name == "MEMORY.md" } + found.filter { $0.name != "MEMORY.md" }
        }
    }

    /// No more of a project's conversations than this are asked for its folder.
    private static let conversationsAsked = 5

    /// The folder a project of Claude Code is about: the `cwd` one of its
    /// conversations recorded, the newest first, when it is a folder this
    /// project's name stands for. Nil when no conversation tells it: the
    /// name alone cannot ("apps-web" is "apps/web" as well as "apps-web").
    static func claudeFolder(of project: String, in projects: URL) -> String? {
        let directory = projects.appendingPathComponent(project, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = urls.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(conversationsAsked)
        let needle = Data("\"cwd\"".utf8)
        for (url, _) in newest {
            // A conversation's first lines name where it ran.
            for line in AgentHistory.read(url, head: 256 * 1024).split(separator: 0x0a).prefix(200) where line.range(of: needle) != nil {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let cwd = object["cwd"] as? String else { continue }
                if AgentHistory.claudeProjectName(for: cwd) == project { return cwd }
            }
        }
        return nil
    }

    // MARK: One memory

    /// Why a request was refused, in the words both apps show.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The memory a client names, found again among every memory listed
    /// here: whatever path a client sends, only a file that is one of
    /// those, a note in the `memory` folder of one of Claude Code's
    /// projects, is read, written or deleted.
    public static func memory(at path: String, home: String = NSHomeDirectory()) -> AgentMemory? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return allMemories(home: home).first { $0.path == wanted }
    }

    public static func read(_ path: String, home: String = NSHomeDirectory()) -> Result<AgentMemoryContent, Refusal> {
        guard let memory = memory(at: path, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        guard case .text(let text) = FileBrowser.read(memory.path) else { return .failure(Refusal(MemoryWords.notText)) }
        return .success(AgentMemoryContent(memory: memory, text: text))
    }

    /// Replaces a memory's text, all at once. Refused, nothing written,
    /// when the file is not as the client last saw it (`seen`, its date).
    public static func write(_ text: String, to path: String, seen: Date, home: String = NSHomeDirectory()) -> Result<AgentMemory, Refusal> {
        guard let memory = memory(at: path, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        // Dates travel as seconds with a fraction: the same to the millisecond.
        guard abs(memory.modifiedAt.timeIntervalSince(seen)) < 0.001 else { return .failure(Refusal(MemoryWords.changedMeanwhile(memory.name))) }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: memory.path), options: .atomic)
        } catch {
            return .failure(Refusal(MemoryWords.notWritten(memory.name, reason: error.localizedDescription)))
        }
        guard let written = self.memory(at: memory.path, home: home) else { return .failure(Refusal(MemoryWords.gone)) }
        return .success(written)
    }

    /// Moves a memory to the Trash. The memory it was when done, or why not.
    public static func delete(_ path: String, home: String = NSHomeDirectory()) -> Result<AgentMemory, Refusal> {
        guard let memory = memory(at: path, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        do {
            try FileBrowser.trash(memory.path)
            return .success(memory)
        } catch {
            return .failure(Refusal(MemoryWords.notTrashed(memory.name, reason: "\(error)")))
        }
    }
}
#endif
