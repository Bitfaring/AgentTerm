import ActivityKit
import AgentTermClient
import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import Combine
import SwiftUI
import UserNotifications

enum LinkStatus: Equatable {
    case connecting
    case connected
    case offline(String?)
}

/// A screen that can be pushed onto the navigation stack.
enum Route: Hashable {
    case session(SessionID)
    /// What an agent's last turn came to, opened from the Inbox (#71).
    case result(SessionID)
    /// All of the Inbox (#66).
    case inbox
    /// One item of the Inbox, all of it: what touching it opens, as on the
    /// Mac (the owner's decision, 2026-11-21).
    case notice(UInt64)
    /// An agent's screen with one of its own shells ("s:<id>") or pages
    /// ("b:<id>") in front.
    case companion(agent: SessionID, item: String)
    /// A folder's changes and history.
    case folder(String)
    /// The diff of one changed file.
    case file(folder: String, file: String, staged: Bool)
    /// A file on the Mac, to read or edit.
    case document(path: String)
    /// The same, shown at a line a search found (#45).
    case documentLine(path: String, line: Int)
    /// The commits of a folder's checked out branch (#36).
    case commits(folder: String)
    /// One commit: its message and the files it changed.
    case commit(folder: String, hash: String)
    /// What a commit did to one file.
    case commitFile(folder: String, hash: String, file: String)
    /// What is in a folder's stash (#38).
    case stashes(folder: String)
    /// One stash: its files, and bringing it back or dropping it.
    case stash(folder: String, hash: String)
    /// What a stash holds of one file.
    case stashFile(folder: String, hash: String, file: String)
}

/// A file on the Mac as it was last read.
struct RemoteFile: Equatable {
    var content: FileContent
    /// The bytes of an image.
    var data: Data?
}

struct HandoffPlan: Equatable {
    let id: String
    let prompt: String
}

/// A project folder on the Mac with the sessions running in it.
struct FolderGroup: Identifiable {
    /// `nil` is the home directory, offered when the Mac has no folders yet.
    let path: String?
    let sessions: [SessionInfo]

    var id: String { path ?? "~" }
    var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "Home" }
}

@MainActor
final class PhoneModel: ObservableObject {
    /// Every Mac this iPhone is paired with.
    @Published private(set) var hosts: [SavedHost] = []
    /// The Mac on screen. There is one connection at a time, to this Mac.
    @Published private(set) var pairing: SavedHost?
    /// The sheet for pairing one more Mac.
    @Published var showPairSheet = false
    /// A pairing code is being traded for a token.
    @Published private(set) var isPairing = false
    @Published private(set) var status: LinkStatus = .offline(nil) {
        // The Live Activity can only be kept true while connected (#24).
        didSet { if status != oldValue { updateLiveActivity() } }
    }
    @Published private(set) var sessions: [SessionInfo] = []
    /// The tabs of the browser in AgentTerm on the Mac (#76). The phone
    /// does not browse: it looks at a tab, and takes it from its agent or
    /// gives it back.
    @Published private(set) var browserTabs: [BrowserTabInfo] = []
    /// What the Mac answered about a tab: a picture of it, or why there is none.
    @Published private(set) var browserPictures: [String: Data] = [:]
    @Published private(set) var browserProblems: [String: String] = [:]
    private var browserAsks = BrowserAsks<(BrowserResult) -> Void>()

    /// Asks the browser on the Mac, through its host. With no connection,
    /// nothing could answer it: refused at once (#198).
    func askBrowser(_ request: BrowserRequest, _ done: @escaping (BrowserResult) -> Void = { _ in }) {
        guard let connection else { return done(.refused(BrowserWords.otherMacClosed(connectedMacName))) }
        let id = browserAsks.add(done)
        connection.send(.browserAsk(id: id, request: request))
    }

    func browserAnswered(id: Int, result: BrowserResult) {
        browserAsks.answered(id)?(result)
    }

    /// The Mac the connection is to: the one being paired while pairing.
    private var connectedMacName: String {
        (isPairing ? pendingPairing?.name : pairing?.name) ?? "the Mac"
    }

    /// The connection closed, or was left for another Mac (#198, as the
    /// Mac's #196): what waits for the Mac's browser cannot be answered by
    /// it now, so each is answered at once, refused in the Mac's words, and
    /// said where its own refusal is said (a page's problem, a sheet's).
    private func refuseBrowserAsks() {
        guard let closed = browserAsks.closed(mac: connectedMacName) else { return }
        for done in closed.waiting { done(.refused(closed.why)) }
    }

    /// Asks for a picture of a tab as it is now.
    func refreshPicture(of tab: String) {
        askBrowser(.picture(tab: tab)) { [weak self] result in
            switch result {
            case .image(let data, _):
                self?.browserPictures[tab] = data
                self?.browserProblems[tab] = nil
            case .refused(let why):
                self?.browserProblems[tab] = why
            default:
                break
            }
        }
    }

    /// Takes a tab from its agent, or gives it back.
    func setUserHas(_ tab: String, _ has: Bool) {
        askBrowser(has ? .takeOver(tab: tab) : .giveBack(tab: tab)) { [weak self] result in
            if case .refused(let why) = result { self?.browserProblems[tab] = why }
        }
    }

    // MARK: A page, live (#76)

    /// The last picture of a page this iPhone watches, and the page's size
    /// in CSS pixels, by which a touch on it is placed.
    struct BrowserFrame {
        let image: UIImage
        let width: Double
        let height: Double
    }

    @Published private(set) var browserFrames: [String: BrowserFrame] = [:]

    /// The pages whose screen is open, and the width in pixels their
    /// pictures are asked at, watched again when the connection comes back
    /// (#209): the Mac's watch ended with the connection.
    private var watchedPages: [String: Int] = [:]

    /// Starts or stops being sent a page's pictures, `width` pixels wide:
    /// the pixels of the room they are drawn in (`PagePicture.width`,
    /// #107). Asked again at another width when the room changes.
    func watch(_ tab: String, _ on: Bool, width: Int = 0) {
        if on { watchedPages[tab] = width } else { watchedPages[tab] = nil }
        askBrowser(.watch(tab: tab, on: on, width: on ? width : 0)) { [weak self] result in
            // Watched again once the Mac is back: what was refused while it
            // was not is no longer so (#198).
            if case .refused(let why) = result { self?.browserProblems[tab] = why } else { self?.browserProblems[tab] = nil }
        }
        if !on { browserFrames[tab] = nil }
    }

    /// Uses the page: what an agent's tab the Mac then gives to the user.
    func useBrowser(_ request: BrowserRequest, _ done: @escaping (BrowserResult) -> Void = { _ in }) {
        guard let tab = request.tab else { return }
        askBrowser(request) { [weak self] result in
            if case .refused(let why) = result { self?.browserProblems[tab] = why } else { self?.browserProblems[tab] = nil }
            done(result)
        }
    }

    /// The Mac's browser profiles, the default first: with several, a page
    /// of the user's is opened in the one picked (#76).
    @Published private(set) var browserProfiles: [BrowserProfileInfo] = []

    func loadBrowserProfiles() {
        guard status == .connected else { return }
        askBrowser(.profiles) { [weak self] result in
            if case .profiles(let list) = result { self?.browserProfiles = list }
        }
    }

    /// Opens a tab of the user's on the Mac, in a project, in a profile
    /// (its id), the default, or private: `done` gets its id, or nil when
    /// it could not be opened, and why.
    func openPage(in project: String, url: String? = nil, profile: String? = nil, isPrivate: Bool = false, _ done: @escaping (String?, String?) -> Void) {
        askBrowser(.newTab(project: project, url: url, profile: profile, private: isPrivate)) { result in
            switch result {
            case .opened(let tab): done(tab, nil)
            case .refused(let why): done(nil, why)
            default: done(nil, "The Mac did not open it.")
            }
        }
    }
    /// How the sessions are arranged: order, pins and groups. The Mac keeps
    /// it, and its window and every phone show the same.
    @Published var sessionLayout = TabLayout() {
        didSet {
            guard sessionLayout != oldValue, layoutKnown, !applyingHostLayout else { return }
            connection?.send(.setTabLayout(sessionLayout))
        }
    }
    /// Whether the Mac is kept awake while sessions run. Nil until the Mac
    /// has said, which an older version never does.
    @Published private(set) var keepAwake: Bool?

    /// Whether the Mac's host starts when its user logs in. Nil from a Mac
    /// that cannot do that, or that has not said yet.
    @Published private(set) var startAtLogin: Bool?
    /// What keeps the agents from opening shells although that is on (#58),
    /// as the host says it, and those of them the user has closed here.
    @Published private(set) var agentShellsFaults: [AgentShellsFault] = []
    @Published private var closedShellsFaults: Set<String> = []
    /// The ones to warn of: a fault that was closed is shown again only
    /// after it went away and came back.
    var shownShellsFaults: [AgentShellsFault] { agentShellsFaults.filter { !closedShellsFaults.contains($0.id) } }

    func dismiss(_ fault: AgentShellsFault) { closedShellsFaults.insert(fault.id) }

    private func took(_ faults: [AgentShellsFault]) {
        agentShellsFaults = faults
        closedShellsFaults.formIntersection(faults.map(\.id))
    }

    func setStartAtLogin(_ on: Bool) {
        startAtLogin = on
        connection?.send(.setStartAtLogin(on))
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        connection?.send(.setKeepAwake(on))
    }

    /// The display too, only on power, and for how long. The Mac keeps
    /// them, and its Settings show the same.
    @Published private(set) var keepAwakeOptions = KeepAwakeOptions()

    func setKeepAwakeOptions(_ options: KeepAwakeOptions) {
        keepAwakeOptions = options
        connection?.send(.setKeepAwakeOptions(options))
    }

    /// How things are shown: the temperature's unit, diffs in one panel or
    /// two, changes as a list or a tree. The host keeps them, so a choice
    /// made here shows on the Mac too, and the other way round. The views
    /// read them from this app's preferences, which are written here.
    @Published private(set) var display = DisplaySettings.stored()
    func setDisplay(_ change: (inout DisplaySettings) -> Void) {
        var settings = display
        change(&settings)
        settings = settings.checked
        guard settings != display else { return }
        display = settings
        settings.store()
        connection?.send(.setDisplaySettings(settings))
    }

    /// The host's settings, or, from a host that keeps none yet, the cue
    /// to hand it this app's.
    private func hostSent(display settings: DisplaySettings?) {
        if let settings {
            display = settings.checked
            display.store()
        } else {
            connection?.send(.setDisplaySettings(display))
        }
    }

    /// Which agent writes commit messages, and how it is asked. Kept by the Mac.
    @Published private(set) var commitWriter = CommitWriterSettings()

    func setCommitWriter(_ settings: CommitWriterSettings) {
        commitWriter = settings
        connection?.send(.setCommitWriter(settings))
    }

    /// The folders an agent is writing a commit message for right now.
    @Published private(set) var writingCommitMessage: Set<String> = []

    /// Asks an agent on the Mac for the message of what is staged. The
    /// answer lands in the message field; nothing is committed.
    func writeCommitMessage(in folder: String) {
        guard status == .connected, !writingCommitMessage.contains(folder) else { return }
        writingCommitMessage.insert(folder)
        connection?.send(.writeCommitMessage(path: folder))
    }

    func cancelCommitMessage(in folder: String) {
        guard writingCommitMessage.contains(folder) else { return }
        connection?.send(.cancelCommitMessage(path: folder))
    }

    /// The agent that would write a commit message: the one chosen, or the
    /// first one installed on the Mac.
    var commitWriterAgent: AgentInfo? {
        commitWriter.writer(among: agents)
    }

    /// What is asked of each folder's git on the Mac (#116): what the user
    /// asked for holds the folder, the fetch the app makes by itself holds
    /// nothing, and what is asked for meanwhile is sent when it is over.
    @Published private var remoteWork = RemoteWork<ClientMessage>()
    /// "push", "pull" and the rest while one the user asked for is under
    /// way in a folder.
    var syncing: [String: String] { remoteWork.busy }

    /// Asks the Mac for something of a folder's git that holds the folder
    /// until it is over. Refused while something else asked for is under
    /// way, the buttons being held then; kept while the app asks the
    /// folder's remotes by itself, and sent when that is over.
    /// How many answers with a folder's changes the Mac still owes, as on
    /// the Mac (#285): it answers side by side, and the changes asked for
    /// before a commit may come back while git is still at it.
    private var diffAnswersDue: [String: Int] = [:]

    /// Sends what the Mac answers with the folder's changes, counted.
    /// - Parameter quietly: a look at the changes, which nobody asked for in
    ///   words: not said when it cannot be sent.
    private func sendForDiff(_ message: ClientMessage, in folder: String, quietly: Bool = false) {
        guard status == .connected, let connection else {
            if !quietly { self.message = NotConnectedWords.notDone(pairing?.name ?? "The Mac") }
            return
        }
        diffAnswersDue[folder, default: 0] += 1
        connection.send(message)
    }

    private func ask(_ what: String, in folder: String, _ message: ClientMessage) {
        guard status == .connected else { return }
        if remoteWork.ask(what, in: folder, keeping: message) == .begin { connection?.send(message) }
    }

    /// Pushes the folder's branch. For a branch that follows nothing yet
    /// the Mac picks the remote the changes name, and sets it to be followed.
    func push(in folder: String) {
        ask("push", in: folder, .gitPush(path: folder))
    }

    /// Brings in what the upstream has: the way the repository is set up
    /// to (`mode` nil), by "merge" or by "rebase" (#37).
    func pull(in folder: String, mode: String? = nil) {
        ask("pull", in: folder, .gitPull(path: folder, mode: mode))
    }

    /// What the last fetch no one asked for said when it failed, by folder.
    @Published private(set) var fetchProblems: [String: String] = [:]
    private var fetchedAt: [String: Date] = [:]
    /// A forced push that waits to be confirmed, with what it would overwrite.
    @Published var pendingForcePush: ForcePush?
    @Published private(set) var askingForcePush: String?

    struct ForcePush: Identifiable {
        let folder: String
        let question: ForcePushQuestion
        /// The commit the upstream was at when it was looked at: the push
        /// is made only while it is still there.
        let lease: String
        var id: String { folder }
    }

    /// Asks the folder's remotes on the Mac for what is new. `automatic`
    /// when no one asked: its failure is noted, and interrupts no one. It
    /// holds no button either (#116): what is asked for while it is under
    /// way is sent when it is over.
    func fetch(in folder: String, automatic: Bool = false) {
        guard status == .connected else { return }
        let message = ClientMessage.gitFetch(path: folder, automatic: automatic)
        if automatic {
            guard remoteWork.beginQuietFetch(in: folder) else { return }
        } else {
            switch remoteWork.ask("fetch", in: folder, keeping: message) {
            case .refused: return
            case .kept:
                fetchedAt[folder] = Date()
                return
            case .begin: break
            }
        }
        fetchedAt[folder] = Date()
        connection?.send(message)
    }

    /// Fetches the folder on screen when it is time to: the setting on, a
    /// remote to ask, and the last fetch longer ago than the interval.
    func fetchIfDue(_ folder: String) {
        guard display.fetchAutomatically, let diff = diffs[folder], diff.isRepository, diff.upstream != nil || diff.pushRemote != nil else { return }
        guard Date().timeIntervalSince(fetchedAt[folder] ?? .distantPast) >= DisplaySettings.fetchInterval else { return }
        fetch(in: folder, automatic: true)
    }

    /// Asks the Mac what a forced push would overwrite, then asks the user.
    func requestForcePush(in folder: String) {
        guard status == .connected, askingForcePush == nil else { return }
        askingForcePush = folder
        connection?.send(.gitForcePushPreview(path: folder))
    }

    func forcePushConfirmed(_ push: ForcePush) {
        ask("push", in: push.folder, .gitPush(path: push.folder, force: true, lease: push.lease))
    }

    /// How the Mac is doing: processor, memory, network, heat, battery, uptime.
    /// Kept apart from this model, so that figures arriving every few
    /// seconds redraw only the view that shows them, not the lists: a list
    /// that is rebuilt drops the row being dragged in it.
    let system = SystemStatsStore()

    /// The hosts of the Mac's SSH configuration.
    @Published private(set) var sshHosts: [String] = []
    /// The protocol version the Mac's host speaks. Zero until it has said.
    private var hostVersion = 0

    /// Opens `ssh <host>` on the Mac, which makes the Mac the way to that host.
    func connectSSH(_ host: String) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: nil)))
        connection?.send(.connectSSH(host: host, size: startingSize))
    }

    /// How the version of AgentTerm on the Mac compares with this app's.
    @Published private(set) var hostMatch = ProtocolMatch.same
    /// Parts of AgentTerm on the Mac that stopped without being asked to:
    /// the host above all, whose sessions ended with it. Kept by the Mac
    /// until the user has seen them here or on another device.
    @Published private(set) var failures: [PartFailure] = []

    /// The user has seen it: it goes here and on every other device.
    func dismiss(_ failure: PartFailure) {
        failures.removeAll { $0.id == failure.id }
        connection?.send(.dismissFailure(id: failure.id))
    }
    /// The session being dragged in the list, from when it is picked up.
    var draggedSession: String?
    /// The folder being dragged in the list.
    var draggedFolder: String?

    /// Puts a listed folder just before another, or last. The Mac keeps
    /// the list, so its window shows the same order.
    func moveFolder(_ path: String, before target: String?) {
        guard path != target, folders.contains(path) else { return }
        connection?.send(.moveFolder(path: path, before: target))
    }

    /// Moves a listed folder one place up (-1) or down (+1).
    func moveFolder(_ path: String, by offset: Int) {
        guard let index = folders.firstIndex(of: path), folders.indices.contains(index + offset) else { return }
        moveFolder(path, before: offset < 0 ? folders[index - 1] : (folders.indices.contains(index + 2) ? folders[index + 2] : nil))
    }

    func canMoveFolder(_ path: String, by offset: Int) -> Bool {
        guard let index = folders.firstIndex(of: path) else { return false }
        return folders.indices.contains(index + offset)
    }
    /// True once the Mac on screen has listed its sessions.
    /// True once the Mac has listed its sessions.
    @Published private(set) var sessionsKnown = false
    /// Whether `sessions` is what the Mac says now: not after the app was in
    /// the background, where iOS may have held the connection without a
    /// word, nor after it closed. A notification's reply or press waits for
    /// a list said after it (#276).
    private var sessionsFresh = false
    /// The session whose earlier output is being sent, until all of it is here.
    @Published private(set) var replaying: SessionID?
    /// True once it has sent the arrangement.
    private var layoutKnown = false
    private var applyingHostLayout = false
    @Published private(set) var folders: [String] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var agentsLoaded = false
    /// The screens on the navigation stack.
    @Published var path: [Route] = [] {
        // A notice hides by itself once its session is opened, however the
        // user got there, and does not come back when they leave it (#60).
        didSet {
            // What a done agent's turn came to is what its notice told: the
            // notice goes, and the session is seen only once it is opened.
            if case .result(let id)? = path.last { readInbox(session: id) }
            guard let open = openSessionID else { return }
            sawNotice(of: open)
        }
    }

    /// What the agent of the session on screen said or asks is seen: its
    /// notification goes from Notification Center, and the Mac is told, so
    /// that the other devices hide their notice of it (#60).
    private func sawNotice(of session: SessionID) {
        readInbox(session: session)
        // Told again while the host still has it unseen (#67): the same
        // words said twice are two turns.
        guard let info = sessions.first(where: { $0.id == session }), let state = info.state, !state.isWorking,
            info.unseen == true || noticeSeenTold?.session != session || noticeSeenTold?.state != state
        else { return }
        noticeSeenTold = (session, state)
        connection?.send(.noticeSeen(session: session, state: state))
    }

    /// The last notice the Mac was told is seen, so it is told once.
    private var noticeSeenTold: (session: SessionID, state: AgentState)?
    /// The tab in front: "sessions", "history", "schedules" or "settings".
    @Published var tab = "sessions"
    /// A folder's uncommitted changes, by folder. Without the diffs.
    @Published private(set) var diffs: [String: DiffSnapshot] = [:]
    // MARK: Stash (#38)

    /// What is in each folder's stash, newest first.
    @Published private(set) var stashes: [String: [StashInfo]] = [:]
    /// The files each stash that was opened holds, by its hash.
    @Published private(set) var stashFiles: [String: [FileDiff]] = [:]

    func loadStashes(_ folder: String) { connection?.send(.gitStashes(path: folder)) }

    func loadStash(_ hash: String, in folder: String) {
        guard stashFiles[hash] == nil else { return }
        connection?.send(.gitStashShow(path: folder, hash: hash))
    }

    /// Puts the folder's changes aside on the Mac, the new files too when asked.
    func stash(named name: String, untracked: Bool, in folder: String) {
        sendForDiff(.gitStash(path: folder, message: name, untracked: untracked), in: folder)
    }

    func applyStash(_ hash: String, pop: Bool, in folder: String) {
        sendForDiff(.gitStashApply(path: folder, hash: hash, pop: pop), in: folder)
    }

    /// Throws a stash away, once the user was asked.
    func dropStash(_ hash: String, in folder: String) {
        sendForDiff(.gitStashDrop(path: folder, hash: hash), in: folder)
    }

    // MARK: Commits (#36)

    /// The commits of each folder's checked out branch, newest first, as
    /// far as they were asked for, and whether there are older ones.
    @Published private(set) var commits: [String: [CommitInfo]] = [:]
    @Published private(set) var commitsMore: [String: Bool] = [:]
    /// The folders a page of commits is on its way for.
    @Published private(set) var loadingCommits: Set<String> = []
    /// What each commit that was opened changed, by its hash.
    @Published private(set) var commitDetails: [String: CommitDetails] = [:]
    static let commitsPage = 50
    /// The branch whose commits each folder lists, as on the Mac: nil for
    /// the checked out one. Another branch's commits are picked onto it.
    @Published var commitsBranch: [String: String] = [:]

    /// Reads the first page of a folder's commits again.
    func loadCommits(_ folder: String) {
        commits[folder] = []
        commitsMore[folder] = false
        loadingCommits.insert(folder)
        connection?.send(.gitLog(path: folder, branch: commitsBranch[folder], skip: 0, limit: Self.commitsPage))
    }

    /// Reads the next page, when there is one and none is on its way.
    func loadMoreCommits(_ folder: String) {
        guard commitsMore[folder] == true, !loadingCommits.contains(folder) else { return }
        loadingCommits.insert(folder)
        connection?.send(.gitLog(path: folder, branch: commitsBranch[folder], skip: commits[folder]?.count ?? 0, limit: Self.commitsPage))
    }

    /// Lists another branch's commits, or the checked out one's (nil).
    func showCommits(of branch: String?, in folder: String) {
        commitsBranch[folder] = branch
        loadCommits(folder)
    }

    /// Reverts a commit, or picks it onto the checked out branch (#36), once
    /// the user was asked in the words of `CommitActionQuestion`. One that
    /// conflicts is left to be resolved, as on the Mac, and said.
    func apply(_ action: CommitActionQuestion.Action, _ commit: CommitInfo, in folder: String) {
        ask(
            action == .revert ? "revert" : "cherry-pick", in: folder,
            action == .revert ? .gitRevert(path: folder, hash: commit.hash) : .gitCherryPick(path: folder, hash: commit.hash))
    }

    func loadCommit(_ hash: String, in folder: String) {
        guard commitDetails[hash] == nil else { return }
        connection?.send(.gitShow(path: folder, hash: hash))
    }

    /// The branches of each folder that was asked about (#35), its own first.
    @Published private(set) var branches: [String: [BranchInfo]] = [:]

    func loadBranches(_ folder: String) { connection?.send(.gitBranches(path: folder)) }

    /// Checks a branch out on the Mac. Refused there, in words, when
    /// changes that are not committed would be lost.
    func switchBranch(_ branch: BranchInfo, in folder: String) {
        sendForDiff(.gitSwitch(path: folder, branch: branch.name), in: folder)
    }

    func createBranch(named name: String, from start: String?, checkout: Bool, in folder: String) {
        sendForDiff(.gitCreateBranch(path: folder, name: name, from: start, checkout: checkout), in: folder)
    }

    /// Gives one of the repository's own branches another name (#35).
    func renameBranch(_ branch: BranchInfo, to name: String, in folder: String) {
        sendForDiff(.gitRenameBranch(path: folder, from: branch.name, to: name), in: folder)
    }

    /// Deletes one of the repository's own branches, once asked as on the
    /// Mac (`DeleteBranchQuestion`): with force for one whose commits are
    /// on no other branch, which is asked about twice.
    func deleteBranch(_ branch: BranchInfo, in folder: String) {
        sendForDiff(.gitDeleteBranch(path: folder, name: branch.name, force: !branch.isMerged), in: folder)
    }
    /// The diff of a file, by `patchKey`. A missing file is stored as nil.
    @Published private(set) var patches: [String: FileDiff?] = [:]
    /// What each agent's account has used and has left, by agent.
    @Published private(set) var accountUsage: [String: AccountUsage] = [:]

    /// Asks the agents' services again.
    func refreshAccountUsage() {
        connection?.send(.accountUsage(refresh: true))
    }

    /// The files and folders in a folder of the Mac, by folder.
    @Published private(set) var fileListings: [String: [FileEntry]] = [:]
    /// Files of the Mac that were opened, by path.
    @Published private(set) var remoteFiles: [String: RemoteFile] = [:]
    /// The file being saved and not answered yet.
    @Published private(set) var savingFile: String?
    /// A file that was just created on the Mac, for the tree to open.
    @Published var createdFile: String?
    private var savingText: String?
    /// The commit message being written, by folder.
    @Published var commitDrafts: [String: String] = [:]
    /// The folder a commit was asked for and not answered yet.
    @Published private(set) var committing: String?
    /// Conversations by folder. The empty key is "everywhere on the Mac".
    @Published private(set) var histories: [String: [Conversation]] = [:]
    /// The conversation of a running session that is being handed off.
    @Published var sessionHandoff: Conversation?
    /// What the receiving agent would be told, while the handoff sheet is open.
    @Published private(set) var handoffPlan: HandoffPlan?
    /// The folder shown in the folder picker.
    @Published private(set) var listing: DirectoryListing?
    @Published var showBrowser = false
    @Published private(set) var controller: TerminalController?
    @Published private(set) var foreignSize: TermSize?
    /// Who decides it, when the host says (#120).
    @Published private(set) var sizeDriver: SizeDriver?
    @Published var message: String?
    @Published private(set) var fontSize: Double

    private var connection: AgentTermConnection?
    /// Where a pairing code came from, until the Mac answers it.
    private var pendingPairing: PairingInfo?
    private var openCreatedSession = false
    private var reattachAfterConnect = false
    private var retryScheduled = false
    /// Attempts to connect since the last time it worked.
    private var failedAttempts = 0
    /// Whether the app is in front. One that iOS launched in the background
    /// (for a push) is not (#190).
    private var active = UIApplication.shared.applicationState != .background

    // MARK: Agents that finished or need an instruction (#22)

    /// The Mac's schedules (#11), as its host keeps them.
    @Published private(set) var schedules: [Schedule] = []

    /// Each folder's git worktrees (#23, #33), as its host lists them.
    @Published private(set) var worktrees: [String: [WorktreeInfo]] = [:]
    /// The worktrees the host is making for sessions, and where each is at (#244).
    @Published private(set) var worktreesInProgress: [WorktreeInProgress] = []
    /// What became of the last worktree that was finished.
    @Published var worktreeSaid: String?

    func listWorktrees(_ folder: String) { connection?.send(.listWorktrees(folder: folder)) }
    func finishWorktree(_ worktree: WorktreeInfo, of folder: String, _ finish: WorktreeFinish, deleteBranch: Bool) {
        connection?.send(.finishWorktree(folder: folder, path: worktree.path, finish: finish, deleteBranch: deleteBranch))
    }
    /// Whether a schedule was sent to be saved: not while the Mac is not
    /// connected, which is said (#286), and the form stays open.
    @discardableResult func save(_ schedule: Schedule) -> Bool { sendOrSay(.saveSchedule(schedule)) }
    func removeSchedule(_ id: String) { sendOrSay(.removeSchedule(id: id)) }

    /// Sends what changes the Mac, or says at once that it is not connected
    /// and nothing was done (#286, principle 3).
    @discardableResult private func sendOrSay(_ message: ClientMessage) -> Bool {
        guard status == .connected, let connection else {
            self.message = NotConnectedWords.notDone(pairing?.name ?? "The Mac")
            return false
        }
        connection.send(message)
        return true
    }

    // MARK: What is done with a schedule and its runs (#47)

    /// Every schedule is held back.
    @Published private(set) var schedulesPaused = false
    /// What runs printed, as asked for, by the run's id; nil inside when
    /// nothing was kept of one.
    @Published private(set) var runOutputs: [String: String?] = [:]

    func runNow(_ schedule: Schedule) { sendOrSay(.runSchedule(id: schedule.id)) }
    func stop(_ run: ScheduleOverview.Run) { sendOrSay(.stopScheduleRun(id: run.schedule.id, at: run.run.at)) }
    func duplicate(_ schedule: Schedule) { sendOrSay(.duplicateSchedule(id: schedule.id)) }
    func pauseSchedules(_ paused: Bool) { sendOrSay(.pauseSchedules(paused)) }
    func loadOutput(of run: ScheduleOverview.Run) { connection?.send(.scheduleRunOutput(id: run.schedule.id, at: run.run.at)) }

    /// Someone is at the Mac: for the Live Activity.
    @Published private(set) var macInUse = false
    /// Whether to be told at all: a switch in the Settings tab.
    @Published var notifyAgents: Bool = UserDefaults.standard.object(forKey: "notifyAgents") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyAgents, forKey: "notifyAgents")
            if notifyAgents { notifications.askOnce() }
            updatePush()
        }
    }

    // MARK: The first screen: may the app notify? (#180)

    /// Shown once, at the first launch, while iOS was not asked yet: the
    /// question alone, not an onboarding like the Mac's (the owner's
    /// decision, 2026-11-20).
    @Published private(set) var asksNotifications = false
    static let notificationsAskedKey = "notifications.asked"

    private func checkNotificationAsk() {
        // A test sees it whatever iOS was told before (`AGENTTERM_ASK_NOTIFICATIONS`).
        if ProcessInfo.processInfo.environment["AGENTTERM_ASK_NOTIFICATIONS"] != nil { return asksNotifications = true }
        guard !UserDefaults.standard.bool(forKey: Self.notificationsAskedKey) else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ask = settings.authorizationStatus == .notDetermined
            Task { @MainActor [weak self] in self?.asksNotifications = ask }
        }
    }

    /// Allowed, or not now: not shown again either way. Not now turns the
    /// app's notifications off (the owner's decision, #195): the switch in
    /// Settings shows it, and iOS is asked only once it is turned on.
    func answerNotificationAsk(allow: Bool) {
        UserDefaults.standard.set(true, forKey: Self.notificationsAskedKey)
        guard allow else {
            notifyAgents = false
            asksNotifications = false
            return
        }
        notifications.askOnce { _ in
            Task { @MainActor [weak self] in
                self?.asksNotifications = false
                self?.updatePush()
            }
        }
    }

    // MARK: Through Apple while the app is closed (#66)

    /// Whether to be told through Apple too: a switch under the one above.
    @Published var pushAlso: Bool = UserDefaults.standard.object(forKey: "pushAlso") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pushAlso, forKey: "pushAlso")
            updatePush()
        }
    }
    /// What the Mac on screen says of it.
    @Published private(set) var hostPushState: PushState?
    /// What stops it on this iPhone, when something does.
    @Published private(set) var pushProblem: String?
    private var deviceToken: String?
    private var pushTokenWatch: AnyCancellable?
    private var pushFailureWatch: AnyCancellable?
    /// Registered on this connection already: once each time, so that the
    /// host's ticket from the relay stays fresh.
    private var pushAsked = false

    /// Whether iOS has notifications turned off for the app, as its
    /// Settings say when the app comes to the front (#213).
    @Published private(set) var notificationsRefused = false

    /// Whether iOS lets the app notify: the switch shows off while it does
    /// not (#213), and the footnote says why.
    var pushAllowed: Bool { !notificationsRefused && pushProblem != PushWords.notAllowed }

    /// Reads what the iPhone's Settings say of the app's notifications:
    /// they are changed there, while the app is away.
    private func readNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let refused = settings.authorizationStatus == .denied
            Task { @MainActor [weak self] in
                guard let self, self.notificationsRefused != refused else { return }
                self.notificationsRefused = refused
                // Allowed again: registered now, not at the next connection.
                if !refused, self.pushProblem == PushWords.notAllowed { self.pushProblem = nil }
                self.updatePush()
            }
        }
    }

    /// What the switch's footnote says (principle 3): what holds it back,
    /// else what the Mac says.
    var pushState: PushState? {
        guard notifyAgents else { return nil }
        // Said whatever the switch keeps, which shows off then (#212).
        if AppChannel.current != .release { return .unavailable(reason: PushWords.notInThisBuild) }
        if !pushAllowed { return .unavailable(reason: PushWords.notAllowed) }
        guard pushAlso else { return nil }
        if let pushProblem { return .unavailable(reason: pushProblem) }
        return hostPushState
    }

    /// Registers with the Mac on screen, or no longer, as the switches say.
    private func updatePush() {
        guard status == .connected, let connection, let pairing else { return }
        // Nor while iOS has them off (#213): the switch shows off then.
        guard notifyAgents, pushAlso, AppChannel.current == .release, !notificationsRefused else {
            if hostPushState == .on { connection.send(.pushUnregister) }
            return
        }
        guard !pushAsked else { return }
        guard let deviceToken else {
            notifications.askOnce { allowed in
                DispatchQueue.main.async {
                    self.pushProblem = allowed ? nil : PushWords.notAllowed
                    if allowed { UIApplication.shared.registerForRemoteNotifications() }
                }
            }
            return
        }
        let key = PushKeys.load(mac: pairing.id)?.key ?? PushSeal.newKey()
        guard PushKeys.save(PushKeys.Saved(key: key, macName: pairing.name), mac: pairing.id) else {
            pushProblem = PushWords.keyNotKept
            return
        }
        pushProblem = nil
        pushAsked = true
        connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: pairing.id)))
    }

    /// Replies from a notification that came through Apple, sent once the
    /// Mac says its agent still asks exactly what was told.
    private var pendingPushAnswers: [(session: SessionID, digest: String, text: String)] = []
    /// A session to open once the Mac it is on is reached.
    private var pendingOpen: SessionID?

    /// A reply from a notification that came through Apple: its state was
    /// shortened to fit, so the Mac's own is waited for and compared.
    func answer(session: SessionID, onMac mac: String, digest: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, show(mac: mac) else { return }
        pendingPushAnswers.append((session, digest, text))
        if status == .connected, sessionsFresh { sendPushAnswers() } else { askForSessions() }
    }

    private func sendPushAnswers() {
        for answer in pendingPushAnswers {
            if let state = sessions.first(where: { $0.id == answer.session })?.state, PushNotice.digest(state) == answer.digest {
                connection?.send(.answer(session: answer.session, to: state, text: answer.text))
            } else {
                message = PushWords.movedOn
            }
        }
        pendingPushAnswers.removeAll()
    }

    /// Opens the session a notification is about, on its Mac.
    func open(session: SessionID, onMac mac: String) {
        guard show(mac: mac) else { return }
        if sessionsFresh {
            openNotified(session)
        } else {
            pendingOpen = session
            askForSessions()
        }
    }

    private func openNotified(_ session: SessionID) {
        pendingOpen = nil
        guard sessions.contains(where: { $0.id == session }) else {
            message = PushWords.sessionEnded
            return
        }
        tab = "sessions"
        path = [.session(session)]
    }

    /// Goes to a paired Mac; false, said, when it is no longer paired.
    private func show(mac: String) -> Bool {
        guard let host = hosts.first(where: { $0.id == mac }) else {
            message = PushWords.macForgotten
            return false
        }
        if host.id != pairing?.id || !entered { enter(host) }
        return true
    }
    /// Replies given while the connection was gone, sent once it is back.
    private var pendingAnswers: [(session: SessionID, state: AgentState, text: String)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    let notifications = AgentNotifications.shared

    // MARK: Notices from the Mac (#66, decided 2026-11-19)

    /// This iPhone's own Inbox of the Mac on screen: what it was told of,
    /// kept after it is read, for 30 days.
    @Published private(set) var inbox = InboxBook()

    private static func inboxKey(_ mac: String) -> String { "inbox-\(mac)" }

    private func loadInbox() {
        guard let mac = pairing?.id, let data = PrivateFiles.read(Self.inboxKey(mac)),
            let saved = MessageCoding.decode(InboxBook.self, from: data)
        else { return inbox = InboxBook() }
        inbox = saved
        inbox.prune()
    }

    private func saveInbox() {
        guard let mac = pairing?.id else { return }
        PrivateFiles.write(MessageCoding.encode(inbox), as: Self.inboxKey(mac))
    }

    /// What the Mac told: into the Inbox; seen at once when its session is
    /// on screen. A notification only once the host says its time has come
    /// (`alerted`).
    private func told(_ notice: Notice) {
        inbox.take([notice])
        saveInbox()
        if active, let session = notice.session, session == openSessionID { sawNotice(of: session) }
    }

    /// Time to show it as a notification, at the same moment as the Mac:
    /// unless it was read or handled, or its session is on screen.
    private func alerted(_ id: UInt64) {
        guard let mac = pairing?.id, let entry = inbox.entries.first(where: { $0.id == id }), !entry.read,
            entry.notice.handled == nil, notifyAgents, entry.notice.alerts
        else { return }
        if active, let session = entry.notice.session, session == openSessionID { return sawNotice(of: session) }
        notifications.post(entry.notice, mac: mac, macName: pairing?.name ?? "the Mac")
    }

    /// Read here: read on every device. Said to the Mac once connected,
    /// if it is not now (`noticeLog`).
    private func readHere(_ ids: [UInt64]) {
        guard !ids.isEmpty else { return }
        inbox.markRead(ids: ids)
        saveInbox()
        if let mac = pairing?.id { notifications.remove(mac: mac, notices: ids) }
        if status == .connected { connection?.send(.readNotices(ids: ids)) }
    }

    private func readInbox(session: SessionID) {
        readHere(inbox.unread(session: session))
    }

    func read(_ entry: InboxBook.Entry) {
        readHere([entry.id])
    }

    func delete(_ entry: InboxBook.Entry) {
        inbox.delete(entry.id)
        saveInbox()
    }

    func deleteReadInbox() {
        inbox.deleteRead()
        saveInbox()
    }

    func deleteAllInbox() {
        inbox.deleteAll()
        saveInbox()
    }

    /// Dismissed here, from a notification: handled on every device.
    func dismissNotice(_ id: UInt64, onMac mac: String) {
        guard mac == pairing?.id else { return }
        inbox.markRead(id)
        saveInbox()
        if status == .connected, let connection {
            connection.send(.handleNotice(id: id, how: .dismissed))
        } else {
            pendingDismissals[mac, default: []].append(id)
        }
    }

    /// Dismissals made while the connection was gone, sent once it is back,
    /// by Mac: a notice's number is its Mac's, and another Mac's of the same
    /// number is another notice (#284).
    private var pendingDismissals: [String: [UInt64]] = [:]

    // MARK: The Live Activity (#24)

    /// Whether to show it at all: a switch in the Settings tab.
    @Published var showsLiveActivity: Bool = UserDefaults.standard.object(forKey: "showsLiveActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsLiveActivity, forKey: "showsLiveActivity")
            updateLiveActivity()
        }
    }
    /// Whether iOS lets the app show Live Activities, as it last said: the
    /// switch shows off while it does not (#212).
    @Published private(set) var liveActivitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
    private var activityAllowedWatch: Task<Void, Never>?
    private var liveActivity: Activity<AgentsActivityAttributes>? = PhoneModel.shownActivity
    /// Its push token, and the one that starts one, as iOS gave them: sent
    /// to the Mac, which keeps the activity true while the app is asleep
    /// (#168). The released build only: the development one has no push.
    private var activityToken: String?
    private var activityStartToken: String?
    private var activityWatch: Task<Void, Never>?
    /// Since when nothing has worked or waited here; nil while something does.
    private var activityIdleSince: Date?
    private var activityIdleCheck: Task<Void, Never>?
    private var activityStartWatch: Task<Void, Never>?

    private static var activityPushes: Bool { AppChannel.current == .release }

    /// Shown while an agent works or waits, whether someone is at the Mac
    /// or not (#168); updated here while connected, and by the Mac through
    /// Apple while the app is asleep. Left showing "done" when every agent
    /// is done; ended at once when switched off.
    /// iOS turned Live Activities on or off for the app, in its Settings.
    private func liveActivityAllowedChanged(_ allowed: Bool) {
        guard allowed != liveActivitiesAllowed else { return }
        liveActivitiesAllowed = allowed
        updateLiveActivity()
    }

    func updateLiveActivity() {
        takeUpShownActivity()
        let enabled = showsLiveActivity && ActivityAuthorizationInfo().areActivitiesEnabled
        watchActivityStart(enabled)
        // Not connected, nothing is known here: what was shown stays, and
        // goes out of date by itself.
        guard status == .connected || !enabled else { return }
        let state = AgentsStatus.of(sessions: sessions, failures: failures)
        // Kept between turns, only updated (#180): ended once nothing has
        // worked or waited for `LiveActivityRule.keptIdle`.
        if state.isActive {
            activityIdleSince = nil
        } else if activityIdleSince == nil {
            activityIdleSince = Date()
            activityIdleCheck?.cancel()
            activityIdleCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(LiveActivityRule.keptIdle + 1))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.updateLiveActivity() }
            }
        }
        let decision = LiveActivityRule.decide(enabled: enabled, status: state, idleSince: activityIdleSince)
        // Nothing is started for a state with nothing in it.
        if decision == .show, !state.isActive, liveActivity == nil { return }
        // Without push nothing keeps it true once the app sleeps.
        let content = ActivityContent(state: state, staleDate: Self.activityPushes ? nil : Date().addingTimeInterval(10 * 60))
        if decision == .show {
            if let liveActivity {
                Task { await liveActivity.update(content) }
            } else {
                liveActivity = try? Activity.request(
                    attributes: AgentsActivityAttributes(mac: pairing?.name ?? "the Mac"), content: content, pushType: Self.activityPushes ? .token : nil)
                watchActivityToken()
            }
        } else if let activity = liveActivity {
            liveActivity = nil
            activityToken = nil
            sendActivityTokens()
            // Done is true and stays true; anything else could go stale.
            Task { await activity.end(content, dismissalPolicy: decision == .endShowingDone ? .default : .immediate) }
        }
    }

    /// The activity iOS shows, not one that ended or was dismissed.
    private static var shownActivity: Activity<AgentsActivityAttributes>? {
        Activity<AgentsActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// The Mac ends an activity and starts the next one through Apple
    /// while the app sleeps (#194): one that ended is let go, so that a new
    /// one is asked for rather than an ended one updated, and one the Mac
    /// started is taken up, its token watched and given to the Mac,
    /// rather than a second one asked for.
    private func takeUpShownActivity() {
        if let liveActivity, liveActivity.activityState == .active || liveActivity.activityState == .stale { return }
        let shown = Self.shownActivity
        guard shown?.id != liveActivity?.id else { return }
        liveActivity = shown
        activityToken = nil
        if shown != nil {
            watchActivityToken()
        } else {
            activityWatch?.cancel()
            activityWatch = nil
            sendActivityTokens()
        }
    }

    private func watchActivityToken() {
        activityWatch?.cancel()
        guard Self.activityPushes, let activity = liveActivity else { return }
        activityWatch = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    self?.activityToken = token
                    self?.sendActivityTokens()
                }
            }
        }
    }

    /// The token that lets the Mac start an activity while the app is
    /// asleep (iOS 17.2).
    private func watchActivityStart(_ enabled: Bool) {
        guard Self.activityPushes else { return }
        guard enabled else {
            activityStartWatch?.cancel()
            activityStartWatch = nil
            if activityStartToken != nil {
                activityStartToken = nil
                sendActivityTokens()
            }
            return
        }
        guard activityStartWatch == nil, #available(iOS 17.2, *) else { return }
        activityStartWatch = Task { [weak self] in
            for await data in Activity<AgentsActivityAttributes>.pushToStartTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    self?.activityStartToken = token
                    self?.sendActivityTokens()
                }
            }
        }
    }

    /// To the Mac, once it keeps this iPhone told through Apple.
    /// The Live Activity is of the Mac on screen, by its name (#282): one
    /// that is left, switched from or forgotten, ends, and is told to stop
    /// sending it states and starting it, while it can still be told.
    private func leaveLiveActivity() {
        if Self.activityPushes, status == .connected { connection?.send(.liveActivity(token: nil, startToken: nil)) }
        activityToken = nil
        guard let activity = liveActivity ?? Self.shownActivity else { return }
        liveActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func sendActivityTokens() {
        guard Self.activityPushes, status == .connected, hostPushState == .on else { return }
        connection?.send(.liveActivity(token: activityToken, startToken: activityStartToken))
    }

    /// The Live Activity was touched: the session that waits, or the list.
    func openFromLink(_ url: URL) -> Bool {
        guard url.host == "session" else { return false }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value.flatMap(UInt32.init)
        tab = "sessions"
        if let id, sessions.contains(where: { $0.id == id }) { path = [.session(id)] }
        return true
    }

    /// Opens the session a notice is about, in the Sessions tab.
    func open(_ notice: AgentNotice) {
        guard sessions.contains(where: { $0.id == notice.session }) else { return }
        tab = "sessions"
        path = [.session(notice.session)]
    }

    /// Opens what an Inbox item is about: a done agent's result, the
    /// session of one that asks. A failure is only read.
    /// An item of the Inbox touched: read, and shown whole, whatever it is,
    /// as the Mac shows the item picked (the owner's decision, 2026-11-21);
    /// its session is opened from there.
    func open(_ entry: InboxBook.Entry) {
        read(entry)
        tab = "sessions"
        path = [.notice(entry.id)]
    }

    // MARK: The Inbox (#67)

    /// An agent's name as the Mac lists it, its id when it is not listed.
    func agentName(_ id: String) -> String { agents.first { $0.id == id }?.name ?? (id == "shell" ? "Shell" : id) }

    /// The last turn of each session's agent, as the host told it (#71).
    @Published private(set) var turnResults: [SessionID: TurnResult] = [:]

    /// Takes an item out of the Inbox without opening it, on every device:
    /// a done session is seen, a failure dismissed. A question stays until
    /// it is answered.
    func dismiss(_ item: InboxItem) {
        switch item.kind {
        case .session(let info):
            guard let state = info.state, !state.isWaiting else { return }
            connection?.send(.noticeSeen(session: info.id, state: state))
        case .failure(let failure):
            dismiss(failure)
        case .notice:
            // Over already: nothing to tell the Mac.
            break
        }
    }

    /// A reply to an agent where it was told of: typed into its session by
    /// the host only while the agent still asks what it answers.
    func answer(session: SessionID, to state: AgentState, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Not on a connection iOS may have held while the app was away:
        // after the list is said again, which proves it alive (#276).
        if status == .connected, sessionsFresh, let connection {
            connection.send(.answer(session: session, to: state, text: text))
        } else {
            pendingAnswers.append((session, state, text))
            askForSessions()
        }
    }

    /// The app left the front: iOS lets it run a little longer, during
    /// which the connection lives. The Mac is told, and tells this iPhone
    /// through Apple from now on, as it does while the app sleeps (#190):
    /// a suspended app's connection may stay open, and what is sent over
    /// it is not seen until the app is in front again.
    func enteredBackground() {
        active = false
        // What it lists may be old by the time a notification is answered.
        sessionsFresh = false
        if status == .connected { connection?.send(.deviceInBackground(true)) }
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Agents") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
    private static let fontSizeKey = "terminalFontSize"
    private static let currentHostKey = "currentHost"
    static let fontSizes: ClosedRange<Double> = 9...18

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = Self.fontSizes.contains(saved) ? saved : 12
        hosts = PairingStore.load()
        let last = UserDefaults.standard.string(forKey: Self.currentHostKey)
        pairing = hosts.first { $0.id == last } ?? hosts.first
        loadInbox()
        notifications.model = self
        checkNotificationAsk()
        readNotificationPermission()
        pushTokenWatch = PushToken.shared.$token.receive(on: DispatchQueue.main).sink { [weak self] token in
            self?.deviceToken = token
            self?.updatePush()
        }
        #if DEBUG
        // For trying the notification service extension in a simulator,
        // where there is no relay (#66): "<mac>|<name>|<key in base64>".
        if let test = ProcessInfo.processInfo.environment["AGENTTERM_PUSH_TEST_KEY"]?.split(separator: "|"), test.count == 3,
            let key = Data(base64Encoded: String(test[2]))
        {
            PushKeys.save(PushKeys.Saved(key: key, macName: String(test[1])), mac: String(test[0]))
        }
        #endif
        pushFailureWatch = PushToken.shared.$failure.receive(on: DispatchQueue.main).sink { [weak self] failure in
            if let failure { self?.pushProblem = PushWords.tokenRefused(failure) }
        }
        activityAllowedWatch = Task { [weak self] in
            for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates {
                self?.liveActivityAllowedChanged(allowed)
            }
        }
        if pairing != nil { connect() }
    }

    // MARK: Derived state

    var installedAgents: [AgentInfo] { agents.filter(\.isInstalled) }

    // MARK: Arranging sessions

    /// What a folder's section lists, as the Mac's strip holds it (#127):
    /// each agent in the order chosen, pinned ones first, its own pages and
    /// shells under it; then the user's shells, then the user's pages, each
    /// under a heading of their kind.
    enum SessionItem: Identifiable {
        case session(SessionInfo)
        /// The heading of an agent's own shells or pages, under it: "Shells", "Browser".
        case part(agent: SessionID, title: String)
        /// The heading of the user's own shells or pages, with how many
        /// there are, as the Mac's tab of them says it.
        case heading(HolderKind, folder: String, count: Int)
        /// A shell an agent opened, under it.
        case shell(SessionInfo)
        /// A shell of the user's, under the Shells heading.
        case userShell(SessionInfo)
        /// A page of the Mac's browser an agent opened, under it.
        case page(BrowserTabInfo)
        /// A page of the user's, or of an agent that ended, under the
        /// Browser heading.
        case userPage(BrowserTabInfo)

        var id: String {
            switch self {
            case .session(let session): return session.layoutID
            case .part(let agent, let title): return "p:\(agent):\(title)"
            case .heading(let kind, let folder, _): return "h:\(kind.rawValue):\(folder)"
            case .shell(let shell), .userShell(let shell): return "s:" + shell.layoutID
            case .page(let tab), .userPage(let tab): return "b:" + tab.id
            }
        }
    }

    /// Whether a session is a shell an agent opened that still runs: shown
    /// under its agent, as on the Mac, not on its own.
    private func isCompanion(_ session: SessionInfo) -> Bool {
        // An agent's session only: one an agent typed in a shell opened is
        // the user's (#129), as on the Mac.
        session.openedBy.map { agent in sessions.contains { $0.id == agent && $0.agent != nil } } ?? false
    }

    /// An agent's own shells and pages, in the order of the tabs.
    func companions(of agent: SessionID) -> (shells: [SessionInfo], pages: [BrowserTabInfo]) {
        // An agent's session only: what an agent typed in a shell opened is
        // the user's (#129), listed so, as on the Mac.
        guard sessions.contains(where: { $0.id == agent && $0.agent != nil }) else { return ([], []) }
        let order = Dictionary(sessionLayout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let shells = sessions.filter { $0.openedBy == agent }.sorted { (order[$0.layoutID] ?? .max, $0.id) < (order[$1.layoutID] ?? .max, $1.id) }
        return (shells, browserTabs.filter { $0.openedBy == agent })
    }

    private func companionItems(of agent: SessionInfo) -> [SessionItem] {
        let (shells, pages) = companions(of: agent.id)
        var items: [SessionItem] = []
        if !pages.isEmpty { items += [.part(agent: agent.id, title: "Browser")] + pages.map(SessionItem.page) }
        if !shells.isEmpty { items += [.part(agent: agent.id, title: "Shells")] + shells.map(SessionItem.shell) }
        return items
    }

    /// The pages of the user's, and of agents that ended, that no folder shows.
    var loosePages: [BrowserTabInfo] {
        let paths = Set(groups.compactMap(\.path))
        let running = Set(sessions.filter { $0.agent != nil }.map(\.id))
        return browserTabs.filter { tab in !(tab.openedBy.map(running.contains) ?? false) && !paths.contains(tab.project) }
    }

    func items(for group: FolderGroup) -> [SessionItem] {
        let own = Dictionary(group.sessions.map { ($0.layoutID, $0) }, uniquingKeysWith: { $1 })
        var items: [SessionItem] = []
        // The agents, in the order of the Mac's strip, each with its own.
        var listed: Set<String> = []
        for id in sessionLayout.order {
            guard let session = own[id], session.agent != nil, !isCompanion(session) else { continue }
            listed.insert(id)
            items.append(.session(session))
            items += companionItems(of: session)
        }
        // Agents the arrangement has not heard of yet.
        for session in group.sessions where session.agent != nil && !listed.contains(session.layoutID) && !isCompanion(session) {
            items.append(.session(session))
            items += companionItems(of: session)
        }
        let folder = group.path ?? ""
        // The user's shells of the folder, under one heading.
        let shells = group.sessions.filter { $0.agent == nil && !isCompanion($0) }
        if !shells.isEmpty { items += [.heading(.shells, folder: folder, count: shells.count)] + shells.map(SessionItem.userShell) }
        // The user's pages of the folder, under one heading, as on the Mac.
        let running = Set(sessions.filter { $0.agent != nil }.map(\.id))
        let pages = browserTabs.filter { tab in !(tab.openedBy.map(running.contains) ?? false) && tab.project == group.path }
        if !pages.isEmpty { items += [.heading(.browser, folder: folder, count: pages.count)] + pages.map(SessionItem.userPage) }
        return items
    }

    /// Moves an agent's session one place up (-1) or down (+1) among those
    /// its folder shows.
    func move(_ session: SessionInfo, by offset: Int, in group: FolderGroup) {
        let shown = items(for: group).compactMap { item -> String? in
            if case .session(let info) = item { return info.layoutID } else { return nil }
        }
        guard let index = shown.firstIndex(of: session.layoutID), shown.indices.contains(index + offset) else { return }
        if offset < 0 {
            sessionLayout.move(session.layoutID, before: shown[index + offset])
        } else {
            sessionLayout.move(session.layoutID, after: shown[index + offset])
        }
    }

    func canMove(_ session: SessionInfo, by offset: Int, in group: FolderGroup) -> Bool {
        let shown = items(for: group).compactMap { item -> String? in
            if case .session(let info) = item { return info.layoutID } else { return nil }
        }
        guard let index = shown.firstIndex(of: session.layoutID) else { return false }
        return shown.indices.contains(index + offset)
    }

    /// The arrangement belongs to the Mac, which keeps it and sends it.
    private func resetSessionLayout() {
        sessionsKnown = false
        layoutKnown = false
        sessionLayout = TabLayout()
    }

    /// Brings the arrangement up to date with the sessions that run. Only
    /// the agents' sessions, the ones with a tab of their own: the Mac's
    /// window has tabs of its own in there, for shells, pages and files.
    private func syncSessionLayout() {
        guard sessionsKnown, layoutKnown else { return }
        var layout = sessionLayout
        layout.sync(with: SessionInfo.withTabs(sessions).map(\.layoutID), owns: SessionInfo.isLayoutID)
        sessionLayout = layout
    }

    var groups: [FolderGroup] {
        var result = folders.map { folder in
            // A session in a worktree of the folder is the folder's (#23).
            FolderGroup(path: folder, sessions: sessions.filter { WorktreePath.belongs($0.cwd, to: folder) })
        }
        // Sessions started outside the listed folders still need a home.
        let known = Set(folders)
        let loose = Dictionary(grouping: sessions.filter { !known.contains($0.cwd) && !known.contains(WorktreePath.project(of: $0.cwd) ?? "") }, by: \.cwd)
        result += loose.keys.sorted().map { FolderGroup(path: $0, sessions: loose[$0] ?? []) }
        if result.isEmpty { result = [FolderGroup(path: nil, sessions: [])] }
        return result
    }

    func session(_ id: SessionID) -> SessionInfo? { sessions.first { $0.id == id } }

    // MARK: What was written for a session and not sent yet

    /// Kept on the phone, per Mac and session, so that leaving the terminal
    /// or closing the app does not lose a message half written. Not
    /// published: the field that shows it holds the text while it is typed.
    private var composeDrafts: [String: String] =
        PrivateFiles.read(PhoneModel.composeDraftsKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    private static let composeDraftsKey = "composeDrafts"

    /// In a file of the app's own, not its preferences (#287).
    private func saveComposeDrafts() {
        if let data = try? JSONEncoder().encode(composeDrafts) { PrivateFiles.write(data, as: Self.composeDraftsKey) }
    }

    /// Session numbers start over when the Mac's host is restarted, so the
    /// time the session began is part of what names it.
    private func composeDraftKey(for id: SessionID) -> String? {
        guard let pairing, let session = session(id) else { return nil }
        return "\(pairing.id)/\(id)/\(Int(session.createdAt.timeIntervalSince1970))"
    }

    func composeDraft(for id: SessionID) -> String {
        composeDraftKey(for: id).flatMap { composeDrafts[$0] } ?? ""
    }

    func setComposeDraft(_ text: String, for id: SessionID) {
        guard let key = composeDraftKey(for: id), composeDrafts[key] != (text.isEmpty ? nil : text) else { return }
        composeDrafts[key] = text.isEmpty ? nil : text
        saveComposeDrafts()
    }

    /// Drops what was written for sessions of this Mac that have ended.
    private func pruneComposeDrafts(of host: String, keeping sessions: [SessionInfo]) {
        let kept = Set(sessions.map { "\(host)/\($0.id)/\(Int($0.createdAt.timeIntervalSince1970))" })
        let before = composeDrafts.count
        // Also what belonged to a Mac that is no longer paired under that name.
        let paired = Set(hosts.map(\.id))
        composeDrafts = composeDrafts.filter { draft in
            guard let owner = draft.key.split(separator: "/").first.map(String.init), paired.contains(owner) else { return false }
            return owner != host || kept.contains(draft.key)
        }
        if composeDrafts.count != before { saveComposeDrafts() }
    }

    /// What is written in answer to what an agent asks (#232), apart from
    /// the prompt: for that session and that question only, gone when the
    /// agent asks something else or nothing. In memory, as the question
    /// lasts only while the agent waits.
    private var answerDrafts: [String: (state: AgentState, text: String)] = [:]

    func answerDraft(for id: SessionID, to state: AgentState) -> String {
        composeDraftKey(for: id).flatMap { answerDrafts[$0] }.flatMap { $0.state == state ? $0.text : nil } ?? ""
    }

    func setAnswerDraft(_ text: String, for id: SessionID, to state: AgentState) {
        guard let key = composeDraftKey(for: id) else { return }
        if text.isEmpty { answerDrafts[key] = nil } else { answerDrafts[key] = (state: state, text: text) }
    }

    /// The session whose terminal is on screen, if one is on top.
    var openSessionID: SessionID? {
        if case .session(let id)? = path.last { return id }
        return nil
    }

    static func patchKey(folder: String, file: String, staged: Bool) -> String { folder + "\n" + (staged ? "staged:" : "") + file }

    /// Agents a conversation of `agent` can be handed to.
    /// The agents a conversation can be handed to. In its own folder that is
    /// every other agent; in another folder the same agent can take it too.
    func handoffTargets(from agent: String, sameFolder: Bool = true) -> [AgentInfo] {
        sameFolder ? installedAgents.filter { $0.id != agent } : installedAgents
    }

    func agentID(for session: SessionInfo) -> String {
        session.agent ?? session.typedAgent ?? "shell"
    }

    // MARK: Pairing

    /// A pairing link opened from elsewhere, waiting for the user to say
    /// yes (#279): a page or another app can open one, and pairing sends
    /// this device's name to the host it names.
    @Published var pairingAsked: PairingInfo?

    /// A link from outside the app: asked first.
    func askToPair(with url: URL) {
        guard let info = PairingInfo(url: url) else { return pair(with: url) }
        pairingAsked = info
    }

    /// The link that was asked about, said yes to.
    func pairAsked() {
        guard let info = pairingAsked else { return }
        pairingAsked = nil
        pair(with: info)
    }

    func pair(with url: URL) {
        guard let info = PairingInfo(url: url) else {
            message = "That is not an AgentTerm pairing code. Show a new one on the Mac and try again."
            return
        }
        pair(with: info)
    }

    private func pair(with info: PairingInfo) {
        // Another Mac comes on screen once paired (#282).
        leaveLiveActivity()
        disconnect()
        message = nil
        pendingPairing = info
        isPairing = true
        // The code is only good for getting a token of our own, once.
        open(host: info.host, port: info.port, credential: .pairingCode(info.code))
    }

    func pair(withText text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "That is not an AgentTerm pairing code."
            return
        }
        pair(with: url)
    }

    /// Shows another paired Mac. The connection moves with it.
    func select(_ host: SavedHost) {
        guard host.id != pairing?.id else { return }
        leaveLiveActivity()
        disconnect()
        clearHostState()
        setCurrent(host)
        connect()
    }

    /// True once a Mac was picked from the list of Macs: the tabs then show
    /// that Mac. The app opens on the list, so which Mac is on screen is
    /// always something the user chose.
    @Published private(set) var entered = false

    /// Picks a Mac from the list and goes into its tabs.
    func enter(_ host: SavedHost) {
        select(host)
        if connection == nil { connect() }
        path = []
        tab = "sessions"
        entered = true
    }

    /// Back to the list of Macs. The Mac that was on screen stays connected
    /// until another is picked, so coming back to it is instant.
    func showMacs() {
        entered = false
    }

    /// Forgets the Mac on screen and goes back to the list of Macs.
    func forgetMac() {
        if let pairing { forget(pairing) }
    }

    /// Forgets a paired Mac: its token is thrown away, and pairing again is
    /// the only way back to it.
    func forget(_ host: SavedHost) {
        let wasCurrent = host.id == pairing?.id
        // Its pushes would no longer open: the Mac is asked to stop them.
        if wasCurrent, hostPushState == .on { connection?.send(.pushUnregister) }
        PushKeys.delete(mac: host.id)
        PrivateFiles.remove(Self.inboxKey(host.id))
        hosts.removeAll { $0.id == host.id }
        PairingStore.save(hosts)
        pruneComposeDrafts(of: host.id, keeping: [])
        guard wasCurrent else { return }
        leaveLiveActivity()
        disconnect()
        clearHostState()
        pendingPairing = nil
        isPairing = false
        entered = false
        setCurrent(hosts.first)
        if pairing != nil { connect() }
    }

    private func setCurrent(_ host: SavedHost?) {
        pairing = host
        loadInbox()
        resetSessionLayout()
        UserDefaults.standard.set(host?.id, forKey: Self.currentHostKey)
    }

    /// What was shown belongs to the Mac that is being left.
    private func clearHostState() {
        // What was kept to send to the Mac left, or of it, is not the next
        // one's (#284): answers and opens wait for that Mac's sessions;
        // its pages, stashes, commits and branches are its own.
        pendingAnswers = []
        pendingPushAnswers = []
        pendingOpen = nil
        diffAnswersDue = [:]
        browserTabs = []
        browserFrames = [:]
        watchedPages = [:]
        stashes = [:]
        commits = [:]
        commitsMore = [:]
        loadingCommits = []
        branches = [:]
        keepAwake = nil
        startAtLogin = nil
        took([])
        keepAwakeOptions = KeepAwakeOptions()
        commitWriter = CommitWriterSettings()
        schedules = []
        worktrees = [:]
        worktreesInProgress = []
        writingCommitMessage = []
        remoteWork.forgetAll()
        sshHosts = []
        system.stats = nil
        hostVersion = 0
        hostMatch = .same
        failures = []
        turnResults = [:]
        sessions = []
        folders = []
        agents = []
        agentsLoaded = false
        diffs = [:]
        patches = [:]
        commitDrafts = [:]
        committing = nil
        accountUsage = [:]
        fileListings = [:]
        remoteFiles = [:]
        savingFile = nil
        createdFile = nil
        histories = [:]
        listing = nil
        handoffPlan = nil
    }

    // MARK: Connection

    /// The list of sessions, said again by the Mac: asked of a connection
    /// that is up, or said on connecting (#276).
    private func askForSessions() {
        if status == .connected, let connection {
            connection.send(.list)
            connection.check()
        } else {
            reachMac()
        }
    }

    /// Connects to the Mac on screen, or makes sure its connection is alive,
    /// without saying the app is in front: an answer from a notification
    /// is given from the background, and the Mac goes on telling this
    /// iPhone through Apple (#278).
    func reachMac() {
        if pairing != nil, connection == nil {
            connect()
        } else {
            connection?.check()
        }
    }

    /// Called when the app comes to the front.
    func resume() {
        active = true
        // Changed in the iPhone's Settings while the app was away.
        liveActivityAllowedChanged(ActivityAuthorizationInfo().areActivitiesEnabled)
        readNotificationPermission()
        if status == .connected { connection?.send(.deviceInBackground(false)) }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        if pairing != nil, connection == nil {
            connect()
        } else {
            // The connection the app left behind may have died while it
            // was away. Ask, so a dead one is replaced within seconds.
            connection?.check()
        }
    }

    func retry() {
        if connection == nil { connect() }
    }

    private func connect() {
        guard let pairing else { return }
        open(host: pairing.host, port: pairing.port, credential: .token(pairing.token))
    }

    private func open(host: String, port: UInt16, credential: AgentTermConnection.Credential) {
        status = .connecting
        let connection = AgentTermConnection(
            host: host, port: port, credential: credential, clientName: UIDevice.current.name,
            kind: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone)
        self.connection = connection
        connection.onState = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                self.connectionChanged(state)
            }
        }
        connection.onMessage = { [weak self, weak connection] message in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                self.handle(message)
            }
        }
        connection.onOutput = { [weak self] session, data in
            MainActor.assumeIsolated {
                guard let controller = self?.controller, controller.session == session else { return }
                controller.feed(data)
            }
        }
        connection.connect()
    }

    private func disconnect() {
        connection?.close()
        connection = nil
        // Its `.closed` is not heard once it is not the connection: what
        // waited is answered here, for a switch, a pairing, a Mac forgotten.
        refuseBrowserAsks()
        controller = nil
        foreignSize = nil
        path = []
        showBrowser = false
        status = .offline(nil)
    }

    private func connectionChanged(_ state: AgentTermConnection.State) {
        switch state {
        case .connecting:
            break
        case .connected:
            // Wait for `welcome`: a wrong token is only known after that.
            break
        case .closed(let reason):
            connection = nil
            sessionsFresh = false
            // What waited for that connection's answer waits no more: the
            // commit, the save, the forced push's question, a page of
            // commits, a session to open (#281). The commit's message and
            // the file's text stay where they were.
            let waited = committing != nil || savingFile != nil || askingForcePush != nil || !lastCommitWanted.isEmpty
            committing = nil
            savingFile = nil
            askingForcePush = nil
            loadingCommits = []
            diffAnswersDue = [:]
            openCreatedSession = false
            lastCommitWanted = [:]
            if waited, !isPairing { message = NotConnectedWords.notAnswered(pairing?.name ?? "The Mac") }
            refuseBrowserAsks()
            replaying = nil
            status = .offline(reason)
            if isPairing {
                // Pairing did not work out: the Mac refused the code, or
                // could not be reached at all.
                isPairing = false
                pendingPairing = nil
                if message == nil {
                    message = "Could not reach the Mac. Check that Tailscale is connected on this \(ThisDevice.name) and on the Mac, then try again."
                }
                // Back to the Mac that was on screen before, if there was one.
                if pairing != nil { connect() }
            } else {
                scheduleRetry()
            }
        }
    }

    /// Keeps trying while the app is in front, so walking back into coverage
    /// reconnects without a tap.
    private func scheduleRetry() {
        guard !retryScheduled, pairing != nil else { return }
        retryScheduled = true
        // At once the first time, since most drops are over as soon as they
        // are noticed; then every few seconds while the Mac stays out of reach.
        let delay: TimeInterval = failedAttempts == 0 ? 0.5 : 3
        failedAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.connection == nil, self.pairing != nil, UIApplication.shared.applicationState == .active {
                self.connect()
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        #if DEBUG
        TouchLog.received(message)
        #endif
        // While pairing, the host asked is not the Mac on screen: only its
        // answer to the code is taken, nothing it says of sessions, folders
        // or the Mac on screen's notices (#279).
        if isPairing {
            switch message {
            case .paired, .error: break
            default: return
            }
        }
        switch message {
        case .welcome(let version, _, _, _):
            hostMatch = ProtocolMatch(host: version)
            if hostMatch != .same { Telemetry.shared.record(.versionMismatch(hostIsOlder: hostMatch == .hostOlder)) }
            status = .connected
            // In front or in the background, from the start (#190).
            connection?.send(.deviceInBackground(!active))
            if let mac = pairing?.id {
                for id in pendingDismissals[mac] ?? [] { connection?.send(.handleNotice(id: id, how: .dismissed)) }
                pendingDismissals[mac] = nil
            }
            pushAsked = false
            hostPushState = nil
            for answer in pendingAnswers { connection?.send(.answer(session: answer.session, to: answer.state, text: answer.text)) }
            pendingAnswers.removeAll()
            failedAttempts = 0
            reattachAfterConnect = true
            // Whatever was under way when the connection dropped got no answer.
            writingCommitMessage = []
            remoteWork.forgetAll()
            connection?.send(.agents(refresh: false))
            // A page left open while the connection was away is watched
            // again, as if opened now (#209).
            for (tab, width) in watchedPages.sorted(by: { $0.key < $1.key }) { watch(tab, true, width: width) }
            // A Mac from before 0.4.0 does not know the request, and would
            // answer with an error for the user to wonder about.
            hostVersion = version
            if version >= 6 { connection?.send(.sshHosts) }
        case .sessions(let list):
            sessions = list
            sessionsKnown = true
            sessionsFresh = true
            turnResults = turnResults.filter { id, _ in list.contains { $0.id == id } }
            updateLiveActivity()
            if !pendingPushAnswers.isEmpty { sendPushAnswers() }
            for answer in pendingAnswers { connection?.send(.answer(session: answer.session, to: answer.state, text: answer.text)) }
            pendingAnswers.removeAll()
            if let pendingOpen { openNotified(pendingOpen) }
            if let pairing { pruneComposeDrafts(of: pairing.id, keeping: list) }
            syncSessionLayout()
            if let open = openSessionID, !list.contains(where: { $0.id == open }) {
                // The session ended: back to the screen it was opened from.
                path.removeLast()
                controller = nil
                foreignSize = nil
            } else if let open = openSessionID, active {
                // Done or asking while its terminal is on screen: seen (#67).
                sawNotice(of: open)
            }
            if reattachAfterConnect {
                reattachAfterConnect = false
                // The connection was lost while a terminal was on screen.
                if let open = openSessionID {
                    if let controller, controller.session == open, let have = controller.position, hostVersion >= 6 {
                        // The terminal is still here with all it was sent:
                        // only what the session wrote since is asked for.
                        connection?.send(.attach(session: open, size: session(open)?.size ?? .default, have: have, history: controller.historyAsked))
                    } else {
                        controller = nil
                        self.open(open)
                    }
                }
            }
        case .agents(let list):
            agents = list
            agentsLoaded = true
        case .startAtLogin(let on):
            startAtLogin = on
        case .agentShellsFaults(let faults):
            took(faults)
        case .turnResult(let session, let result):
            turnResults[session] = result
        case .noticeSeen:
            // Seen on the Mac, or on another device: its notice is handled,
            // which the Mac says on its own (`noticeHandled`).
            break
        case .browserFrame(let tab, let jpeg, let width, let height):
            if let image = UIImage(data: jpeg) { browserFrames[tab] = BrowserFrame(image: image, width: width, height: height) }
        case .agentPrompts(let custom, let defaults):
            // Edited here too (#155), as in the Mac's Settings > Agents.
            agentPrompts = AgentPrompts(custom: custom, defaults: defaults)
        case .shellSettings(let settings, let loginShell, let shells):
            shellSettings = MacShellSettings(settings: settings, loginShell: loginShell, shells: shells)
        case .agentShellResult, .agentBrowserResult, .browserCall:
            // For `agenttermd mcp`, and for the Mac app that shows the browser.
            break
        case .browserTabs(let tabs):
            // The browser's tabs, on the Mac (#76).
            browserTabs = tabs
        case .browserAnswer(let id, let result):
            browserAnswered(id: id, result: result)
        case .macInUse(let inUse):
            macInUse = inUse
            updateLiveActivity()
        case .pushState(let state):
            hostPushState = state
            // Registered: the Live Activity's tokens with it (#168).
            if state == .on {
                if liveActivity != nil, activityWatch == nil { watchActivityToken() }
                sendActivityTokens()
            }
            // Off on a new connection, or forgotten by the Mac: asked again.
            if state == .off { pushAsked = false }
            updatePush()
        case .noticeLog(let list):
            inbox.take(list, log: true)
            saveInbox()
            // What was handled while this iPhone was away goes from
            // Notification Center too.
            if let mac = pairing?.id {
                notifications.remove(mac: mac, notices: list.filter { $0.handled != nil || $0.read == true }.map(\.id))
            }
            // Read here while the Mac was not reached.
            let unsaid = inbox.readHere(notTold: list)
            if !unsaid.isEmpty { connection?.send(.readNotices(ids: unsaid)) }
        case .notice(let notice):
            told(notice)
        case .noticeAlert(let id):
            alerted(id)
        case .noticesRead(let ids):
            inbox.markRead(ids: ids)
            saveInbox()
            if let mac = pairing?.id { notifications.remove(mac: mac, notices: ids) }
        case .noticeHandled(let id, let handled):
            inbox.handled(id, handled)
            saveInbox()
            if let mac = pairing?.id { notifications.remove(mac: mac, notices: [id]) }
        case .schedules(let list):
            schedules = list
        case .schedulesPaused(let paused):
            schedulesPaused = paused
        case .scheduleRunOutput(let id, let at, let text):
            runOutputs[ScheduleOverview.Run.id(schedule: id, at: at)] = .some(text)
        case .worktrees(let folder, let list):
            worktrees[folder] = list
        case .worktreesInProgress(let list):
            worktreesInProgress = list
        case .conversationRead(let id, let details):
            conversationDetails[id] = .some(details)
            // The last few are kept: each may be large.
            if conversationDetails.count > 6, let other = conversationDetails.keys.first(where: { $0 != id }) { conversationDetails[other] = nil }
        case .historyFound(let search, let hits):
            guard search == historySearch, let key = historySearchKey else { break }
            historyHits[key, default: []] += hits
        case .historySearchEnded(let search):
            guard search == historySearch, let key = historySearchKey else { break }
            historySearching.remove(key)
        case .historyOlder(let folder, let conversations, let more):
            let key = folder ?? ""
            let known = Set((olderHistory[key] ?? []).map(\.id))
            olderHistory[key, default: []] += conversations.filter { !known.contains($0.id) }
            if !more { historyEnded.insert(key) }
        case .conversationDeleted(let id):
            deletedConversations.insert(id)
            conversationDetails[id] = nil
            for key in histories.keys { histories[key]?.removeAll { $0.id == id } }
            for key in olderHistory.keys { olderHistory[key]?.removeAll { $0.id == id } }
            for key in historyHits.keys { historyHits[key]?.removeAll { $0.id == id } }
        case .conversationsDeleted(let deleted, let kept):
            // The rows going say the rest; one that was kept is told.
            if kept > 0 { self.message = DeleteConversationsQuestion.done(deleted: deleted, kept: kept) }
        case .conversationExported(_, let path):
            exportedTranscript = path
        case .filesFound(let search, let files, let among):
            guard search == searchNumber else { break }
            foundFiles = files
            filesAmong = among
        case .textFound(let search, let matches):
            guard search == searchNumber else { break }
            foundLines += matches
        case .searchEnded(let search, let truncated, let problem):
            guard search == searchNumber else { break }
            isSearching = false
            searchTruncated = truncated
            searchProblem = problem
        case .worktreeFinished(_, _, let said):
            worktreeSaid = said
        case .keepAwake(let on):
            keepAwake = on
        case .keepAwakeOptions(let options):
            keepAwakeOptions = options
        case .commitWriter(let settings):
            commitWriter = settings
        case .displaySettings(let settings):
            hostSent(display: settings)
        case .commitMessage(let folder, let text):
            writingCommitMessage.remove(folder)
            // A draft: it goes in the field, to be read before committing.
            if let text { commitDrafts[folder] = text }
        case .agentSetup(let report):
            // Set up from here too (#155), as in the Mac's Settings > Hooks & MCP.
            agentSetup = report
        case .sshHosts(let list):
            sshHosts = list
        case .systemStats(let stats):
            system.stats = stats
        case .tabLayout(let layout):
            layoutKnown = true
            applyingHostLayout = true
            sessionLayout = layout
            applyingHostLayout = false
            syncSessionLayout()
        case .folders(let list):
            folders = list
        case .attached(let info, _):
            if !sessions.contains(where: { $0.id == info.id }) { sessions.append(info) }
            if openCreatedSession {
                openCreatedSession = false
                controller = makeController(for: info.id)
                // Started here: the host sends all of it, as for any create.
                controller?.historyAsked = nil
                foreignSize = nil
                showBrowser = false
                // On top of wherever it was started from, so Back returns there.
                path.removeAll { if case .session = $0 { return true } else { return false } }
                path.append(.session(info.id))
                // The terminal is in the Sessions tab, wherever it was started from.
                tab = "sessions"
            }
            // What follows is the session's earlier output, until `replayed`.
            if controller?.session == info.id {
                controller?.beginReplay(size: info.size)
                // Earlier lines asked for show in a strip; the screen stays.
                if controller?.loadingHistory != true { replaying = info.id }
            }
        case .replaying(let id, let from, let above):
            if let above, controller?.session == id { controller?.historyKept = above }
            guard let current = controller, current.session == id, current.position != from else { return }
            if current.position != nil, !current.loadingHistory {
                // The Mac could not go on from where this terminal stopped
                // and sends all it keeps: that is for a terminal that starts empty.
                controller = makeController(for: id)
                controller?.beginReplay(size: session(id)?.size)
            }
            controller?.position = from
        case .replayed(let id):
            if replaying == id { replaying = nil }
            if controller?.session == id {
                // Earlier lines brought in are not the phone coming back: the
                // session is in use here already, and taking it again would
                // draw it for the screen's size, leaving the lines just read.
                let paging = controller?.loadingHistory == true
                controller?.endReplay()
                // Open here is in use here: the session takes this screen's
                // size, also when the phone comes back after it was away
                // and the Mac had it at its own, without a button.
                if !paging { controller?.claimSize() }
            }
        case .resized(let id, let size, let driver, let by):
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].size = size }
            guard let controller, controller.session == id else { return }
            controller.hostResized(to: size, driver: driver)
            foreignSize = controller.foreignSize
            sizeDriver = driver ? nil : by
        case .exited:
            break
        case .paired(_, let token):
            Telemetry.shared.record(.devicePaired)
            guard let info = pendingPairing else { return }
            let saved = SavedHost(id: UUID().uuidString, host: info.host, port: info.port, name: info.name, token: token)
            // Pairing again with a Mac replaces what was saved for it.
            hosts.removeAll { $0.host == saved.host && $0.port == saved.port }
            hosts.append(saved)
            PairingStore.save(hosts)
            clearHostState()
            setCurrent(saved)
            pendingPairing = nil
            isPairing = false
            showPairSheet = false
            // Paired: iOS is asked now whether the app may notify, rather
            // than when the first agent is told of, which is shown with the
            // app open too (#66).
            if notifyAgents { notifications.askOnce() }
            // A Mac that was just paired is the one to look at.
            path = []
            tab = "sessions"
            entered = true
        case .error(let text, _):
            if text == "invalid token", !isPairing {
                // Of the Mac on screen, never of one being paired (#279):
                // that one was not asked with a token of this iPhone's.
                let name = pairing?.name ?? "The Mac"
                forgetMac()
                self.message = "\(name) removed this \(ThisDevice.name) from its paired devices. Pair it again to reconnect."
            } else if text == "invalid pairing code" {
                self.message = "That pairing code has expired or was already used. Show a new one on the Mac and try again."
            } else if text == "malformed message" {
                // A Mac from before 0.4.0 does not know what was asked and
                // will never answer it.
                openCreatedSession = false
                writingCommitMessage = []
                remoteWork.forgetAll()
                self.message = HostErrorWords.olderHost
            } else {
                // A request that was going to open a session failed.
                openCreatedSession = false
                // So did a commit, if one was waiting. Its message is kept.
                committing = nil
                // And a save: the edits stay in the editor.
                savingFile = nil
                self.message = HostErrorWords.words(for: text)
            }
        case .gitBranches(let folder, let list):
            branches[folder] = list
        case .gitLastCommit(let folder, let last):
            guard let wanted = lastCommitWanted.removeValue(forKey: folder) else { break }
            if let last { wanted(last) } else { self.message = LastCommit.noneYet }
        case .gitStashes(let folder, let list):
            stashes[folder] = list
        case .gitStashShow(_, let hash, let files):
            stashFiles[hash] = files ?? []
        case .gitLog(let folder, let branch, let skip, let list, let more):
            // Of the branch listed now, not of one listed before.
            guard branch == commitsBranch[folder] else { break }
            loadingCommits.remove(folder)
            switch CommitPages.add(list, skip: skip, to: commits[folder] ?? []) {
            case .listed(let all):
                commits[folder] = all
                commitsMore[folder] = more
            case .stale:
                // The same commit twice would be two rows of one id (#300).
                loadCommits(folder)
            case .other:
                break
            }
        case .gitShow(let folder, let hash, let details):
            commitDetails[hash] = details ?? commits[folder]?.first { $0.hash == hash }.map { CommitDetails(commit: $0) }
        case .diff(let folder, let snapshot):
            // The answer to something done inside a submodule: the folders
            // around it are asked what they say of it now (#44).
            let around = diffs.filter { outer in
                folder.hasPrefix(outer.key + "/")
                    && outer.value.submodules.contains { folder == $0.directory(in: outer.key) || folder.hasPrefix($0.directory(in: outer.key) + "/") }
            }
            if let outermost = around.keys.min(by: { $0.count < $1.count }) { loadDiff(outermost) }
            take(snapshot, of: folder)
            let due = max((diffAnswersDue[folder] ?? 0) - 1, 0)
            diffAnswersDue[folder] = due == 0 ? nil : due
            if committing == folder, due == 0 {
                // The answer to a commit that git accepted, once every answer
                // that was due is in (#285): one asked for before it may come
                // back while git is still at it.
                committing = nil
                commitDrafts[folder] = nil
                amending[folder] = nil
            }
        case .gitFetched(let folder, let problem, let automatic):
            // What was asked for while the app fetched by itself is sent
            // now (#116).
            if automatic {
                if let kept = remoteWork.quietFetchEnded(in: folder) { connection?.send(kept) }
            } else {
                remoteWork.ended(in: folder)
            }
            if let problem {
                if automatic { fetchProblems[folder] = problem } else { self.message = problem }
            } else {
                fetchProblems[folder] = nil
            }
        case .gitForcePushPreview(let folder, let upstream, let loses, let at):
            guard askingForcePush == folder else { break }
            askingForcePush = nil
            if let upstream, let at, let branch = diffs[folder]?.branch {
                pendingForcePush = ForcePush(folder: folder, question: ForcePushQuestion(branch: branch, upstream: upstream, loses: loses), lease: at)
            } else {
                self.message = ForcePushQuestion.couldNotAsk
            }
        case .gitSynced(let folder):
            // Not at the `diff` before it: one asked for while git was still
            // at work would free the buttons for a second push beside the first.
            let was = remoteWork.ended(in: folder)
            // A revert or a pick made a commit: the list is another now.
            if was == "revert" || was == "cherry-pick", commits[folder] != nil { loadCommits(folder) }
        case .diffFile(let folder, let file):
            // The host answers per folder; the file asked for is the one waiting.
            if let file {
                patches[Self.patchKey(folder: folder, file: file.path, staged: file.isStaged)] = file
            } else if let waiting = pendingPatch, waiting.folder == folder {
                patches[Self.patchKey(folder: folder, file: waiting.file, staged: waiting.staged)] = .some(nil)
            }
            pendingPatch = nil
        case .history(let folder, let conversations):
            histories[folder ?? ""] = conversations
            if let session = pendingSessionHandoff, folder == session.cwd {
                pendingSessionHandoff = nil
                // The session's conversation is the newest one its agent has
                // in that folder since the session started.
                let agent = agentID(for: session)
                let own = conversations.filter { $0.agent == agent }
                let current = self.session(session.id) ?? session
                // The Mac already worked out which conversation the session
                // is having; without that, the newest one since it started.
                if let found = own.first(where: { $0.sessionID == current.conversationID })
                    ?? own.first(where: { $0.updatedAt >= session.createdAt.addingTimeInterval(-5) })
                {
                    sessionHandoff = found
                } else {
                    self.message = HandoffWords.noConversation(session.title)
                }
            }
        case .directory(let listing):
            self.listing = listing
        case .handoffPlan(let id, let prompt):
            handoffPlan = HandoffPlan(id: id, prompt: prompt)
        case .accountUsage(let list):
            accountUsage = Dictionary(list.map { ($0.agent, $0) }, uniquingKeysWith: { $1 })
        case .files(let directory, let entries):
            fileListings[directory] = entries
        case .file(let path, let content, let data):
            remoteFiles[path] = RemoteFile(content: content, data: data)
        case .fileSaved(let path):
            if savingFile == path, let text = savingText { remoteFiles[path] = RemoteFile(content: .text(text), data: nil) }
            savingFile = nil
            savingText = nil
        case .fileCreated(let path, let isDirectory):
            if !isDirectory { createdFile = path }
        case .failures(let list):
            failures = list
            // What stopped is counted in the Live Activity (#168).
            updateLiveActivity()
        case .pairingCode, .devices:
            break
        }
    }

    private func makeController(for id: SessionID) -> TerminalController {
        let controller = TerminalController(session: id, fontSize: fontSize)
        controller.onInput = { [weak self] data in self?.connection?.sendInput(data, to: id) }
        controller.onResize = { [weak self] size in self?.connection?.send(.resize(session: id, size: size)) }
        controller.onClaim = { [weak self] size in self?.connection?.send(.takeControl(session: id, size: size)) }
        // A few hundred lines above the screen to start with; more as it is
        // scrolled up (HIST-6).
        controller.historyAsked = Self.historyToStartWith
        controller.onNeedsHistory = { [weak self] lines in
            guard let self else { return }
            self.connection?.send(.attach(session: id, size: self.session(id)?.size ?? .default, history: lines))
        }
        controller.onLoadingHistory = { [weak self, weak controller] loading in
            self?.loadingHistory = loading ? id : nil
            if !loading { self?.historyLoaded = controller?.historyAsked }
        }
        return controller
    }

    /// How many lines above the screen a session is opened with.
    static let historyToStartWith = 500
    /// The session whose earlier lines are on their way.
    @Published private(set) var loadingHistory: SessionID?
    /// How many lines above the screen the open terminal has asked for, as
    /// the tests read it.
    @Published private(set) var historyLoaded: Int?

    // MARK: Actions

    /// The grid a new session should start with. The terminal screen is not
    /// on screen yet, so its room is worked out from the screen: all of the
    /// width, and the height left by the bars above and below. The width is
    /// what matters, since a wrong one makes the shell draw its first prompt
    /// for a width the terminal does not have.
    private var startingSize: TermSize {
        let screen = UIScreen.main.bounds.size
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let safe = window?.safeAreaInsets ?? .zero
        let bounds = window?.bounds.size ?? screen
        let sides = 2 * TerminalInsets.horizontal(onItsSide: bounds.width > bounds.height)
        let width = bounds.width - safe.left - safe.right - sides
        // Navigation bar, key bar and compose field take about this much.
        let height = bounds.height - safe.top - safe.bottom - 44 - 52 - 56 - 2 * TerminalInsets.vertical
        return TerminalMetrics.grid(for: CGSize(width: width, height: height), fontSize: fontSize) ?? TermSize(cols: 48, rows: 30)
    }

    /// Starts an agent, or a shell when `agent` is nil, and opens it.
    func launch(_ agent: AgentInfo?, in folder: String?) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: agent?.id)))
        connection?.send(.create(CreateRequest(command: agent?.id, cwd: folder, title: agent?.name, size: startingSize)))
    }

    /// Starts an agent, or a shell, in a new worktree of a folder (#34), on
    /// a branch of its own cut from `from`, and opens it.
    func launchInWorktree(_ agent: AgentInfo?, in folder: String, branch: String?, from: String?) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: agent?.id)))
        connection?.send(.createInWorktree(request: CreateRequest(command: agent?.id, cwd: folder, title: agent?.name, size: startingSize), branch: branch, from: from))
    }

    /// The folder a worktree belongs to: the one AgentTerm made it for, or
    /// the one whose list of worktrees names it. Nil for a folder that is
    /// no worktree of another.
    func project(ofWorktree path: String) -> String? {
        if let project = WorktreePath.project(of: path) { return project }
        return worktrees.first { $0.value.contains { !$0.isMain && $0.path == path } }?.key
    }

    /// Attaches to a session so its terminal can be shown.
    func open(_ id: SessionID) {
        guard controller?.session != id else { return }
        controller = makeController(for: id)
        foreignSize = nil
        // Attach with the size the session already has; ours follows after layout.
        connection?.send(.attach(session: id, size: session(id)?.size ?? .default, history: controller?.historyAsked ?? Self.historyToStartWith))
    }

    /// Stops watching a session. The Mac gets its own size back.
    func leave(_ id: SessionID) {
        guard controller?.session == id else { return }
        connection?.send(.detach(session: id))
        controller = nil
        foreignSize = nil
    }

    // MARK: Changes, history, folders

    private var pendingPatch: (folder: String, file: String, staged: Bool)?
    /// A running session whose conversation is being looked up to hand off.
    private var pendingSessionHandoff: SessionInfo?

    func loadDiff(_ folder: String) {
        sendForDiff(.diff(path: folder), in: folder, quietly: true)
    }

    /// Keeps a folder's changes, and those of the submodules changed inside
    /// it under their own folders (#44): each is then a folder as any other
    /// to what stages, commits and discards in it.
    private func take(_ snapshot: DiffSnapshot, of folder: String) {
        // One that has no changes inside it any more is not kept as it was.
        for old in diffs[folder]?.submodules ?? [] where !snapshot.submodules.contains(where: { $0.path == old.path }) {
            diffs[old.directory(in: folder)] = nil
        }
        diffs[folder] = snapshot
        for submodule in snapshot.submodules { take(submodule.changes, of: submodule.directory(in: folder)) }
    }

    func loadPatch(folder: String, file: String, staged: Bool) {
        pendingPatch = (folder, file, staged)
        connection?.send(.diffFile(path: folder, file: file, staged: staged))
    }

    // MARK: Searching a folder's files (#45)

    /// Files whose name matches what was typed, best first, and how many
    /// files the folder has.
    @Published private(set) var foundFiles: [String] = []
    @Published private(set) var filesAmong = 0
    /// Lines that hold the text that was searched for.
    @Published private(set) var foundLines: [TextMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchTruncated = false
    @Published private(set) var searchProblem: String?
    /// Numbers the searches: an answer to an earlier one is not shown.
    private var searchNumber = 0

    func findFiles(_ query: String, in folder: String) {
        searchNumber += 1
        connection?.send(.findFiles(search: searchNumber, path: folder, query: query))
    }

    func findText(_ query: String, caseSensitive: Bool, in folder: String) {
        stopSearch()
        searchNumber += 1
        foundLines = []
        searchTruncated = false
        searchProblem = nil
        guard !query.isEmpty, status == .connected else { return }
        isSearching = true
        connection?.send(.findText(search: searchNumber, path: folder, query: query, caseSensitive: caseSensitive))
    }

    func stopSearch() {
        if isSearching { connection?.send(.stopSearch(search: searchNumber)) }
        isSearching = false
    }

    /// Forgets what a search found, when it is closed.
    func clearSearch() {
        stopSearch()
        searchNumber += 1
        foundFiles = []
        filesAmong = 0
        foundLines = []
        searchTruncated = false
        searchProblem = nil
    }

    // MARK: Files

    func loadFiles(_ directory: String) {
        connection?.send(.files(path: directory))
    }

    func loadFile(_ path: String, anyway: Bool = false) {
        connection?.send(.readFile(path: path, anyway: anyway ? true : nil))
    }

    func saveFile(_ path: String, text: String) {
        guard savingFile == nil else { return }
        // Nothing would answer: never a save that waits for ever (#281).
        guard status == .connected, connection != nil else {
            message = NotConnectedWords.notSaved(pairing?.name ?? "The Mac")
            return
        }
        savingFile = path
        savingText = text
        connection?.send(.writeFile(path: path, text: text))
    }

    func createFile(named name: String, in directory: String, isDirectory: Bool) {
        connection?.send(.createFile(directory: directory, name: name, isDirectory: isDirectory))
    }

    func renameFile(_ path: String, to name: String) {
        remoteFiles[path] = nil
        connection?.send(.renameFile(path: path, name: name))
    }

    func trashFile(_ path: String) {
        remoteFiles[path] = nil
        connection?.send(.trashFile(path: path))
    }

    /// Stages files for the next commit. No files means every change.
    func stage(_ files: [String], in folder: String) {
        sendForDiff(.gitStage(path: folder, files: files), in: folder)
    }

    /// Takes files out of the next commit. No files means all of them.
    func unstage(_ files: [String], in folder: String) {
        sendForDiff(.gitUnstage(path: folder, files: files), in: folder)
    }

    /// Discards changes that are not staged, once the user was asked (#39):
    /// back to what is staged or committed, and to the Mac's Trash what git
    /// does not track. No files means every such change.
    func discard(_ files: [String], in folder: String) {
        sendForDiff(.gitDiscard(path: folder, files: files), in: folder)
    }

    /// Commits what is staged with the message written for the folder.
    func commit(in folder: String) {
        guard committing == nil, let message = commitDrafts[folder] else { return }
        guard status == .connected, connection != nil else {
            self.message = NotConnectedWords.notCommitted(pairing?.name ?? "The Mac")
            return
        }
        committing = folder
        // The last commit is being amended: this replaces it (#41).
        sendForDiff(amending[folder] != nil ? .gitAmend(path: folder, message: message) : .gitCommit(path: folder, message: message), in: folder)
    }

    // MARK: Conflicts (#42)

    /// Gives up the merge, rebase, cherry-pick or revert that is stopped on
    /// conflicts on the Mac, once the user was asked. Resolving the files
    /// is done on the Mac.
    func abortOperation(in folder: String) {
        ask("abort", in: folder, .gitAbort(path: folder))
    }

    /// Goes on with it, once every file was resolved on the Mac.
    func continueOperation(in folder: String) {
        ask("continue", in: folder, .gitContinue(path: folder))
    }

    // MARK: Amend and undo the last commit (#41)

    /// The commit being amended, by folder.
    @Published private(set) var amending: [String: LastCommit] = [:]
    /// Undoing or amending that waits to be confirmed.
    @Published var pendingRewrite: PendingRewrite?
    /// What is done with a folder's last commit once the Mac has said it.
    private var lastCommitWanted: [String: (LastCommit) -> Void] = [:]

    struct PendingRewrite: Identifiable {
        let folder: String
        let action: RewriteCommitQuestion.Action
        let last: LastCommit
        var again = false
        var id: String { folder + action.rawValue + last.commit.hash + (again ? "again" : "") }
    }

    /// Starts amending the last commit: its message goes into the commit
    /// box. One a remote has already is asked about first.
    func requestAmend(in folder: String) {
        lastCommitWanted[folder] = { [weak self] last in
            if last.isPushed { self?.pendingRewrite = PendingRewrite(folder: folder, action: .amend, last: last) } else { self?.beginAmend(last, in: folder) }
        }
        connection?.send(.gitLastCommit(path: folder))
    }

    private func beginAmend(_ last: LastCommit, in folder: String) {
        amending[folder] = last
        commitDrafts[folder] = last.message
    }

    func cancelAmend(in folder: String) {
        guard amending[folder] != nil else { return }
        amending[folder] = nil
        commitDrafts[folder] = nil
    }

    func requestUndoCommit(in folder: String) {
        lastCommitWanted[folder] = { [weak self] last in self?.pendingRewrite = PendingRewrite(folder: folder, action: .undo, last: last) }
        connection?.send(.gitLastCommit(path: folder))
    }

    func rewriteConfirmed(_ pending: PendingRewrite) {
        switch pending.action {
        case .amend:
            beginAmend(pending.last, in: pending.folder)
        case .undo:
            // One a remote has is asked about once more, once this
            // question has gone.
            if pending.last.isPushed && !pending.again {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.pendingRewrite = PendingRewrite(folder: pending.folder, action: .undo, last: pending.last, again: true)
                }
                return
            }
            ask("undo", in: pending.folder, .gitUndoCommit(path: pending.folder))
        }
    }

    /// `folder` nil loads every conversation on the Mac.
    func loadHistory(_ folder: String?) {
        connection?.send(.history(path: folder))
    }

    // MARK: History: search, read, delete (#46)

    /// Conversations as they were read, by their id; nil inside for one
    /// that is no longer there.
    @Published private(set) var conversationDetails: [String: ConversationDetails?] = [:]
    /// What a search of History found, by the list it was for ("" for
    /// every conversation); nothing while that list is not searched.
    @Published private(set) var historyHits: [String: [HistoryHit]] = [:]
    @Published private(set) var historySearching: Set<String> = []
    /// Pages of older conversations asked for after the first, by list,
    /// and the lists that have none older.
    @Published private(set) var olderHistory: [String: [Conversation]] = [:]
    @Published private(set) var historyEnded: Set<String> = []
    /// Where a transcript was written out as a file on the Mac, until it is opened.
    @Published var exportedTranscript: String?
    private var historySearch = 0
    private var historySearchKey: String?

    /// Searches a list's conversations by title and by what was said. An
    /// empty query shows the list again.
    func searchHistory(_ query: String, in folder: String?) {
        let key = folder ?? ""
        historySearch += 1
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, status == .connected else {
            historyHits[key] = nil
            historySearching.remove(key)
            return
        }
        historySearchKey = key
        historyHits[key] = []
        historySearching.insert(key)
        connection?.send(.searchHistory(search: historySearch, path: folder, query: wanted, titlesOnly: historyTitlesOnly))
    }

    /// Searches look at the titles only, not at what was said (#50), as on
    /// the Mac. Kept on this iPhone; what was said too by default.
    @Published var historyTitlesOnly = UserDefaults.standard.bool(forKey: "historyTitlesOnly") {
        didSet { UserDefaults.standard.set(historyTitlesOnly, forKey: "historyTitlesOnly") }
    }

    /// The conversations deleted since the app started, here or on another
    /// device: a list picking some to delete lets them go (#50).
    @Published private(set) var deletedConversations: Set<String> = []

    /// Deletes several conversations' records on the Mac at once (#50), or
    /// every one there (`ids` nil), once the user was asked twice.
    func deleteConversations(_ ids: [String]?) {
        connection?.send(.deleteConversations(ids: ids))
    }

    func readConversation(_ conversation: Conversation) {
        connection?.send(.readConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    /// Deletes a conversation's record on the Mac, once the user was asked twice.
    func deleteConversation(_ conversation: Conversation) {
        connection?.send(.deleteConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func exportConversation(_ conversation: Conversation) {
        connection?.send(.exportConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func loadOlderHistory(_ folder: String?) {
        let key = folder ?? ""
        guard let oldest = ((histories[key] ?? []) + (olderHistory[key] ?? [])).map(\.updatedAt).min() else { return }
        connection?.send(.historyOlder(path: folder, before: oldest))
    }

    /// Reopens a conversation in its agent and shows its terminal.
    func resume(_ conversation: Conversation) {
        guard status == .connected else { return }
        openCreatedSession = true
        connection?.send(.resume(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd, size: startingSize))
    }

    /// Asks the Mac what the receiving agent would be told, to show it.
    func requestHandoffPlan(for conversation: Conversation) {
        handoffPlan = nil
        connection?.send(.handoffPlan(agent: conversation.agent))
    }

    /// Hands a conversation's work to another agent and shows its terminal.
    /// `prompt` is the plan's prompt as the user left it.
    /// `folder` is where the receiving agent starts; nil is the conversation's own folder.
    func handoff(_ conversation: Conversation, to target: AgentInfo, prompt: String, note: String, in folder: String? = nil) {
        guard status == .connected else { return }
        openCreatedSession = true
        let plan = handoffPlan
        let edited = plan.map { prompt != $0.prompt } ?? false
        Telemetry.shared.record(
            .handoff(from: .init(id: conversation.agent), to: .init(id: target.id), otherFolder: folder != nil && folder != conversation.cwd))
        connection?.send(
            .handoff(
                agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd,
                target: target.id, plan: plan?.id, prompt: edited ? prompt : nil, note: note, size: startingSize, folder: folder
            ))
        handoffPlan = nil
    }

    /// Continues a conversation in a new worktree of `folder` (#150), as the
    /// Mac does: the host makes it, hands the conversation off into it and
    /// starts `target` there.
    func handoffInNewWorktree(_ conversation: Conversation, to target: AgentInfo, in folder: String, branch: String?, from: String?) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.handoff(from: .init(id: conversation.agent), to: .init(id: target.id), otherFolder: true))
        connection?.send(
            .handoff(
                agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd, target: target.id, plan: nil, prompt: nil,
                note: "", size: startingSize, folder: folder, worktree: NewWorktree(branch: branch, from: from)))
    }

    // MARK: The Mac's settings, from here (#155)

    /// What each agent has of AgentTerm's in its configuration on the Mac.
    @Published private(set) var agentSetup: AgentSetupReport?

    struct AgentPrompts: Equatable {
        var custom: [String: String]
        var defaults: [String: String]
    }
    /// What each agent's new sessions are told: the user's own words, and
    /// AgentTerm's default.
    @Published private(set) var agentPrompts: AgentPrompts?

    struct MacShellSettings: Equatable {
        var settings: ShellSettings
        var loginShell: String
        var shells: [String]
    }
    /// How the Mac's shells are started.
    @Published private(set) var shellSettings: MacShellSettings?

    func askAgentSetup() { connection?.send(.agentSetupStatus) }

    /// Installs or removes AgentTerm's part in an agent's configuration on
    /// the Mac, or in every installed one's (nil): the host runs it there.
    func runAgentSetup(agent: String?, remove: Bool = false) {
        guard status == .connected else { return }
        connection?.send(.runAgentSetup(agent: agent, remove: remove))
    }

    /// The words an agent is told; nil goes back to AgentTerm's.
    func setAgentPrompt(_ agent: String, _ text: String?) {
        guard status == .connected else { return }
        connection?.send(.setAgentPrompt(agent: agent, text: text))
    }

    func setShellSettings(_ settings: ShellSettings) {
        guard status == .connected else { return }
        connection?.send(.setShellSettings(settings))
    }

    /// Changes the browser's profiles, in the Mac's app (#155); what it
    /// refuses is said.
    func changeProfiles(_ change: ProfileChange) {
        askBrowser(.profile(change)) { [weak self] result in
            switch result {
            case .profiles(let list): self?.browserProfiles = list
            case .refused(let why): self?.profileProblem = why
            default: break
            }
        }
    }
    @Published var profileProblem: String?

    /// Forgets the folder last looked at, so the next browse starts at home.
    func forgetListing() { listing = nil }

    /// Shows the folders inside `path`, or inside the home folder.
    func browse(_ path: String?) {
        connection?.send(.listDirectory(path: path))
    }

    func addFolder(_ path: String) {
        connection?.send(.addFolder(path: path))
    }

    /// Takes a folder off the list the Mac and the iPhone share. Its sessions
    /// keep running.
    func removeFolder(_ path: String) {
        connection?.send(.removeFolder(path: path))
    }

    /// True when a session runs an agent whose work could go to another one.
    func canHandOff(_ session: SessionInfo) -> Bool {
        let agent = agentID(for: session)
        return agent != "shell" && !handoffTargets(from: agent).isEmpty
    }

    /// Finds the conversation a running session is having, to hand it off.
    func requestHandoff(session: SessionInfo) {
        guard status == .connected else { return }
        pendingSessionHandoff = session
        connection?.send(.history(path: session.cwd))
    }

    func end(_ id: SessionID) {
        connection?.send(.kill(session: id))
    }

    func takeControl() {
        controller?.claimSize()
    }

    func refreshAgents() {
        agentsLoaded = false
        connection?.send(.agents(refresh: true))
        if hostVersion >= 6 { connection?.send(.sshHosts) }
    }

    func changeFontSize(by delta: Double) {
        let size = min(max(fontSize + delta, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard size != fontSize else { return }
        fontSize = size
        UserDefaults.standard.set(size, forKey: Self.fontSizeKey)
        controller?.setFontSize(size)
    }
}

/// Notifications of agents that finished or need an instruction (#22): the
/// app makes them itself, from what the host says over its connection,
/// while iOS lets the app run; after that, the Mac sends them through Apple
/// (#66) and the notification service extension makes the same ones.
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Made as the app finishes launching (`AppDelegate`), as iOS asks of a
    /// notification center's delegate: the press that launched the app is
    /// told to it then, before the model is (#277).
    static let shared = AgentNotifications()

    weak var model: PhoneModel? {
        didSet {
            guard model != nil else { return }
            let waiting = untilTheModel
            untilTheModel = []
            for answer in waiting { answer() }
        }
    }
    /// What a notification's press asked before the model was made.
    private var untilTheModel: [() -> Void] = []

    /// Runs `answer` with the model there, at once or once it is.
    private func withModel(_ answer: @escaping () -> Void) {
        if model != nil { answer() } else { untilTheModel.append(answer) }
    }
    /// Whether iOS was asked, and who waits for its answer (#200).
    private var permission = PermissionAsk<(Bool) -> Void>()

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Added to what iOS keeps, never in its place: the categories the
        // extension made for notifications that came while the app was not
        // running hold their buttons (#277).
        center.getNotificationCategories { known in center.setNotificationCategories(known.union(NoticeContent.fixedCategories)) }
    }

    /// The categories of questions with choices (#55), by the notification
    /// each is for: iOS takes a notification's buttons from its category,
    /// so a question's choices make one of its own, replaced by the next
    /// thing told of the same session.
    private var choiceCategories: [String: UNNotificationCategory] = [:]

    /// The category of a notice: one of its own for a question with
    /// choices, a button for each and the text reply after them.
    private func category(of notice: AgentNotice, request: String) -> String {
        choiceCategories[request] = NoticeContent.choiceCategory(of: notice, request: request)
        if let own = choiceCategories[request] { return own.identifier }
        return notice.takesAReply ? NoticeContent.replyCategory : NoticeContent.openCategory
    }

    /// Asks iOS, the first time, whether the app may notify; `done` is told
    /// whether it may. Never while the app's notifications are off (#195):
    /// whatever asks, iOS is asked only once the user turns them on. What
    /// asks while iOS's question is open is told its answer (#200), not the
    /// settings, which say "not determined" until then.
    @MainActor func askOnce(_ done: ((Bool) -> Void)? = nil) {
        let done = done ?? { _ in }
        switch permission.ask(done, switchedOn: model?.notifyAgents != false) {
        case .refuse:
            done(false)
        case .wait:
            break
        case .readSettings:
            UNUserNotificationCenter.current().getNotificationSettings { settings in done(settings.authorizationStatus == .authorized) }
        case .request:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    for waiting in self.permission.answered() { waiting(granted) }
                }
            }
        }
    }

    /// Takes back what was posted of these notices: handled, here or on
    /// another device (#66).
    func remove(mac: String, notices: [UInt64]) {
        guard !notices.isEmpty else { return }
        let identifiers = notices.map { PushNotice.identifier(mac: mac, notice: $0) }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    @MainActor func post(_ notice: Notice, mac: String, macName: String) {
        askOnce()
        let identifier = PushNotice.identifier(mac: mac, notice: notice.id)
        let content: UNMutableNotificationContent
        if let agent = notice.agentNotice {
            content = NoticeContent.content(of: agent, id: notice.id, mac: mac, macName: macName)
            content.categoryIdentifier = category(of: agent, request: identifier)
        } else {
            content = NoticeContent.content(of: nil, id: notice.id, mac: mac, macName: macName, title: notice.title(on: macName), body: notice.body)
        }
        let center = UNUserNotificationCenter.current()
        let made = Set(choiceCategories.values)
        // Its category first, added to what iOS keeps, as the extension does
        // (#277): an earlier notification's buttons stay. Then, not again
        // what came through Apple while the app was asleep: the same name
        // replaces it, and one shown already is left as it is.
        center.getNotificationCategories { known in
            let kept = known.filter { old in !made.contains { $0.identifier == old.identifier } }
            center.setNotificationCategories(kept.union(made).union(NoticeContent.fixedCategories))
            center.getDeliveredNotifications { shown in
                guard !shown.contains(where: { $0.request.identifier == identifier }) else { return }
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
        }
    }

    /// A background push that takes a notification back (#66), until the
    /// extension can do it itself.
    static func takeBack(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let gone = userInfo["g"] as? String else { return false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [gone])
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let info = content.userInfo
        let session = (info["session"] as? Int).map { SessionID(truncatingIfNeeded: $0) }
        // The whole state from a notification the app made; from a push
        // (#66), what names it.
        let state = (info["state"] as? String).flatMap { MessageCoding.decode(AgentState.self, from: Data($0.utf8)) }
        let digest = info["stateDigest"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let noticeID = (info["notice"] as? String).flatMap(UInt64.init)
        if action == UNNotificationDismissActionIdentifier {
            DispatchQueue.main.async { [weak self] in
                defer { completionHandler() }
                self?.withModel { [weak self] in
                    if let noticeID, let mac = info["mac"] as? String { self?.model?.dismissNotice(noticeID, onMac: mac) }
                }
            }
            return
        }
        // A button's title is the choice, in the agent's words: from the
        // state, else from the category the extension made for it.
        center.getNotificationCategories { categories in
            let button = categories.first { $0.identifier == content.categoryIdentifier }?.actions.first { $0.identifier == action }?.title
            DispatchQueue.main.async { [weak self] in
                defer { completionHandler() }
                // A press that launched the app waits for its model (#277).
                self?.withModel { [weak self] in
                    guard let model = self?.model, let mac = info["mac"] as? String else { return }
                    guard let session else {
                        // A failure: read once it is opened.
                        if let noticeID, action == UNNotificationDefaultActionIdentifier { model.dismissNotice(noticeID, onMac: mac) }
                        return
                    }
                    var text = typed
                    if text == nil, action.hasPrefix("choice-") {
                        text =
                            state.flatMap { AgentNotice(session: session, name: "", folder: "", state: $0).choice(ofButton: action) }
                            ?? (info[NoticeContent.choicesKey] as? [String: String])?[action] ?? button
                    }
                    if let text {
                        if let state, model.pairing?.id == mac {
                            model.answer(session: session, to: state, text: text)
                        } else if let digest {
                            model.answer(session: session, onMac: mac, digest: digest, text: text)
                        }
                    } else if action == UNNotificationDefaultActionIdentifier {
                        model.open(session: session, onMac: mac)
                    }
                }
            }
        }
    }

    /// In front too, iOS's own banner (#66, decided 2026-11-19): the app
    /// draws none. Not for the session on screen, which is then seen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let session = (notification.request.content.userInfo["session"] as? Int).map { SessionID(truncatingIfNeeded: $0) }
        DispatchQueue.main.async { [weak self] in
            if let session, session == self?.model?.openSessionID {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound])
            }
        }
    }

}
