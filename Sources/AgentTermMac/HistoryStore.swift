import AgentTermProtocol
import Foundation

/// What History does beyond listing the conversations (#46): filtering
/// and grouping them, searching what was said, reading one, pinning,
/// hiding and deleting. The host does the reading and keeps the pins, for
/// this Mac as for another, so that every device shows the same.
@MainActor
final class HistoryStore: ObservableObject {
    /// One of the two lists: every conversation on the Mac, in History,
    /// or the folder on show's, in the side panel.
    struct Scope {
        var filter = HistoryFilter()
        var query = ""
        /// What a search found; nil while nothing is searched for.
        var hits: [HistoryHit]?
        var isSearching = false
        /// Pages of older conversations asked for after the first.
        var older: [Conversation] = []
        /// Whether there may be older ones still.
        var more = true
    }

    @Published var all = Scope()
    @Published var folder = Scope()
    @Published private(set) var pinned: Set<String> = []
    @Published private(set) var hidden: Set<String> = []
    /// Conversations as they were read, by their id; nil for one that is
    /// no longer there.
    @Published private(set) var details: [String: ConversationDetails?] = [:]
    /// The conversation the user is asked about before it is deleted, and
    /// the one asked about a second time: two questions, one after the other.
    @Published var deleting: Conversation?
    @Published var deletingAgain: Conversation?

    var send: ((ClientMessage) -> Void)?
    /// A transcript was written out as a file, here.
    var exported: ((String) -> Void)?
    /// A conversation was deleted.
    var deleted: ((String) -> Void)?
    /// What came of deleting several at once, in words, to be said (#50).
    var deletedMany: ((String) -> Void)?

    /// Searches look at the titles only, not at what was said (#50). Kept
    /// on this Mac; what was said too by default.
    @Published var titlesOnly = UserDefaults.standard.bool(forKey: "historyTitlesOnly") {
        didSet { UserDefaults.standard.set(titlesOnly, forKey: "historyTitlesOnly") }
    }

    /// The list whose conversations are being picked to be deleted, the
    /// folder's (true) or all (false), and those picked, by `Conversation.id`.
    @Published var picking: Bool?
    @Published var picked: Set<String> = []

    /// Several conversations the user is asked about before they are
    /// deleted, twice: those picked, or every one on the Mac (`ids` nil).
    struct ManyToDelete: Identifiable {
        let ids: [String]?
        let again: Bool
        var id: String { (ids?.joined(separator: ",") ?? "all") + (again ? "!" : "") }
    }
    @Published var deletingMany: ManyToDelete?

    func startPicking(ofFolder: Bool) {
        picked = []
        picking = ofFolder
    }

    func stopPicking() {
        picking = nil
        picked = []
    }

    func togglePicked(_ conversation: Conversation) {
        if picked.contains(conversation.id) { picked.remove(conversation.id) } else { picked.insert(conversation.id) }
    }

    func requestDeletePicked() {
        guard !picked.isEmpty else { return }
        deletingMany = ManyToDelete(ids: picked.sorted(), again: false)
    }

    func requestDeleteAll() { deletingMany = ManyToDelete(ids: nil, again: false) }

    /// The first question answered: the second once it has left the
    /// screen; the second answered: they are deleted.
    func deleteManyConfirmed() {
        guard let asked = deletingMany else { return }
        deletingMany = nil
        if !asked.again {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.deletingMany = ManyToDelete(ids: asked.ids, again: true) }
            return
        }
        send?(.deleteConversations(ids: asked.ids))
        stopPicking()
    }

    /// Numbers the searches, of both lists.
    private var counter = 0
    /// The number of the search going on for each list, the folder's (true)
    /// or all (false): each list has its own, and the host keeps one of each.
    private var numbers: [Bool: Int] = [:]
    /// The search each list waits a moment to start, after the last key.
    private var pending: [Bool: DispatchWorkItem] = [:]

    /// The list a search's answer is for: none when it is no longer wanted.
    private func list(of search: Int) -> Bool? { numbers.first { $0.value == search }?.key }

    subscript(ofFolder ofFolder: Bool) -> Scope {
        get { ofFolder ? folder : all }
        set { if ofFolder { folder = newValue } else { all = newValue } }
    }

    /// Everything known of another Mac is forgotten; the filters stay.
    func reset() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        numbers = [:]
        all.hits = nil
        all.isSearching = false
        all.older = []
        all.more = true
        folderChanged()
        details = [:]
        deleting = nil
        deletingAgain = nil
        deletingMany = nil
        stopPicking()
    }

    /// The side panel shows another folder: its own conversations.
    func folderChanged() {
        pending[true]?.cancel()
        numbers[true] = nil
        folder.hits = nil
        folder.isSearching = false
        folder.older = []
        folder.more = true
        folder.query = ""
    }

    // MARK: Searching

    /// Searches for what is typed in one of the lists, a moment after the
    /// last key. An empty field shows the list again.
    func search(ofFolder: Bool, path: String?) {
        // This list's only: the other's search goes on.
        pending[ofFolder]?.cancel()
        let query = self[ofFolder: ofFolder].query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            numbers[ofFolder] = nil
            self[ofFolder: ofFolder].hits = nil
            self[ofFolder: ofFolder].isSearching = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.counter += 1
            self.numbers[ofFolder] = self.counter
            self[ofFolder: ofFolder].hits = []
            self[ofFolder: ofFolder].isSearching = true
            self.send?(.searchHistory(search: self.counter, path: ofFolder ? path : nil, query: query, titlesOnly: self.titlesOnly))
        }
        pending[ofFolder] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: One conversation

    func read(_ conversation: Conversation) {
        send?(.readConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func export(_ conversation: Conversation) {
        send?(.exportConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func pin(_ conversation: Conversation, _ pinned: Bool) { send?(.markConversation(id: conversation.id, pinned: pinned, hidden: nil)) }
    func hide(_ conversation: Conversation, _ hidden: Bool) { send?(.markConversation(id: conversation.id, pinned: nil, hidden: hidden)) }

    /// Deleting is asked about twice: it is the agent's own record that
    /// goes. The second question comes once the first has left the screen.
    func firstQuestionConfirmed() {
        guard let asked = deleting else { return }
        deleting = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.deletingAgain = asked }
    }

    func deleteConfirmed() {
        guard let asked = deletingAgain else { return }
        deletingAgain = nil
        send?(.deleteConversation(agent: asked.agent, sessionID: asked.sessionID, cwd: asked.cwd))
    }

    func loadOlder(ofFolder: Bool, path: String?, shown: [Conversation]) {
        guard let oldest = (shown + self[ofFolder: ofFolder].older).map(\.updatedAt).min() else { return }
        send?(.historyOlder(path: ofFolder ? path : nil, before: oldest))
    }

    // MARK: From the host

    /// - Parameter folderPath: The folder the side panel shows.
    func handle(_ message: ServerMessage, folderPath: String?) {
        switch message {
        case .historyMarks(let pinned, let hidden):
            self.pinned = Set(pinned)
            self.hidden = Set(hidden)
        case .conversationRead(let id, let read):
            details[id] = .some(read)
            // The last few are kept: each may be megabytes.
            if details.count > 8, let other = details.keys.first(where: { $0 != id }) { details[other] = nil }
        case .historyFound(let search, let hits):
            guard let ofFolder = list(of: search) else { return }
            self[ofFolder: ofFolder].hits = (self[ofFolder: ofFolder].hits ?? []) + hits
        case .historySearchEnded(let search):
            guard let ofFolder = list(of: search) else { return }
            numbers[ofFolder] = nil
            self[ofFolder: ofFolder].isSearching = false
        case .historyOlder(let path, let conversations, let more):
            let ofFolder = path != nil
            guard !ofFolder || path == folderPath else { return }
            let known = Set(self[ofFolder: ofFolder].older.map(\.id))
            self[ofFolder: ofFolder].older += conversations.filter { !known.contains($0.id) }
            self[ofFolder: ofFolder].more = more
        case .conversationsDeleted(let deleted, let kept):
            // The rows going say the rest; one that was kept is told.
            if kept > 0 { deletedMany?(DeleteConversationsQuestion.done(deleted: deleted, kept: kept)) }
        case .conversationDeleted(let id):
            picked.remove(id)
            details[id] = nil
            all.older.removeAll { $0.id == id }
            folder.older.removeAll { $0.id == id }
            all.hits?.removeAll { $0.id == id }
            folder.hits?.removeAll { $0.id == id }
            deleted?(id)
        case .conversationExported(_, let path):
            exported?(path)
        default:
            break
        }
    }
}
