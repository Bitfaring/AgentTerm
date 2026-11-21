#if os(macOS)
import AgentTermProtocol
import Foundation
import Network

/// Owns every terminal session and serves them to clients over WebSocket.
///
/// All state is confined to one serial queue.
public final class HostServer {
    public struct Configuration {
        public var port: UInt16
        public var token: String
        /// Also listen on the Mac's Tailscale address so paired phones can connect.
        /// The protocol version the host says it speaks. Only tests change
        /// it, to see what a client does with a host of another release.
        public var protocolVersion = agenttermProtocolVersion
        /// The release the host says it is from. Only tests change it, to
        /// see what the Mac does with a host left from another release (#121).
        public var release = AppVersion.current
        /// What the host says it is built from; tests change it (#121).
        public var revision = AppVersion.hostRevision
        public var listenOnTailscale: Bool
        /// Bytes of recent output kept per session, for a client that comes
        /// back after losing its connection: it is sent what it missed.
        public var scrollbackLimit: Int
        /// Lines above the screen kept per session and sent, with the
        /// screen, to a client that attaches.
        public var screenLines = 10_000
        /// A folder to take the agents' programs from, for tests: a
        /// session's command that starts with an agent's name then runs the
        /// program of that name in here, not the installed one the shell
        /// would find.
        public var agentsDirectory: String?
        /// What starts this host at login, for a host that can be. Nil for
        /// one that cannot: clients then show no switch for it.
        public var loginItem: LoginItem?
        /// Overrides agent detection, mainly for tests.
        public var detectAgents: () -> [AgentInfo]
        /// Where the shared folder list is saved. `nil` keeps it in memory only.
        public var foldersFile: URL?
        /// Where paired devices are saved. `nil` keeps them in memory only.
        public var devicesFile: URL?
        /// Home folder whose agent files hold the conversation history.
        public var home: String
        /// Path of `agenttermd`, which Claude Code sessions run as their status
        /// line to report their usage. `nil` leaves Claude Code as it is.
        public var statusLineTool: String?
        /// Where those reports are kept, one file per session, and what the
        /// agents' hooks tell of each session (`AgentHooks`).
        public var usageDirectory: URL?
        /// Where the host keeps what it gives Copilot CLI and Antigravity
        /// for their hooks: a plugin, a folder. Nil gives those two none.
        public var hooksDirectory: URL?
        /// The MCP server the agents' sessions are given (#10), and what
        /// earlier builds left of it in the agents' configuration. Nil gives
        /// none and takes nothing out: a test's host, a trial run.
        public var agentShells: AgentShellsSetup?
        /// How long since a key or the pointer was used on the Mac, in
        /// seconds; nil when that is not known. A test stands one in.
        public var idleSeconds: () -> TimeInterval? = { MacUse.idleSeconds() }
        /// Asks the agents' services what their accounts have left. `nil`
        /// asks nobody, which is what tests want.
        public var fetchAccountUsage: ((String) -> AccountUsage?)?
        /// Whether the Mac is plugged in. Tests say so themselves.
        public var isOnPower: () -> Bool = { PowerSource.isOnPower }
        /// Takes or lets go of the hold that keeps the Mac awake (whether to
        /// hold, whether the display too) and says whether it is held. Nil
        /// for macOS's own; a test stands in one that refuses.
        public var holdAwake: ((_ held: Bool, _ display: Bool) -> Bool)?
        /// Home folder whose SSH configuration names the hosts to offer.
        /// Nil reads the one of `home`.
        public var sshHome: String?
        /// How often sessions are named and measured, in seconds. Tests
        /// shorten it.
        public var refreshInterval: TimeInterval = 6
        /// How often schedules are looked at, in seconds (#11). Tests shorten it.
        public var scheduleInterval: TimeInterval = 20
        /// How long an agent's hooks and MCP server have to be heard from
        /// before its session says they are missing (#129). Tests shorten it.
        public var linkGrace: TimeInterval = 20
        /// How long a notice that waits is kept from being a notification
        /// (`Notice.pushWaits`). Tests shorten it.
        public var pushWait: TimeInterval = Notice.pushWait
        /// How long the Live Activity is kept, updated, with nothing
        /// working or waiting (`LiveActivityRule.keptIdle`). Tests shorten it.
        public var activityKeptIdle: TimeInterval = LiveActivityRule.keptIdle
        /// The relay that passes notices on to Apple for devices that are
        /// away (#66). Nil sends none: a development build, a test.
        public var pushRelay: URL?
        /// Where the devices that are told through Apple are kept, with
        /// their keys. Nil keeps them in memory only.
        public var pushesFile: URL?
        /// How the relay is asked; tests stand one in. Nil asks it over
        /// the network.
        public var pushTransport: PushCenter.Transport?
        /// Where the notices of the last 30 days are kept (#66). Nil keeps
        /// them in memory only.
        public var noticesFile: URL?
        /// How long a call of one of AgentTerm's own tools, which its agent
        /// said it is about to make, has to reach the agent's MCP server
        /// before the agent is taken to wait for leave to make it (#141).
        /// Tests shorten it.
        public var leaveGrace: TimeInterval = 2
        /// How often the program in front of each shell is looked at, for an
        /// agent typed by hand (#129). Tests shorten it.
        public var foregroundInterval: TimeInterval = 2
        /// Adds AgentTerm's hooks and MCP server to the agents' own
        /// configuration when a client asks (#129). Nil does nothing: a
        /// test's host.
        public var agentSetup: AgentSetup?
        /// The time, for schedules. A test sets its own clock.
        public var now: () -> Date = Date.init
        /// Where the host notes that it is running (`HostMarker`), so the
        /// host after it can tell that it died, and keeps the reports of
        /// parts that stopped until someone has seen them (`FailureLog`).
        /// Nil does neither.
        public var stateDirectory: URL?

        public init(
            port: UInt16 = agenttermDefaultPort,
            token: String,
            listenOnTailscale: Bool = true,
            scrollbackLimit: Int = 1024 * 1024,
            loginItem: LoginItem? = nil,
            detectAgents: @escaping () -> [AgentInfo] = AgentDetector.detect,
            foldersFile: URL? = nil,
            devicesFile: URL? = nil,
            home: String = NSHomeDirectory(),
            statusLineTool: String? = nil,
            usageDirectory: URL? = nil,
            fetchAccountUsage: ((String) -> AccountUsage?)? = nil
        ) {
            self.port = port
            self.token = token
            self.listenOnTailscale = listenOnTailscale
            self.scrollbackLimit = scrollbackLimit
            self.loginItem = loginItem
            self.detectAgents = detectAgents
            self.foldersFile = foldersFile
            self.devicesFile = devicesFile
            self.home = home
            self.statusLineTool = statusLineTool
            self.usageDirectory = usageDirectory
            self.fetchAccountUsage = fetchAccountUsage
        }
    }

    public enum StartError: Error, CustomStringConvertible {
        case listenerFailed(String)
        /// The hosts before this one died too often within a minute
        /// (`HostMarker.deathsThatBreak`): it is not to run until the user
        /// asks. A host that gets this exits with status 0, so that launchd
        /// does not start it again either.
        case keepsDying(Int)

        public var description: String {
            switch self {
            case .listenerFailed(let reason): return "could not listen: \(reason)"
            case .keepsDying(let count):
                return "the host stopped unexpectedly \(count) times within a minute, so it is not started again until AgentTerm is opened and asked to"
            }
        }
    }

    private final class Client {
        let id: ClientID
        let connection: NWConnection
        /// Whether the connection arrived on the loopback interface.
        let isLocal: Bool
        /// What it called itself when it said hello: "Mac" for the Mac's own
        /// app, a device's name for a device.
        var name = ""
        /// What the device said it is (#157); nil when it did not.
        var kind: DeviceKind?
        var identity: DeviceRegistry.Identity?
        var attached: Set<SessionID> = []
        /// Sessions whose screen is being written out for this client, with
        /// the output that came since, sent once the screen is.
        var awaitingScreen: [SessionID: (attach: Int, output: [DataFrame])] = [:]
        /// A Mac app that says it is in front: someone is at the Mac.
        var inFront = false
        /// A device that says its app went to the background (#190): away,
        /// though iOS may keep its connection open while it is suspended.
        /// What it is told goes through Apple until it is in front again.
        var inBackground = false
        /// Numbers the large messages sent in pieces.
        var nextMessage: UInt32 = 0
        /// The searches for text this client has going (#45), by its number.
        var searches: [Int: SearchFlag] = [:]
        /// Its searches of the history (#46), by their number, with whether
        /// each is of everywhere: apart from those for text, which a client
        /// numbers by themselves (#50).
        var historySearches: [Int: (flag: SearchFlag, everywhere: Bool)] = [:]

        var authenticated: Bool { identity != nil }
        /// The Mac's own apps may pair and revoke devices.
        var isAdmin: Bool { identity == .local }
        /// A paired device: the user's, from afar.
        var isDevice: Bool { if case .device = identity { return true } else { return false } }

        init(id: ClientID, connection: NWConnection, isLocal: Bool) {
            self.id = id
            self.connection = connection
            self.isLocal = isLocal
        }
    }

    /// Says to a search that goes on off the host's queue that it is no
    /// longer wanted.
    private final class SearchFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private final class Session {
        var info: SessionInfo
        let process: PTYProcess
        var arbiter: SizeArbiter
        /// The session's screen, which a client that attaches is sent. Only
        /// used on `mirrorQueue`: writing it out for a client that attaches
        /// takes tens of milliseconds for a long session, which the queue
        /// every session's output goes through must not wait for (#21).
        let mirror: ScreenMirror
        let mirrorQueue: DispatchQueue
        /// The last of the raw output, for a client that was here before.
        var scrollback = Data()
        /// Where the end of `scrollback` is in all the session ever wrote.
        /// It starts at a number of its own rather than at nothing: session
        /// numbers start over when the host does, and a client that comes
        /// back with a place in a session of before must not be taken to
        /// have a place in this one.
        var written = Int.random(in: 0..<(1 << 40))
        /// Its program was asked to end (the tab closed, the host stopping):
        /// a signal it then dies of is not reported.
        var endAsked = false
        /// What the status line relay could not save was reported.
        var usageFailureReported = false
        /// The last event its agent's hooks saved, as read.
        var lastEvent: Data?
        /// Since when its agent runs: the session's start, or when one typed
        /// in it was found (#129). Its hooks and MCP server have until a
        /// grace after it to be heard from.
        var agentSince: Date?
        /// Whether AgentTerm had instructions for its agent when it started
        /// (#172): what the session was given, whatever is saved later.
        var promptGiven = true
        /// A call of one of AgentTerm's own tools that its agent said it is
        /// about to make, and when: until the call comes to its server, or
        /// the agent says anything else (#141).
        var announcedCall: (tool: String, at: Date)?
        /// When its agent's MCP server last asked for what a tool does.
        var lastToolCall: Date?
        /// The turn its agent is in, from its start (#71).
        var turn: TurnRecord?
        /// What its agent's last turn came to.
        var lastTurn: TurnResult?
        /// What an agent's MCP server names it by, to open and reach the
        /// shells it opens (#10). Every session has one (#129): an agent
        /// typed in a shell uses it too.
        var agentKey: String?
        /// When a schedule's run last wrote anything, by the host's clock:
        /// one whose agent's state is not known is taken to be done once it
        /// has been quiet for a while.
        var lastOutputAt = Date.distantPast
        /// What is to be typed into it, without Return, once its shell has
        /// written something: then it is at its prompt (`CreateRequest.typed`).
        var pendingTyped: String?
        /// Its shell was set up to say when its commands start and end
        /// (`ShellIntegration`): a shell an agent opened.
        var marksPrepared = false
        /// What Settings > Shell has run first in it, typed with Return
        /// once it shows its prompt, as a person would.
        var pendingStartup: String?

        init(info: SessionInfo, process: PTYProcess, screenLines: Int) {
            self.info = info
            self.process = process
            self.mirror = ScreenMirror(size: info.size, scrollback: screenLines)
            self.mirrorQueue = DispatchQueue(label: "agentterm.screen.\(info.id)")
            self.arbiter = SizeArbiter(fallback: info.size)
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "agentterm.host")
    /// Where what a turn came to is worked out (#71): git and the agents'
    /// records, away from the host's queue.
    private let turnQueue = DispatchQueue(label: "agentterm.host.turns", qos: .utility)
    private let detectionQueue = DispatchQueue(label: "agentterm.host.detect")
    /// Git and file reading for clients, kept off the queue that moves terminal bytes.
    private let workQueue = DispatchQueue(label: "agentterm.host.work", qos: .userInitiated, attributes: .concurrent)
    /// The last changes read per folder, so asking for one file's diff right
    /// after the list does not run git again.
    private var diffCache: [String: (snapshot: DiffSnapshot, at: Date)] = [:]
    /// The folders whose changes clients ask about, watched so that they are
    /// worked out again only after their files changed; the last few only.
    private var diffWatches: [String: FolderWatch] = [:]
    private var diffWatchOrder: [String] = []
    private var diffDirty: Set<String> = []
    private static let diffWatchesKept = 8

    private func watchForDiff(_ path: String) {
        diffWatchOrder.removeAll { $0 == path }
        diffWatchOrder.append(path)
        guard diffWatches[path] == nil else { return }
        while diffWatchOrder.count > Self.diffWatchesKept {
            let oldest = diffWatchOrder.removeFirst()
            diffWatches[oldest] = nil
            diffDirty.remove(oldest)
        }
        workQueue.async { [weak self] in
            let paths = FolderWatch.paths(for: path)
            self?.queue.async {
                guard let self, self.diffWatchOrder.contains(path), self.diffWatches[path] == nil else { return }
                self.diffWatches[path] = FolderWatch(paths: paths, queue: self.queue) { [weak self] in self?.diffDirty.insert(path) }
                // What changed before the watch began is not known: once more.
                self.diffDirty.insert(path)
            }
        }
    }
    /// Handoff plans that were shown to a user, until they are used. The
    /// prompt in a plan names a file, and the handoff has to write that file.
    private var handoffPlans: [String: (plan: Handoff.Plan, at: Date)] = [:]
    private var listeners: [String: NWListener] = [:]
    private var tailscaleTimer: DispatchSourceTimer?
    private var summaryTimer: DispatchSourceTimer?
    private var summarizing = false
    /// What each agent's account has left, and when its service was last asked.
    private var accountUsage: [String: AccountUsage] = [:]
    private var accountAsked: [String: Date] = [:]
    private var accountAsking: Set<String> = []
    /// Services are asked this often while an agent has a session.
    private static let accountInterval: TimeInterval = 300
    private var clients: [ClientID: Client] = [:]
    private var sessions: [SessionID: Session] = [:]
    private var nextClientID: ClientID = 1
    private var nextSessionID: SessionID = 1
    private var agents: [AgentInfo]?
    private var agentWaiters: [ClientID] = []
    private var detecting = false
    private var boundPort: UInt16 = 0
    private var folders: [String] = []
    private let registry: DeviceRegistry
    /// Parts that stopped without being asked to, until the user has seen
    /// them on one of the clients.
    private var failures: [PartFailure] = []
    /// An agent's MCP server was refused when it signed in, and none has
    /// signed in since.
    private var agentShellsRefused = false
    private var agentShellsFaultsTold: [AgentShellsFault] = []

    // MARK: The browser (#76)

    /// The app on this Mac that shows the browser and does what is asked of it.
    private var browserProvider: ClientID?
    /// Its tabs, as it last said.
    private var browserTabsList: [BrowserTabInfo] = []
    /// What waits for the app's answer, by the number it was asked with:
    /// who asked, under which number of theirs, and whether an agent did.
    private var browserCalls: [Int: (client: ClientID, id: Int, agent: Bool)] = [:]
    private var nextBrowserCall = 1
    /// What a session's agent said or asks that the user has seen on one
    /// device (#60), for the devices that connect later.
    private var noticesSeen: [SessionID: AgentState] = [:]
    /// The devices told through Apple while they are away (#66).
    private let push: PushCenter
    /// What agents asked and finished, and what stopped work (#66).
    private let notices: NoticeCenter
    /// What this host notes about itself in the state folder while it runs.
    private var marker: HostMarker?
    private var markerFile: URL?

    public init(configuration: Configuration) {
        self.configuration = configuration
        registry = DeviceRegistry(localToken: configuration.token, file: configuration.devicesFile)
        push = PushCenter(relay: configuration.pushRelay, file: configuration.pushesFile, transport: configuration.pushTransport)
        notices = NoticeCenter(file: configuration.noticesFile)
        if let file = configuration.foldersFile, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            folders = saved
        }
        if let file = settingsFile, let data = try? Data(contentsOf: file),
            let saved = MessageCoding.decode(Settings.self, from: data)
        {
            keepAwake = saved.keepAwake ?? false
            keepAwakeOptions = saved.keepAwakeOptions ?? KeepAwakeOptions()
            commitWriter = saved.commitWriter ?? CommitWriterSettings()
            displaySettings = saved.display
            startAtLoginChosen = saved.startAtLoginChosen ?? false
            shellSettings = saved.shell ?? ShellSettings()
        }
        if let file = tabLayoutFile, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode(TabLayout.self, from: data)
        {
            tabLayout = saved
        }
    }

    /// Whether to keep the Mac awake while sessions run. Kept next to the folders.
    private var keepAwake = false
    private let sleepGuard = SleepGuard()
    private var settingsFile: URL? {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    /// The display too, only on power, and for how long.
    private var keepAwakeOptions = KeepAwakeOptions()
    /// Which agent writes commit messages, and how it is asked.
    private var commitWriter = CommitWriterSettings()
    /// How things are shown on every device. Nil until a client has said:
    /// the first one to connect then brings what it had chosen.
    private var displaySettings: DisplaySettings?
    /// The agents writing a commit message now, by folder.
    private var commitRuns: [String: CommitWriter.Run] = [:]
    private let statsQueue = DispatchQueue(label: "agentterm.host.stats", qos: .utility)
    /// Measures the Mac itself. Confined to `statsQueue`.
    private let systemSampler = SystemSampler()
    private var systemTimer: DispatchSourceTimer?
    private var systemStats: SystemStats?
    private var samplingSystem = false

    /// Measures the Mac and tells the clients, while there is one to tell.
    private func refreshSystemStats() {
        guard !samplingSystem, clients.values.contains(where: \.authenticated) else { return }
        samplingSystem = true
        statsQueue.async { [weak self] in
            guard let self else { return }
            let stats = self.systemSampler.sample()
            self.queue.async {
                self.samplingSystem = false
                guard stats != self.systemStats else { return }
                self.systemStats = stats
                for client in self.clients.values where client.authenticated { self.send(.systemStats(stats), to: client) }
            }
        }
    }

    /// What the host keeps in `settings.json`. Every field is optional, so
    /// the file of an earlier version still reads.
    private struct Settings: Codable {
        var keepAwake: Bool?
        var keepAwakeOptions: KeepAwakeOptions?
        var commitWriter: CommitWriterSettings?
        var display: DisplaySettings?
        /// The user turned Start at Login on or off once: from then on it
        /// is theirs. Until then it is turned on, the default.
        var startAtLoginChosen: Bool?
        /// How shells are started (Settings > Shell).
        var shell: ShellSettings?
    }

    /// How shells are started (Settings > Shell).
    private var shellSettings = ShellSettings()

    /// The program a new session starts: the shell picked for a shell, the
    /// login shell for a command, which is written for it.
    private func program(forCommand command: String?) -> String {
        guard (command ?? "").isEmpty, let program = shellSettings.program, FileManager.default.isExecutableFile(atPath: program) else {
            return HostEnvironment.shell
        }
        return program
    }

    /// The shells the Mac has, to pick from: those `/etc/shells` names and
    /// those Homebrew put in its folders.
    private static var availableShells: [String] {
        let listed = ((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.hasPrefix("/") }
        let brewed = ["/opt/homebrew/bin", "/usr/local/bin"].flatMap { folder in ["zsh", "bash", "fish", "nu"].map { "\(folder)/\($0)" } }
        var seen = Set<String>()
        return (listed + brewed).filter { FileManager.default.isExecutableFile(atPath: $0) && seen.insert($0).inserted }
    }

    private var shellSettingsMessage: ServerMessage {
        .shellSettings(shellSettings, loginShell: HostEnvironment.shell, shells: Self.availableShells)
    }

    /// Whether the user has turned Start at Login on or off.
    private var startAtLoginChosen = false

    /// Start at Login is on by default: turned on the first time a host
    /// that can be started at login runs, until the user has chosen.
    private func startAtLoginByDefault() {
        // Without a settings file the user's choice could not be kept: then
        // it is not turned on by itself either.
        guard let item = configuration.loginItem, settingsFile != nil, !startAtLoginChosen else { return }
        // One that could not be turned on is not the user's choice: the
        // next host tries again.
        if !item.isOn {
            do { try item.turnOn() } catch { return }
        }
        startAtLoginChosen = true
        saveSettings()
    }

    private func saveSettings() {
        guard let file = settingsFile else { return }
        let settings = Settings(
            keepAwake: keepAwake, keepAwakeOptions: keepAwakeOptions, commitWriter: commitWriter, display: displaySettings,
            startAtLoginChosen: startAtLoginChosen, shell: shellSettings)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MessageCoding.encode(settings).write(to: file, options: .atomic)
    }

    /// The hold on sleep follows the setting and whether anything runs:
    /// with no session there is nothing to stay awake for. A hold that was
    /// given a time ends when the time is up.
    private func updateSleepGuard() {
        if keepAwake, let until = keepAwakeOptions.until, until <= Date() {
            keepAwake = false
            keepAwakeOptions.until = nil
            saveSettings()
            broadcastKeepAwake()
        }
        let powered = !keepAwakeOptions.onlyOnPower || configuration.isOnPower()
        // Any session holds the Mac awake, or only an agent at work.
        let running = keepAwakeOptions.onlyWhileWorking ? sessions.values.contains { $0.info.state?.isWorking == true } : !sessions.isEmpty
        let soon = schedules.contains { schedule in
            schedule.enabled && schedule.nextRun.map { $0.timeIntervalSince(configuration.now()) <= Self.awakeBeforeRun } == true
        }
        let wanted = (keepAwake && running && powered) || soon
        let held =
            configuration.holdAwake.map { $0(wanted, keepAwakeOptions.display) }
            ?? sleepGuard.set(held: wanted, display: keepAwakeOptions.display)
        noteSleepHold(wanted: wanted, held: held)
    }

    /// The report of a hold macOS refused, while it is refused.
    private var refusedHold: String?

    /// A hold that is wanted and refused is reported once; it is asked for
    /// again on every refresh, and the report says so once it is held.
    private func noteSleepHold(wanted: Bool, held: Bool) {
        if wanted && !held {
            guard refusedHold == nil else { return }
            let failure = PartFailure(
                part: .keepAwake, at: Date(), restarted: false,
                reason: "macOS would not hold it, so the Mac may sleep while sessions run. AgentTerm asks again every few seconds.")
            refusedHold = failure.id
            report(failure)
        } else if let id = refusedHold {
            refusedHold = nil
            // Held again: said in the report that is still there. One that
            // is no longer wanted is left as it was.
            guard wanted, let index = failures.firstIndex(where: { $0.id == id }) else { return }
            failures[index].restarted = true
            saveFailures()
            broadcastFailures()
        }
    }

    private func broadcastKeepAwake() {
        for client in clients.values where client.authenticated {
            send(.keepAwake(keepAwake), to: client)
            send(.keepAwakeOptions(keepAwakeOptions), to: client)
        }
    }

    /// Looks again when a timed hold is due to end.
    private func scheduleKeepAwakeEnd() {
        guard keepAwake, let until = keepAwakeOptions.until else { return }
        queue.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow) + 0.05) { [weak self] in self?.updateSleepGuard() }
    }

    /// True while the Mac is being kept awake. For tests.
    public var isKeepingAwake: Bool { queue.sync { sleepGuard.isHeld } }
    /// True while the display is being kept on too. For tests.
    public var isKeepingDisplayAwake: Bool { queue.sync { sleepGuard.holdsDisplay } }

    /// Where an agent runs when it writes a commit message.
    private var commitWriterDirectory: URL {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("commit-writer", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-commit-writer", isDirectory: true)
    }

    /// How the tabs are arranged, for every client. Kept next to the folders.
    private var tabLayout = TabLayout()
    private var tabLayoutFile: URL? {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("tabs.json")
    }

    // MARK: Lifecycle

    /// Starts listening on the loopback interface and returns the bound port.
    /// The Tailscale listener is added when the interface is up, now or later.
    @discardableResult
    public func start() throws -> UInt16 {
        let port = try listen(on: "127.0.0.1", port: configuration.port)
        let deaths = queue.sync {
            boundPort = port
            // Only once the port is this host's: a host that cannot listen
            // there leaves the one that can to find out what happened.
            return noteStart()
        }
        if let deaths {
            stop()
            throw StartError.keepsDying(deaths)
        }

        // Names sessions after the conversations their agents are having.
        let summaries = DispatchSource.makeTimerSource(queue: queue)
        summaries.schedule(deadline: .now() + min(3, configuration.refreshInterval), repeating: configuration.refreshInterval)
        summaries.setEventHandler { [weak self] in
            guard let self else { return }
            // Still alive: what the next host takes for the time this one
            // died, should it die.
            if let file = self.markerFile { HostMarker.touch(file) }
            // Power may have been plugged in or pulled since the last look.
            self.updateSleepGuard()
            self.updateMacInUse()
            self.checkLoginItem()
            self.checkStatusLines()
            // In case the folder's watch missed one.
            self.readEvents()
            self.refreshSummaries()
        }
        // The Mac itself is measured more often than its sessions: a
        // network speed or a processor load that is seconds old says little.
        let system = DispatchSource.makeTimerSource(queue: queue)
        system.schedule(deadline: .now() + 0.2, repeating: min(3, configuration.refreshInterval))
        system.setEventHandler { [weak self] in self?.refreshSystemStats() }
        queue.sync {
            summaryTimer = summaries
            watchEvents()
            // What AgentTerm tells each agent, for its MCP server to give.
            writePromptsForServers()
            loadSchedules()
            loadHistoryMarks()
            startAtLoginByDefault()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + min(1, configuration.scheduleInterval), repeating: configuration.scheduleInterval)
            timer.setEventHandler { [weak self] in self?.checkSchedules() }
            timer.resume()
            scheduleTimer = timer
            let links = DispatchSource.makeTimerSource(queue: queue)
            links.schedule(deadline: .now() + configuration.foregroundInterval, repeating: configuration.foregroundInterval)
            links.setEventHandler { [weak self] in self?.lookAtAgentLinks() }
            links.resume()
            linkTimer = links
            systemTimer = system
            scheduleKeepAwakeEnd()
        }
        system.resume()
        summaries.resume()
        guard configuration.listenOnTailscale else { return port }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 15)
        timer.setEventHandler { [weak self] in self?.syncTailscaleListener() }
        queue.sync { tailscaleTimer = timer }
        timer.resume()
        return port
    }

    public func stop() {
        queue.sync {
            // A stop that was asked for, so it is not a death. Before the
            // clients are let go: an app that sees its connection close
            // looks for the marker to know which of the two it was.
            if let file = markerFile { try? FileManager.default.removeItem(at: file) }
            markerFile = nil
            marker = nil
            tailscaleTimer?.cancel()
            tailscaleTimer = nil
            summaryTimer?.cancel()
            scheduleTimer?.cancel()
            scheduleTimer = nil
            linkTimer?.cancel()
            linkTimer = nil
            eventsWatch?.cancel()
            eventsWatch = nil
            summaryTimer = nil
            systemTimer?.cancel()
            systemTimer = nil
            listeners.values.forEach { $0.cancel() }
            listeners.removeAll()
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
            sessions.values.forEach {
                $0.endAsked = true
                $0.process.hangUp()
            }
            sessions.removeAll()
            // Their runs end with them. Not before the schedules were read:
            // a host that could not start would save none over them.
            if schedulesLoaded {
                endRunsOfTheHostBefore(at: configuration.now())
                runStarts.removeAll()
                saveSchedules()
            }
            commitRuns.values.forEach { $0.cancel() }
            commitRuns.removeAll()
            sleepGuard.set(held: false)
        }
    }

    public var sessionCount: Int { queue.sync { sessions.count } }

    // MARK: Parts that stopped

    /// Reads what the host before this one left, reports it if it died,
    /// and notes that this one runs. Returns how often the hosts before it
    /// died lately when that is too often for this one to run.
    private func noteStart(now: Date = Date()) -> Int? {
        guard let directory = configuration.stateDirectory else { return nil }
        failures = FailureLog.read(in: directory)
        let file = HostMarker.file(in: directory, port: boundPort)
        var deaths: [Date] = []
        if let found = HostMarker.read(file), !found.marker.isRunning {
            // It left its marker, so it did not stop as asked: it was
            // killed or it crashed, and its sessions ended with it. Whoever
            // started this host started it again.
            deaths = HostMarker.recent(found.marker.deaths + [found.aliveAt], now: now)
            // Broken means three times in sixty seconds, however the host
            // was started again: by the app, or by launchd with the app
            // closed. Then this one does not run.
            let broken = deaths.count >= HostMarker.deathsThatBreak
            failures.append(PartFailure(part: .host, at: found.aliveAt, ended: found.marker.sessions, restarted: !broken, broken: broken))
            failures = Array(failures.suffix(FailureLog.limit))
            FailureLog.write(failures, in: directory)
            if broken {
                // What is reported is kept; the deaths that were counted
                // are not, so the next start, which only the user makes
                // (opening the app, Try Again, logging in), runs.
                try? FileManager.default.removeItem(at: file)
                return deaths.count
            }
        }
        let marker = HostMarker(sessions: endedSessions(), deaths: deaths)
        marker.write(to: file)
        self.marker = marker
        markerFile = file
        // A client that came in while the listener was starting.
        if !failures.isEmpty { broadcastFailures() }
        return nil
    }

    /// The sessions as the marker names them: what would end with this host.
    private func endedSessions() -> [EndedSession] {
        sessions.values.map(\.info).sorted { $0.id < $1.id }.map(EndedSession.init)
    }

    /// Writes the marker again when what would end with the host changed.
    private func updateMarker() {
        guard let file = markerFile, var marker else { return }
        let now = endedSessions()
        guard now != marker.sessions else { return }
        marker.sessions = now
        marker.write(to: file)
        self.marker = marker
    }

    // MARK: Schedules (#11)

    private var schedules: [Schedule] = []
    /// Until when the schedules were looked at: a time that came between it
    /// and now, while the Mac slept, is a run that was missed.
    private var schedulesChecked: Date?
    /// The last limit reset each agent's schedules ran for.
    private var resetsRun: [String: Date] = [:]
    /// From when each schedule is looked at: when it was saved, so that a
    /// time of today that passed before it was made is not taken for due.
    private var schedulesFrom: [String: Date] = [:]
    /// Runs that came due and wait: for two others to end, for the run
    /// before them, or for what has to be looked at first. Oldest first.
    private var waitingRuns: [(schedule: String, at: Date, note: String)] = []
    /// Every schedule is held back (#47).
    private var schedulesPaused = false
    /// Runs being got ready off the queue: their condition looked at,
    /// their worktree made. By `runKey`.
    private var preparingRuns: Set<String> = []
    /// What each run's session started from: its schedule, when it came
    /// due, its folder and how the folder was then.
    private var runStarts: [SessionID: (schedule: String, at: Date, directory: String, before: GitActions.Baseline?)] = [:]
    /// Why a run's session was ended by the host or the user, to be said
    /// of it when it has ended.
    private var runStops: [SessionID: String] = [:]

    private func runKey(_ schedule: String, _ at: Date) -> String { "\(schedule)@\(Int(at.timeIntervalSince1970))" }

    /// Where what a run printed is kept.
    private func runOutputFile(_ schedule: String, _ at: Date) -> URL? {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("\(schedule)-\(Int(at.timeIntervalSince1970)).txt")
    }
    /// When each run's session was first seen done, to close it a day later.
    private var runDoneAt: [SessionID: Date] = [:]
    private var scheduleTimer: DispatchSourceTimer?
    /// Looks for agents typed in shells, and for links not heard from (#129).
    private var linkTimer: DispatchSourceTimer?

    static let maxRunsAtOnce = 2
    /// How long a run whose agent's state is not known may write nothing
    /// before it is taken to be done.
    static let quietRunIsDone: TimeInterval = 3600
    static let afterLimitReset: TimeInterval = 120
    static let keepRunFor: TimeInterval = 24 * 3600
    static let awakeBeforeRun: TimeInterval = 10 * 60

    private struct SchedulesFile: Codable {
        var schedules: [Schedule]
        var checked: Date?
        var resetsRun: [String: Date]?
        var from: [String: Date]?
        var paused: Bool?
    }

    private var schedulesFile: URL? { configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("schedules.json") }

    /// Whether this host read its schedules, and so may save them.
    private var schedulesLoaded = false

    private func loadSchedules() {
        schedulesLoaded = true
        guard let file = schedulesFile, let data = FileManager.default.contents(atPath: file.path),
            let saved = MessageCoding.decode(SchedulesFile.self, from: data)
        else { return }
        schedules = saved.schedules
        schedulesChecked = saved.checked
        resetsRun = saved.resetsRun ?? [:]
        schedulesFrom = saved.from ?? [:]
        schedulesPaused = saved.paused ?? false
        // A host that died left its runs going: they ended with it, about
        // when it last looked at its schedules.
        endRunsOfTheHostBefore(at: saved.checked)
    }

    static let endedWithTheHost = "Its session ended with the host"

    /// The runs whose session was this host's, or the host's before, are
    /// over: no session outlives the host that started it. The number of
    /// their session is forgotten, since the next host gives its own
    /// sessions the same numbers from 1.
    private func endRunsOfTheHostBefore(at end: Date?) {
        for index in schedules.indices {
            for place in schedules[index].runs.indices {
                var run = schedules[index].runs[place]
                if run.started && run.ended == nil {
                    run.ended = max(end ?? run.at, run.startedAt ?? run.at)
                    run.outcome = Self.endedWithTheHost
                }
                run.session = nil
                schedules[index].runs[place] = run
            }
        }
    }

    private func saveSchedules() {
        guard let file = schedulesFile else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MessageCoding.encode(SchedulesFile(schedules: schedules, checked: schedulesChecked, resetsRun: resetsRun, from: schedulesFrom, paused: schedulesPaused)).write(to: file, options: .atomic)
    }

    private func broadcastSchedules() {
        for client in clients.values where client.authenticated { send(.schedules(schedules), to: client) }
    }

    /// Adds or changes a schedule; why not, when it is refused.
    private func save(_ wanted: Schedule) -> String? {
        var schedule = wanted
        guard SchedulePermissions.offered(by: schedule.agent).contains(schedule.permissions) else {
            return "\(schedule.agent) cannot run with “\(schedule.permissions.label)”."
        }
        guard schedule.permissions != .skipAll || schedule.warningAccepted else {
            return "A schedule that skips permissions cannot be saved before its warning was shown and accepted."
        }
        guard !schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Write what the agent is to do." }
        // Asked once now, while the user is here, rather than at 3 a.m.
        do { try ScheduleRunner.trustFolder(of: schedule, home: configuration.home) } catch {
            return "The folder could not be trusted for \(schedule.agent): \(error.localizedDescription)"
        }
        if case .every(let minutes, _, _) = schedule.when, minutes < 5 { return "A schedule runs every 5 minutes at the most often." }
        if case .dates(let moments) = schedule.when, moments.isEmpty { return "Pick at least one date for it to run on." }
        if let most = schedule.maxMinutes, most < 1 { return "The longest a run may take is at least a minute." }
        // What the host keeps is not the client's to set.
        let kept = schedules.first { $0.id == schedule.id }
        schedule.runs = kept?.runs ?? []
        let now = configuration.now()
        // What was changed about it, kept with it (#47).
        schedule.edits = kept?.edits ?? []
        if let kept {
            let what = schedule.changes(from: kept)
            if !what.isEmpty { schedule.edits = Array((schedule.edits + [ScheduleEdit(at: now, what: what)]).suffix(Schedule.editsKept)) }
        }
        // Changed, or new: looked at from now on.
        if kept?.when != schedule.when || kept?.enabled != schedule.enabled { schedulesFrom[schedule.id] = now }
        if schedulesChecked == nil { schedulesChecked = now }
        schedule.nextRun = nextRun(of: schedule, after: configuration.now())
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) { schedules[index] = schedule } else { schedules.append(schedule) }
        saveSchedules()
        broadcastSchedules()
        updateSleepGuard()
        return nil
    }

    /// When it comes due next, after `date`.
    private func nextRun(of schedule: Schedule, after date: Date) -> Date? {
        guard schedule.enabled, !schedulesPaused else { return nil }
        if case .limitReset = schedule.when {
            let done = resetsRun[schedule.agent] ?? .distantPast
            return resets(of: schedule.agent).filter { $0 > done }.map { $0.addingTimeInterval(Self.afterLimitReset) }.filter { $0 > date }.min()
        }
        return schedule.when.next(after: date)
    }

    /// When the account limits of an agent start over, as its service last said.
    private func resets(of agent: String) -> [Date] {
        accountUsage[agent].map { $0.groups.flatMap(\.limits).compactMap(\.resetsAt) } ?? []
    }

    /// Runs what came due since the last look, at most once each however
    /// many times it came due meanwhile; closes the sessions of runs done
    /// for a day.
    private func checkSchedules() {
        let now = configuration.now()
        let checked = schedulesChecked ?? now
        // A look that came this late means the Mac slept in between.
        let slept = now.timeIntervalSince(checked) > max(3 * configuration.scheduleInterval, 90)
        var changed = false
        // Noted once every schedule was looked at: each of an agent's
        // schedules runs for the same reset, not only the first.
        var ranFor: [String: Date] = [:]
        // Held back: nothing comes due, and nothing is caught up afterwards.
        for index in schedules.indices where schedules[index].enabled && !schedulesPaused {
            let schedule = schedules[index]
            let since = max(checked, schedulesFrom[schedule.id] ?? checked)
            let due: Date?
            if case .limitReset = schedule.when {
                let done = resetsRun[schedule.agent] ?? .distantPast
                // Since the last look too, as any other time: not one that
                // passed while the schedules were paused, or before this
                // one was saved or turned on.
                let passed = resets(of: schedule.agent).filter {
                    $0 > done && $0.addingTimeInterval(Self.afterLimitReset) > since && $0.addingTimeInterval(Self.afterLimitReset) <= now
                }
                due = passed.max()?.addingTimeInterval(Self.afterLimitReset)
                if let latest = passed.max() { ranFor[schedule.agent] = max(latest, ranFor[schedule.agent] ?? latest) }
            } else {
                due = schedule.when.next(after: since).flatMap { $0 <= now ? $0 : nil }
            }
            guard let due else { continue }
            changed = true
            let missed = slept && now.timeIntervalSince(due) > configuration.scheduleInterval * 2
            if missed && !schedule.catchUp {
                record(ScheduleRun(at: due, started: false, note: "Missed while the Mac was asleep or off"), in: index)
            } else {
                waitingRuns.append((schedule.id, due, missed ? "Missed at \(due.formatted(date: .omitted, time: .shortened)), run when the Mac was next awake" : "Started"))
            }
        }
        resetsRun.merge(ranFor) { _, new in new }
        schedulesChecked = now
        startWaitingRuns()
        endOverdueRuns(now: now)
        noteFinishedRuns(now: now)
        closeFinishedRuns(now: now)
        for index in schedules.indices {
            let next = nextRun(of: schedules[index], after: now)
            if next != schedules[index].nextRun {
                schedules[index].nextRun = next
                changed = true
            }
        }
        saveSchedules()
        if changed { broadcastSchedules() }
        updateSleepGuard()
    }

    /// Whether a run's agent is still at it: working, or waiting for the
    /// user. One whose state is not known (its hooks never ran, or it was
    /// interrupted) is taken to be done once it has been quiet for an hour.
    private func isGoing(_ session: Session, now: Date) -> Bool {
        switch session.info.state {
        case .done?: return false
        case nil: return now.timeIntervalSince(session.lastOutputAt) < Self.quietRunIsDone
        default: return true
        }
    }

    /// The runs of a schedule that are still going: their session runs,
    /// and their agent is not done.
    private func going(_ scheduleName: String, now: Date) -> [Session] {
        sessions.values.filter { $0.info.schedule == scheduleName && isGoing($0, now: now) }
    }

    private func startWaitingRuns() {
        let now = configuration.now()
        var still: [(schedule: String, at: Date, note: String)] = []
        // Counted here too: two that start in one look are two.
        var starting = 0
        for run in waitingRuns {
            guard let index = schedules.firstIndex(where: { $0.id == run.schedule }) else { continue }
            let schedule = schedules[index]
            let key = runKey(schedule.id, run.at)
            // Being got ready: it starts, or says why not, when that is done.
            if preparingRuns.contains(key) {
                still.append(run)
                continue
            }
            if !going(schedule.name, now: now).isEmpty || preparingRuns.contains(where: { $0.hasPrefix(schedule.id + "@") }) {
                if schedule.waitsForPrevious {
                    still.append(run)
                } else {
                    record(ScheduleRun(at: run.at, started: false, note: "Skipped: the run before it is still going"), in: index)
                }
                continue
            }
            let running = sessions.values.filter { $0.info.schedule != nil && isGoing($0, now: now) }.count + preparingRuns.count + starting
            guard running < Self.maxRunsAtOnce else {
                still.append(run)
                continue
            }
            // Never somewhere else: a session whose folder is gone starts in
            // the home folder, and an agent that skips permissions would
            // have all of it.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: schedule.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                notStarted(run.at, in: index, "Not started: its folder \(schedule.folder) is not there")
                continue
            }
            if schedule.condition == .always && !schedule.inWorktree {
                starting += 1
                start(schedule, at: run.at, note: run.note, in: schedule.folder, worktree: nil, before: nil)
            } else {
                // What it waits on runs git, and may fetch: off the queue.
                preparingRuns.insert(key)
                still.append(run)
                prepare(schedule, at: run.at, note: run.note)
            }
        }
        waitingRuns = still
    }

    /// Looks at what has to be so for a run (#47) and makes its worktree,
    /// off the queue, and then starts it or says why it is not started.
    private func prepare(_ schedule: Schedule, at: Date, note: String) {
        let home = configuration.home
        workQueue.async { [weak self] in
            var skipped: String?
            var failed: String?
            switch schedule.condition {
            case .always:
                break
            case .whenChanged:
                let changes = GitDiff.snapshot(directory: schedule.folder)
                if !changes.isRepository {
                    failed = "Not started: its folder is not a git repository, so it cannot be told whether anything changed"
                } else if changes.files.isEmpty && changes.submodules.isEmpty {
                    skipped = "Skipped: nothing is changed in the folder"
                }
            case .afterPull:
                let before = GitActions.head(in: schedule.folder)
                let unfinished = GitActions.unfinished(in: schedule.folder)
                if before == nil {
                    failed = "Not started: its folder is not a git repository with a commit, so there is nothing to pull"
                } else if let problem = GitActions.pull(in: schedule.folder) {
                    if unfinished == nil, GitActions.unfinished(in: schedule.folder) != nil {
                        // Nobody is there to resolve them: the folder is put
                        // back as it was, rather than left half merged.
                        let undone = GitActions.abortOperation(in: schedule.folder)
                        failed =
                            undone == nil
                            ? "Not started: the pull stopped on conflicts, and was undone. Pull by hand to resolve them"
                            : "Not started: the pull stopped on conflicts, and could not be undone: \(Self.firstLine(of: undone ?? "")). Resolve them, or abort it, in the folder"
                    } else {
                        failed = "Not started: the pull failed. \(Self.firstLine(of: problem))"
                    }
                } else if GitActions.head(in: schedule.folder) == before {
                    skipped = "Skipped: the pull brought nothing new"
                }
            }
            var directory = schedule.folder
            var worktree: String?
            if skipped == nil, failed == nil, schedule.inWorktree {
                do {
                    // A branch of its own, named after the schedule and the time.
                    let stamp = DateFormatter()
                    stamp.dateFormat = "yyyyMMdd-HHmm"
                    let name = schedule.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                        .split(separator: "-").joined(separator: "-")
                    let made = try GitWorktrees.create(in: schedule.folder, agent: schedule.agent, branch: "schedule/\(name.isEmpty ? "run" : name)-\(stamp.string(from: at))")
                    directory = made.directory
                    worktree = made.directory
                    // A worktree that is not ready is not started in, with
                    // nobody there to see what the agent would make of it.
                    // It is kept, to be looked at.
                    if let problem = GitWorktrees.checkOutSubmodules(in: made.directory) {
                        failed = "Not started: the submodules could not be checked out in its worktree. \(Self.firstLine(of: problem))"
                    }
                    if failed == nil {
                        // The agent would ask whether the new folder is trusted, with nobody there.
                        var there = schedule
                        there.folder = made.directory
                        do { try ScheduleRunner.trustFolder(of: there, home: home) } catch {
                            failed = "Not started: its worktree could not be trusted for \(schedule.agent). \(error.localizedDescription)"
                        }
                    }
                } catch {
                    failed = "Not started: its worktree could not be made. \(error.localizedDescription)"
                }
            }
            let before = failed == nil && skipped == nil ? GitActions.baseline(in: directory) : nil
            self?.queue.async {
                guard let self else { return }
                self.preparingRuns.remove(self.runKey(schedule.id, at))
                self.waitingRuns.removeAll { $0.schedule == schedule.id && $0.at == at }
                guard let index = self.schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
                if let failed {
                    self.notStarted(at, in: index, failed, worktree: worktree)
                } else if let skipped {
                    self.record(ScheduleRun(at: at, started: false, note: skipped), in: index)
                } else {
                    self.start(self.schedules[index], at: at, note: note, in: directory, worktree: worktree, before: before)
                }
                self.saveSchedules()
                self.startWaitingRuns()
            }
        }
    }

    /// A run that should have started and did not: recorded, and said in
    /// the banner of both apps, since nobody is watching a schedule.
    private func notStarted(_ at: Date, in index: Int, _ why: String, worktree: String? = nil) {
        var run = ScheduleRun(at: at, started: false, note: why)
        run.worktree = worktree
        record(run, in: index)
        report(PartFailure(part: .schedule, name: schedules[index].name, at: configuration.now(), restarted: false, reason: why + "."))
    }

    /// What git or a command said, in a line for a run's note.
    static func firstLine(of said: String) -> String {
        said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
    }

    /// Starts a run's agent in its folder, or in the worktree made for it.
    private func start(_ schedule: Schedule, at: Date, note: String, in directory: String, worktree: String?, before: GitActions.Baseline?) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var there = schedule
        there.folder = directory
        let (command, environment) = ScheduleRunner.launch(there)
        let request = CreateRequest(command: command, cwd: directory, title: schedule.name)
        guard let id = create(request, for: nil, run: there, environment: environment) else {
            notStarted(at, in: index, "Not started: the agent could not be started")
            return
        }
        var run = ScheduleRun(at: at, started: true, session: id, note: note)
        run.startedAt = configuration.now()
        run.worktree = worktree
        record(run, in: index)
        runStarts[id] = (schedule.id, at, directory, before)
        if before == nil {
            // Read beside the start: what the run changes is counted from here.
            workQueue.async { [weak self] in
                let found = GitActions.baseline(in: directory)
                self?.queue.async { if self?.runStarts[id]?.before == nil { self?.runStarts[id]?.before = found } }
            }
        }
    }

    /// Stops the runs that took longer than their schedule lets them (#47).
    private func endOverdueRuns(now: Date) {
        for schedule in schedules {
            guard let most = schedule.maxMinutes else { continue }
            for run in schedule.runs where run.started && run.ended == nil {
                // Its own session, and its time from when that started: not
                // the time it waited before.
                guard let id = run.session, let session = sessions[id], runStarts[id]?.schedule == schedule.id, runStops[id] == nil,
                    now.timeIntervalSince(run.startedAt ?? run.at) > Double(most) * 60
                else { continue }
                let why = "Stopped: it ran longer than \(most) min"
                runStops[id] = why
                report(PartFailure(part: .schedule, name: schedule.name, at: now, restarted: false, reason: why + "."))
                end(session)
            }
        }
    }

    /// Notes the runs whose agent is done, while their session stays open
    /// for a day: how they ended, what they printed and what they changed.
    private func noteFinishedRuns(now: Date) {
        for session in sessions.values where session.info.schedule != nil && runStarts[session.info.id] != nil {
            if !isGoing(session, now: now) { runEnded(session, outcome: "Done") }
        }
    }

    /// A run is over: when, how, what it printed and what it changed in git.
    private func runEnded(_ session: Session, outcome: String) {
        let id = session.info.id
        guard let start = runStarts.removeValue(forKey: id), let index = schedules.firstIndex(where: { $0.id == start.schedule }),
            let place = schedules[index].runs.firstIndex(where: { $0.session == id && $0.at == start.at })
        else { return }
        schedules[index].runs[place].ended = configuration.now()
        schedules[index].runs[place].outcome = runStops.removeValue(forKey: id) ?? outcome
        broadcastSchedules()
        saveSchedules()
        let file = runOutputFile(start.schedule, start.at)
        let mirror = session.mirror
        let workQueue = workQueue
        session.mirrorQueue.async { [weak self] in
            // The screen and what scrolled by, as text: read where the
            // session's screen is kept, and nothing more there.
            let text = mirror.text(linesAbove: 5000)
            // Writing it out and asking git are not the session's to wait for.
            workQueue.async {
                var kept = false
                if let file, !text.isEmpty {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    kept = (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil
                }
                let changes = start.before.flatMap { GitActions.changes(since: $0, in: start.directory) }
                self?.queue.async {
                    guard let self, let index = self.schedules.firstIndex(where: { $0.id == start.schedule }),
                        let place = self.schedules[index].runs.firstIndex(where: { $0.at == start.at && $0.started })
                    else { return }
                    self.schedules[index].runs[place].hasOutput = kept
                    self.schedules[index].runs[place].changes = changes
                    self.saveSchedules()
                    self.broadcastSchedules()
                    self.forgetOldRunOutput()
                }
            }
        }
    }

    /// What runs printed is kept as long as the runs themselves are.
    private func forgetOldRunOutput() {
        guard let folder = runOutputFile("x", Date())?.deletingLastPathComponent() else { return }
        let kept = Set(schedules.flatMap { schedule in schedule.runs.compactMap { self.runOutputFile(schedule.id, $0.at)?.lastPathComponent } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: What the apps ask of a schedule (#47)

    private func runNow(_ id: String, for client: Client) {
        guard let schedule = schedules.first(where: { $0.id == id }) else { return }
        let now = configuration.now()
        if !schedule.waitsForPrevious, !going(schedule.name, now: now).isEmpty {
            send(.error("“\(schedule.name)” is running: stop that run first, or have its runs wait for the one before."), to: client)
            return
        }
        waitingRuns.append((id, now, "Run now"))
        startWaitingRuns()
        saveSchedules()
        updateSleepGuard()
    }

    private func stopRun(of id: String, at: Date, for client: Client) {
        // One that still waits to start is taken off the list.
        // Named by when it came due, as the device has it: the same to the millisecond.
        if let waiting = waitingRuns.firstIndex(where: { $0.schedule == id && abs($0.at.timeIntervalSince(at)) < 0.001 }),
            !preparingRuns.contains(runKey(id, waitingRuns[waiting].at))
        {
            let due = waitingRuns.remove(at: waiting).at
            if let index = schedules.firstIndex(where: { $0.id == id }) { record(ScheduleRun(at: due, started: false, note: "Stopped by you before it started"), in: index) }
            return
        }
        guard let run = schedules.first(where: { $0.id == id })?.runs.first(where: { $0.cameDue(at: at) && $0.started }),
            let session = run.session.flatMap({ sessions[$0] })
        else {
            send(.error("That run is not going on any more."), to: client)
            return
        }
        runStops[session.info.id] = "Stopped by you"
        end(session)
    }

    private func sendRunOutput(of id: String, at: Date, to client: Client) {
        // The run's own moment, which its file is named by.
        let due = schedules.first { $0.id == id }?.runs.first { $0.cameDue(at: at) }?.at ?? at
        let file = runOutputFile(id, due)
        work(for: client, { file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }) { server, client, text in
            server.send(.scheduleRunOutput(id: id, at: at, text: text), to: client)
        }
    }

    private func duplicateSchedule(_ id: String) {
        guard let schedule = schedules.first(where: { $0.id == id }) else { return }
        schedules.append(schedule.duplicate(named: Set(schedules.map(\.name))))
        saveSchedules()
        broadcastSchedules()
    }

    private func pauseSchedules(_ paused: Bool) {
        guard paused != schedulesPaused else { return }
        schedulesPaused = paused
        let now = configuration.now()
        // From now on: what came due while they were held back is not run.
        schedulesChecked = now
        if paused { waitingRuns.removeAll { !preparingRuns.contains(runKey($0.schedule, $0.at)) } }
        for index in schedules.indices { schedules[index].nextRun = nextRun(of: schedules[index], after: now) }
        saveSchedules()
        for client in clients.values where client.authenticated { send(.schedulesPaused(paused), to: client) }
        broadcastSchedules()
        updateSleepGuard()
    }

    private func record(_ run: ScheduleRun, in index: Int) {
        schedules[index].runs = Array((schedules[index].runs + [run]).suffix(Schedule.runsKept))
        // Once is once.
        if case .once = schedules[index].when, run.started || !schedules[index].catchUp { schedules[index].enabled = false }
        broadcastSchedules()
    }

    /// A run's session whose agent has been done for a day is closed.
    private func closeFinishedRuns(now: Date) {
        for session in sessions.values where session.info.schedule != nil {
            guard !isGoing(session, now: now) else {
                runDoneAt[session.info.id] = nil
                continue
            }
            let since = runDoneAt[session.info.id] ?? now
            runDoneAt[session.info.id] = since
            guard now.timeIntervalSince(since) >= Self.keepRunFor else { continue }
            runDoneAt[session.info.id] = nil
            end(session)
        }
    }

    // MARK: History (#46)

    /// How many older conversations are given at a time.
    private static let historyPage = 200

    /// The conversations the user pinned and hid, by `Conversation.id`.
    private struct HistoryMarks: Codable {
        var pinned: Set<String> = []
        var hidden: Set<String> = []
    }
    private var historyMarks = HistoryMarks()
    private var historyMarksFile: URL? { configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("history.json") }

    private func loadHistoryMarks() {
        guard let file = historyMarksFile, let data = FileManager.default.contents(atPath: file.path) else { return }
        historyMarks = MessageCoding.decode(HistoryMarks.self, from: data) ?? HistoryMarks()
    }

    private func saveHistoryMarks() {
        guard let file = historyMarksFile else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MessageCoding.encode(historyMarks).write(to: file, options: .atomic)
    }

    private var historyMarksMessage: ServerMessage { .historyMarks(pinned: historyMarks.pinned.sorted(), hidden: historyMarks.hidden.sorted()) }

    private func broadcastHistoryMarks() {
        for client in clients.values where client.authenticated { send(historyMarksMessage, to: client) }
    }

    private func searchHistory(search: Int, in path: String?, query: String, titlesOnly: Bool = false, for client: Client) {
        // One at a time for each list, everywhere's and a folder's, which
        // the Mac shows side by side; a search for text is another's.
        let everywhere = path == nil
        client.historySearches.values.filter { $0.everywhere == everywhere }.forEach { $0.flag.stop() }
        let flag = SearchFlag()
        client.historySearches[search] = (flag, everywhere)
        let id = client.id
        let home = configuration.home
        workQueue.async { [weak self] in
            // Every conversation there is, not only the page that is listed.
            let all = path.map { AgentHistory.conversations(in: $0, home: home, limit: .max) } ?? AgentHistory.allConversations(home: home, limit: .max)
            AgentHistory.search(query, in: all, titlesOnly: titlesOnly, isCancelled: { flag.isStopped }) { hit in
                self?.queue.async {
                    guard let self, let client = self.clients[id], !flag.isStopped else { return }
                    self.send(.historyFound(search: search, hits: [hit]), to: client)
                }
            }
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                if client.historySearches[search]?.flag === flag { client.historySearches[search] = nil }
                self.send(.historySearchEnded(search: search), to: client)
            }
        }
    }

    private func deleteConversation(agent: String, sessionID: String, cwd: String, for client: Client) {
        // Its agent may be writing to it.
        if sessions.values.contains(where: { $0.info.agent == agent && $0.info.conversationID == sessionID }) {
            send(.error("A session is having that conversation: end it first."), to: client)
            return
        }
        let home = configuration.home
        let id = agent + ":" + sessionID
        work(
            for: client,
            { () -> String? in
                // Found again among the agents' own files, whatever the client says of where it is.
                guard let conversation = AgentHistory.conversation(agent: agent, sessionID: sessionID, cwd: cwd, home: home) else { return "That conversation is no longer there." }
                return AgentHistory.delete(conversation, home: home)
            }
        ) { server, client, problem in
            if let problem {
                server.send(.error(problem), to: client)
                return
            }
            server.historyMarks.pinned.remove(id)
            server.historyMarks.hidden.remove(id)
            server.saveHistoryMarks()
            server.broadcastHistoryMarks()
            for other in server.clients.values where other.authenticated { server.send(.conversationDeleted(id: id), to: other) }
        }
    }

    /// Several conversations deleted at once (#50): those named, or every
    /// one on the host when `ids` is nil. Never one that is pinned, nor one
    /// a session is having, whose agent may be writing to it; Antigravity's
    /// are refused by `AgentHistory.delete` and kept.
    private func deleteConversations(_ ids: [String]?, for client: Client) {
        let home = configuration.home
        let pinned = historyMarks.pinned
        let inSession = Set(sessions.values.compactMap { session in session.info.conversationID.map { (session.info.agent ?? "") + ":" + $0 } })
        let wanted = ids.map(Set.init)
        work(
            for: client,
            { () -> (deleted: [String], kept: Int) in
                let all = AgentHistory.allConversations(home: home, limit: .max)
                let named = wanted.map { wanted in all.filter { wanted.contains($0.id) } } ?? all
                var deleted: [String] = []
                var kept = 0
                for conversation in named {
                    // Pinned is kept, as the question says: unpinned first.
                    if pinned.contains(conversation.id) || inSession.contains(conversation.id) {
                        kept += 1
                    } else if AgentHistory.delete(conversation, home: home) == nil {
                        deleted.append(conversation.id)
                    } else {
                        kept += 1
                    }
                }
                return (deleted, kept)
            }
        ) { server, client, result in
            for id in result.deleted {
                server.historyMarks.pinned.remove(id)
                server.historyMarks.hidden.remove(id)
            }
            if !result.deleted.isEmpty {
                server.saveHistoryMarks()
                server.broadcastHistoryMarks()
            }
            for other in server.clients.values where other.authenticated {
                for id in result.deleted { server.send(.conversationDeleted(id: id), to: other) }
            }
            server.send(.conversationsDeleted(deleted: result.deleted.count, kept: result.kept), to: client)
        }
    }

    /// Written into the host's own folder, a file for each conversation,
    /// written over when it is asked for again.
    private func exportConversation(agent: String, sessionID: String, cwd: String, for client: Client) {
        guard let folder = configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("transcripts", isDirectory: true) else {
            send(.error("This host has nowhere to write the transcript."), to: client)
            return
        }
        let home = configuration.home
        let id = agent + ":" + sessionID
        let name = AgentDetector.known.first { $0.id == agent }?.name ?? agent
        work(
            for: client,
            { () -> String? in
                guard let conversation = AgentHistory.conversation(agent: agent, sessionID: sessionID, cwd: cwd, home: home) else { return nil }
                let file = folder.appendingPathComponent("\(agent)-\(sessionID).md")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try AgentHistory.details(of: conversation).markdown(agentName: name).write(to: file, atomically: true, encoding: .utf8)
                    return file.path
                } catch {
                    return nil
                }
            }
        ) { server, client, path in
            if let path {
                server.send(.conversationExported(id: id, path: path), to: client)
            } else {
                server.send(.error("The transcript could not be written."), to: client)
            }
        }
    }

    // MARK: Searching a folder's files (#45)

    /// The files of the folders that were searched by name, kept for a
    /// little while: a name is typed a letter at a time, and each letter
    /// is a search.
    private var fileLists: [String: (files: [String], at: Date)] = [:]
    private static let fileListKeptFor: TimeInterval = 30
    private static let fileListsKept = 6

    private func findFiles(search: Int, in path: String, query: String, for client: Client) {
        // Read again when the search is opened, and when what is kept is old.
        let kept = fileLists[path].flatMap { query.isEmpty || Date().timeIntervalSince($0.at) > Self.fileListKeptFor ? nil : $0.files }
        work(
            for: client,
            { () -> (all: [String]?, found: [String], among: Int) in
                let files = kept ?? FileSearch.files(in: path)
                return (kept == nil ? files : nil, FileSearch.rank(files, query: query), files.count)
            }
        ) { server, client, result in
            if let all = result.all {
                server.fileLists[path] = (all, Date())
                if server.fileLists.count > Self.fileListsKept, let oldest = server.fileLists.min(by: { $0.value.at < $1.value.at })?.key { server.fileLists[oldest] = nil }
            }
            server.send(.filesFound(search: search, files: result.found, among: result.among), to: client)
        }
    }

    private func findText(search: Int, in path: String, query: String, caseSensitive: Bool, for client: Client) {
        // One at a time for each client: what was typed before is not wanted any more.
        client.searches.values.forEach { $0.stop() }
        let flag = SearchFlag()
        client.searches[search] = flag
        let id = client.id
        workQueue.async { [weak self] in
            let ending = FileSearch.text(query, in: path, caseSensitive: caseSensitive, isCancelled: { flag.isStopped }) { matches in
                self?.queue.async {
                    guard let self, let client = self.clients[id], !flag.isStopped else { return }
                    self.send(.textFound(search: search, matches: matches), to: client)
                }
            }
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                if client.searches[search] === flag { client.searches[search] = nil }
                self.send(.searchEnded(search: search, truncated: ending.truncated, problem: ending.problem), to: client)
            }
        }
    }

    // MARK: Worktrees (#23, #33)

    /// Makes the worktree off the queue the sessions use, with its
    /// submodules, then starts the session there. What git ignores is not
    /// brought along: what the worktree needs is done in it by its user.
    private func createInWorktree(_ request: CreateRequest, branch: String?, from: String?, for client: Client) {
        let folder = request.cwd ?? configuration.home
        let agent = SessionSummaries.agent(forCommand: request.command) ?? "shell"
        let id = client.id
        workQueue.async { [weak self] in
            let made = Result { try GitWorktrees.create(in: folder, agent: agent, branch: branch, from: from) }
            var problem: String?
            if case .success(let worktree) = made { problem = GitWorktrees.checkOutSubmodules(in: worktree.directory) }
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                switch made {
                case .failure(let error):
                    self.send(.error("The worktree could not be made: \(error.localizedDescription)"), to: client)
                case .success(let worktree):
                    if let problem { self.send(.error(problem), to: client) }
                    var inWorktree = request
                    inWorktree.cwd = worktree.directory
                    if let created = self.create(inWorktree, for: client) {
                        self.sessions[created]?.info.branch = worktree.branch
                        self.broadcastSessions()
                    }
                    self.sendWorktrees(of: WorktreePath.project(of: folder) ?? folder, to: self.clients.values.filter(\.authenticated).map(\.id))
                }
            }
        }
    }

    private func sendWorktrees(of folder: String, to ids: [ClientID]) {
        let inUse = Set(sessions.values.map(\.info.cwd))
        workQueue.async { [weak self] in
            let list = GitWorktrees.list(folder: folder, inUse: inUse)
            self?.queue.async {
                guard let self else { return }
                for id in ids { if let client = self.clients[id] { self.send(.worktrees(folder: folder, list: list), to: client) } }
            }
        }
    }

    private func finishWorktree(folder: String, path: String, finish: WorktreeFinish, deleteBranch: Bool, for client: Client) {
        // Removing it under a running session would pull its folder away.
        if finish != .pullRequest, sessions.values.contains(where: { $0.info.cwd == path || $0.info.cwd.hasPrefix(path + "/") }) {
            send(.error("A session still runs in that worktree: end it first."), to: client)
            return
        }
        let id = client.id
        workQueue.async { [weak self] in
            let result = Result { try GitWorktrees.finish(folder: folder, path: path, finish: finish, deleteBranch: deleteBranch) }
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                switch result {
                case .success(let said): self.send(.worktreeFinished(folder: folder, path: path, said: said), to: client)
                case .failure(let error): self.send(.error(error.localizedDescription), to: client)
                }
                self.sendWorktrees(of: folder, to: self.clients.values.filter(\.authenticated).map(\.id))
            }
        }
    }

    // MARK: Whether someone is at the Mac (#22, #24)

    /// Five minutes without a key or the pointer, and no app in front: no
    /// one is at the Mac.
    static let idleBeforeAway: TimeInterval = 5 * 60
    private var macInUse = true
    /// A device, not this Mac's own app, was the last to be used: until the
    /// Mac app is used again, no one is at the Mac, whether its app is in
    /// front or its keyboard was touched for something else. A phone put
    /// away is still the one in use: what an agent says goes to it.
    private var usedOnDevice = false

    /// A client typed, took a session or said it was used.
    private func used(by client: Client) {
        let onDevice = client.identity != .local
        guard onDevice != usedOnDevice else { return }
        usedOnDevice = onDevice
        updateMacInUse()
    }

    /// Works it out again, and tells every client when it changed.
    private func updateMacInUse() {
        let front = clients.values.contains { $0.authenticated && $0.inFront }
        let idle = configuration.idleSeconds()
        let now = !usedOnDevice && (front || idle.map { $0 < Self.idleBeforeAway } ?? true)
        guard now != macInUse else { return }
        macInUse = now
        for client in clients.values where client.authenticated { send(.macInUse(now), to: client) }
    }

    private func broadcastFailures() {
        for client in clients.values where client.authenticated { send(.failures(failures), to: client) }
        updateActivity()
    }

    /// A part stopped without being asked to: kept until someone has seen
    /// it, and told to every client.
    private func report(_ failure: PartFailure) {
        failures.append(failure)
        failures = Array(failures.suffix(FailureLog.limit))
        saveFailures()
        broadcastFailures()
        // Into every Inbox, and a notification when it stopped work (#66).
        if let notice = notices.report(failure, now: configuration.now()) { tellEveryone(notice) }
    }

    private func saveFailures() {
        if let directory = configuration.stateDirectory { FailureLog.write(failures, in: directory) }
    }

    /// Why a session's program ended, when it did not end by itself or as
    /// asked: killed, or crashed. `code` is what the session reports, 128
    /// and the signal for a program a signal ended. A signal the user sends
    /// from the keyboard (Control C) or the host sends to close it is not
    /// such an end.
    static func unexpectedEnd(code: Int32) -> String? {
        guard code > 128 else { return nil }
        switch code - 128 {
        case SIGKILL: return "It was killed (SIGKILL), by macOS or by another program."
        case SIGSEGV: return "It crashed (SIGSEGV)."
        case SIGBUS: return "It crashed (SIGBUS)."
        case SIGILL: return "It crashed (SIGILL)."
        case SIGABRT: return "It crashed (SIGABRT)."
        case SIGTRAP: return "It crashed (SIGTRAP)."
        case SIGFPE: return "It crashed (SIGFPE)."
        default: return nil
        }
    }

    /// Sessions of Claude Code whose usage the status line relay could not
    /// save: reported once each, until it saves again.
    private func checkStatusLines() {
        for session in sessions.values where session.info.agent == "claude" {
            guard let file = usageFile(for: session.info.id) else { continue }
            let problem = StatusLineRelay.failureFile(for: file.path)
            guard let said = FileManager.default.contents(atPath: problem) else {
                session.usageFailureReported = false
                continue
            }
            guard !session.usageFailureReported else { continue }
            session.usageFailureReported = true
            let reason = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            report(
                PartFailure(
                    part: .statusLine, name: session.info.displayName, at: Date(), restarted: false,
                    reason: "Its usage band keeps the figures it had." + (reason.isEmpty ? "" : " " + reason)))
        }
    }

    private static func parameters(host: String, port: UInt16) -> NWParameters {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 4 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        return parameters
    }

    /// Blocks until the listener is ready. Must not be called on `queue`.
    private func listen(on host: String, port: UInt16) throws -> UInt16 {
        let listener = try makeListener(host: host, port: port)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error.localizedDescription; ready.signal()
            case .cancelled: failure = failure ?? "cancelled"; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { failure = "timed out" }
        if let failure {
            listener.cancel()
            throw StartError.listenerFailed("\(host):\(port): \(failure)")
        }
        listener.stateUpdateHandler = nil
        queue.sync { listeners[host] = listener }
        return listener.port?.rawValue ?? port
    }

    private func makeListener(host: String, port: UInt16) throws -> NWListener {
        let listener = try NWListener(using: Self.parameters(host: host, port: port))
        // Which listener took the connection tells whether it came from this Mac.
        let isLocal = host == "127.0.0.1"
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, isLocal: isLocal) }
        return listener
    }

    /// Keeps a listener on the current Tailscale address, following the
    /// interface as it comes up, goes away or changes address.
    private func syncTailscaleListener() {
        let address = Tailscale.ipv4Address()
        for (host, listener) in listeners where host != "127.0.0.1" && host != address {
            listener.cancel()
            listeners[host] = nil
        }
        guard let address, listeners[address] == nil,
            let listener = try? makeListener(host: address, port: boundPort)
        else { return }
        listeners[address] = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state, let self, let listener else { return }
            listener.cancel()
            if self.listeners[address] === listener { self.listeners[address] = nil }
        }
        listener.start(queue: queue)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, isLocal: Bool) {
        let client = Client(id: nextClientID, connection: connection, isLocal: isLocal)
        nextClientID += 1
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(from: client)

        // A client that never authenticates is not kept around.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self, let client, !client.authenticated else { return }
            self.close(client)
        }
    }

    private func receive(from client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            if error != nil {
                self.drop(client)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                if let data, let message = MessageCoding.decode(ClientMessage.self, from: data) {
                    self.handle(message, from: client)
                } else {
                    self.send(.error("malformed message"), to: client)
                }
            case .binary:
                if let data, let frame = DataFrame(decoding: data) { self.handle(frame, from: client) }
            case .close:
                self.drop(client)
                return
            default:
                break
            }
            if self.clients[client.id] != nil { self.receive(from: client) }
        }
    }

    private func close(_ client: Client) {
        client.connection.cancel()
        drop(client)
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        // Nobody is left to send what its searches find.
        client.searches.values.forEach { $0.stop() }
        client.historySearches.values.forEach { $0.flag.stop() }
        if client.inFront { updateMacInUse() }
        for id in client.attached {
            guard let session = sessions[id] else { continue }
            if session.arbiter.remove(client.id) { applySize(of: session) }
        }
        client.attached.removeAll()
        if case .device(let id) = client.identity {
            broadcastDevices()
            activityWentAway(id)
        }
        if browserProvider == client.id { setBrowserProvider(client, false) }
        // A device that goes no longer watches a page.
        for (tab, watchers) in browserWatchers where watchers.contains(client.id) { setWatching(tab, client.id, false, width: 0) }
    }

    private func send(_ message: ServerMessage, to client: Client) {
        let data = MessageCoding.encode(message)
        // Larger than a frame may be: in pieces, one after the other (#21).
        if let frames = MessageParts.frames(for: data, id: client.nextMessage) {
            client.nextMessage &+= 1
            for frame in frames { send(frame, to: client) }
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, completion: .idempotent)
    }

    private func send(_ frame: DataFrame, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        client.connection.send(content: frame.encoded(), contentContext: context, completion: .idempotent)
    }

    private func broadcastSessions() {
        updateSleepGuard()
        updateMarker()
        let list = sessions.values.map(\.info).sorted { $0.id < $1.id }
        for client in clients.values where client.authenticated {
            send(.sessions(list), to: client)
        }
        updateNotices(list)
        updateActivity()
    }

    // MARK: The Live Activity through Apple (#168)

    /// What the devices' Live Activities were last sent.
    private var activityStatus: AgentsStatus?
    private var activityPending = false
    private var activitySentAt = Date.distantPast
    /// iOS shows an activity as out of date when no update came for this
    /// long; while agents work, it is sent again before.
    static let activityRefresh: TimeInterval = 15 * 60

    /// The host's state changed, or may have: sent to the devices that are
    /// away, a burst of changes gathered into one update.
    private func updateActivity(force: Bool = false) {
        let status = AgentsStatus.of(sessions: sessions.values.map(\.info), failures: failures)
        guard force || status != activityStatus, !activityPending else { return }
        activityPending = true
        queue.asyncAfter(deadline: .now() + (force ? 0 : 3)) { [weak self] in self?.sendActivity() }
    }

    private func endActivityIfIdle() {
        guard let since = activityIdleSince, !activityEnded,
            configuration.now().timeIntervalSince(since) >= configuration.activityKeptIdle
        else { return }
        updateActivity(force: true)
    }

    /// Since when nothing has worked or waited; nil while something does.
    private var activityIdleSince: Date?
    /// The activities were ended, after `activityKeptIdle` with nothing.
    private var activityEnded = false
    /// The devices that were away when the activities ended, or went away
    /// since, and were sent the end (#192). One that was present then and
    /// goes away later is sent it when it goes: its own wait may not run
    /// out, since iOS suspends the app.
    private var activityEndSent: Set<String> = []

    private func sendActivity() {
        activityPending = false
        let status = AgentsStatus.of(sessions: sessions.values.map(\.info).sorted { $0.id < $1.id }, failures: failures)
        let now = configuration.now()
        if status.isActive {
            activityIdleSince = nil
            activityEnded = false
            activityEndSent = []
        } else if activityIdleSince == nil {
            activityIdleSince = now
            // Looked at again once it has been idle long enough to end.
            queue.asyncAfter(deadline: .now() + configuration.activityKeptIdle + 0.05) { [weak self] in
                self?.endActivityIfIdle()
            }
        }
        let decision = LiveActivityRule.decide(
            enabled: true, status: status, idleSince: activityIdleSince, now: now, keptIdle: configuration.activityKeptIdle)
        let end = decision != .show
        // Ended once; nothing more until something works again.
        if end && activityEnded { return }
        activityEnded = end
        activityStatus = status
        activitySentAt = now
        let mac = Host.current().localizedName ?? "Mac"
        for device in push.activityDevices where !presentDevices.contains(device) {
            if end { activityEndSent.insert(device) }
            if let item = push.activity(status, end: end, mac: mac, to: device) { sendPush(item) }
        }
    }

    /// A device went away, closed or in the background: when the
    /// activities were ended while it was present, it is sent the end now,
    /// once (#192).
    private func activityWentAway(_ device: String) {
        guard activityEnded, let status = activityStatus, !activityEndSent.contains(device), !presentDevices.contains(device),
            push.activityDevices.contains(device)
        else { return }
        activityEndSent.insert(device)
        if let item = push.activity(status, end: true, mac: Host.current().localizedName ?? "Mac", to: device) { sendPush(item) }
    }

    // MARK: Notices, on every device (#66)

    /// Who a client is told for: the Mac's own app, or a paired device. A
    /// client that does not say what it is (`agenttermd mcp`) is told none.
    private func noticeKey(of client: Client) -> String? {
        guard client.kind != nil, let identity = client.identity else { return nil }
        switch identity {
        case .local: return "local"
        case .device(let id): return id
        }
    }

    /// The devices connected with their app in front: the others are
    /// away, and told through Apple (#66). A device whose app went to the
    /// background is away though its connection may still be open (#190).
    private var presentDevices: Set<String> {
        Set(
            clients.values.compactMap { client -> String? in
                if case .device(let id) = client.identity, !client.inBackground { return id }
                return nil
            })
    }

    private func updateNotices(_ list: [SessionInfo]) {
        let (new, handled) = notices.update(sessions: list, now: configuration.now())
        for notice in new { tellEveryone(notice) }
        for notice in handled { tellHandled(notice) }
    }

    /// A new notice: to every client's Inbox at once; a notification on
    /// every device at once, or after `Notice.pushWait` when it waits and
    /// is still not handled nor read by then (the owner's decision,
    /// 2026-11-20).
    private func tellEveryone(_ notice: Notice) {
        for client in clients.values where client.authenticated && noticeKey(of: client) != nil {
            send(.notice(notice), to: client)
        }
        guard notice.alerts else { return }
        let wait = notice.pushWaits(macInUse: macInUse) ? configuration.pushWait : 0
        if wait <= 0 { return alert(notice.id) }
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.alert(notice.id) }
    }

    /// Its time has come: a notification on every device, over the
    /// connection or, for a device that is away, through Apple: only that
    /// way for one in the background (#190), so it is not shown twice.
    private func alert(_ id: UInt64) {
        guard let notice = notices.pending(id) else { return }
        notices.becameDue(id)
        var reached: Set<String> = []
        for client in clients.values where client.authenticated && !client.inBackground {
            guard let key = noticeKey(of: client), !reached.contains(key) else { continue }
            send(.noticeAlert(id: id), to: client)
            reached.insert(key)
        }
        for key in reached { notices.told(id, to: key, throughApple: false) }
        for device in Set(push.targets.keys).subtracting(presentDevices) {
            guard let item = push.push(notice, to: device) else { continue }
            notices.told(id, to: device, throughApple: true)
            sendPush(item)
        }
    }

    /// What came due that this client was not shown, here or through
    /// Apple: on connecting, and for a device back in front (#190).
    private func tellUntold(_ client: Client) {
        guard let key = noticeKey(of: client) else { return }
        for notice in notices.untold(to: key) {
            send(.noticeAlert(id: notice.id), to: client)
            notices.told(notice.id, to: key, throughApple: false)
        }
    }

    /// Read on a device: read on every one, and taken away from the
    /// devices that had it through Apple and are away.
    private func tellRead(_ ids: [UInt64]) {
        guard !ids.isEmpty else { return }
        for client in clients.values where client.authenticated && noticeKey(of: client) != nil {
            send(.noticesRead(ids: ids), to: client)
        }
        for id in ids {
            for device in notices.pushedTo(id) where !presentDevices.contains(device) {
                if let item = push.takeBack(id, from: device) { sendPush(item) }
            }
        }
    }

    /// Handled: taken away on every client, and from the devices that had
    /// it through Apple and are away.
    private func tellHandled(_ notice: Notice) {
        guard let handled = notice.handled else { return }
        for client in clients.values where client.authenticated && noticeKey(of: client) != nil {
            send(.noticeHandled(id: notice.id, handled: handled), to: client)
        }
        for device in notices.pushedTo(notice.id) where !presentDevices.contains(device) {
            if let item = push.takeBack(notice.id, from: device) { sendPush(item) }
        }
    }

    private func handleNotices(_ handled: [Notice]) {
        for notice in handled { tellHandled(notice) }
    }

    private func sendPush(_ item: PushCenter.Push) {
        push.send(item) { [weak self] reason, forgotten in
            self?.queue.async { self?.pushFailed(device: item.device, reason: reason, forgotten: forgotten) }
        }
    }

    /// Said in the banner of both apps (principle 3), once for each device:
    /// a newer failure takes the place of an earlier one not seen yet.
    private func pushFailed(device: String, reason: String, forgotten: Bool) {
        let name = registry.devices().first { $0.id == device }?.name ?? "a device"
        failures.removeAll { $0.part == .push && $0.name == name }
        let then = forgotten ? " It is no longer told through Apple until its app connects again." : ""
        report(PartFailure(part: .push, name: name, at: configuration.now(), restarted: false, reason: "The relay said: \(reason).\(then)"))
    }

    private func sendPushState(_ state: PushState, toDevice device: String) {
        for client in clients.values where client.identity == .device(id: device) { send(.pushState(state), to: client) }
    }

    // MARK: Messages

    private func handle(_ message: ClientMessage, from client: Client) {
        if case .hello(let token, let name, let kind) = message {
            client.name = name
            client.kind = kind
            guard let identity = registry.authenticate(token: token, isLocal: client.isLocal, kind: kind) else {
                // An agent's server that is refused leaves its agent without
                // shells, and nothing else would say so (#58).
                if name == Self.agentShellsClient, client.isLocal { setAgentShellsRefused(true) }
                refuse(client, "invalid token")
                return
            }
            if name == Self.agentShellsClient { setAgentShellsRefused(false) }
            admit(client, as: identity)
            return
        }
        if case .pair(let code, let device, let kind) = message {
            client.kind = kind
            guard !client.authenticated, let paired = registry.redeem(code: code, deviceName: device, kind: kind) else {
                refuse(client, "invalid pairing code")
                return
            }
            // The token is sent once, here. Only its hash is kept.
            send(.paired(device: paired.device.id, token: paired.token), to: client)
            admit(client, as: .device(id: paired.device.id))
            return
        }
        guard client.authenticated else {
            close(client)
            return
        }

        switch message {
        case .hello, .pair:
            break
        case .agentSetupStatus:
            if let report = lastAgentSetup { send(.agentSetup(report), to: client) }
            reportAgentSetup(to: client)
        case .runAgentSetup(let agent, let remove):
            // Into this Mac's agents' configuration, with AgentTerm's own
            // commands only: from its own app, or a paired device (the
            // owner's decision, #155, 2026-11-18). An agent's server is not
            // the user.
            guard client.isAdmin || client.isDevice else { return send(.error("Only the user's devices set this Mac's agents up."), to: client) }
            runAgentSetup(agent: agent, remove: remove)
        case .createPairingCode:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            let created = registry.createCode()
            send(.pairingCode(code: created.code, expiresAt: created.expiresAt), to: client)
        case .cancelPairingCode:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            registry.cancelCode()
        case .listDevices:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            send(.devices(deviceList()), to: client)
        case .revokeDevice(let id):
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            guard registry.revoke(id) else { return }
            push.unregister(device: id)
            notices.forget(device: id)
            for other in clients.values where other.identity == .device(id: id) { close(other) }
            broadcastDevices()
        case .list:
            send(.sessions(sessions.values.map(\.info).sorted { $0.id < $1.id }), to: client)
        case .agents(let refresh):
            requestAgents(for: client, refresh: refresh)
        case .create(let request):
            if let agent = request.openedBy {
                // A shell for an agent, opened by the user in its group
                // (#127): a shell only, for an agent that runs, in its folder.
                guard request.command == nil, let owner = sessions[agent], owner.info.agent != nil else {
                    send(.error("A shell can be opened only for an agent that runs."), to: client)
                    return
                }
                var shell = request
                shell.cwd = owner.info.cwd
                create(shell, for: client, openedBy: agent)
            } else {
                create(request, for: client)
            }
        case .agentShell(let id, let key, let request):
            handleAgentShell(id: id, key: key, request: request, from: client)
        case .agentBrowser(let id, let key, let request):
            handleAgentBrowser(id: id, key: key, request: request, from: client)
        case .browserProvider(let on):
            setBrowserProvider(client, on)
        case .browserReply(let id, let result):
            browserReplied(id, result, from: client)
        case .browserTabs(let list):
            // Only from the app that shows the browser.
            guard browserProvider == client.id else { return }
            browserTabsList = list
            for other in clients.values where other.authenticated { send(.browserTabs(list), to: other) }
        case .browserAsk(let id, let request):
            handleBrowserAsk(id: id, request: request, from: client)
        case .setAgentPrompt(let agent, let text):
            setAgentPrompt(agent, text)
        case .browserFrame(let tab, let jpeg, let width, let height):
            browserFramed(tab: tab, jpeg: jpeg, width: width, height: height, from: client)
        case .setShellSettings(let settings):
            if let program = settings.program, !FileManager.default.isExecutableFile(atPath: program) {
                return send(.error("\(program) is not a program that can be run: the shell was not changed."), to: client)
            }
            shellSettings = settings
            saveSettings()
            let message = shellSettingsMessage
            for other in clients.values where other.authenticated { send(message, to: other) }
        case .noticeSeen(let id, let state):
            // Only what the agent still says: what it said before is gone
            // from every device already.
            guard let session = sessions[id], session.info.state == state else { return }
            noticesSeen[id] = state
            // Shown on one device is shown: it leaves every one's Inbox (#67).
            if case .done = state, session.info.unseen == true {
                session.info.unseen = nil
                broadcastSessions()
            }
            for other in clients.values where other.authenticated && other !== client { send(.noticeSeen(session: id, state: state), to: other) }
            // Its notice is handled, on every device (#66).
            handleNotices(notices.handle(session: id, state: state, how: .opened, now: configuration.now()))
        case .answer(let id, let state, let text):
            // Only while the agent still asks what the reply answers: one
            // that comes later is not typed into what it asks next.
            guard let session = sessions[id], session.info.state == state else {
                send(.error(PushWords.movedOn), to: client)
                return
            }
            handleNotices(notices.handle(session: id, state: state, how: .answered, now: configuration.now()))
            // As a person types it, a step at a time: text and Return for a
            // prompt, the keys that pick a choice for a list of them (#55).
            // Whether the program takes a paste is known where its screen
            // is kept, after what it wrote before.
            let mirror = session.mirror
            let agent = session.info.agent
            session.mirrorQueue.async { [weak self, weak session] in
                let bracketedPaste = mirror.bracketedPasteMode
                self?.queue.async {
                    guard let self else { return }
                    for (index, step) in AgentAnswer.steps(agent: agent, state: state, text: text, bracketedPaste: bracketedPaste).enumerated() {
                        self.queue.asyncAfter(deadline: .now() + 0.15 * Double(index)) { [weak session] in session?.process.write(Data(step.utf8)) }
                    }
                }
            }
        case .appInFront(let front):
            guard client.isDevice else {
                client.inFront = front
                return updateMacInUse()
            }
            // A device's app: in the background it is away (#190).
            guard client.inBackground == front, case .device(let device) = client.identity else { return }
            client.inBackground = !front
            if front { tellUntold(client) } else { activityWentAway(device) }
        case .used:
            used(by: client)
        case .pushRegister(let registration):
            guard case .device(let id) = client.identity else { return send(.error("not allowed"), to: client) }
            push.register(registration, device: id) { [weak self] state in
                self?.queue.async { self?.sendPushState(state, toDevice: id) }
            }
        case .pushUnregister:
            guard case .device(let id) = client.identity else { return send(.error("not allowed"), to: client) }
            push.unregister(device: id)
            sendPushState(.off, toDevice: id)
        case .saveSchedule(let schedule):
            if let problem = save(schedule) { send(.error(problem), to: client) }
        case .runSchedule(let id):
            runNow(id, for: client)
        case .stopScheduleRun(let id, let at):
            stopRun(of: id, at: at, for: client)
        case .scheduleRunOutput(let id, let at):
            sendRunOutput(of: id, at: at, to: client)
        case .duplicateSchedule(let id):
            duplicateSchedule(id)
        case .pauseSchedules(let paused):
            pauseSchedules(paused)
        case .createInWorktree(let request, let branch, let from):
            createInWorktree(request, branch: branch, from: from, for: client)
        case .listWorktrees(let folder):
            sendWorktrees(of: folder, to: [client.id])
        case .finishWorktree(let folder, let path, let finish, let deleteBranch):
            finishWorktree(folder: folder, path: path, finish: finish, deleteBranch: deleteBranch, for: client)
        case .removeSchedule(let id):
            schedules.removeAll { $0.id == id }
            schedulesFrom[id] = nil
            saveSchedules()
            broadcastSchedules()
        case .attach(let id, let size, let have, let history):
            guard let session = sessions[id] else {
                send(.error("no such session"), to: client)
                return
            }
            attach(client, to: session, size: size, have: have, history: history)
        case .detach(let id):
            client.attached.remove(id)
            if let session = sessions[id], session.arbiter.remove(client.id) { applySize(of: session) }
        case .resize(let id, let size):
            guard let session = sessions[id], client.attached.contains(id) else { return }
            if session.arbiter.update(client.id, size: size) { applySize(of: session) }
        case .takeControl(let id, let size):
            guard let session = sessions[id], client.attached.contains(id) else { return }
            let changed = session.arbiter.takeControl(client.id, size: size)
            if changed { applySize(of: session) } else { announceSize(of: session) }
            used(by: client)
        case .kill(let id):
            guard let session = sessions[id] else { return }
            endWithWhatItOpened(session)
        case .setStartAtLogin(let wanted):
            guard let item = configuration.loginItem else { return }
            startAtLoginChosen = true
            saveSettings()
            do {
                if wanted { try item.turnOn() } else { try item.turnOff() }
            } catch {
                send(.error("Could not \(wanted ? "set the host to start" : "stop the host from starting") at login: \(error.localizedDescription)"), to: client)
            }
            // To everyone, and as it is now: also when it could not be changed.
            startAtLoginSaid = item.isOn
            for other in clients.values where other.authenticated { send(.startAtLogin(item.isOn), to: other) }
        case .setKeepAwake(let wanted):
            // Nothing to change: the asker is told what is kept (as below).
            guard wanted != keepAwake else { return send(.keepAwake(keepAwake), to: client) }
            keepAwake = wanted
            // A switch-on lasts as long as the options say.
            keepAwakeOptions.until = wanted ? keepAwakeOptions.minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } : nil
            saveSettings()
            updateSleepGuard()
            scheduleKeepAwakeEnd()
            broadcastKeepAwake()
        case .setKeepAwakeOptions(var options):
            options.minutes = options.minutes.flatMap { $0 > 0 ? min($0, 7 * 24 * 60) : nil }
            // When the hold ends is the host's to say: from now when the
            // length changed, as it was otherwise.
            if !keepAwake {
                options.until = nil
            } else if options.minutes != keepAwakeOptions.minutes {
                options.until = options.minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) }
            } else {
                options.until = keepAwakeOptions.until
            }
            guard options != keepAwakeOptions else { return send(.keepAwakeOptions(keepAwakeOptions), to: client) }
            keepAwakeOptions = options
            saveSettings()
            updateSleepGuard()
            scheduleKeepAwakeEnd()
            broadcastKeepAwake()
        case .setCommitWriter(var settings):
            // An agent the host does not know cannot be run.
            if let agent = settings.agent, !AgentDetector.known.contains(where: { $0.id == agent }) { settings.agent = nil }
            if settings.model?.trimmingCharacters(in: .whitespaces).isEmpty == true { settings.model = nil }
            if settings.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { settings.prompt = nil }
            // What it asked for may be tidied into what is kept already: the
            // asker is told what is kept, rather than left with its own copy.
            guard settings != commitWriter else { return send(.commitWriter(commitWriter), to: client) }
            commitWriter = settings
            saveSettings()
            for other in clients.values where other.authenticated { send(.commitWriter(settings), to: other) }
        case .setDisplaySettings(let wanted):
            let settings = wanted.checked
            guard settings != displaySettings else {
                if settings != wanted { send(.displaySettings(displaySettings), to: client) }
                return
            }
            displaySettings = settings
            saveSettings()
            // The sender has it already, unless it was tidied.
            for other in clients.values where other.authenticated && (other !== client || settings != wanted) { send(.displaySettings(settings), to: other) }
        case .writeCommitMessage(let path):
            writeCommitMessage(in: path, for: client)
        case .cancelCommitMessage(let path):
            commitRuns[path]?.cancel()
        case .sshHosts:
            let home = configuration.sshHome ?? configuration.home
            work(for: client, { SSHConfig.hosts(home: home) }) { server, client, hosts in
                server.send(.sshHosts(hosts), to: client)
            }
        case .connectSSH(let host, let size):
            let home = configuration.sshHome ?? configuration.home
            // The name goes on a command line, so only one the Mac's own
            // configuration lists, and plain at that, is taken.
            work(for: client, { SSHConfig.isSafeHost(host) && SSHConfig.hosts(home: home).contains(host) }) { server, client, known in
                guard known else { return server.send(.error("\(host) is not a host in this Mac's SSH configuration."), to: client) }
                server.create(CreateRequest(command: "ssh \(host)", cwd: server.configuration.home, title: host, size: size), for: client)
            }
        case .setTabLayout(let layout):
            guard layout != tabLayout else { return }
            tabLayout = layout
            if let file = tabLayoutFile, let data = try? JSONEncoder().encode(layout) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            // The sender has it already.
            for other in clients.values where other.authenticated && other !== client {
                send(.tabLayout(layout), to: other)
            }
        case .moveFolder(let path, let before):
            guard path != before, let from = folders.firstIndex(of: path) else { return }
            var moved = folders
            moved.remove(at: from)
            moved.insert(path, at: before.flatMap { moved.firstIndex(of: $0) } ?? moved.count)
            guard moved != folders else { return }
            folders = moved
            foldersChanged()
        case .addFolder(let path):
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue else {
                send(.error("not a folder: \(path)"), to: client)
                return
            }
            guard !folders.contains(standardized) else { return }
            folders.append(standardized)
            foldersChanged()
        case .removeFolder(let path):
            guard folders.contains(path) else { return }
            folders.removeAll { $0 == path }
            foldersChanged()
        case .diff(let path):
            // Asked again and again while a client shows it: worked out again
            // only when the folder's files changed since (#21).
            if let cached = diffCache[path], diffWatches[path] != nil, !diffDirty.contains(path) {
                send(.diff(path: path, snapshot: cached.snapshot.withoutPatches), to: client)
                return
            }
            watchForDiff(path)
            diffDirty.remove(path)
            work(for: client, { GitDiff.snapshot(directory: path) }) { server, client, snapshot in
                server.diffCache[path] = (snapshot, Date())
                server.send(.diff(path: path, snapshot: snapshot.withoutPatches), to: client)
            }
        case .diffFile(let path, let file, let staged):
            // From the last look while it is recent, as before: a diff asked for
            // right after the list is answered in turn, a file that is not
            // there with nothing, which can only be told apart by its order.
            if let cached = diffCache[path], Date().timeIntervalSince(cached.at) < 20 || (diffWatches[path] != nil && !diffDirty.contains(path)) {
                send(.diffFile(path: path, file: cached.snapshot.files.first { $0.path == file && $0.isStaged == staged }), to: client)
                return
            }
            work(for: client, { GitDiff.snapshot(directory: path) }) { server, client, snapshot in
                server.diffCache[path] = (snapshot, Date())
                server.send(.diffFile(path: path, file: snapshot.files.first { $0.path == file && $0.isStaged == staged }), to: client)
            }
        case .accountUsage(let refresh):
            // Asking again is allowed, but not in a tight loop.
            if refresh { refreshAccountUsage(olderThan: 15) }
            send(.accountUsage(accountUsageList()), to: client)
        case .findFiles(let search, let path, let query):
            findFiles(search: search, in: path, query: query, for: client)
        case .findText(let search, let path, let query, let caseSensitive):
            findText(search: search, in: path, query: query, caseSensitive: caseSensitive, for: client)
        case .stopSearch(let search):
            client.searches[search]?.stop()
        case .files(let path):
            work(for: client, { FileBrowser.list(path) }) { server, client, entries in
                server.send(.files(path: path, entries: entries), to: client)
            }
        case .readFile(let path, let anyway):
            work(
                for: client,
                { () -> (FileContent, Data?) in
                    let content = FileBrowser.read(path, anyway: anyway == true)
                    guard content == .image else { return (content, nil) }
                    // The client cannot read the Mac's disk, so the picture travels.
                    if let data = FileBrowser.imageData(path) { return (.image, data) }
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                    return (.tooLarge(bytes: size), nil)
                }
            ) { server, client, result in
                server.send(.file(path: path, content: result.0, data: result.1), to: client)
            }
        case .writeFile(let path, let text):
            files(
                for: client, in: nil,
                {
                    try FileBrowser.write(text, to: path); return .fileSaved(path: path)
                })
        case .createFile(let directory, let name, let isDirectory):
            files(for: client, in: directory) {
                let path = isDirectory ? try FileBrowser.createFolder(named: name, in: directory) : try FileBrowser.createFile(named: name, in: directory)
                return .fileCreated(path: path, isDirectory: isDirectory)
            }
        case .renameFile(let path, let name):
            files(for: client, in: (path as NSString).deletingLastPathComponent) {
                try FileBrowser.rename(path, to: name); return nil
            }
        case .trashFile(let path):
            files(for: client, in: (path as NSString).deletingLastPathComponent) {
                try FileBrowser.trash(path); return nil
            }
        case .gitStage(let path, let files):
            git(for: client, in: path) { GitActions.stage(files, in: path) }
        case .gitUnstage(let path, let files):
            git(for: client, in: path) { GitActions.unstage(files, in: path) }
        case .gitDiscard(let path, let files):
            git(for: client, in: path) { GitActions.discard(files, in: path) }
        case .gitResolve(let path, let file, let take):
            git(for: client, in: path) {
                guard let resolution = GitActions.Resolution(rawValue: take) else { return "This host does not know how to resolve a file “\(take)”." }
                return GitActions.resolve(file, as: resolution, in: path)
            }
        case .gitContinue(let path):
            git(for: client, in: path, sync: true) { GitActions.continueOperation(in: path) }
        case .gitAbort(let path):
            git(for: client, in: path, sync: true) { GitActions.abortOperation(in: path) }
        case .gitApplyPart(let path, let file, let patch, let use):
            git(for: client, in: path) {
                guard let use = PatchParts.Use(rawValue: use) else { return "This host does not know what “\(use)” is to do with a part of a file." }
                return GitActions.applyPart(patch, use: use, file: file, in: path)
            }
        case .gitLastCommit(let path):
            work(for: client, { GitActions.lastCommit(in: path) }) { server, client, last in server.send(.gitLastCommit(path: path, last: last), to: client) }
        case .gitAmend(let path, let message):
            git(for: client, in: path, sync: true) { GitActions.amend(message: message, in: path) }
        case .gitUndoCommit(let path):
            git(for: client, in: path, sync: true) { GitActions.undoLastCommit(in: path) }
        case .gitStashes(let path):
            work(for: client, { GitActions.stashes(in: path) }) { server, client, list in server.send(.gitStashes(path: path, stashes: list), to: client) }
        case .gitStash(let path, let message, let untracked):
            git(for: client, in: path, stashes: true) { GitActions.stash(message: message, untracked: untracked, in: path) }
        case .gitStashShow(let path, let hash):
            work(for: client, { GitActions.stashFiles(hash, in: path) }) { server, client, files in
                server.send(.gitStashShow(path: path, hash: hash, files: files), to: client)
            }
        case .gitStashApply(let path, let hash, let pop):
            git(for: client, in: path, stashes: true) { GitActions.applyStash(hash, pop: pop, in: path) }
        case .gitStashDrop(let path, let hash):
            git(for: client, in: path, stashes: true) { GitActions.dropStash(hash, in: path) }
        case .gitLog(let path, let branch, let skip, let limit):
            // No more at once than a list shows a page of.
            let count = min(max(limit, 1), 200)
            work(for: client, { GitActions.log(in: path, branch: branch, skip: skip, limit: count) }) { server, client, found in
                server.send(.gitLog(path: path, branch: branch, skip: skip, commits: found.commits, more: found.more), to: client)
            }
        case .gitShow(let path, let hash):
            work(for: client, { GitActions.show(hash, in: path) }) { server, client, details in
                server.send(.gitShow(path: path, hash: hash, details: details), to: client)
            }
        case .gitRevert(let path, let hash):
            git(for: client, in: path, sync: true) { GitActions.revert(hash, in: path) }
        case .gitCherryPick(let path, let hash):
            git(for: client, in: path, sync: true) { GitActions.cherryPick(hash, in: path) }
        case .gitBranches(let path):
            work(for: client, { GitActions.branches(in: path) }) { server, client, list in server.send(.gitBranches(path: path, branches: list), to: client) }
        case .gitSwitch(let path, let branch):
            git(for: client, in: path, branches: true) { GitActions.switchTo(branch, in: path) }
        case .gitCreateBranch(let path, let name, let from, let checkout):
            git(for: client, in: path, branches: true) { GitActions.createBranch(name, from: from, checkout: checkout, in: path) }
        case .gitRenameBranch(let path, let from, let to):
            git(for: client, in: path, branches: true) { GitActions.renameBranch(from, to: to, in: path) }
        case .gitDeleteBranch(let path, let name, let force):
            git(for: client, in: path, branches: true) { GitActions.deleteBranch(name, force: force, in: path) }
        case .gitCommit(let path, let message):
            git(for: client, in: path) { GitActions.commit(message: message, in: path) }
        case .gitPush(let path, let force, let lease):
            git(for: client, in: path, sync: true) { GitActions.push(in: path, force: force ?? false, lease: lease) }
        case .gitPull(let path, let mode):
            git(for: client, in: path, sync: true) { GitActions.pull(in: path, mode: mode.flatMap(GitActions.PullMode.init(rawValue:)) ?? .asSetUp) }
        case .gitFetch(let path, let automatic):
            work(
                for: client,
                { () -> (String?, DiffSnapshot) in
                    let problem = GitActions.fetch(in: path)
                    return (problem, GitDiff.snapshot(directory: path))
                }
            ) { server, client, result in
                server.diffCache[path] = (result.1, Date())
                server.send(.gitFetched(path: path, problem: result.0, automatic: automatic), to: client)
                server.send(.diff(path: path, snapshot: result.1.withoutPatches), to: client)
            }
        case .gitForcePushPreview(let path):
            work(for: client, { GitActions.forcePushLoses(in: path) }) { server, client, found in
                server.send(.gitForcePushPreview(path: path, upstream: found?.upstream, loses: found?.commits ?? [], at: found?.at), to: client)
            }
        case .history(let path):
            let home = configuration.home
            work(
                for: client,
                {
                    path.map { AgentHistory.conversations(in: $0, home: home) } ?? AgentHistory.allConversations(home: home)
                }
            ) { server, client, conversations in
                server.send(.history(path: path, conversations: conversations), to: client)
            }
        case .historyOlder(let path, let before):
            let home = configuration.home
            work(
                for: client,
                { () -> [Conversation] in
                    let all = path.map { AgentHistory.conversations(in: $0, home: home, limit: .max) } ?? AgentHistory.allConversations(home: home, limit: .max)
                    return all.filter { $0.updatedAt < before }
                }
            ) { server, client, older in
                server.send(.historyOlder(path: path, conversations: Array(older.prefix(Self.historyPage)), more: older.count > Self.historyPage), to: client)
            }
        case .readConversation(let agent, let sessionID, let cwd):
            let home = configuration.home
            let id = agent + ":" + sessionID
            work(for: client, { AgentHistory.conversation(agent: agent, sessionID: sessionID, cwd: cwd, home: home).map(AgentHistory.details(of:)) }) {
                server, client, details in
                server.send(.conversationRead(id: id, details: details), to: client)
            }
        case .searchHistory(let search, let path, let query, let titlesOnly):
            searchHistory(search: search, in: path, query: query, titlesOnly: titlesOnly ?? false, for: client)
        case .markConversation(let id, let pinned, let hidden):
            if let pinned { if pinned { historyMarks.pinned.insert(id) } else { historyMarks.pinned.remove(id) } }
            if let hidden { if hidden { historyMarks.hidden.insert(id) } else { historyMarks.hidden.remove(id) } }
            saveHistoryMarks()
            broadcastHistoryMarks()
        case .deleteConversation(let agent, let sessionID, let cwd):
            deleteConversation(agent: agent, sessionID: sessionID, cwd: cwd, for: client)
        case .deleteConversations(let ids):
            deleteConversations(ids, for: client)
        case .exportConversation(let agent, let sessionID, let cwd):
            exportConversation(agent: agent, sessionID: sessionID, cwd: cwd, for: client)
        case .resume(let agent, let sessionID, let cwd, let size):
            guard AgentDetector.known.contains(where: { $0.id == agent }), AgentHistory.isSafeIdentifier(sessionID) else {
                send(.error("cannot resume that conversation"), to: client)
                return
            }
            let conversation = Conversation(agent: agent, sessionID: sessionID, title: "", updatedAt: Date(), cwd: cwd)
            // A resumed session's conversation is known from the start.
            create(CreateRequest(command: conversation.resumeCommand, cwd: cwd, title: Handoff.name(of: agent), size: size), for: client, conversationID: sessionID)
        case .handoffPlan(let agent):
            guard AgentDetector.known.contains(where: { $0.id == agent }) else {
                send(.error("cannot hand off from that agent"), to: client)
                return
            }
            // Plans nobody used are dropped after an hour.
            handoffPlans = handoffPlans.filter { Date().timeIntervalSince($0.value.at) < 3600 }
            let plan = Handoff.plan(for: Conversation(agent: agent, sessionID: "", title: "", updatedAt: Date(), cwd: ""))
            let id = UUID().uuidString
            handoffPlans[id] = (plan, Date())
            send(.handoffPlan(id: id, prompt: plan.prompt), to: client)
        case .handoff(let agent, let sessionID, let cwd, let target, let planID, let prompt, let note, let size, let folder, let worktree):
            let home = configuration.home
            // Only a plan this host made is honored, so a client names a
            // plan and never a path to write to.
            let plan = planID.flatMap { handoffPlans.removeValue(forKey: $0) }?.plan
            work(
                for: client,
                { () -> Result<(prepared: Handoff.Prepared, branch: String?, problem: String?), Error> in
                    // Looked up again here: the conversation's files are on this
                    // machine, and what the client holds is only a description.
                    let found =
                        AgentHistory.conversations(in: cwd, home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                        ?? AgentHistory.allConversations(home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                    guard let found else { return .failure(HandoffRequestError.notFound) }
                    return Result {
                        // In a new worktree (#150): made first, and said when it cannot be.
                        if let worktree {
                            let made = try Handoff.prepareInNewWorktree(
                                found, to: target, worktree: worktree, plan: plan, prompt: prompt, note: note, of: folder)
                            return (made.prepared, made.branch, made.problem)
                        }
                        return (try Handoff.prepare(found, to: target, plan: plan, prompt: prompt, note: note, in: folder), nil, nil)
                    }
                }
            ) { server, client, result in
                switch result {
                case .success(let made):
                    if let problem = made.problem { server.send(.error(problem), to: client) }
                    let request = CreateRequest(command: made.prepared.command, cwd: made.prepared.directory, title: Handoff.name(of: target), size: size)
                    if let created = server.create(request, for: client), let branch = made.branch {
                        server.sessions[created]?.info.branch = branch
                        server.broadcastSessions()
                    }
                    if made.branch != nil, let project = WorktreePath.project(of: made.prepared.directory) {
                        server.sendWorktrees(of: project, to: server.clients.values.filter(\.authenticated).map(\.id))
                    }
                case .failure(let error as GitWorktrees.Failure):
                    server.send(.error("The worktree could not be made: \(error.localizedDescription)"), to: client)
                case .failure(let error):
                    server.send(.error("\(error)"), to: client)
                }
            }
        case .listDirectory(let path):
            let home = configuration.home
            work(for: client, { Self.listing(of: path ?? home, home: home) }) { server, client, listing in
                if let listing {
                    server.send(.directory(listing), to: client)
                } else {
                    server.send(.error("cannot open that folder"), to: client)
                }
            }
        case .dismissFailure(let id):
            // Seen on one device is seen: it goes from every one.
            guard let index = failures.firstIndex(where: { $0.id == id }) else { return }
            failures.remove(at: index)
            saveFailures()
            broadcastFailures()
            handleNotices(notices.handle(failure: id, now: configuration.now()))
        case .liveActivity(let token, let start):
            guard case .device(let id) = client.identity else { return send(.error("not allowed"), to: client) }
            push.setActivity(device: id, token: token, start: start)
        case .handleNotice(let id, let how):
            if let notice = notices.handle(id, how: how, now: configuration.now()) { tellHandled(notice) }
        case .readNotices(let ids):
            tellRead(notices.read(ids))
        }
    }

    /// Runs a git change, then answers with the folder's changes as they are
    /// now, so the client's list is right whether it worked or not. A push
    /// or a pull (`sync`) takes long enough for other answers about the
    /// folder to come in between, so its end is said in so many words.
    ///
    /// A change to the branches (`branches`) is answered with them as well,
    /// before the changes, whose branch may be another now.
    /// One to the stash (`stashes`) likewise.
    private func git(
        for client: Client, in path: String, sync: Bool = false, branches: Bool = false, stashes: Bool = false, _ action: @escaping () -> String?
    ) {
        work(
            for: client,
            { () -> (String?, DiffSnapshot, [BranchInfo]?, [StashInfo]?) in
                let problem = action()
                return (
                    problem, GitDiff.snapshot(directory: path), branches ? GitActions.branches(in: path) : nil, stashes ? GitActions.stashes(in: path) : nil
                )
            }
        ) { server, client, result in
            server.diffCache[path] = (result.1, Date())
            // What was done in a submodule changes what the folders around
            // it show of it (#44): theirs are read again when asked for.
            for outer in Set(server.diffCache.keys).union(server.diffWatches.keys) where path.hasPrefix(outer + "/") {
                server.diffCache[outer] = nil
                server.diffDirty.insert(outer)
            }
            if let problem = result.0 { server.send(.error(problem), to: client) }
            if let list = result.2 { server.send(.gitBranches(path: path, branches: list), to: client) }
            if let list = result.3 { server.send(.gitStashes(path: path, stashes: list), to: client) }
            server.send(.diff(path: path, snapshot: result.1.withoutPatches), to: client)
            if sync { server.send(.gitSynced(path: path), to: client) }
        }
    }

    /// Runs a change to the files, answers with what it returns or with the
    /// problem, then with the folder's listing as it is now.
    private func files(for client: Client, in directory: String?, _ action: @escaping () throws -> ServerMessage?) {
        work(
            for: client,
            { () -> (ServerMessage?, [FileEntry]?) in
                var answer: ServerMessage?
                do { answer = try action() } catch { answer = .error("\(error)") }
                return (answer, directory.map { FileBrowser.list($0) })
            }
        ) { server, client, result in
            if let answer = result.0 { server.send(answer, to: client) }
            if let directory, let entries = result.1 { server.send(.files(path: directory, entries: entries), to: client) }
        }
    }

    /// Has an agent write the commit message for what is staged in a
    /// folder, and answers with it. One run per folder: asking again
    /// replaces the run under way.
    private func writeCommitMessage(in path: String, for client: Client) {
        commitRuns.removeValue(forKey: path)?.cancel()
        let run = CommitWriter.Run()
        commitRuns[path] = run
        let settings = commitWriter
        let known = agents
        let detect = configuration.detectAgents
        let scratch = commitWriterDirectory
        let id = client.id
        workQueue.async { [weak self] in
            let installed = known ?? detect()
            let result = CommitWriter.write(in: path, settings: settings, agents: installed, scratch: scratch, run: run)
            self?.queue.async {
                guard let self else { return }
                if self.agents == nil { self.agents = installed }
                if self.commitRuns[path] === run { self.commitRuns[path] = nil }
                guard let client = self.clients[id] else { return }
                switch result {
                case .success(let message):
                    self.send(.commitMessage(path: path, message: message), to: client)
                case .failure(let failure):
                    // Stopping is what was asked for, not a problem to report.
                    if failure != .cancelled { self.send(.error("\(failure)"), to: client) }
                    self.send(.commitMessage(path: path, message: nil), to: client)
                }
            }
        }
    }

    private enum HandoffRequestError: Error, CustomStringConvertible {
        case notFound
        var description: String { "That conversation is no longer on this Mac." }
    }

    /// Runs `job` off the server queue and hands its result back on it, if
    /// the client that asked is still connected.
    private func work<T>(for client: Client, _ job: @escaping () -> T, then: @escaping (HostServer, Client, T) -> Void) {
        let id = client.id
        workQueue.async { [weak self] in
            let result = job()
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                then(self, client, result)
            }
        }
    }

    /// The folders inside `path`, hidden ones left out.
    static func listing(of path: String, home: String) -> DirectoryListing? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        else { return nil }
        let folders =
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let parent = url.path == "/" ? nil : url.deletingLastPathComponent().path
        let standardHome = URL(fileURLWithPath: home).standardizedFileURL.path
        return DirectoryListing(path: url.path, parent: parent, folders: folders, isHome: url.path == standardHome)
    }

    /// Looks up what each agent session is about and tells the clients when
    /// a session's name changed. Reads the agents' files, so off this queue.
    /// Asks the services of the agents that have a session, or a schedule
    /// waiting for their limit to start over (which has to know when, also
    /// after the host started again), where the last answer is older than
    /// `age`.
    private func refreshAccountUsage(olderThan age: TimeInterval) {
        guard let fetch = configuration.fetchAccountUsage else { return }
        let now = Date()
        let waiting = schedules.filter { schedule in
            guard schedule.enabled, case .limitReset = schedule.when else { return false }
            return true
        }.map(\.agent)
        for agent in Set(sessions.values.compactMap(\.info.agent) + waiting) where !accountAsking.contains(agent) {
            if let asked = accountAsked[agent], now.timeIntervalSince(asked) < age { continue }
            accountAsking.insert(agent)
            accountAsked[agent] = now
            workQueue.async { [weak self] in
                let answer = fetch(agent)
                self?.queue.async {
                    guard let self else { return }
                    self.accountAsking.remove(agent)
                    guard var answer else { return }
                    // An answer that failed keeps the figures already known,
                    // with their age, and says what went wrong.
                    if answer.problem != nil, answer.groups.isEmpty, let known = self.accountUsage[agent], !known.groups.isEmpty {
                        var kept = known
                        kept.problem = answer.problem
                        answer = kept
                    }
                    guard self.accountUsage[agent] != answer else { return }
                    self.accountUsage[agent] = answer
                    let message = ServerMessage.accountUsage(self.accountUsageList())
                    for client in self.clients.values where client.identity != nil { self.send(message, to: client) }
                }
            }
        }
    }

    private func accountUsageList() -> [AccountUsage] {
        accountUsage.values.sorted { $0.agent < $1.agent }
    }

    private func usageFile(for id: SessionID) -> URL? {
        configuration.usageDirectory?.appendingPathComponent("session-\(id).json")
    }

    /// Where the hooks write, apart from the usage files: Claude Code's
    /// status line writes those several times a second, and the watch of
    /// the hooks' folder is not to wake for it.
    private var eventsDirectory: URL? { configuration.usageDirectory?.appendingPathComponent("events", isDirectory: true) }

    /// What a session's agent's hooks last said (`AgentHooks`).
    private func eventsFile(for id: SessionID) -> URL? {
        eventsDirectory?.appendingPathComponent("session-\(id).json")
    }

    /// Watches the folder the hooks write in, so that a state is known when
    /// it begins rather than at the next refresh.
    private var eventsWatch: DispatchSourceFileSystemObject?

    private func watchEvents() {
        guard let directory = eventsDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.readEvents() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        eventsWatch = source
    }

    /// Reads what each session's hooks said since the last look, and tells
    /// every client of a state that changed.
    private func readEvents() {
        var changed = false
        for session in sessions.values {
            guard let file = eventsFile(for: session.info.id), let data = FileManager.default.contents(atPath: file.path),
                data != session.lastEvent
            else { continue }
            session.lastEvent = data
            guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let agent = record["agent"] as? String, let event = record["event"] as? String
            else { continue }
            // Its hooks are heard (#129); in a shell, the agent typed in it.
            if heard(.hooks, from: session, agent: agent) { changed = true }
            let at = (record["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            // Whatever it says ends the wait for a call it announced.
            session.announcedCall = nil
            guard case .set(var state) = AgentHooks.change(agent: agent, event: event, input: record["input"] as? [String: Any] ?? [:], now: at)
            else { continue }
            // About to call one of AgentTerm's own tools (#141): the call
            // comes to its server, or the agent is held at it.
            if let tool = AgentHooks.ownToolCall(agent: agent, event: event, input: record["input"] as? [String: Any] ?? [:], server: AppChannel.current.mcpServerName) {
                if let called = session.lastToolCall, called >= at {
                    state = .working(since: at)
                } else {
                    announce(tool, at: at, in: session)
                }
            }
            // Still working is working since it began.
            if case .working = state, case .working(let since)? = session.info.state { state = .working(since: since) }
            let note = AgentHooks.note(agent: session.info.agent, beforeAnyEvent: false)
            let input = record["input"] as? [String: Any] ?? [:]
            if state?.isWorking == true, session.turn == nil { beginTurn(of: session, at: at, input: input) }
            guard state != session.info.state || note != session.info.stateNote else { continue }
            // Done anew: in the Inbox until a device shows it (#67). Any
            // other state takes it out; a question is listed by itself.
            if case .done = state {
                if session.info.state != state { session.info.unseen = true }
                endTurn(of: session, at: at, end: .done, input: input)
            } else {
                session.info.unseen = nil
                // Codex says when the user stopped the turn.
                if state == nil, event == "Interrupt" { endTurn(of: session, at: at, end: .stopped, input: input) }
            }
            session.info.state = state
            session.info.stateNote = note
            changed = true
        }
        // An agent working in the same repository as a turn makes its
        // changes not all that turn's.
        for session in sessions.values where session.turn?.shared == false {
            if anotherAgentWorks(besides: session) { session.turn?.shared = true }
        }
        if changed { broadcastSessions() }
    }

    // MARK: An agent held at one of AgentTerm's own tools (#141)

    /// An agent said it is about to call one of AgentTerm's own tools.
    /// Antigravity asks leave for a tool of an MCP server and says nothing
    /// while it waits, but a call that is made reaches the session's
    /// server: one that has not come after a grace is held, and the agent
    /// waits for leave, with the tool as its own question names it.
    private func announce(_ tool: String, at: Date, in session: Session) {
        session.announcedCall = (tool, at)
        queue.asyncAfter(deadline: .now() + configuration.leaveGrace) { [weak self, weak session] in
            guard let self, let session, let held = session.announcedCall, held.at == at, self.sessions[session.info.id] === session else { return }
            session.info.state = .waitingForPermission(AgentQuestion(text: held.tool))
            session.info.unseen = nil
            self.broadcastSessions()
        }
    }

    /// The session's MCP server asked for what a tool does: the call its
    /// agent announced came, so it was not held, or no longer is.
    private func toolCalled(by session: Session) {
        session.lastToolCall = Date()
        guard session.announcedCall != nil else { return }
        session.announcedCall = nil
        if session.info.state?.isWorking != true {
            session.info.state = .working(since: Date())
            broadcastSessions()
        }
    }

    // MARK: What a turn came to (#71)

    /// A turn begins when its agent starts working: what the folder looks
    /// like then is taken, away from the host's queue.
    private func beginTurn(of session: Session, at: Date, input: [String: Any]) {
        // Turned off in Settings: nothing is looked at.
        guard displaySettings?.turnResults ?? true else { return }
        let request = (input["prompt"] as? String) ?? (input["lastUserInput"] as? String)
        let record = TurnRecord(startedAt: at, directory: session.info.cwd, request: request)
        record.shared = anotherAgentWorks(besides: session)
        session.turn = record
        turnQueue.async { record.before = GitSnapshot.take(of: record.directory) }
    }

    /// The turn ended: what it came to is made from the agent's record and
    /// the folder as it is now, and told to every device.
    private func endTurn(of session: Session, at: Date, end: TurnResult.End, input: [String: Any]) {
        guard let record = session.turn, let agent = session.info.agent ?? session.info.typedAgent else { return }
        session.turn = nil
        if anotherAgentWorks(besides: session) { record.shared = true }
        let shared = record.shared
        let ownWorktree = WorktreePath.project(of: record.directory) != nil && !sessions.values.contains { $0 !== session && $0.info.cwd == record.directory }
        let transcript = (input["transcript_path"] as? String) ?? (input["transcriptPath"] as? String)
        let turnID = input["turn_id"] as? String
        let said = (input["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = session.info.id
        turnQueue.async { [weak self] in
            let read = transcript.flatMap { TurnTranscript.read(agent: agent, file: $0, turnID: turnID) }
            var changes: TurnResult.Changes?
            if let before = record.before, let after = GitSnapshot.take(of: record.directory) {
                changes = TurnResult.Changes(files: GitSnapshot.changes(from: before, to: after), shared: shared, ownWorktree: ownWorktree)
            }
            let result = TurnResult(
                request: record.request ?? read?.request, reply: said ?? read?.reply, startedAt: record.startedAt, endedAt: at, end: end,
                commands: read?.commands, changes: changes)
            self?.queue.async {
                guard let self, let session = self.sessions[id] else { return }
                session.lastTurn = result
                for client in self.clients.values where client.authenticated { self.send(.turnResult(session: id, result: result), to: client) }
            }
        }
    }

    /// Whether the agent of another session works in the same folder, or
    /// one inside it or around it.
    private func anotherAgentWorks(besides session: Session) -> Bool {
        let folder = session.info.cwd
        return sessions.values.contains { other in
            guard other !== session, other.info.agent != nil, other.turn != nil || other.info.state?.isWorking == true else { return false }
            let path = other.info.cwd
            return path == folder || path.hasPrefix(folder + "/") || folder.hasPrefix(path + "/")
        }
    }

    private func refreshSummaries() {
        // Kept fresh while agents work: iOS shows an activity that is not
        // updated as out of date (#168).
        if activityStatus?.isActive == true, configuration.now().timeIntervalSince(activitySentAt) > Self.activityRefresh { updateActivity(force: true) }
        refreshAccountUsage(olderThan: Self.accountInterval)
        guard !summarizing else { return }
        let running = sessions.values.compactMap { session -> SessionSummaries.Running? in
            guard let agent = session.info.agent else { return nil }
            return SessionSummaries.Running(
                id: session.info.id, agent: agent, cwd: session.info.cwd,
                createdAt: session.info.createdAt, conversationID: session.info.conversationID
            )
        }
        guard !running.isEmpty else { return }
        summarizing = true
        let home = configuration.home
        var reports: [SessionID: URL] = [:]
        for session in running where session.agent == "claude" { reports[session.id] = usageFile(for: session.id) }
        workQueue.async { [weak self] in
            var conversations: [Conversation] = []
            for folder in Set(running.map(\.cwd)) {
                conversations += AgentHistory.conversations(in: folder, home: home)
            }
            let matches = SessionSummaries.assign(running, conversations: conversations)
            var usage: [SessionID: SessionUsage] = [:]
            for (id, conversation) in matches {
                if let file = conversation.source { usage[id] = AgentUsage.read(agent: conversation.agent, file: file) }
            }
            // What Claude Code reported itself says more: its limits, and
            // how large its context is.
            for (id, file) in reports {
                if let data = try? Data(contentsOf: file), let reported = StatusLineRelay.usage(from: data) { usage[id] = reported }
            }
            // Copilot CLI keeps a file of a session before there is a
            // conversation to match it by.
            for session in running where session.agent == "copilot" && usage[session.id] == nil {
                if let file = AgentUsage.copilotSessionFile(cwd: session.cwd, startedAfter: session.createdAt, home: home) {
                    usage[session.id] = AgentUsage.read(agent: "copilot", file: file)
                }
            }
            // Every agent's session names a model: the one its settings
            // name, until the session itself records which it uses.
            var configured: [String: String?] = [:]
            for session in running where usage[session.id]?.model == nil {
                let model = configured[session.agent] ?? AgentUsage.configuredModel(agent: session.agent, home: home)
                configured[session.agent] = .some(model)
                guard let model else { continue }
                var known = usage[session.id] ?? SessionUsage()
                known.model = model
                usage[session.id] = known
            }
            self?.queue.async {
                guard let self else { return }
                self.summarizing = false
                var changed = false
                for (id, used) in usage where matches[id] == nil {
                    // Usage can be known before the conversation is. What
                    // was read then is not lost to a later read with less.
                    guard let session = self.sessions[id] else { continue }
                    var used = used
                    if let known = session.info.usage {
                        used.contextTokens = used.contextTokens ?? known.contextTokens
                        used.contextWindow = used.contextWindow ?? known.contextWindow
                        used.effort = used.effort ?? known.effort
                    }
                    guard session.info.usage != used else { continue }
                    session.info.usage = used
                    changed = true
                }
                for (id, conversation) in matches {
                    guard let session = self.sessions[id] else { continue }
                    if session.info.summary != conversation.title || session.info.conversationID != conversation.sessionID {
                        session.info.summary = conversation.title
                        session.info.conversationID = conversation.sessionID
                        changed = true
                    }
                    // A read that found nothing keeps what was known.
                    if let used = usage[id], session.info.usage != used {
                        session.info.usage = used
                        changed = true
                    }
                }
                if changed { self.broadcastSessions() }
            }
        }
    }

    /// Tells the client why, then closes once the message had time to arrive.
    private func refuse(_ client: Client, _ reason: String) {
        send(.error(reason), to: client)
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self, weak client] in
            if let self, let client { self.close(client) }
        }
    }

    private func admit(_ client: Client, as identity: DeviceRegistry.Identity) {
        client.identity = identity
        send(
            .welcome(
                version: configuration.protocolVersion, host: Host.current().localizedName ?? "Mac", release: configuration.release,
                revision: configuration.revision), to: client)
        if case .device(let id) = identity {
            send(.pushState(push.state(of: id)), to: client)
        }
        send(.sessions(sessions.values.map(\.info).sorted { $0.id < $1.id }), to: client)
        // The last 30 days, for its Inbox; then what it was not told of yet,
        // here or through Apple (#66).
        if noticeKey(of: client) != nil {
            send(.noticeLog(notices.log), to: client)
            tellUntold(client)
        }
        // What stopped before this client came, until someone has seen it.
        send(.failures(failures), to: client)
        if !accountUsage.isEmpty { send(.accountUsage(accountUsageList()), to: client) }
        send(.folders(folders), to: client)
        send(.tabLayout(tabLayout), to: client)
        send(.keepAwake(keepAwake), to: client)
        send(.keepAwakeOptions(keepAwakeOptions), to: client)
        if configuration.agentShells != nil || !agentShellsFaults.isEmpty { send(.agentShellsFaults(agentShellsFaults), to: client) }
        send(.macInUse(macInUse), to: client)
        // What was seen on another device while this one was away, as far
        // as its agent still says it.
        noticesSeen = noticesSeen.filter { sessions[$0.key]?.info.state == $0.value }
        for (id, state) in noticesSeen { send(.noticeSeen(session: id, state: state), to: client) }
        // What the last turns came to, kept while the device was away (#71).
        for session in sessions.values {
            if let result = session.lastTurn { send(.turnResult(session: session.info.id, result: result), to: client) }
        }
        send(.schedules(schedules), to: client)
        send(.schedulesPaused(schedulesPaused), to: client)
        send(.browserTabs(browserTabsList), to: client)
        send(agentPromptsMessage, to: client)
        send(shellSettingsMessage, to: client)
        send(historyMarksMessage, to: client)
        send(.commitWriter(commitWriter), to: client)
        if let item = configuration.loginItem { send(.startAtLogin(item.isOn), to: client) }
        // Without any yet, the client is sent none and hands over its own.
        send(.displaySettings(displaySettings), to: client)
        if let systemStats { send(.systemStats(systemStats), to: client) }
        if client.isAdmin {
            send(.devices(deviceList()), to: client)
        } else {
            broadcastDevices()
        }
    }

    private func deviceList() -> [DeviceInfo] {
        let connected = Set(
            clients.values.compactMap { client -> String? in
                if case .device(let id) = client.identity { return id }
                return nil
            })
        return registry.devices(connected: connected)
    }

    /// Paired devices are the Mac's business only.
    private func broadcastDevices() {
        let list = deviceList()
        for client in clients.values where client.isAdmin {
            send(.devices(list), to: client)
        }
    }

    private func foldersChanged() {
        if let file = configuration.foldersFile, let data = try? JSONEncoder().encode(folders) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        for client in clients.values where client.authenticated {
            send(.folders(folders), to: client)
        }
    }

    private func handle(_ frame: DataFrame, from client: Client) {
        guard client.authenticated, frame.kind == .input,
            client.attached.contains(frame.session), let session = sessions[frame.session]
        else { return }
        if TerminalReply.isReply(frame.payload) {
            // An emulator answering the program's question, not a person
            // typing. Only the answer of the client in use is passed on, and
            // it does not move the session to that client.
            if session.arbiter.answerer == client.id { session.process.write(frame.payload) }
            return
        }
        // Typing takes control of the session's size.
        if session.arbiter.activity(client.id) { applySize(of: session) }
        used(by: client)
        session.process.write(frame.payload)
        // It may have stopped the turn, and not every agent says so: nor
        // does Antigravity when its question for leave is cancelled (#141).
        if session.info.state?.isWorking == true || session.announcedCall != nil, AgentHooks.mayStopATurn(frame.payload) {
            session.announcedCall = nil
            session.info.state = nil
            session.info.unseen = nil
            endTurn(of: session, at: Date(), end: .stopped, input: [:])
            broadcastSessions()
        }
    }

    private func requestAgents(for client: Client, refresh: Bool) {
        if let agents, !refresh {
            send(.agents(agents), to: client)
            return
        }
        agentWaiters.append(client.id)
        guard !detecting else { return }
        detecting = true
        let detect = configuration.detectAgents
        detectionQueue.async { [weak self] in
            let found = detect()
            self?.queue.async {
                guard let self else { return }
                self.agents = found
                self.detecting = false
                for id in self.agentWaiters {
                    if let waiter = self.clients[id] { self.send(.agents(found), to: waiter) }
                }
                self.agentWaiters.removeAll()
            }
        }
    }

    // MARK: Sessions

    @discardableResult
    private func create(
        _ request: CreateRequest, for client: Client?, conversationID: String? = nil, openedBy: SessionID? = nil, run: Schedule? = nil,
        environment more: [String: String] = [:]
    ) -> SessionID? {
        // The host's home: the user's, or a test's own, never the home of
        // the person running the tests.
        var cwd = request.cwd ?? configuration.home
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
            cwd = configuration.home
        }
        let size = request.size.clamped
        let id = nextSessionID
        var command = request.command
        var environment = HostEnvironment.sessionEnvironment()
        let agent = SessionSummaries.agent(forCommand: command)
        // AgentTerm starts an agent with no arguments of its own (#129): its
        // hooks, AgentTerm's MCP server, Claude Code's status line and what
        // it is told come from its own configuration, which
        // `agenttermd setup` adds to. Every session, a shell's too, has
        // what they need to reach this host: an agent typed by hand in it
        // is heard as one started from a button.
        if let events = eventsFile(for: id) {
            try? FileManager.default.removeItem(at: events)
            environment[AppChannel.current.eventsVariable] = events.path
        }
        if let usage = usageFile(for: id) {
            try? FileManager.default.removeItem(at: usage)
            environment[AppChannel.current.usageVariable] = usage.path
        }
        // Copilot CLI does not take an MCP server's instructions: it reads
        // what it is told from a folder its environment names.
        if let told = try? AgentHooks.instructionsEnvironment(
            agent: "copilot", directory: configuration.hooksDirectory, prompt: agentPrompt(for: "copilot"), current: environment)
        {
            environment.merge(told) { _, new in new }
        }
        // A schedule's run of Antigravity trusts the schedule's folder, as
        // the user asked by scheduling it there; for that run only.
        if let run, agent == "agy", let trust = AgentHooks.antigravityTrust([run.folder], home: configuration.home) {
            command = (command ?? "") + trust
        }
        if let directory = configuration.agentsDirectory, let agent = SessionSummaries.agent(forCommand: command), let text = command,
            text == agent || text.hasPrefix(agent + " ")
        {
            command = Handoff.shellQuote((directory as NSString).appendingPathComponent(agent)) + text.dropFirst(agent.count)
        }
        environment.merge(more) { _, new in new }
        // A shell is the program picked in Settings > Shell; a command is
        // started by the login shell, for which it is written.
        let isShell = (request.command ?? "").isEmpty
        let program = program(forCommand: request.command)
        // A shell an agent opens says when its commands start and end, for
        // `shell_run` (#10), unless that is turned off; what it is to run
        // first is run before its first prompt, not taken for a command of
        // the agent's. The user's own sessions are left as they are.
        var marksPrepared = false
        var startup: String?
        if isShell {
            startup = openedBy == nil ? shellSettings.startup : shellSettings.agentStartup
            if startup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { startup = nil }
        }
        if openedBy != nil, isShell,
            let integration = ShellIntegration.environment(shell: program, current: environment, startup: startup)
        {
            environment.merge(integration) { _, new in new }
            marksPrepared = true
            startup = nil
        }
        // The MCP server of the agent in it, started or typed, tells the host
        // which session's it is (#129: every session's).
        let agentKey = UUID().uuidString + UUID().uuidString
        environment[Self.agentShellsVariable] = AgentShellsMCP.Session(
            port: boundPort, key: agentKey, useShells: agent.map { agentPrompt(for: $0) != nil } ?? true, agent: agent
        ).variable()
        let process: PTYProcess
        do {
            process = try PTYProcess(
                executable: program,
                arguments: HostEnvironment.shellArguments(command: command, shell: program),
                environment: environment,
                cwd: cwd,
                size: size,
                queue: queue
            )
        } catch {
            if let client { send(.error("\(error)"), to: client) }
            return nil
        }

        nextSessionID += 1
        let fallbackTitle =
            request.command?.split(separator: " ").first.map(String.init)
            ?? (program as NSString).lastPathComponent
        let info = SessionInfo(
            id: id, title: request.title ?? fallbackTitle, cwd: cwd, size: size, createdAt: Date(),
            agent: SessionSummaries.agent(forCommand: request.command),
            // A session started with an agent's own resume command is that
            // conversation's, whoever typed the command.
            conversationID: conversationID ?? SessionSummaries.resumedConversation(inCommand: request.command),
            stateNote: agent.flatMap { AgentHooks.note(agent: $0, beforeAnyEvent: true) }
        )
        let session = Session(info: info, process: process, screenLines: configuration.screenLines)
        session.agentKey = agentKey
        if let agentID = info.agent {
            session.info.link = AgentLink()
            session.agentSince = configuration.now()
            session.promptGiven = agentPrompt(for: agentID) != nil
            refreshPrompt(session)
        }
        session.marksPrepared = marksPrepared
        session.info.openedBy = openedBy
        session.pendingTyped = request.typed.flatMap { $0.isEmpty ? nil : $0 }
        session.pendingStartup = startup
        session.info.schedule = run?.name
        session.info.schedulePermissions = run?.permissions
        if run != nil { session.lastOutputAt = configuration.now() }
        sessions[id] = session

        process.onOutput = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.record(data, in: session)
        }
        process.onExit = { [weak self] status in
            self?.sessionExited(id, status: status)
        }

        if let client { attach(client, to: session, size: size) }
        broadcastSessions()
        // An agent that was not in use until now: ask its service right away.
        refreshAccountUsage(olderThan: Self.accountInterval)
        return id
    }

    // MARK: Shells an agent opens (#10)

    /// The variable that gives an agent's session its port and key, for
    /// the MCP server the agent starts.
    public static let agentShellsVariable = "AGENTTERM_MCP"

    /// Start at Login as the clients were last told.
    private var startAtLoginSaid: Bool?

    /// Start at Login turned on or off outside AgentTerm, in System Settings
    /// or by removing the launch agent: every client is told.
    private func checkLoginItem() {
        guard let item = configuration.loginItem else { return }
        let on = item.isOn
        guard on != startAtLoginSaid else { return }
        let first = startAtLoginSaid == nil
        startAtLoginSaid = on
        // The first look only notes it: each client was told at its welcome.
        if first { return }
        for client in clients.values where client.authenticated { send(.startAtLogin(on), to: client) }
    }

    /// Does what an agent asks of the shells it opened, as the session its
    /// key names, and answers the client that asked. An agent sees, reads,
    /// types into and closes only the shells it opened; another agent's,
    /// the user's own sessions, and the agents', it never reaches. One whose
    /// agent's session has ended is the user's.
    private func handleAgentShell(id: Int, key: String, request: AgentShellRequest, from client: Client) {
        func answer(_ result: AgentShellResult) { send(.agentShellResult(id: id, result: result), to: client) }
        guard !key.isEmpty, let owner = sessions.values.first(where: { $0.agentKey == key }) else {
            return answer(.refused("This is not the session of an agent AgentTerm started, or that session has ended."))
        }
        // A tool's call came to the server (#141); its start is no call.
        if case .started = request {} else { toolCalled(by: owner) }
        /// A shell this agent opened and that still runs.
        func own(_ session: SessionID) -> (Session?, String) {
            guard let shell = sessions[session], shell.info.openedBy == owner.info.id else {
                return (nil, "There is no shell \(session) of yours: you see and use only the shells you opened. Open one with shell_open, or list yours with shell_list.")
            }
            return (shell, "")
        }
        switch request {
        case .open(let command, let title):
            // Shells only: one agent starting another spends an account
            // without anyone having asked.
            if let command, SessionSummaries.agent(forCommand: command) != nil {
                return answer(.refused("Starting an agent is not allowed: open a shell, with a command or without."))
            }
            let first = command?.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let request = CreateRequest(command: command, cwd: owner.info.cwd, title: title ?? first ?? "shell", size: owner.info.size)
            // Not attached to the agent's server, which only asks: attached,
            // it would be the device using the shell, and the Mac that shows
            // it would say another device is (MCP-12).
            guard let created = create(request, for: nil, openedBy: owner.info.id), let session = sessions[created] else {
                return answer(.refused("The shell could not be started."))
            }
            answer(.opened(session.info))
        case .list:
            answer(.shells(sessions.values.filter { $0.info.openedBy == owner.info.id }.map(\.info).sorted { $0.id < $1.id }))
        case .read(let session, let linesAbove):
            let (found, why) = own(session)
            guard let shell = found else { return answer(.refused(why)) }
            let lines = min(linesAbove, configuration.screenLines)
            // Read where the screen is kept, after what was written to it,
            // without this queue, which every session's output goes
            // through, waiting for that (#21). Answers are matched by `id`.
            let mirror = shell.mirror
            shell.mirrorQueue.async { [weak self] in
                let text = mirror.text(linesAbove: lines)
                self?.queue.async { answer(.screen(text)) }
            }
        case .send(let session, let text, let keys):
            let (found, why) = own(session)
            guard let shell = found else { return answer(.refused(why)) }
            var bytes = text ?? ""
            for key in keys {
                guard let typed = TerminalKeys.bytes(for: key) else { return answer(.refused("There is no key called “\(key)”.")) }
                bytes += typed
            }
            shell.process.write(Data(bytes.utf8))
            answer(.done)
        case .run(let session, let command):
            let (found, why) = own(session)
            guard let shell = found else { return answer(.refused(why)) }
            let mirror = shell.mirror
            let prepared = shell.marksPrepared
            // As the screen stands once what came before is fed to it.
            shell.mirrorQueue.async { [weak self, weak shell] in
                var before = mirror.command(lines: 0)
                before.prepared = prepared
                let paste = mirror.bracketedPasteMode
                self?.queue.async { [weak shell] in
                    guard let shell else { return answer(.refused("Shell \(session) has ended.")) }
                    if before.integrated, before.running {
                        return answer(
                            .refused(
                                "Shell \(session) is still running a command. Wait for it to end with shell_wait, stop it with shell_stop, or open another shell with shell_open."
                            ))
                    }
                    shell.process.write(Data((SentText.text(command, bracketedPaste: paste) + "\r").utf8))
                    answer(.ran(before))
                }
            }
        case .command(let session, let lines):
            let (found, why) = own(session)
            guard let shell = found else { return answer(.refused(why)) }
            let mirror = shell.mirror
            let prepared = shell.marksPrepared
            shell.mirrorQueue.async { [weak self] in
                var state = mirror.command(lines: lines)
                state.prepared = prepared
                self?.queue.async { answer(.command(state)) }
            }
        case .close(let session):
            let (found, why) = own(session)
            guard let shell = found else { return answer(.refused(why)) }
            shell.endAsked = true
            shell.process.hangUp()
            queue.asyncAfter(deadline: .now() + 3) { [weak shell] in shell?.process.forceKill() }
            answer(.done)
        case .started(let agent):
            // The session's agent has AgentTerm's MCP server (#129).
            if heard(.mcp, from: owner, agent: agent) { broadcastSessions() }
            answer(.done)
        }
    }

    // MARK: Whether an agent talks to the host (#129)

    private enum LinkPart: Hashable { case hooks, mcp }

    /// What a shell heard before the agent typed in it was found, for when
    /// it is.
    private var heardEarly: [SessionID: Set<LinkPart>] = [:]

    /// Something of an agent's link to this host was heard from: its hooks,
    /// which name their agent, or its MCP server, which names the agent it
    /// was started by when it can. In a shell it is of an agent typed there.
    /// Returns whether the session changed.
    private func heard(_ part: LinkPart, from session: Session, agent: String?) -> Bool {
        let before = session.info
        if session.info.agent == nil {
            if session.info.typedAgent == nil, let agent, SessionSummaries.agent(forCommand: agent) != nil {
                typedAgentFound(agent, in: session)
            }
            guard session.info.typedAgent != nil else {
                heardEarly[session.info.id, default: []].insert(part)
                return false
            }
        }
        switch part {
        case .hooks: session.info.link?.hooks = true
        case .mcp: session.info.link?.mcp = true
        }
        refreshPrompt(session)
        return session.info != before
    }

    /// An agent typed by hand in a shell was found: the shell is its session
    /// while it runs, what was heard before it included.
    private func typedAgentFound(_ agent: String, in session: Session) {
        session.info.typedAgent = agent
        session.agentSince = configuration.now()
        let early = heardEarly.removeValue(forKey: session.info.id) ?? []
        session.info.link = AgentLink(hooks: early.contains(.hooks) ? true : nil, mcp: early.contains(.mcp) ? true : nil)
        session.promptGiven = agentPrompt(for: agent) != nil
        refreshPrompt(session)
    }

    /// What AgentTerm's instructions came to in a session (#172), from how
    /// they reach its agent and what its MCP server did.
    private func refreshPrompt(_ session: Session) {
        guard let agent = session.info.agent ?? session.info.typedAgent, var link = session.info.link else { return }
        link.prompt = AgentLink.prompt(agent: agent, given: session.promptGiven, mcp: link.mcp)
        session.info.link = link
    }

    /// Looks at each session's agent: one typed in a shell is found from
    /// the program in front of its terminal, and goes when the shell is in
    /// front again; hooks and an MCP server not heard from within a grace
    /// of the agent's start are said missing.
    private func lookAtAgentLinks() {
        var changed = false
        let now = configuration.now()
        for session in sessions.values {
            if session.info.agent == nil, let front = session.process.foregroundCommand {
                let typed = SessionSummaries.agent(forCommand: front)
                if let typed, typed != session.info.typedAgent {
                    typedAgentFound(typed, in: session)
                    changed = true
                } else if typed == nil, session.info.typedAgent != nil {
                    // It ended: a shell again, with nothing of the agent's.
                    session.info.typedAgent = nil
                    session.info.link = nil
                    session.info.state = nil
                    session.info.unseen = nil
                    session.turn = nil
                    session.agentSince = nil
                    heardEarly[session.info.id] = nil
                    changed = true
                }
            }
            guard var link = session.info.link, let since = session.agentSince, now.timeIntervalSince(since) >= configuration.linkGrace else { continue }
            if link.hooks == nil { link.hooks = false }
            if link.mcp == nil { link.mcp = false }
            if let agent = session.info.agent ?? session.info.typedAgent {
                link.prompt = AgentLink.prompt(agent: agent, given: session.promptGiven, mcp: link.mcp)
            }
            if link != session.info.link {
                session.info.link = link
                changed = true
            }
        }
        if changed { broadcastSessions() }
    }

    // MARK: Setting the agents up (#129)

    /// The agents being set up or taken out now.
    private var agentSetupBusy: Set<String> = []
    /// What was last found, for a client that asks while it is looked at again.
    private var lastAgentSetup: AgentSetupReport?

    /// Asks each agent what it has of AgentTerm's, off the host's queue, and
    /// tells the client that asked, or every client.
    private func reportAgentSetup(to client: Client?) {
        guard let setup = configuration.agentSetup else { return }
        workQueue.async { [weak self] in
            let found = setup.report()
            self?.queue.async {
                guard let self else { return }
                var report = found
                report.busy = self.agentSetupBusy.sorted()
                self.lastAgentSetup = report
                if let client {
                    self.send(.agentSetup(report), to: client)
                } else {
                    for client in self.clients.values where client.authenticated { self.send(.agentSetup(report), to: client) }
                }
            }
        }
    }

    /// Adds AgentTerm's hooks and MCP server to an agent's own
    /// configuration, or every installed one's, or takes them out; every
    /// client is told when it starts and when it is done.
    private func runAgentSetup(agent: String?, remove: Bool) {
        guard let setup = configuration.agentSetup else { return }
        let agents = agent.map { [$0] } ?? (lastAgentSetup?.agents.filter(\.installed).map(\.agent) ?? AgentDetector.known.map(\.id))
        agentSetupBusy.formUnion(agents)
        if var report = lastAgentSetup {
            report.busy = agentSetupBusy.sorted()
            for client in clients.values where client.authenticated { send(.agentSetup(report), to: client) }
        }
        workQueue.async { [weak self] in
            for agent in agents {
                if remove { setup.remove(agent) } else { setup.install(agent) }
            }
            self?.queue.async {
                guard let self else { return }
                self.agentSetupBusy.subtract(agents)
                self.reportAgentSetup(to: nil)
            }
        }
    }

    // MARK: What the agents are told

    /// What the user wrote for each agent in Settings, by agent; one that
    /// is not here is told the default.
    private lazy var agentPrompts: [String: String] = {
        guard let data = FileManager.default.contents(atPath: Self.agentPromptsFile.path) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    public static var agentPromptsFile: URL { HostEnvironment.supportDirectory.appendingPathComponent("agent-prompts.json") }

    /// What AgentTerm tells an agent by default, when it gives it the MCP
    /// server: to run its commands in the shells the user sees, and to use
    /// AgentTerm's browser. Always, with no switch (decided by the owner on
    /// 2026-11-16): the user who wants it otherwise changes the words.
    private func defaultPrompt(for agent: String) -> String? {
        AgentShellsInstructions.told(useShells: configuration.agentShells != nil, browser: configuration.agentShells != nil)
    }

    func agentPrompt(for agent: String) -> String? {
        if let own = agentPrompts[agent] { return own.isEmpty ? nil : own }
        return defaultPrompt(for: agent)
    }

    /// Where the agent's MCP server finds its instructions: the same words,
    /// which it gives as its own. Codex reads only those.
    public static func promptFile(for agent: String) -> URL {
        HostEnvironment.supportDirectory.appendingPathComponent("prompts", isDirectory: true).appendingPathComponent(agent + ".md")
    }

    /// Writes what each agent is told where its MCP server finds it: at the
    /// start, and when the user changes it. The server gives it as its
    /// instructions, to an agent started from a button or typed in a shell.
    private func writePromptsForServers() {
        for agent in AgentDetector.known.map(\.id) { writePromptForServer(agentPrompt(for: agent), agent: agent) }
    }

    private func writePromptForServer(_ prompt: String?, agent: String) {
        let file = Self.promptFile(for: agent)
        guard let prompt else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(prompt.utf8).write(to: file, options: .atomic)
    }

    /// The user's words for an agent, or none to go back to the default.
    private func setAgentPrompt(_ agent: String, _ text: String?) {
        if let text { agentPrompts[agent] = text } else { agentPrompts[agent] = nil }
        if let data = try? JSONEncoder().encode(agentPrompts) {
            try? FileManager.default.createDirectory(at: Self.agentPromptsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.agentPromptsFile, options: .atomic)
        }
        writePromptForServer(agentPrompt(for: agent), agent: agent)
        broadcastAgentPrompts()
    }

    private var agentPromptsMessage: ServerMessage {
        let agents = AgentDetector.known.map(\.id)
        var defaults: [String: String] = [:]
        for agent in agents { defaults[agent] = defaultPrompt(for: agent) ?? "" }
        return .agentPrompts(custom: agentPrompts, defaults: defaults)
    }

    func broadcastAgentPrompts() {
        let message = agentPromptsMessage
        for client in clients.values where client.authenticated { send(message, to: client) }
    }

    // MARK: The browser (#76)

    /// The Mac app on this Mac says it shows the browser, or no longer does.
    /// Only an app that signed in with this Mac's own token, on this Mac,
    /// may: the browser holds the user's sign-ins.
    private func setBrowserProvider(_ client: Client, _ on: Bool) {
        if on {
            guard client.isAdmin, client.isLocal else { return send(.error("not allowed"), to: client) }
            browserProvider = client.id
            return
        }
        guard browserProvider == client.id else { return }
        browserProvider = nil
        browserTabsList = []
        browserWatchers = [:]
        for other in clients.values where other.authenticated && other !== client { send(.browserTabs([]), to: other) }
        // Whoever waits for the app is answered now, with why.
        for (call, waiting) in browserCalls {
            browserCalls[call] = nil
            answerBrowser(waiting, .refused(BrowserWords.noApp))
        }
    }

    /// The devices that watch a tab's page live, by tab (`BrowserRequest.watch`).
    private var browserWatchers: [String: Set<ClientID>] = [:]

    /// A device starts or stops watching a page. The app is asked for its
    /// pictures while one device watches it, and no longer once none does.
    private func setWatching(_ tab: String, _ client: ClientID, _ on: Bool, width: Int) {
        var watchers = browserWatchers[tab] ?? []
        let was = !watchers.isEmpty
        if on { watchers.insert(client) } else { watchers.remove(client) }
        browserWatchers[tab] = watchers.isEmpty ? nil : watchers
        guard was != !watchers.isEmpty || (on && width > 0), let providerID = browserProvider, let provider = clients[providerID] else { return }
        // Not waited for: the pictures are the answer.
        let call = nextBrowserCall
        nextBrowserCall += 1
        send(.browserCall(id: call, agent: nil, request: .watch(tab: tab, on: !watchers.isEmpty, width: width)), to: provider)
    }

    /// A picture of a page, from the app, to the devices that watch it.
    private func browserFramed(tab: String, jpeg: Data, width: Double, height: Double, from client: Client) {
        guard browserProvider == client.id, let watchers = browserWatchers[tab] else { return }
        let message = ServerMessage.browserFrame(tab: tab, jpeg: jpeg, width: width, height: height)
        for id in watchers { if let watcher = clients[id] { send(message, to: watcher) } }
    }

    private func answerBrowser(_ waiting: (client: ClientID, id: Int, agent: Bool), _ result: BrowserResult) {
        guard let asker = clients[waiting.client] else { return }
        send(waiting.agent ? .agentBrowserResult(id: waiting.id, result: result) : .browserAnswer(id: waiting.id, result: result), to: asker)
    }

    /// Passes a request on to the app that shows the browser, and answers
    /// whoever asked when it answers, or at once when there is no such app.
    private func callBrowser(_ request: BrowserRequest, agent: SessionID?, for waiting: (client: ClientID, id: Int, agent: Bool)) {
        guard let providerID = browserProvider, let provider = clients[providerID] else {
            return answerBrowser(waiting, .refused(BrowserWords.noApp))
        }
        let call = nextBrowserCall
        nextBrowserCall += 1
        browserCalls[call] = waiting
        send(.browserCall(id: call, agent: agent, request: request), to: provider)
        // An app that is there and silent is waited for, as long as the
        // request may take and a little more.
        var seconds: Double = 60
        if case .wait(_, _, _, let wait) = request { seconds = min(max(wait, 0), 600) + 30 }
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let waiting = self.browserCalls.removeValue(forKey: call) else { return }
            self.answerBrowser(waiting, .refused("The AgentTerm app did not answer for \(Int(seconds)) seconds. Try again; if it goes on, ask the user to look at the app."))
        }
    }

    private func browserReplied(_ call: Int, _ result: BrowserResult, from client: Client) {
        guard browserProvider == client.id, let waiting = browserCalls.removeValue(forKey: call) else { return }
        answerBrowser(waiting, result)
    }

    /// What an agent asks of the browser, as the session its key names.
    /// Which tabs it may reach is the app's to check: it knows them.
    private func handleAgentBrowser(id: Int, key: String, request: BrowserRequest, from client: Client) {
        let waiting = (client: client.id, id: id, agent: true)
        guard !key.isEmpty, let owner = sessions.values.first(where: { $0.agentKey == key }) else {
            return answerBrowser(waiting, .refused("This is not the session of an agent AgentTerm started, or that session has ended."))
        }
        switch request {
        case .picture, .takeOver, .giveBack, .profile:
            // The user's, from a device.
            return answerBrowser(waiting, .refused("That is for the user, not for an agent."))
        default:
            // A tool's call came to the server (#141).
            toolCalled(by: owner)
            callBrowser(request, agent: owner.info.id, for: waiting)
        }
    }

    /// What a device asks of the browser: its tabs, a picture of one, and
    /// taking one over from its agent or giving it back. A device does not
    /// drive the pages.
    private func handleBrowserAsk(id: Int, request: BrowserRequest, from client: Client) {
        let waiting = (client: client.id, id: id, agent: false)
        switch request {
        case .tabs:
            answerBrowser(waiting, .tabs(browserTabsList))
        case .watch(let tab, let on, let width):
            guard browserProvider != nil else { return answerBrowser(waiting, .refused(BrowserWords.noApp)) }
            setWatching(tab, client.id, on, width: width)
            answerBrowser(waiting, .text(on ? "Watching tab \(tab)." : "No longer watching tab \(tab)."))
        default:
            guard request.isTheDevices else {
                return answerBrowser(waiting, .refused("A device can look at a tab of the browser and use its page, not drive it as an agent does."))
            }
            callBrowser(request, agent: nil, for: waiting)
        }
    }

    /// The name an agent's MCP server signs in under.
    public static let agentShellsClient = "MCP"

    /// What keeps the agents from opening shells, for the apps to warn of.
    private var agentShellsFaults: [AgentShellsFault] {
        agentShellsRefused ? [AgentShellsFault(cause: .signIn)] : []
    }

    private func setAgentShellsRefused(_ refused: Bool) {
        guard agentShellsRefused != refused else { return }
        agentShellsRefused = refused
        broadcastAgentShellsFaults()
    }

    private func broadcastAgentShellsFaults() {
        let faults = agentShellsFaults
        guard faults != agentShellsFaultsTold else { return }
        agentShellsFaultsTold = faults
        for client in clients.values where client.authenticated { send(.agentShellsFaults(faults), to: client) }
    }

    private func attach(_ client: Client, to session: Session, size: TermSize, have: Int? = nil, history: Int? = nil) {
        client.attached.insert(session.info.id)
        // Watching is not using: this only sets the size if nobody else is attached.
        let changed = session.arbiter.update(client.id, size: size)
        if changed {
            session.info.size = session.arbiter.currentSize
            session.process.resize(session.info.size)
            let size = session.info.size, mirror = session.mirror
            session.mirrorQueue.async { mirror.resize(size) }
        }
        send(.attached(session.info), to: client)
        let id = session.info.id
        if let have, have <= session.written, session.written - have <= session.scrollback.count {
            // A client that was here before, a phone after its network
            // changed: its terminal has all up to `have`, so only what came
            // since is sent, not a screen it would only draw again.
            client.awaitingScreen[id] = nil
            sendReplay(session.scrollback.suffix(session.written - have), of: session, from: have, above: nil, to: client)
            return
        }
        // Anyone else gets the screen as it is now, with the lines above it,
        // written out for the size the session has, on the session's own
        // queue. To the client it is output like any other, and it counts on
        // from the end of it as it would after the session's own; what the
        // session writes meanwhile follows it.
        attachments += 1
        let attachment = attachments
        client.awaitingScreen[id] = (attachment, [])
        let written = session.written
        let mirror = session.mirror
        session.mirrorQueue.async { [weak self] in
            let replay = mirror.snapshot(linesAbove: history)
            let above = mirror.linesAbove
            self?.queue.async {
                guard let self, let session = self.sessions[id], let waiting = client.awaitingScreen[id], waiting.attach == attachment,
                    client.attached.contains(id)
                else { return }
                client.awaitingScreen[id] = nil
                self.sendReplay(replay, of: session, from: written - replay.count, above: above, to: client)
                for frame in waiting.output { self.send(frame, to: client) }
            }
        }
    }

    /// Counts attaches, to tell a screen still on its way from a newer one.
    private var attachments = 0

    private func sendReplay(_ replay: Data, of session: Session, from: Int, above: Int?, to client: Client) {
        send(.replaying(session: session.info.id, from: from, above: above), to: client)
        // In pieces: the whole of it may be larger than one message may be.
        var start = replay.startIndex
        while start < replay.endIndex {
            let end = replay.index(start, offsetBy: Self.replayPiece, limitedBy: replay.endIndex) ?? replay.endIndex
            send(DataFrame(kind: .output, session: session.info.id, payload: Data(replay[start..<end])), to: client)
            start = end
        }
        // The replay holds the questions the program once asked its terminal
        // (which terminal are you, where is the cursor). The client must not
        // answer those again: the answers would reach the program as if they
        // were typed. This marks where the replay ends.
        send(.replayed(session: session.info.id), to: client)
        announceSize(of: session)
    }

    /// How much of a replay goes in one message. Well under what a message
    /// may hold, and small enough that live output is not kept waiting.
    private static let replayPiece = 256 * 1024

    private func record(_ data: Data, in session: Session) {
        var typedAfter = 0.3
        if let startup = session.pendingStartup {
            // Run first, a line at a time with Return, as a person types
            // them; what is to be typed after it waits a little longer.
            session.pendingStartup = nil
            typedAfter = 0.6
            let lines = startup.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r") + "\r"
            queue.asyncAfter(deadline: .now() + 0.3) { [weak session] in session?.process.write(Data(lines.utf8)) }
        }
        if let typed = session.pendingTyped {
            // The shell has started to write its prompt: typed a moment
            // later, once the prompt is out, and never with Return.
            session.pendingTyped = nil
            let text = typed.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            queue.asyncAfter(deadline: .now() + typedAfter) { [weak session] in session?.process.write(Data(text.utf8)) }
        }
        let mirror = session.mirror
        session.mirrorQueue.async { mirror.feed(data) }
        session.scrollback.append(data)
        session.written += data.count
        if session.info.schedule != nil { session.lastOutputAt = configuration.now() }
        // Cut back to the limit only once it is well past it: cutting
        // copies what is kept, and doing that for every piece of output of
        // a busy program would copy megabytes many times a second.
        let limit = configuration.scrollbackLimit
        if session.scrollback.count > limit + max(limit / 4, 64 * 1024) {
            session.scrollback = Data(session.scrollback.suffix(limit))
        }
        let frame = DataFrame(kind: .output, session: session.info.id, payload: data)
        for id in session.arbiter.clients {
            guard let client = clients[id] else { continue }
            // After its screen, which is still being written out.
            if client.awaitingScreen[session.info.id] != nil {
                client.awaitingScreen[session.info.id]?.output.append(frame)
            } else {
                send(frame, to: client)
            }
        }
    }

    /// Resizes the PTY to the arbiter's size and tells every attached client.
    private func applySize(of session: Session) {
        session.info.size = session.arbiter.currentSize
        session.process.resize(session.info.size)
        let size = session.info.size, mirror = session.mirror
        session.mirrorQueue.async { mirror.resize(size) }
        announceSize(of: session)
    }

    private func announceSize(of session: Session) {
        let driver = session.arbiter.driver
        let by = driver.flatMap { clients[$0] }.map(sizeDriver)
        for id in session.arbiter.clients {
            guard let client = clients[id] else { continue }
            let drives = driver == id
            send(.resized(session: session.info.id, size: session.info.size, driver: drives, by: drives ? nil : by), to: client)
        }
    }

    /// Who a client is, for the others' banners (#120): the Mac's own app
    /// by the Mac's name, a device by the name it gave and what it said it
    /// is (#157).
    private func sizeDriver(_ client: Client) -> SizeDriver {
        if client.identity == .local, client.name == "Mac" { return SizeDriver(name: Host.current().localizedName ?? "Mac", kind: .mac) }
        return SizeDriver(name: client.name.isEmpty ? "another device" : client.name, kind: client.kind)
    }

    /// Ends a session the user asked to end, and with an agent's the shells
    /// and pages it opened (#145): its tab holds them, and closing it closes
    /// all it holds, on the Mac and on the iPhone alike. An agent that ends
    /// by itself still leaves them to the user.
    private func endWithWhatItOpened(_ session: Session) {
        let id = session.info.id
        if let providerID = browserProvider, let provider = clients[providerID] {
            for page in browserTabsList where page.openedBy == id {
                // As a device's close: whatever the app answers, nobody waits for it.
                let call = nextBrowserCall
                nextBrowserCall += 1
                send(.browserCall(id: call, agent: nil, request: .close(tab: page.id)), to: provider)
            }
        }
        for shell in sessions.values where shell.info.openedBy == id { end(shell) }
        end(session)
    }

    /// Ends a session as closing its window does, and kills what is left of
    /// it three seconds on: a program may take no notice of the hang-up.
    private func end(_ session: Session) {
        session.endAsked = true
        session.process.hangUp()
        queue.asyncAfter(deadline: .now() + 3) { [weak session] in session?.process.forceKill() }
    }

    private func sessionExited(_ id: SessionID, status: Int32) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        // A run that ends with its session, before its agent was seen done.
        if session.info.schedule != nil { runEnded(session, outcome: session.endAsked ? "Its session was ended" : "Its session ended") }
        runStops[id] = nil
        if let file = usageFile(for: id) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: StatusLineRelay.failureFile(for: file.path))
        }
        if let file = eventsFile(for: id) { try? FileManager.default.removeItem(at: file) }
        if !session.endAsked, let reason = Self.unexpectedEnd(code: status) {
            report(
                PartFailure(
                    part: .session, name: session.info.displayName, at: Date(), ended: [EndedSession(session.info)], restarted: false,
                    reason: reason))
        }
        for clientID in session.arbiter.clients {
            guard let client = clients[clientID] else { continue }
            client.attached.remove(id)
            send(.exited(session: id, status: status), to: client)
        }
        broadcastSessions()
    }
}
#endif
