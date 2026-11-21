import AgentTermProtocol
import Foundation

/// The agents' memory as the window shows it (#220): the two lists, every
/// folder's in Memory and the folder on show's in the side panel, the
/// memories read, and what was changed in them and not saved yet. The host
/// does the listing, reading, writing and deleting, for this Mac as for
/// another.
@MainActor
final class MemoryStore: ObservableObject {
    /// A memory as it was read, or why it could not be.
    enum Loaded: Equatable {
        case content(AgentMemoryContent)
        case problem(String)
    }

    /// Every memory on the Mac, as Memory lists
    /// them. `nil` while loading.
    @Published private(set) var all: [AgentMemory]?
    /// The folder on show's, as the side panel lists
    /// them. `nil` while loading.
    @Published private(set) var ofFolder: [AgentMemory]?
    /// Memories as they were read, by path.
    @Published private(set) var loaded: [String: Loaded] = [:]
    /// What was changed and not saved, by path, and the date each file had
    /// when its change began: a change is never written over a file that
    /// changed since.
    @Published private(set) var drafts: [String: String] = [:]
    private var bases: [String: Date] = [:]
    /// What was sent to be written, by path, until the host answers.
    private var saving: [String: String] = [:]
    /// Why a memory was not written or not deleted, by path, as the host
    /// said: shown with the memory until it is changed, saved or reverted.
    @Published private(set) var refused: [String: String] = [:]
    /// A refusal to say over the window: of a memory that is not on show.
    var say: ((String) -> Void)?

    /// The memory picked in Memory, shown in the middle of the window.
    @Published var selection: AgentMemory?
    /// The memory picked in the side panel, in a sheet over Sessions.
    @Published var panelMemory: AgentMemory?
    /// The memory the user is asked about before it is deleted.
    @Published var deleting: AgentMemory?

    var send: ((ClientMessage) -> Void)?
    /// The folder the side panel's list was asked for.
    private var folderAsked: String?

    /// Everything known of another Mac is forgotten.
    func reset() {
        all = nil
        ofFolder = nil
        loaded = [:]
        drafts = [:]
        bases = [:]
        saving = [:]
        refused = [:]
        selection = nil
        panelMemory = nil
        deleting = nil
        folderAsked = nil
    }

    /// The side panel shows another folder: its own memories.
    func folderChanged() {
        ofFolder = nil
        folderAsked = nil
        panelMemory = nil
    }

    // MARK: The lists

    /// Asks for a list again: every folder's, or the folder on show's.
    func refresh(ofFolder: Bool, path: String?) {
        if ofFolder {
            guard let path else {
                self.ofFolder = []
                return
            }
            folderAsked = path
            send?(.memories(path: path))
        } else {
            send?(.memories(path: nil))
        }
    }

    // MARK: One memory

    func read(_ memory: AgentMemory) {
        send?(.readMemory(path: memory.path))
    }

    /// The text on show: what was changed, or what was read.
    func text(of memory: AgentMemory) -> String? {
        if let draft = drafts[memory.path] { return draft }
        if case .content(let content) = loaded[memory.path] { return content.text }
        return nil
    }

    func isChanged(_ memory: AgentMemory) -> Bool { drafts[memory.path] != nil }

    /// What is typed in a memory. Text that is what was read is no change.
    func setText(_ text: String, for memory: AgentMemory) {
        guard case .content(let content) = loaded[memory.path] else { return }
        if text == content.text {
            drafts[memory.path] = nil
            bases[memory.path] = nil
        } else {
            if drafts[memory.path] == nil { bases[memory.path] = content.memory.modifiedAt }
            if drafts[memory.path] != text { drafts[memory.path] = text }
        }
    }

    /// Drops what was changed, and reads the memory again.
    func revert(_ memory: AgentMemory) {
        refused[memory.path] = nil
        drafts[memory.path] = nil
        bases[memory.path] = nil
        read(memory)
    }

    /// Writes what was changed. The host refuses it, in words, when the
    /// file is no longer as it was when the change began.
    func save(_ memory: AgentMemory) {
        guard let text = drafts[memory.path], let seen = bases[memory.path] else { return }
        saving[memory.path] = text
        refused[memory.path] = nil
        send?(.writeMemory(path: memory.path, text: text, seen: seen))
    }

    /// Asked once: it goes to the Trash.
    func deleteConfirmed() {
        guard let asked = deleting else { return }
        deleting = nil
        send?(.deleteMemory(path: asked.path))
    }

    // MARK: From the host

    func handle(_ message: ServerMessage) {
        switch message {
        case .memories(let path, let list):
            if let path {
                guard path == folderAsked else { return }
                if ofFolder != list { ofFolder = list }
            } else if all != list {
                all = list
            }
            // What is shown of one that is still listed follows the list.
            if let picked = selection, let now = list.first(where: { $0.path == picked.path }), now != picked { selection = now }
        case .memoryRead(let path, let content, let problem):
            if let content {
                loaded[path] = .content(content)
                // A change that is what the file now holds is none.
                if drafts[path] == content.text {
                    drafts[path] = nil
                    bases[path] = nil
                }
                replace(content.memory)
            } else {
                loaded[path] = .problem(problem ?? MemoryWords.gone)
            }
        case .memorySaved(let memory):
            let text = saving.removeValue(forKey: memory.path)
            if let text {
                loaded[memory.path] = .content(AgentMemoryContent(memory: memory, text: text))
                if drafts[memory.path] == text {
                    drafts[memory.path] = nil
                    bases[memory.path] = nil
                } else if drafts[memory.path] != nil {
                    // Typed on while it was written: the change goes on from what was written.
                    bases[memory.path] = memory.modifiedAt
                }
            }
            replace(memory)
        case .memoryRefused(let path, let problem):
            saving[path] = nil
            // With the memory when it is on show, where the user is
            // looking; over the window otherwise (a row's Delete).
            if selection?.path == path || panelMemory?.path == path { refused[path] = problem } else { say?(problem) }
        case .memoryDeleted(let path):
            refused[path] = nil
            all?.removeAll { $0.path == path }
            ofFolder?.removeAll { $0.path == path }
            loaded[path] = nil
            drafts[path] = nil
            bases[path] = nil
            saving[path] = nil
            if selection?.path == path { selection = nil }
            if panelMemory?.path == path { panelMemory = nil }
            if deleting?.path == path { deleting = nil }
        default:
            break
        }
    }

    /// A memory as it is now, wherever it is listed or shown. Its folder
    /// stays the one each list has it under.
    private func replace(_ memory: AgentMemory) {
        func updated(_ list: [AgentMemory]?) -> [AgentMemory]? {
            list?.map { old in
                guard old.path == memory.path else { return old }
                var new = memory
                new.folder = old.folder
                return new
            }
        }
        let everywhere = updated(all)
        if everywhere != all { all = everywhere }
        let inFolder = updated(ofFolder)
        if inFolder != ofFolder { ofFolder = inFolder }
        if let picked = selection, picked.path == memory.path, let now = updated([picked])?.first, now != picked { selection = now }
        if let picked = panelMemory, picked.path == memory.path, let now = updated([picked])?.first, now != picked { panelMemory = now }
    }
}
