import AgentTermHost
import AgentTermProtocol
import AppKit
import CAgentTermCEF
import CryptoKit
import SwiftUI

/// The browser's tabs (#76). Each is Chromium's, in a profile the user
/// keeps, or in a private one in memory; an agent drives the tabs it opened,
/// through the host, and sees what the user sees.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    /// The profiles the tabs use (#76), set by the app.
    var profiles: BrowserProfiles?
    /// The profile each agent's session was given, for the tabs it opens.
    var agentProfiles: [SessionID: String] = [:]
    /// The next tab's number, kept so that a tab's id is never used twice.
    private var counter = UserDefaults.standard.integer(forKey: "browserTabCounter")

    func tab(forTab id: String) -> BrowserTab? { tabs.first { $0.tabID == id } }
    func tab(id: String) -> BrowserTab? { tabs.first { $0.id == id } }

    /// A new tab in `project`'s profile, opened by an agent's session or by
    /// the user. Chromium starts it at once, for an agent waits on it.
    /// `starts` false: Chromium makes its page itself, a window a page opened (#162).
    @discardableResult
    func open(url: String?, project: String, owner: SessionInfo?, profile: String? = nil, starts: Bool = true) -> BrowserTab {
        counter += 1
        UserDefaults.standard.set(counter, forKey: "browserTabCounter")
        let profile = profile ?? profiles?.defaultID ?? BrowserProfiles.firstID
        let tab = BrowserTab(id: String(counter), project: project, profile: profile, owner: owner?.id, ownerTab: owner.map(TabID.session), model: self)
        if let url, !url.isEmpty { tab.url = BrowserTab.address(from: url) }
        tabs.append(tab)
        if starts { tab.start() }
        return tab
    }

    func close(_ tab: BrowserTab) {
        tab.shutDown()
        tabs.removeAll { $0 === tab }
        // The last tab of a private profile: what it kept goes.
        if BrowserProfiles.isPrivate(tab.profile), !tabs.contains(where: { $0.profile == tab.profile }) {
            Chromium.shared.forgetProfile(tab.profile)
        }
    }

    // MARK: Another Mac's pages (#147)

    /// What is asked of the other Mac's browser, through its host, for a
    /// page of its shown here: set by the app.
    var remote: ((BrowserRequest) -> Void)?

    /// The other Mac's pages, as its host lists them: a tab here for each,
    /// which draws the pictures its Mac sends and asks that Mac for the
    /// rest. No Chromium of this Mac's is started for one.
    func mirror(_ list: [BrowserTabInfo], sessions: [SessionInfo]) {
        let ids = Set(list.map(\.id))
        tabs.removeAll { $0.isRemote && !ids.contains($0.id) }
        for info in list {
            let owner = info.openedBy.flatMap { id in sessions.first { $0.id == id } }
            let tab: BrowserTab
            if let found = tabs.first(where: { $0.isRemote && $0.id == info.id }) {
                tab = found
            } else {
                tab = BrowserTab(id: info.id, project: info.project, profile: info.profile, owner: info.openedBy, ownerTab: owner.map(TabID.session), model: self)
                tab.isRemote = true
                tabs.append(tab)
            }
            tab.project = info.project
            if tab.owner != info.openedBy { tab.owner = info.openedBy }
            tab.ownerTab = owner.map(TabID.session)
            tab.remoteProfile = info.profile
            if tab.title != info.title { tab.title = info.title }
            if tab.url != info.url { tab.url = info.url }
            if tab.loading != info.loading { tab.loading = info.loading }
            if tab.userHasIt != info.userHasIt { tab.userHasIt = info.userHasIt }
            // Not told: the other Mac's page knows whether it can go back.
            tab.canGoBack = true
            tab.canGoForward = true
        }
        changed?()
    }

    /// Closes every tab: another Mac is on show.
    func closeAll() {
        let closing = tabs
        closing.forEach { close($0) }
    }

    /// Something of a tab changed that other devices show.
    var changed: (() -> Void)?
    /// A page opened a window: a tab of the app instead, as its tab's.
    var popup: ((BrowserTab, String) -> Void)?
    /// A tab's page closed itself (#162).
    var closedByItsPage: ((BrowserTab) -> Void)?
    /// A tab's page took the keyboard.
    var focused: ((BrowserTab) -> Void)?

    /// The windows Chrome's own interface opened by itself, an extension's
    /// page say, held back out of sight (#125): told in the Browser tab, the
    /// last first, with a button that shows it.
    @Published private(set) var heldChromeWindows: [NSWindow] = []
    private var chromeWatch: [NSObjectProtocol] = []

    /// Watches for a window of Chrome's own that the app did not ask for: a
    /// browser window, with a title bar and a size of its own, in none of
    /// the app's views. Dialogs and bubbles, an extension's install prompt
    /// say, are left as they are. It is hidden, not closed: what made it
    /// (installing an extension) goes on.
    func watchChromeWindows() {
        let names: [Notification.Name] = [
            NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        chromeWatch = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdChromeWindows() }
            }
        }
    }

    /// Chromium's windows are of its own kind (`NativeWidgetMacNSWindow`, a
    /// browser's a kind of it). Looked up each time: the framework that has
    /// it is loaded only once the browser starts.
    static var chromiumWindowClass: AnyClass? { NSClassFromString("NativeWidgetMacNSWindow") }

    static func isChromeBrowserWindow(_ window: NSWindow) -> Bool {
        guard let kind = chromiumWindowClass, window.isKind(of: kind) else { return false }
        // A bubble or a dialog is a window of the one it belongs to.
        return window.parent == nil && window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
            && window.identifier?.rawValue != "agentterm.chrome-window"
    }

    private func holdChromeWindows() {
        // One Chrome closed by itself is no longer held.
        let open = Set(NSApp.windows.map(ObjectIdentifier.init))
        if heldChromeWindows.contains(where: { !open.contains(ObjectIdentifier($0)) }) {
            heldChromeWindows.removeAll { !open.contains(ObjectIdentifier($0)) }
        }
        // Chrome shows a window it made more than once as it opens it: one
        // held back is kept out of sight until it is asked for.
        for window in heldChromeWindows where window.isVisible { window.orderOut(nil) }
        for window in NSApp.windows where window.isVisible && Self.isChromeBrowserWindow(window) && !heldChromeWindows.contains(window) {
            window.orderOut(nil)
            heldChromeWindows.append(window)
        }
    }

    /// Shows the windows that were held back, outside the app, and stops
    /// holding them: what Chrome opened together goes together.
    func showHeld() {
        let held = heldChromeWindows
        heldChromeWindows = []
        for window in held {
            window.identifier = NSUserInterfaceItemIdentifier("agentterm.chrome-window")
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the windows that were held back: Chrome's own closing.
    func dismissHeld() {
        let held = heldChromeWindows
        heldChromeWindows = []
        held.forEach { $0.close() }
    }

    /// Closes the held windows before Chromium stops: a window Chrome opened
    /// by itself would keep it from stopping.
    func closeHeldWindows() {
        let held = heldChromeWindows
        heldChromeWindows = []
        held.forEach { $0.close() }
    }

    func tabChanged() { changed?() }

    // MARK: Not kept

    /// The tabs are not kept: the app opens with none, an agent's that
    /// still runs included (BROWSER-9). What an earlier build kept is
    /// forgotten. A profile keeps its sign-ins and cookies all the same.
    static func forgetKeptTabs() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key == "browserTabs" || key.hasPrefix("browserTabs.") {
            defaults.removeObject(forKey: key)
        }
    }

    /// An agent's tabs whose agent ended are the user's from then on, as
    /// its shells are: in the one Browser, of no folder (#148).
    func sessionsChanged(_ sessions: [SessionInfo]) {
        let running = Set(sessions.map(\.id))
        // Another Mac's are as its host lists them (#147).
        for tab in tabs where !tab.isRemote {
            if let owner = tab.owner, !running.contains(owner) {
                tab.owner = nil
                tab.ownerTab = nil
                tab.userHasIt = false
                tab.project = ""
            }
        }
    }

    /// Every tab, as the other devices see them.
    var infos: [BrowserTabInfo] { tabs.map(\.info) }
}

/// A download a page started, into the Downloads folder.
struct BrowserDownload: Identifiable, Equatable {
    let id: Int32
    var path: String
    var url: String
    var percent: Int32
    /// 0 going on, 1 done, 2 cancelled or failed.
    var state: Int32
}

/// One tab of the browser.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id: String
    /// The folder of the agent that opened it, whose panes show it beside
    /// the agent; "" for the user's, which belong to no folder: the one
    /// Browser, in every project's strip (#148).
    var project: String
    /// The profile it uses: its sign-ins, cookies, storage and cache.
    let profile: String
    /// The agent's session that opened it, while it runs; nil for the user's.
    @Published var owner: SessionID?
    /// That session's tab id, for its area beside it.
    var ownerTab: String?
    @Published var title = "" { didSet { if title != oldValue { model?.tabChanged() } } }
    @Published var url = "" { didSet { if url != oldValue { model?.tabChanged() } } }
    @Published var loading = false { didSet { if loading != oldValue { model?.tabChanged() } } }
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress = 0.0
    /// Why the page did not load: CEF's code, its words, and the address.
    @Published var loadError: (code: Int32, text: String, url: String)?
    @Published var crashed = false
    /// The user took it from its agent, which waits until it is given back.
    @Published var userHasIt = false { didSet { if userHasIt != oldValue { model?.tabChanged() } } }
    /// What an agent did last in it, for the bar over it.
    @Published var agentAction: String?
    @Published var emulating: BrowserDevice? { didSet { model?.tabChanged() } }
    /// Its page's two modes: browsing, or picking its elements to send to
    /// an agent, one after another, until turned off.
    @Published var picking = false
    /// A page asking for a permission: the number to answer, who, and what.
    @Published var permission: (id: Int32, origin: String, what: String)?
    @Published var downloads: [BrowserDownload] = []
    @Published var findCount: Int32 = 0
    @Published var findActive: Int32 = 0
    @Published var zoom = 0.0
    /// Why Chromium could not show it.
    @Published var problem: String?
    /// A page of another Mac's (#147): shown by the pictures it sends,
    /// used through its host. Chromium is never started for it here.
    var isRemote = false
    /// The last picture of it, and the page's size in CSS pixels.
    @Published var remoteFrame: (image: NSImage, width: Double, height: Double)?
    /// The name of the profile it uses there.
    var remoteProfile = ""
    @Published private(set) var browserID: Int32 = 0
    /// The view Chromium draws the page in, moved to whichever pane shows it.
    let container = BrowserContainerView()
    /// The view of a pane last asked to show its page, which has it.
    weak var holder: BrowserHolderView?
    /// Sending pictures of the page to the devices that watch it.
    var frames: Task<Void, Never>?
    /// The last of what devices do to the page, which the next waits for.
    var deviceInput: Task<Void, Never>?

    /// Whether the Mac draws the page now: in a pane of a window that is
    /// on screen and not covered.
    var isDrawn: Bool {
        guard let window = container.window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return !container.isHiddenOrHasHiddenAncestor && !container.visibleRect.isEmpty
    }
    private(set) lazy var devtools = DevToolsSession { [weak self] in self?.browserID ?? 0 }
    private weak var model: BrowserModel?
    private var starting = false
    private var whenCreated: [(Bool) -> Void] = []

    init(id: String, project: String, profile: String, owner: SessionID?, ownerTab: String?, model: BrowserModel) {
        self.id = id
        self.project = project
        self.profile = profile
        self.owner = owner
        self.ownerTab = ownerTab
        self.model = model
        container.tab = self
    }

    /// Shows its page as a device, as tall as the pane it is in at most, or as itself.
    func emulate(_ device: BrowserDevice?) async throws {
        try await devtools.emulate(device, room: container.bounds.size)
        emulating = device
        // Around a device's screen, the pane dark, as DevTools have it: on
        // white, where the screen ends would not be seen.
        container.layer?.backgroundColor = (device == nil ? NSColor.white : NSColor(white: 0.16, alpha: 1)).cgColor
    }

    /// The pane it is in changed size: a page shown as a device is as tall
    /// as it again, once the size has settled (#107).
    func roomChanged() {
        guard let device = emulating else { return }
        refit?.cancel()
        refit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, self.emulating == device else { return }
            await self.devtools.fit(device, in: self.container.bounds.size)
        }
    }
    private var refit: Task<Void, Never>?

    /// Its name in a `TabLayout`.
    var tabID: String { "b:" + id }

    var displayTitle: String { title.isEmpty ? (url.isEmpty ? "New Tab" : url) : title }

    var info: BrowserTabInfo {
        BrowserTabInfo(
            id: id, title: title, url: url, project: project, openedBy: owner, loading: loading, userHasIt: userHasIt,
            emulating: emulating?.name,
            profile: BrowserProfiles.isPrivate(profile) ? BrowserWords.privateProfile : model?.profiles?.profile(profile)?.name ?? "",
            isPrivate: BrowserProfiles.isPrivate(profile))
    }

    /// Whether an agent's session sees it and may drive it: only the one
    /// that opened it.
    func reachable(by agent: SessionID) -> Bool { owner == agent }

    /// An address from what was typed: a URL, a host, a host and port, or
    /// words to search for.
    static func address(from typed: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "about:blank" }
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil, !text.contains(" ") {
            // "localhost:3000" has a scheme's shape: a port is not a scheme.
            if text.range(of: #"^[^/:]+:\d+"#, options: .regularExpression) != nil { return "http://" + text }
            return text
        }
        let local = text.range(of: #"^(localhost|127\.0\.0\.1|\[::1\]|[^\s/]+\.local)(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
        if local { return "http://" + text }
        if !text.contains(" "), text.range(of: #"^[^\s/]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil { return "https://" + text }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return "https://www.google.com/search?q=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
    }

    // MARK: Chromium

    /// Makes its page in Chromium, if it has none yet.
    func start(_ done: ((Bool) -> Void)? = nil) {
        // Closed, it has no page again: the pane that showed it is drawn
        // once more with it before it goes, and asked for one, which
        // nothing closed afterwards; its process ran on (BROWSER-34).
        if isClosed || isRemote { done?(false); return }
        if browserID != 0 { done?(true); return }
        if let done { whenCreated.append(done) }
        guard !starting else { return }
        guard Chromium.shared.start() else {
            problem = Chromium.shared.problem
            flush(false)
            return
        }
        starting = true
        problem = nil
        let isPrivate = BrowserProfiles.isPrivate(profile)
        if !isPrivate { model?.profiles?.markInUse(profile) }
        // In the window, so that Chromium draws it, until a pane shows it.
        BrowserParking.park(container)
        Chromium.shared.create(
            in: container, url: url.isEmpty ? "about:blank" : url, key: profile, folder: isPrivate ? nil : BrowserProfiles.folder(for: profile)
        ) { [weak self] browser in self?.made(browser) ?? { if browser != 0 { atc_close(browser) } }() }
    }

    /// A window a page opened, which Chromium makes itself in this tab's
    /// view, keeping its opener (#162): the view, and what is done with the
    /// browser made there.
    func madeByChromium() -> (view: NSView, made: (Int32) -> Void) {
        starting = true
        if !BrowserProfiles.isPrivate(profile) { model?.profiles?.markInUse(profile) }
        BrowserParking.park(container)
        return (container, { [weak self] browser in self?.made(browser) ?? { if browser != 0 { atc_close(browser) } }() })
    }

    /// Its browser made, or not (0).
    private func made(_ browser: Int32) {
        // Closed while its page was being made: the page goes at once.
        guard !isClosed else {
            if browser != 0 { atc_close(browser) }
            starting = false
            flush(false)
            return
        }
        starting = false
        guard browser != 0 else {
            problem = "Chromium could not open the page."
            flush(false)
            return
        }
        browserID = browser
        Chromium.shared.listen(to: browser) { [weak self] event in self?.handle(event) }
        devtools.start()
        flush(true)
    }

    private func flush(_ created: Bool) {
        let waiting = whenCreated
        whenCreated = []
        waiting.forEach { $0(created) }
    }

    /// Waits until its page is made, starting it if need be.
    func ready() async -> Bool {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }

    /// Its tab was closed: it never has a page again.
    private(set) var isClosed = false

    func shutDown() {
        isClosed = true
        guard browserID != 0 else { return }
        Chromium.shared.forget(browserID)
        atc_close(browserID)
        browserID = 0
    }

    private func handle(_ event: Chromium.Event) {
        switch event.kind {
        case ATC_EVENT_ADDRESS:
            url = event.text ?? url
        case ATC_EVENT_TITLE:
            title = event.text ?? title
        case ATC_EVENT_LOADING:
            loading = event.a != 0
            canGoBack = event.b != 0
            canGoForward = event.c != 0
            if loading {
                loadError = nil
                crashed = false
            }
        case ATC_EVENT_PROGRESS:
            progress = Double(event.a) / 1000
        case ATC_EVENT_LOAD_ERROR:
            loadError = (event.a, event.text ?? "", event.text2 ?? url)
        case ATC_EVENT_POPUP:
            if let address = event.text { model?.popup?(self, address) }
        case ATC_EVENT_CLOSED:
            // Not closed by the app: its page closed itself (`window.close()`,
            // a sign-in's popup once it answered, #162). Its tab goes too.
            let byItsPage = !isClosed
            Chromium.shared.forget(browserID)
            browserID = 0
            if byItsPage { model?.closedByItsPage?(self) }
        case ATC_EVENT_DEVTOOLS_RESULT:
            devtools.received(result: event.a, success: event.b != 0, data: event.data)
        case ATC_EVENT_DEVTOOLS_EVENT:
            devtools.received(event: event.text ?? "", data: event.data)
        case ATC_EVENT_FIND:
            findCount = event.a
            findActive = event.b
        case ATC_EVENT_DOWNLOAD:
            let download = BrowserDownload(id: event.a, path: event.text ?? "", url: event.text2 ?? "", percent: event.b, state: event.c)
            if let index = downloads.firstIndex(where: { $0.id == download.id }) {
                downloads[index] = download
            } else {
                downloads.append(download)
                devtools.happened.append("A download started: \(download.path).")
            }
        case ATC_EVENT_PERMISSION:
            if event.b == -1 {
                if permission?.id == event.a { permission = nil }
            } else {
                permission = (event.a, event.text ?? "", Self.permissionWords(UInt32(bitPattern: event.b)))
            }
        case ATC_EVENT_CRASHED:
            crashed = true
            loading = false
        case ATC_EVENT_FOCUS:
            model?.focused?(self)
        case ATC_EVENT_MENU_COMMAND:
            menuCommand(event.a, link: event.text, image: event.text2)
        default:
            break
        }
    }

    /// An item of the page's right-click menu that the app does itself
    /// (#131): a link or an image opened as a new page, its address copied,
    /// the page's DevTools.
    func menuCommand(_ command: Int32, link: String?, image: String?) {
        func copy(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        switch command {
        case ATC_MENU_OPEN_LINK: if let link, !link.isEmpty { model?.popup?(self, link) }
        case ATC_MENU_COPY_LINK: copy(link)
        case ATC_MENU_OPEN_IMAGE: if let image, !image.isEmpty { model?.popup?(self, image) }
        case ATC_MENU_COPY_IMAGE: copy(image)
        case ATC_MENU_INSPECT: showDevTools()
        default: break
        }
    }

    /// What a page asks for, in words.
    static func permissionWords(_ bits: UInt32) -> String {
        if bits & 0x4000_0000 != 0 {
            // Media: CEF's cef_media_access_permission_types_t.
            var asked: [String] = []
            if bits & 0x1 != 0 { asked.append("your microphone") }
            if bits & 0x2 != 0 { asked.append("your camera") }
            if bits & 0xC != 0 { asked.append("your screen") }
            return asked.isEmpty ? "your camera or microphone" : asked.joined(separator: " and ")
        }
        // cef_permission_request_types_t.
        let names: [(UInt32, String)] = [
            (1 << 0, "your accessibility events"), (1 << 1, "to run apps of yours"), (1 << 2, "to open more windows"), (1 << 3, "to read the clipboard"),
            (1 << 6, "your camera"), (1 << 9, "to reach devices"), (1 << 10, "your location"), (1 << 15, "your microphone"), (1 << 16, "MIDI"),
            (1 << 17, "MIDI devices"), (1 << 18, "to send notifications"), (1 << 19, "to download several files"), (1 << 20, "to protect media"),
            (1 << 21, "to keep the screen on"), (1 << 22, "your local fonts"), (1 << 23, "to store more data"), (1 << 24, "your local network"),
        ]
        let asked = names.filter { bits & $0.0 != 0 }.map(\.1)
        return asked.isEmpty ? "a permission" : asked.joined(separator: ", ")
    }

    // MARK: What the user and the agents do

    func load(_ typed: String) {
        if isRemote { return ask(.navigate(tab: id, url: typed)) }
        let address = Self.address(from: typed)
        url = address
        loadError = nil
        start { [weak self] created in
            guard created, let self else { return }
            atc_load(self.browserID, address)
        }
    }

    func back() { isRemote ? ask(.history(tab: id, step: -1)) : atc_back(browserID) }
    func forward() { isRemote ? ask(.history(tab: id, step: 1)) : atc_forward(browserID) }
    func reload() {
        if isRemote { return ask(.history(tab: id, step: 0)) }
        if browserID == 0 { start() } else { atc_reload(browserID, 0) }
    }
    func stop() { isRemote ? ask(.stop(tab: id)) : atc_stop(browserID) }

    /// What is done to a page of another Mac's is asked of that Mac (#147).
    func ask(_ request: BrowserRequest) { model?.remote?(request) }

    func setZoom(_ level: Double) {
        zoom = min(max(level, -5), 6)
        atc_set_zoom(browserID, zoom)
    }

    func find(_ text: String, forward: Bool = true, next: Bool = false) {
        guard !text.isEmpty else { return stopFinding() }
        atc_find(browserID, text, forward ? 1 : 0, 0, next ? 1 : 0)
    }

    func stopFinding() {
        atc_stop_finding(browserID, 1)
        findCount = 0
        findActive = 0
    }

    func showDevTools() { atc_show_devtools(browserID) }

    /// Its page, or another address, in a window of Chrome's own, outside
    /// the app, in its profile: where an extension's buttons are (#125).
    func openInChromeWindow(_ address: String? = nil) {
        guard browserID != 0 else { return }
        atc_open_chrome_window(browserID, address ?? url)
    }

    func answerPermission(_ allow: Bool) {
        guard let permission else { return }
        atc_answer_permission(permission.id, allow ? 1 : 0)
        self.permission = nil
    }

    func cancelDownload(_ download: BrowserDownload) { atc_cancel_download(download.id) }

    /// Gives the keyboard to its page.
    /// Gives the page the keyboard, as a click in it does: to the view of
    /// Chromium's that takes keys, the innermost that takes the keyboard.
    /// The page's outer view takes none, and Chromium's own `set_focus`
    /// leaves the window's keyboard where it was (PANE-17).
    func focus() {
        guard browserID != 0, let view = atc_view(browserID).map({ Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }) else { return }
        func taker(_ view: NSView) -> NSView? {
            for inner in view.subviews.reversed() { if let found = taker(inner) { return found } }
            return view.acceptsFirstResponder ? view : nil
        }
        if let taker = taker(view) { view.window?.makeFirstResponder(taker) }
        atc_focus(browserID, 1)
    }
}

/// The view Chromium's page is in; its page fills it.
final class BrowserContainerView: NSView {
    /// The tab whose page it is.
    weak var tab: BrowserTab?

    override init(frame: NSRect) {
        super.init(frame: frame.isEmpty ? NSRect(x: 0, y: 0, width: 1280, height: 800) : frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        for view in subviews { view.frame = bounds }
        if bounds.size != oldSize { tab?.roomChanged() }
    }
}

/// Where the pages no pane shows wait, inside the window: Chromium draws a
/// page only in a window, and an agent's page has to be drawn for its
/// pictures, whichever project is on show.
@MainActor
enum BrowserParking {
    static weak var lot: NSView?

    static func park(_ container: NSView) {
        guard let lot, container.superview !== lot else { return }
        container.removeFromSuperview()
        // Its size is kept, so that the page keeps its layout.
        if container.frame.width < 200 || container.frame.height < 200 { container.frame = NSRect(x: 0, y: 0, width: 1280, height: 800) }
        lot.addSubview(container)
    }
}

/// The lot itself: one point in the window's corner, its pages drawn and not seen.
struct BrowserParkingLot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.setAccessibilityElement(false)
        BrowserParking.lot = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// What a pane shows a page in: the page on top is the one seen, and
/// accessibility says whose it is (BROWSER-16).
final class BrowserHolderView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Page" }
    override func accessibilityIdentifier() -> String { "browser-page" }
    override func accessibilityValue() -> Any? {
        MainActor.assumeIsolated { (subviews.last as? BrowserContainerView)?.tab?.displayTitle }
    }

    /// The tab it was last asked to show.
    weak var shownTab: BrowserTab?

    /// The page is to have the keyboard once it is in the window: a part
    /// of an agent's area shown alone, or again with the others, is a new
    /// holder that SwiftUI puts in the window later, and the keyboard went
    /// nowhere when the page left the old one (PANE-19).
    var keyboardWanted = false

    func giveKeyboard() {
        keyboardWanted = true
        DispatchQueue.main.async { [weak self] in self?.takeKeyboardIfInWindow() }
    }

    private func takeKeyboardIfInWindow() {
        guard keyboardWanted, window != nil, let tab = shownTab, tab.holder === self, tab.container.superview === self else { return }
        keyboardWanted = false
        tab.focus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.takeKeyboardIfInWindow() }
    }
}

/// Shows a tab's page in a pane.
struct BrowserHost: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    /// Its pane, or its part of an agent's area, has the keyboard.
    var focused = false

    func makeNSView(context: Context) -> BrowserHolderView {
        let holder = BrowserHolderView()
        holder.wantsLayer = true
        holder.autoresizesSubviews = true
        return holder
    }

    func updateNSView(_ holder: BrowserHolderView, context: Context) {
        // The holder last asked to show the tab has its page. One on its way
        // out, asked once more after a new one took the page (a part of the
        // agent's area shown or hidden), took it back and then parked it,
        // and the new one was left blank (#94).
        if holder.shownTab !== tab || tab.holder == nil {
            holder.shownTab = tab
            tab.holder = holder
        }
        guard tab.holder === holder else { return }
        let container = tab.container
        // The tab shown before, when the pane shows another: back to the
        // lot, still drawn. Left here under the new one, it came back on
        // top of nothing when picked again, and the other's page stayed
        // over it (#92).
        for view in holder.subviews where view !== container { BrowserParking.park(view) }
        if container.superview !== holder {
            container.removeFromSuperview()
            container.frame = holder.bounds
            container.autoresizingMask = [.width, .height]
            holder.addSubview(container)
            // Moved where it has the keyboard: it keeps it.
            if focused { holder.giveKeyboard() }
        }
        if tab.browserID == 0, tab.problem == nil { tab.start() }
    }

    static func dismantleNSView(_ holder: BrowserHolderView, coordinator: ()) {
        // Back to the lot, still drawn, for an agent may still use it.
        MainActor.assumeIsolated {
            if let tab = holder.shownTab, tab.holder === holder { tab.holder = nil }
            for view in holder.subviews { BrowserParking.park(view) }
        }
    }
}
