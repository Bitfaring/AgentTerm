import AgentTermHost
import AgentTermProtocol
import AppKit
import SwiftUI

/// What the browser does for the agents, the user and the other devices
/// (#76). This app shows the browser of the Mac it runs on: it tells that
/// Mac's host so, and answers what the host passes on.
extension AppModel {
    /// What the user picked in a page to send an agent.
    struct BrowserPick: Identifiable {
        let id = UUID()
        let tab: BrowserTab
        let png: Data
        let url: String
        let details: String
    }

    // MARK: Wiring

    /// Called once: what the browser's tabs do reaches the rest of the app.
    func wireBrowser() {
        BrowserModel.forgetKeptTabs()
        browsers.profiles = profiles
        browsers.changed = { [weak self] in self?.browserTabsChanged() }
        browsers.popup = { [weak self] opener, address in
            guard let self else { return }
            let owner = opener.owner.flatMap { id in self.sessions.first { $0.id == id } }
            // In its opener's profile: a window that signs in, the sign-in of
            // that profile, and a private tab's, its private one.
            let tab = self.browsers.open(url: address, project: opener.project, owner: owner, profile: opener.profile)
            opener.devtools.happened.append("The page opened \(address) in a new tab, \(tab.id).")
            // The user's tab opens in front, as a browser's does; an
            // agent's goes beside the agent without taking the keyboard.
            if owner == nil { self.selectTab(id: tab.tabID) }
        }
        browsers.focused = { [weak self] tab in
            guard let self, self.frontTabID != tab.tabID else { return }
            // A page no pane shows was not clicked into: Chromium gave it the
            // keyboard as it loaded, a page a device opened for one. It does
            // not come to the front, and the keyboard goes back.
            guard tab.holder != nil else { return self.focusKeyboard() }
            self.selectTab(id: tab.tabID)
        }
    }

    /// The tabs changed: the panes follow, and the other devices are told,
    /// a moment later so that a page loading says it once.
    func browserTabsChanged() {
        syncTabs()
        var widths: [String: Int] = [:]
        for tab in browsers.tabs {
            if let device = tab.emulating, device.width > 0 { widths[tab.tabID] = device.width }
        }
        if widths != browserEmulation { browserEmulation = widths }
        // Only this Mac's.
        guard !isRemote, !browserTabsPending else { return }
        browserTabsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.browserTabsPending = false
            guard !self.isRemote else { return }
            self.connection?.send(.browserTabs(self.browsers.infos))
        }
    }

    /// Once connected to this Mac's own host: this app shows its browser.
    func announceBrowser() {
        guard !isRemote else { return }
        connection?.send(.browserProvider(true))
        connection?.send(.browserTabs(browsers.infos))
    }

    // MARK: The user's

    /// A new tab of the user's, in the project on show, in front: in the
    /// default profile, the one picked, or private.
    func openBrowserTab(url: String? = nil, profile: String? = nil, isPrivate: Bool = false) {
        guard !isRemote else {
            notice = "The browser is the Mac's own: open it in AgentTerm on \(remote?.name ?? "that Mac")."
            return
        }
        show(.sessions, toggling: false)
        let tab = browsers.open(url: url, project: shownProject, owner: nil, profile: isPrivate ? BrowserProfiles.privateID(for: nil) : profile)
        selectTab(id: tab.tabID)
        if url == nil { browserAddressRequest += 1 }
    }

    func closeBrowserTab(_ tab: BrowserTab) {
        browsers.close(tab)
        if browserInFront == tab.tabID {
            browserInFront = nil
            syncTabs()
            adoptFocusedFront()
        }
    }

    /// The running agents of a tab's project, which what the user picks in
    /// it can be sent to.
    func agentsInProject(of tab: BrowserTab) -> [SessionInfo] {
        sessions.filter { session in
            session.agent != nil && session.openedBy == nil && (tab.project.isEmpty || WorktreePath.belongs(session.cwd, to: tab.project))
        }
    }

    /// The agent that drives a tab, by name: the one that opened it; ""
    /// for the user's.
    func agentNames(of tab: BrowserTab) -> String {
        tab.owner.flatMap { id in sessions.first { $0.id == id }?.displayName } ?? ""
    }

    /// Pictures of a tab's page for the devices that watch it, about ten a
    /// second. While the Mac draws the page they are what it draws,
    /// streamed: a picture taken of a page shown as a device whose pixels
    /// are not the screen's has Chromium lay it out again for the picture,
    /// which the Mac would show in between (#100). While the Mac does not
    /// draw it, which Chromium then stops doing, they are taken, each sent
    /// only when it differs from the last (BROWSER-15).
    func watch(_ tab: BrowserTab, _ on: Bool, width: Int) {
        tab.frames?.cancel()
        tab.frames = nil
        tab.devtools.screencast(width: width, nil)
        guard on else { return }
        tab.frames = Task { @MainActor [weak self, weak tab] in
            var last: Data?
            while !Task.isCancelled {
                guard let self, let tab else { return }
                if await tab.ready() {
                    // The size of what is shown, by which a touch is placed.
                    let size = try? await tab.devtools.viewport()
                    if tab.isDrawn, let size {
                        tab.devtools.screencast(width: width) { [weak self, weak tab] jpeg in
                            guard let self, let tab else { return }
                            self.connection?.send(.browserFrame(tab: tab.id, jpeg: jpeg, width: size.width, height: size.height))
                        }
                    } else {
                        tab.devtools.screencast(width: width, nil)
                        if let frame = try? await tab.devtools.frame(width: width), frame.jpeg != last {
                            last = frame.jpeg
                            self.connection?.send(.browserFrame(tab: tab.id, jpeg: frame.jpeg, width: frame.width, height: frame.height))
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// The user takes a tab from its agents, or gives it back.
    func setUserHas(_ tab: BrowserTab, _ has: Bool) {
        tab.userHasIt = has
        if has { tab.agentAction = nil }
    }

    func emulate(_ tab: BrowserTab, _ device: BrowserDevice?) {
        Task { @MainActor in
            guard await tab.ready() else { return }
            try? await tab.emulate(device)
        }
    }

    /// A click in a page an agent drives takes it over: the two never type
    /// or click in it at once (#76).
    func pageClicked(at point: CGPoint) {
        for (place, frame) in paneFrames where frame.contains(point) {
            guard case .page(let id) = place, let tab = browsers.tab(forTab: id) else { continue }
            if !agentNames(of: tab).isEmpty, !tab.userHasIt { setUserHas(tab, true) }
        }
    }

    // MARK: Profiles

    /// Why an agent's tab was not opened in a profile, in words for it.
    struct ProfileRefusal: Error {
        let text: String
    }

    /// The profile an agent's tab opens in: private, in one of its own in
    /// memory; the one it names; the one its tabs use; or the only one
    /// there is. With several and none named yet, the agent is told which
    /// there are, to ask the user in its conversation (#76).
    private func profile(for agent: SessionInfo, named name: String?, isPrivate: Bool) -> Result<String, ProfileRefusal> {
        if isPrivate { return .success(BrowserProfiles.privateID(for: agent.id)) }
        let names = profiles.infos.map(\.name)
        if let name {
            guard let named = profiles.profile(named: name) else { return .failure(ProfileRefusal(text: BrowserWords.noProfile(name, names))) }
            browsers.agentProfiles[agent.id] = named.id
            return .success(named.id)
        }
        if let chosen = browsers.agentProfiles[agent.id], profiles.profile(chosen) != nil { return .success(chosen) }
        guard profiles.list.count > 1 else {
            browsers.agentProfiles[agent.id] = profiles.defaultID
            return .success(profiles.defaultID)
        }
        return .failure(ProfileRefusal(text: BrowserWords.whichProfile(names)))
    }

    /// Deletes a profile, closing its tabs first.
    func deleteProfile(_ id: String) {
        for tab in browsers.tabs where tab.profile == id { closeBrowserTab(tab) }
        browsers.agentProfiles = browsers.agentProfiles.filter { $0.value != id }
        profiles.delete(id)
    }

    // MARK: Sending a part of a page to an agent

    /// Turns a page's picking on, where each element clicked is sent to an
    /// agent, or off, back to browsing it.
    func setPicking(_ tab: BrowserTab, _ on: Bool) {
        tab.picking = on
        if on { pickForAgent(tab) } else { tab.devtools.stopPicking() }
    }

    /// The sheet of an element picked was closed, sent or not: the next
    /// element is picked while picking is still on.
    func pickDismissed() {
        guard let tab = lastPicked, tab.picking, tab.browserID != 0 else { return }
        pickForAgent(tab)
    }

    /// Lets the user point at an element of the page, then asks what to
    /// send and to whom.
    func pickForAgent(_ tab: BrowserTab) {
        guard tab.browserID != 0 else { return }
        tab.devtools.pickElement { [weak self] node in
            Task { @MainActor in
                guard let self else { return }
                let box = try? await tab.devtools.box(of: node)
                let png = (try? await tab.devtools.screenshot(clip: box, fullPage: false)) ?? Data()
                let details = await tab.devtools.describe(node)
                self.lastPicked = tab
                self.pendingPick = BrowserPick(tab: tab, png: png, url: tab.url, details: details)
            }
        }
        notice = nil
    }

    /// Saves the picture in the project, and types into the agent's
    /// session where it is, with the address, the element and the note.
    func send(_ pick: BrowserPick, note: String, to agent: SessionID) {
        guard let session = sessions.first(where: { $0.id == agent }), let controller = controller(for: agent) else { return }
        let folder = URL(fileURLWithPath: session.cwd).appendingPathComponent(".agentterm/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Handoff.keepOutOfGit(session.cwd)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(stamp)-tab-\(pick.tab.id).png")
        try? pick.png.write(to: file)
        var text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "Look at this element of the page." }
        text += "\nPage: \(pick.url) (browser tab \(pick.tab.id) in AgentTerm)\nScreenshot: \(file.path)"
        if !pick.details.isEmpty { text += "\n" + pick.details }
        let typed = SentText.text(text, bracketedPaste: controller.bracketedPasteMode)
        connection?.sendInput(Data(typed.utf8), to: agent)
        // Apart from the text, or an agent takes the Return for a new line.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.connection?.sendInput(Data("\r".utf8), to: agent) }
        if let session = sessions.first(where: { $0.id == agent }) { select(session: session) }
    }

    // MARK: What is asked of the browser

    /// Does what the host passed on, for an agent's session or a device,
    /// and answers it.
    func answerBrowser(id: Int, agent: SessionID?, request: BrowserRequest) {
        Task { @MainActor in
            let result = await browserResult(agent: agent, request: request)
            connection?.send(.browserReply(id: id, result: result))
        }
    }

    private func browserResult(agent: SessionID?, request: BrowserRequest) async -> BrowserResult {
        if isRemote { return .refused(BrowserWords.noApp) }
        if agent != nil, !agentsUseBrowser { return .refused(BrowserWords.turnedOff) }
        guard let agent else { return await deviceRequest(request) }
        guard let session = sessions.first(where: { $0.id == agent }) else {
            return .refused("This is not the session of an agent AgentTerm started, or that session has ended.")
        }
        switch request {
        case .open(let url, let named, let isPrivate):
            let project = folders.first { WorktreePath.belongs(session.cwd, to: $0.path) }?.path ?? ""
            let profile: String
            switch self.profile(for: session, named: named, isPrivate: isPrivate) {
            case .success(let chosen): profile = chosen
            case .failure(let why): return .refused(why.text)
            }
            // Empty first, then loaded as browser_navigate does: made with
            // its address, its first document is the empty one, which has
            // loaded already, and the page would be said before it is there.
            let tab = browsers.open(url: nil, project: project, owner: session, profile: profile)
            tab.agentAction = "Opened \(url ?? "a tab")"
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            guard let url else { return .text("Opened tab \(tab.id), empty. The user sees it beside you.") }
            let loaded: BrowserResult
            do {
                loaded = try await act(.navigate(tab: tab.id, url: url), in: tab)
            } catch let failure as DevToolsSession.Failure {
                loaded = .refused(failure.text)
            } catch {
                loaded = .refused(error.localizedDescription)
            }
            if case .refused(let why) = loaded { return .text("Opened tab \(tab.id), beside you where the user sees it, but \(why)") }
            return .text("Opened tab \(tab.id)" + (await whereNow(tab)) + " The user sees it beside you.")
        case .tabs:
            return .tabs(browsers.tabs.filter { $0.reachable(by: agent) }.map(\.info))
        case .profiles:
            let uses = browsers.agentProfiles[agent].flatMap { profiles.profile($0)?.name }
            return .text(BrowserWords.profiles(profiles.infos.map(\.name), uses: uses))
        default:
            break
        }
        guard let id = request.tab else { return .refused("Which tab: give its id.") }
        // Another's tab is as good as none: an agent sees only its own.
        guard let tab = browsers.tab(id: id), tab.reachable(by: agent) else { return .refused(BrowserWords.notYours(id)) }
        if request.acts, tab.userHasIt { return .refused(BrowserWords.userHasIt(id)) }
        guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
        if case .close = request {
            closeBrowserTab(tab)
            return .text("Closed tab \(id).")
        }
        var request = request
        if case .upload(let tab, let ref, let paths) = request {
            // Files of its project only: an agent does not send what else
            // is on the Mac to a site (principle 2).
            let project = folders.first { WorktreePath.belongs(session.cwd, to: $0.path) }?.path ?? session.cwd
            let root = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL.path
            var chosen: [String] = []
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: session.cwd).appendingPathComponent(expanded))
                    .resolvingSymlinksInPath().standardizedFileURL
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                    return .refused(BrowserWords.noFile(url.path))
                }
                guard url.path.hasPrefix(root + "/") else { return .refused(BrowserWords.notInProject(url.path, project)) }
                chosen.append(url.path)
            }
            request = .upload(tab: tab, ref: ref, paths: chosen)
        }
        do {
            return try await act(request, in: tab)
        } catch let failure as DevToolsSession.Failure {
            return .refused(failure.text)
        } catch {
            return .refused("It failed: \(error.localizedDescription)")
        }
    }

    /// Where a tab is now, for an agent: its address, title, and what came of the last action.
    private func whereNow(_ tab: BrowserTab) async -> String {
        let title = await tab.devtools.pageTitle() ?? tab.title
        var text = " at \(tab.url)" + (title.isEmpty ? "" : " — “\(title)”") + "."
        if let error = tab.loadError { text += " It did not load: " + BrowserPaneView.words(for: error) }
        let happened = tab.devtools.happened
        tab.devtools.happened = []
        if !happened.isEmpty { text += " " + happened.joined(separator: " ") }
        let errors = tab.devtools.console.suffix(5).filter { $0.level == "error" }
        if !errors.isEmpty { text += " The console has \(errors.count) recent error\(errors.count == 1 ? "" : "s"); see browser_console." }
        return text
    }

    private func act(_ request: BrowserRequest, in tab: BrowserTab) async throws -> BrowserResult {
        let devtools = tab.devtools
        func done(_ action: String) { tab.agentAction = action }
        switch request {
        case .navigate(_, let url):
            let address = BrowserTab.address(from: url)
            done("Went to \(address)")
            tab.loadError = nil
            let answer = try await devtools.call("Page.navigate", ["url": address], seconds: 30)
            if let failed = answer["errorText"] as? String {
                let words = failed.contains("CONNECTION_REFUSED") ? BrowserWords.nothingAnswers(address) : failed
                return .refused("\(address) did not load: \(words)")
            }
            await devtools.waitForLoad(seconds: 20)
            return .text("Loaded" + (await self.whereNow(tab)))
        case .history(_, let step):
            let before = devtools.document
            if step < 0 { tab.back() } else if step > 0 { tab.forward() } else { tab.reload() }
            done(step < 0 ? "Went back" : step > 0 ? "Went forward" : "Reloaded")
            try? await Task.sleep(nanoseconds: 300_000_000)
            if devtools.document != before || step == 0 { await devtools.waitForLoad(seconds: 20) }
            return .text("Now" + (await self.whereNow(tab)))
        case .snapshot(_, let within):
            let text = try await devtools.snapshot(within: within)
            return .text("Tab \(tab.id) at \(tab.url)" + (tab.title.isEmpty ? "" : " — “\(tab.title)”") + ":\n" + text)
        case .screenshot(_, let ref, let fullPage):
            let clip = try await ref.map { try devtools.node(for: $0) }.asyncMap { try await devtools.box(of: $0) }
            let png = try await devtools.screenshot(clip: clip, fullPage: fullPage)
            return .image(png: png, text: "Tab \(tab.id) at \(tab.url)" + (fullPage ? ", all of the page." : clip != nil ? ", element \(ref ?? "")." : ", as it is shown."))
        case .click(_, let ref, let double):
            let node = try devtools.node(for: ref)
            let before = (url: tab.url, document: devtools.document)
            done("Clicked \(ref)")
            try await devtools.click(node, double: double)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if devtools.document != before.document || tab.loading { await devtools.waitForLoad(seconds: 15) }
            let moved = devtools.document != before.document || tab.url != before.url
            return .text("Clicked \(ref). " + (moved ? "The page changed:" : "The page stayed") + (await self.whereNow(tab)))
        case .hover(_, let ref):
            let point = try await devtools.center(of: try devtools.node(for: ref))
            try await devtools.mouse("mouseMoved", at: point)
            done("Pointed at \(ref)")
            return .text("The pointer is over \(ref).")
        case .type(_, let ref, let text, let submit, let append):
            let node = try devtools.node(for: ref)
            done("Typed into \(ref)")
            let value = try await devtools.type(text, into: node, append: append, submit: submit)
            if submit {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if tab.loading { await devtools.waitForLoad(seconds: 15) }
            }
            return .text(
                "Typed into \(ref)" + (value.map { ", which now holds “\($0.count > 200 ? String($0.prefix(200)) + "…" : $0)”" } ?? "")
                    + (submit ? ", and pressed Enter. Now" + (await self.whereNow(tab)) : "."))
        case .select(_, let ref, let values):
            let picked = try await devtools.select(values, in: try devtools.node(for: ref))
            done("Picked \(picked.joined(separator: ", ")) in \(ref)")
            return .text("Picked \(picked.map { "“\($0)”" }.joined(separator: ", ")) in \(ref).")
        case .upload(_, let ref, let paths):
            try await devtools.upload(paths, into: try devtools.node(for: ref))
            let names = paths.map { ($0 as NSString).lastPathComponent }
            done("Chose \(names.joined(separator: ", ")) in \(ref)")
            return .text("Chose \(names.map { "“\($0)”" }.joined(separator: ", ")) in \(ref).")
        case .press(_, let key):
            done("Pressed \(key)")
            let before = devtools.document
            try await devtools.press(key)
            try? await Task.sleep(nanoseconds: 300_000_000)
            if devtools.document != before || tab.loading { await devtools.waitForLoad(seconds: 15) }
            return .text("Pressed \(key). Now" + (await self.whereNow(tab)))
        case .scroll(_, let ref, let x, let y):
            let point: CGPoint
            if let ref {
                point = try await devtools.center(of: try devtools.node(for: ref))
            } else {
                let metrics = try await devtools.call("Page.getLayoutMetrics")
                let viewport = (metrics["cssLayoutViewport"] as? [String: Any]) ?? [:]
                point = CGPoint(x: (viewport["clientWidth"] as? Double ?? 800) / 2, y: (viewport["clientHeight"] as? Double ?? 600) / 2)
            }
            try await devtools.mouse("mouseWheel", at: point, deltaX: x, deltaY: y)
            done("Scrolled")
            try? await Task.sleep(nanoseconds: 250_000_000)
            return .text("Scrolled by \(Int(x)), \(Int(y)).")
        case .wait(_, let text, let gone, let seconds):
            let deadline = Date().addingTimeInterval(min(max(seconds, 0), 600))
            while Date() < deadline {
                if Task.isCancelled { break }
                let page = await devtools.pageText()
                if let text, page.contains(text) { return .text("“\(text)” is on the page" + (await self.whereNow(tab))) }
                if let gone, !page.contains(gone) { return .text("“\(gone)” is gone from the page" + (await self.whereNow(tab))) }
                if text == nil, gone == nil, devtools.loaded || !tab.loading { return .text("The page has loaded" + (await self.whereNow(tab))) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return .text("Still waiting after \(Int(seconds)) seconds; the page" + (await self.whereNow(tab)))
        case .evaluate(_, let script):
            done("Ran a script")
            return .text(try await devtools.evaluate(script))
        case .console(_, let errorsOnly):
            let entries = devtools.console.filter { !errorsOnly || $0.level == "error" || $0.level == "warning" }
            if entries.isEmpty { return .text(errorsOnly ? "No error or warning in the console." : "The console is empty.") }
            return .text(entries.suffix(200).map { "[\($0.level)] \($0.text)" + ($0.source.map { " (\($0))" } ?? "") }.joined(separator: "\n"))
        case .network(_, let failedOnly):
            let requests = devtools.requests.filter { !failedOnly || $0.failure != nil || ($0.status ?? 0) >= 400 }
            if requests.isEmpty { return .text(failedOnly ? "No request failed." : "No request since the page loaded.") }
            return .text(
                requests.suffix(200).map { request in
                    let outcome = request.failure.map { "failed: \($0)" } ?? request.status.map(String.init) ?? (request.done ? "done" : "pending")
                    return "\(request.method) \(request.url) → \(outcome)" + (request.type.isEmpty ? "" : " (\(request.type))")
                }.joined(separator: "\n"))
        case .emulate(_, let device):
            try await tab.emulate(device)
            done(device.map { "Shows the page as \($0.name)" } ?? "Shows the page as itself")
            return .text(device.map { "Tab \(tab.id) is shown as \($0.name)" + ($0.width > 0 ? ", \($0.width) × \($0.height)" : "") + "." } ?? "Tab \(tab.id) is shown as itself again.")
        case .open, .tabs, .close, .picture, .takeOver, .giveBack, .watch, .tap, .text, .newTab, .stop, .profiles:
            return .refused("That is not for this tab.")
        }
    }

    /// What a device asks: a picture of a tab, or taking it over.
    private func deviceRequest(_ request: BrowserRequest, inTurn: Bool = false) async -> BrowserResult {
        // What a device does to a page is done in the order it was sent:
        // each answer is awaited in a task of its own, and text typed and a
        // Backspace after it must not change places.
        if !inTurn, request.acts, let id = request.tab, let tab = browsers.tab(id: id) {
            let before = tab.deviceInput
            let turn = Task { @MainActor [weak self] () -> BrowserResult in
                _ = await before?.value
                guard let self else { return .refused(BrowserWords.noApp) }
                return await self.deviceRequest(request, inTurn: true)
            }
            tab.deviceInput = Task { _ = await turn.value }
            return await turn.value
        }
        if case .profiles = request { return .profiles(profiles.infos) }
        if case .newTab(let project, let url, let named, let isPrivate) = request {
            // The user's, as one opened on the Mac, but not brought to the
            // front there: they are on the device.
            let profile = isPrivate ? BrowserProfiles.privateID(for: nil) : named.flatMap { profiles.profile($0)?.id } ?? profiles.defaultID
            let tab = browsers.open(url: url, project: project, owner: nil, profile: profile)
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            return .opened(tab: tab.id)
        }
        guard let id = request.tab, let tab = browsers.tab(id: id) else { return .refused(BrowserWords.noTab(request.tab ?? "")) }
        switch request {
        case .takeOver:
            setUserHas(tab, true)
            return .tabs(browsers.infos)
        case .giveBack:
            setUserHas(tab, false)
            return .tabs(browsers.infos)
        case .watch(_, let on, let width):
            watch(tab, on, width: width)
            return .text(on ? "Watching." : "Stopped.")
        case .tap(_, let x, let y):
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            // The user acts on it from the device: an agent's tab is theirs
            // until they give it back, as a click on the Mac makes it.
            if tab.owner != nil, !tab.userHasIt { setUserHas(tab, true) }
            do {
                try await tab.devtools.tap(x: x, y: y)
                // Whether a field took the keyboard: the device's comes up.
                return .touched(field: (try? await tab.devtools.fieldHasKeyboard()) ?? false)
            } catch {
                return .refused((error as? DevToolsSession.Failure)?.text ?? error.localizedDescription)
            }
        case .text(_, let text):
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            if tab.owner != nil, !tab.userHasIt { setUserHas(tab, true) }
            do {
                try await tab.devtools.call("Input.insertText", ["text": text])
                return .text("Typed.")
            } catch {
                return .refused((error as? DevToolsSession.Failure)?.text ?? error.localizedDescription)
            }
        case .stop:
            if tab.owner != nil, !tab.userHasIt { setUserHas(tab, true) }
            tab.stop()
            return .text("Stopped.")
        case .emulate(_, let device):
            // As the Show As menu does on the Mac: the page stays its agent's.
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            do {
                try await tab.emulate(device)
                return .tabs(browsers.infos)
            } catch {
                return .refused((error as? DevToolsSession.Failure)?.text ?? error.localizedDescription)
            }
        case .close:
            // As its close button does on the Mac, an agent's tab too.
            closeBrowserTab(tab)
            return .tabs(browsers.infos)
        case .press, .scroll, .history, .navigate:
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            if tab.owner != nil, !tab.userHasIt { setUserHas(tab, true) }
            do {
                return try await act(request, in: tab)
            } catch {
                return .refused((error as? DevToolsSession.Failure)?.text ?? error.localizedDescription)
            }
        case .picture:
            guard await tab.ready() else { return .refused(tab.problem ?? BrowserWords.notInBuild) }
            do {
                // Small, for a phone: a JPEG of what is shown.
                let answer = try await tab.devtools.call("Page.captureScreenshot", ["format": "jpeg", "quality": 60], seconds: 20)
                guard let base64 = answer["data"] as? String, let data = Data(base64Encoded: base64) else { return .refused("The page gave no picture.") }
                return .image(png: data, text: tab.displayTitle)
            } catch let failure as DevToolsSession.Failure {
                return .refused(failure.text)
            } catch {
                return .refused(error.localizedDescription)
            }
        default:
            return .refused("A device can look at a tab, and take it over or give it back.")
        }
    }
}

extension Optional {
    /// The value made into another with an async function, or nil.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
