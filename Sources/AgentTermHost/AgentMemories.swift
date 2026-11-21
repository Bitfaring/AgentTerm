#if os(macOS)
import AgentTermProtocol
import Foundation

/// The agents' memory (#220): the files each agent keeps for itself and
/// reads again, its instructions for a folder or for the user, and the notes
/// it saved from earlier sessions.
///
/// Only what was established of each agent at the version in use is here
/// (principle 5; `docs/DESIGN.md`, "The agents' memory", says how and with
/// which version): a file no agent is known to read is not a memory, and
/// what an agent keeps elsewhere, or where it is not known to keep it, is
/// said to be not shown (`MemoryWords.notShown`), not guessed.
///
/// Reading, writing and deleting take a path from a client, and do it only
/// to a file this lists itself for the folder asked about.
public enum AgentMemories {
    /// Where an agent reads from: a file, or the files of a folder that end
    /// in `suffix`, relative to the folder or to the user's home.
    struct Place {
        var path: String
        /// For a folder of files: what their names end in. Nil for one file.
        var suffix: String?
        var agents: [String]
    }

    /// In the folder itself. Established with Claude Code 2.1.330,
    /// Codex 0.170.0, Antigravity 1.5.12 and Copilot CLI 1.0.114.
    static let inFolder: [Place] = [
        Place(path: "CLAUDE.md", agents: ["claude", "copilot"]),
        Place(path: "CLAUDE.local.md", agents: ["claude"]),
        Place(path: ".claude/CLAUDE.md", agents: ["claude"]),
        Place(path: ".claude/rules", suffix: ".md", agents: ["claude", "copilot"]),
        Place(path: "AGENTS.md", agents: ["codex", "agy", "copilot"]),
        Place(path: "AGENTS.override.md", agents: ["codex"]),
        Place(path: "GEMINI.md", agents: ["agy", "copilot"]),
        Place(path: ".agents/rules", suffix: ".md", agents: ["agy"]),
        Place(path: ".github/copilot-instructions.md", agents: ["copilot"]),
        Place(path: ".github/instructions", suffix: ".instructions.md", agents: ["copilot"]),
    ]

    /// Under the user's home: read in every folder.
    static let ofUser: [Place] = [
        Place(path: ".claude/CLAUDE.md", agents: ["claude"]),
        Place(path: ".claude/rules", suffix: ".md", agents: ["claude"]),
        Place(path: ".codex/AGENTS.md", agents: ["codex"]),
        Place(path: ".codex/AGENTS.override.md", agents: ["codex"]),
        Place(path: ".gemini/GEMINI.md", agents: ["agy"]),
        Place(path: ".gemini/AGENTS.md", agents: ["agy"]),
        Place(path: ".gemini/config/GEMINI.md", agents: ["agy"]),
        Place(path: ".gemini/config/AGENTS.md", agents: ["agy"]),
        Place(path: ".gemini/config/rules", suffix: ".md", agents: ["agy"]),
        Place(path: ".copilot/copilot-instructions.md", agents: ["copilot"]),
        Place(path: ".copilot/instructions", suffix: ".instructions.md", agents: ["copilot"]),
    ]

    /// No more files of one folder of rules or notes than this.
    private static let maxFilesPerPlace = 200

    // MARK: Listing

    /// The memories of a folder, then the user's own. Blocks on file
    /// access, so call it off the main thread. `home` is replaceable for tests.
    public static func memories(of folder: String, home: String = NSHomeDirectory()) -> [AgentMemory] {
        merged(user(home: home) + own(of: folder, home: home))
    }

    /// The memories of each of these folders, then the user's own.
    public static func memories(ofEvery folders: [String], home: String = NSHomeDirectory()) -> [AgentMemory] {
        merged(user(home: home) + folders.flatMap { own(of: $0, home: home) })
    }

    /// The user's own memories only.
    public static func memoriesOfUser(home: String = NSHomeDirectory()) -> [AgentMemory] {
        merged(user(home: home))
    }

    /// A file found in a place, and whether it was reached through a link.
    private struct Found {
        var memory: AgentMemory
        var viaLink: Bool
    }

    /// One file is one memory, whoever reads it and by whichever name: the
    /// agents of two entries for the same file are put together, in the
    /// host's order of agents, under the file's own name rather than a
    /// link's. The first entry is kept, and the user's own come first here,
    /// so that a file both the user's own and in a folder (the home folder
    /// listed as a folder) is the user's. Given back with the folders'
    /// first, then the user's own.
    private static func merged(_ found: [Found]) -> [AgentMemory] {
        var order: [String] = []
        var byPath: [String: Found] = [:]
        for entry in found {
            let path = entry.memory.path
            if var known = byPath[path] {
                for agent in entry.memory.agents where !known.memory.agents.contains(agent) { known.memory.agents.append(agent) }
                if known.viaLink, !entry.viaLink, known.memory.scope == entry.memory.scope {
                    known.memory.name = entry.memory.name
                    known.viaLink = false
                }
                byPath[path] = known
            } else {
                order.append(path)
                byPath[path] = entry
            }
        }
        let known = AgentDetector.known.map(\.id)
        let all = order.compactMap { byPath[$0]?.memory }.map { memory -> AgentMemory in
            var memory = memory
            memory.agents.sort { (known.firstIndex(of: $0) ?? known.count) < (known.firstIndex(of: $1) ?? known.count) }
            return memory
        }
        return all.filter { $0.scope == .folder } + all.filter { $0.scope == .user }
    }

    private static func user(home: String) -> [Found] {
        let root = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        let real = root.resolvingSymlinksInPath().path
        // Named from the home, as the folder's are from the folder.
        return ofUser.flatMap { files(of: $0, under: root, within: real, scope: .user, folder: nil) }.map { found in
            var found = found
            found.memory.name = "~/" + found.memory.name
            return found
        }
    }

    private static func own(of folder: String, home: String) -> [Found] {
        let root = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        let real = root.resolvingSymlinksInPath().path
        var found = inFolder.flatMap { files(of: $0, under: root, within: real, scope: .folder, folder: folder) }
        // What Claude Code writes by itself for the folder: its notes, with
        // their index `MEMORY.md` first.
        let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        let notes = Place(path: ".claude/projects/" + AgentHistory.claudeProjectName(for: root.path) + "/memory", suffix: ".md", agents: ["claude"])
        let written = files(of: notes, under: homeURL, within: homeURL.resolvingSymlinksInPath().path, scope: .folder, folder: folder, writtenByAgent: true, namedFrom: "memory")
        found += written.filter { $0.memory.name == "memory/MEMORY.md" } + written.filter { $0.memory.name != "memory/MEMORY.md" }
        return found
    }

    /// The files of a place that exist, as memories. A file is given by its
    /// real path; one that a link leads out of `real`, the folder it is
    /// looked for under, is not a memory of that folder and is left out.
    private static func files(
        of place: Place, under root: URL, within real: String, scope: AgentMemory.Scope, folder: String?, writtenByAgent: Bool = false, namedFrom: String? = nil
    ) -> [Found] {
        let at = root.appendingPathComponent(place.path)
        var candidates: [(url: URL, name: String)] = []
        if let suffix = place.suffix {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? [])
                .filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .prefix(maxFilesPerPlace)
            candidates = names.map { (at.appendingPathComponent($0), (namedFrom ?? place.path) + "/" + $0) }
        } else {
            candidates = [(at, place.path)]
        }
        return candidates.compactMap { candidate in
            let file = candidate.url.resolvingSymlinksInPath()
            guard file.path.hasPrefix(real.hasSuffix("/") ? real : real + "/"),
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                values.isRegularFile == true, let modified = values.contentModificationDate
            else { return nil }
            // The file itself a link, whatever the folders on the way are.
            let isLink = (try? candidate.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let memory = AgentMemory(
                path: file.path, name: candidate.name, agents: place.agents, scope: scope, folder: folder, writtenByAgent: writtenByAgent,
                modifiedAt: modified, size: values.fileSize ?? 0)
            return Found(memory: memory, viaLink: isLink)
        }
    }

    // MARK: One memory

    /// Why a request was refused, in the words both apps show.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The memory a client names, found again among those listed for the
    /// folder it names (the user's own when nil): whatever path a client
    /// sends, only a file listed here is read, written or deleted.
    public static func memory(at path: String, folder: String?, home: String = NSHomeDirectory()) -> AgentMemory? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        let listed = folder.map { memories(of: $0, home: home) } ?? memoriesOfUser(home: home)
        return listed.first { $0.path == wanted }
    }

    public static func read(_ path: String, folder: String?, home: String = NSHomeDirectory()) -> Result<AgentMemoryContent, Refusal> {
        guard let memory = memory(at: path, folder: folder, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        guard case .text(let text) = FileBrowser.read(memory.path) else { return .failure(Refusal(MemoryWords.notText)) }
        return .success(AgentMemoryContent(memory: memory, text: text))
    }

    /// Replaces a memory's text, all at once. Refused, nothing written,
    /// when the file is not as the client last saw it (`seen`, its date).
    public static func write(_ text: String, to path: String, folder: String?, seen: Date, home: String = NSHomeDirectory()) -> Result<AgentMemory, Refusal> {
        guard let memory = memory(at: path, folder: folder, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        // Dates travel as seconds with a fraction: the same to the millisecond.
        guard abs(memory.modifiedAt.timeIntervalSince(seen)) < 0.001 else { return .failure(Refusal(MemoryWords.changedMeanwhile(memory.name))) }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: memory.path), options: .atomic)
        } catch {
            return .failure(Refusal(MemoryWords.notWritten(memory.name, reason: error.localizedDescription)))
        }
        guard let written = self.memory(at: memory.path, folder: folder, home: home) else { return .failure(Refusal(MemoryWords.gone)) }
        return .success(written)
    }

    /// Moves a memory to the Trash. The memory it was when done, or why not.
    public static func delete(_ path: String, folder: String?, home: String = NSHomeDirectory()) -> Result<AgentMemory, Refusal> {
        guard let memory = memory(at: path, folder: folder, home: home) else { return .failure(Refusal(MemoryWords.notAMemory)) }
        do {
            try FileBrowser.trash(memory.path)
            return .success(memory)
        } catch {
            return .failure(Refusal(MemoryWords.notTrashed(memory.name, reason: "\(error)")))
        }
    }
}
#endif
