import AgentTermProtocol
import AppKit
import SwiftUI

/// A place in the middle of the window a click can land in (#69): a pane,
/// a part of an agent's area inside one, or a page.
enum PanePlace: Hashable {
    case pane(String)
    case part(agent: String, AgentAreaPart)
    /// The page of a browser tab (#76).
    case page(String)
}

/// The parts of an agent's area: the agent, its page, its shells.
enum AgentAreaPart: String, Hashable {
    case agent, browser, shells
}

extension TabID {
    /// A project's Shells, Browser, Diffs or Files tab (#127).
    static func holder(_ kind: HolderKind, _ project: String) -> String { "h:\(kind.rawValue):\(project)" }

    static func holder(of id: String) -> (kind: HolderKind, project: String)? {
        guard id.hasPrefix("h:") else { return nil }
        let rest = id.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":"), let kind = HolderKind(rawValue: String(rest[..<colon])) else { return nil }
        return (kind, String(rest[rest.index(after: colon)...]))
    }
}

/// The panes of the middle of the window (#69), and the groups of its
/// strip (#127). Each project has a layout of its own. Its strip holds
/// groups: each agent, with its own pages and shells; and the user's
/// shells, pages, diffs and files, one group of each. The row under the
/// strip holds the items of the group in front, and is where they are
/// picked, opened and closed. One of the user's groups shows one of its
/// items at a time. An agent's tab shows the agent with its page and its
/// shell beside it, its area (#69): the agent on the left, the page picked
/// on the right, the shell picked under both.
///
/// What the rest of the app calls the tab in front (`selectedSession`,
/// `files.active`, `diffInFront`, `browserInFront`) is the item the
/// keyboard is in, in the group in front of the pane the keyboard is in:
/// setting it brings that group to the front, showing it, and puts the
/// keyboard there.
extension AppModel {
    // MARK: Kept for each Mac

    private static func workspacesKey(_ mac: String?) -> String { mac.map { "paneLayouts.\($0)" } ?? "paneLayouts" }
    private static func agentAreasKey(_ mac: String?) -> String { mac.map { "agentAreas.\($0)" } ?? "agentAreas" }

    static func savedWorkspaces(for mac: String?) -> [String: PaneLayout] {
        UserDefaults.standard.data(forKey: workspacesKey(mac)).flatMap { try? JSONDecoder().decode([String: PaneLayout].self, from: $0) } ?? [:]
    }

    static func savedAgentAreas(for mac: String?) -> [String: AgentArea] {
        UserDefaults.standard.data(forKey: agentAreasKey(mac)).flatMap { try? JSONDecoder().decode([String: AgentArea].self, from: $0) } ?? [:]
    }

    func saveWorkspaces() {
        if let data = try? JSONEncoder().encode(workspaces) { UserDefaults.standard.set(data, forKey: Self.workspacesKey(remote?.id)) }
    }

    func saveAgentAreas() {
        if let data = try? JSONEncoder().encode(agentAreas) { UserDefaults.standard.set(data, forKey: Self.agentAreasKey(remote?.id)) }
    }

    // MARK: Projects

    /// The project a path is in: the listed folder that holds it, the
    /// nearest one, or "" for none.
    func project(ofPath path: String) -> String {
        if let worktreeOf = WorktreePath.project(of: path), folders.contains(where: { $0.path == worktreeOf }) { return worktreeOf }
        return folders.map(\.path).filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? ""
    }

    /// The project of a group or an item. A session is its folder's as the
    /// list at the left has it: started in the folder or in a worktree of it.
    func project(ofTab id: String) -> String {
        // The one Browser and the user's pages are every project's (#148):
        // the one on show.
        if id == Self.theBrowser { return shownProject }
        if let holder = TabID.holder(of: id) { return holder.project }
        if let session = session(forTab: id) {
            return folders.first { WorktreePath.belongs(session.cwd, to: $0.path) }?.path ?? ""
        }
        if let document = document(forTab: id) { return project(ofPath: document.path) }
        if let diff = diffTabs.first(where: { $0.tabID == id }) { return project(ofPath: diff.folder) }
        if let tab = browsers.tab(forTab: id) { return tab.owner == nil ? shownProject : tab.project }
        return ""
    }

    /// The user's pages, all in one group of no folder (#148), as a window
    /// of Chrome holds its tabs.
    static let theBrowser = TabID.holder(.browser, "")

    /// The layout of the project on show.
    var paneLayout: PaneLayout {
        get { workspaces[shownProject] ?? PaneLayout() }
        set { workspaces[shownProject] = newValue }
    }

    // MARK: An agent's own shells and pages

    /// The shells and pages each agent opened, or had opened beside it, by
    /// the tab ids of the agents' sessions; and for each of those, its
    /// agent. A shell whose agent has ended is the user's, and so is one an
    /// agent typed in a shell of the user's opened (#129): only an agent's
    /// session has a tab to hold it.
    var companions: (shells: [String: [String]], browsers: [String: [String]], owner: [String: String]) {
        var shells: [String: [String]] = [:]
        var owner: [String: String] = [:]
        let rank = tabRank
        for shell in sessions where shell.openedBy != nil {
            guard let agent = sessions.first(where: { $0.id == shell.openedBy }), agent.agent != nil else { continue }
            let agentTab = TabID.session(agent), shellTab = TabID.session(shell)
            shells[agentTab, default: []].append(shellTab)
            owner[shellTab] = agentTab
        }
        for (agent, list) in shells { shells[agent] = list.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) } }
        var browserTabs: [String: [String]] = [:]
        for tab in browsers.tabs {
            guard let agentTab = tab.ownerTab, sessions.contains(where: { TabID.session($0) == agentTab && $0.agent != nil }) else { continue }
            browserTabs[agentTab, default: []].append(tab.tabID)
            owner[tab.tabID] = agentTab
        }
        return (shells, browserTabs, owner)
    }

    private var tabRank: [String: Int] { Dictionary(tabLayout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// Whether an agent's tab shows an area: the agent with a page or a
    /// shell of its own beside it.
    func hasArea(_ agentTab: String) -> Bool {
        let all = companions
        return all.shells[agentTab] != nil || all.browsers[agentTab] != nil
    }

    // MARK: The user's own, one group of each kind a project (#127)

    /// Whether a session is a shell of the user's: no agent in it, and no
    /// agent's it is.
    func isUserShell(_ session: SessionInfo) -> Bool { session.agent == nil && companions.owner[TabID.session(session)] == nil }

    /// A project's shells of the user's, in the order they were started.
    func userShells(in project: String) -> [SessionInfo] {
        let owner = companions.owner
        return sessions.filter { $0.agent == nil && owner[TabID.session($0)] == nil && self.project(ofTab: TabID.session($0)) == project }
    }

    /// The user's pages of a project, in the order they were opened: the
    /// pages no agent has beside it.
    func userPages(in project: String) -> [BrowserTab] {
        let owner = companions.owner
        return browsers.tabs.filter { $0.project == project && owner[$0.tabID] == nil }
    }

    /// A project's diffs, in the order they were opened.
    func userDiffs(in project: String) -> [OpenDiff] { diffTabs.filter { self.project(ofPath: $0.folder) == project } }

    /// A project's open files, in the order they were opened.
    func userFiles(in project: String) -> [OpenDocument] { files.documents.filter { self.project(ofPath: $0.path) == project } }

    // MARK: Groups and their items

    /// The groups there are, as the strip holds them: each agent's session,
    /// and each project's groups of the user's that hold something.
    var liveTabIDs: [String] {
        let owner = companions.owner
        var groups = SessionInfo.withTabs(sessions).map(TabID.session)
        var holders: [String] = []
        func add(_ kind: HolderKind, _ project: String) {
            let id = TabID.holder(kind, project)
            if !holders.contains(id) { holders.append(id) }
        }
        for session in sessions where session.agent == nil && owner[TabID.session(session)] == nil { add(.shells, project(ofTab: TabID.session(session))) }
        for tab in browsers.tabs where owner[tab.tabID] == nil { add(.browser, tab.project) }
        for diff in diffTabs { add(.diffs, project(ofPath: diff.folder)) }
        for document in files.documents { add(.files, project(ofPath: document.path)) }
        groups += holders
        return groups
    }

    /// The group an item is shown in: its agent's, or the user's group of
    /// its kind in its project. A group is its own.
    func stripTab(of id: String) -> String {
        if TabID.holder(of: id) != nil { return id }
        if let agent = companions.owner[id] { return agent }
        if let session = session(forTab: id) {
            return session.agent != nil ? id : TabID.holder(.shells, project(ofTab: id))
        }
        if let tab = browsers.tab(forTab: id) { return TabID.holder(.browser, tab.project) }
        if diffTabs.contains(where: { $0.tabID == id }) { return TabID.holder(.diffs, project(ofTab: id)) }
        if document(forTab: id) != nil { return TabID.holder(.files, project(ofTab: id)) }
        return id
    }

    /// A group's items, in the order of its row: an agent first, then its
    /// pages and its shells.
    func members(of group: String) -> [String] {
        if let holder = TabID.holder(of: group) {
            switch holder.kind {
            case .shells: return userShells(in: holder.project).map(TabID.session)
            case .browser: return userPages(in: holder.project).map(\.tabID)
            case .diffs: return userDiffs(in: holder.project).map(\.tabID)
            case .files: return userFiles(in: holder.project).map { TabID.file($0.path) }
            }
        }
        let all = companions
        return [group] + (all.browsers[group] ?? []) + (all.shells[group] ?? [])
    }

    /// The item of a group the keyboard is in, when the group is in front.
    /// One of the user's groups shows one item, the one picked last, else
    /// its first. An agent's tab shows the agent with its page and its
    /// shell beside it: the one of them the keyboard is in.
    func shownMember(of group: String) -> String? {
        if TabID.holder(of: group) == nil, hasArea(group) { return focusedInner(agent: group, part: agentAreaFocus[group] ?? .agent) ?? group }
        let list = members(of: group)
        if let shown = groupShown[group], list.contains(shown) { return shown }
        return list.first
    }

    /// The group in front, as its pane's strip has it.
    var frontStripTab: String? { frontTabID.map(stripTab) }

    /// The page the Browser group of a project shows.
    func shownPage(in project: String) -> BrowserTab? {
        shownMember(of: TabID.holder(.browser, project)).flatMap(browsers.tab(forTab:))
    }

    /// Picks a group of a strip: one of the user's shows the item it
    /// showed; an agent's tab has the keyboard in the agent, whatever part
    /// of its area had it (#69).
    func selectStripTab(_ id: String) {
        listPicked = nil
        if TabID.holder(of: id) == nil {
            if session(forTab: id) != nil { selectTab(id: id) }
            return
        }
        guard let member = shownMember(of: id) else { return }
        selectTab(id: member)
    }

    /// The item after or before the one shown, in the group in front.
    /// The item of that number (from 1) of the row of the group in front,
    /// left to right, given the keyboard, as clicking it would (#171).
    func showMember(number: Int) {
        guard let group = paneLayout.focusedPane.front else { return }
        let list = members(of: group)
        guard number >= 1, number <= list.count else { return }
        selectTab(id: list[number - 1])
        focusKeyboard()
    }

    /// How many items the row of the group in front has.
    var frontMemberCount: Int { paneLayout.focusedPane.front.map { members(of: $0).count } ?? 0 }

    func showNextMember(_ offset: Int) {
        guard let group = paneLayout.focusedPane.front, let shown = shownMember(of: group) else { return }
        let list = members(of: group)
        guard list.count > 1, let index = list.firstIndex(of: shown) else { return }
        selectTab(id: list[(index + offset + list.count) % list.count])
        focusKeyboard()
    }

    /// Closes a project's Browser group, all of its pages: asked first when
    /// there are several.
    func requestCloseBrowser(in project: String) { requestCloseGroup(TabID.holder(.browser, project)) }

    // MARK: Closing a tab of the strip, all it holds (#145)

    /// Closes a tab of the strip and everything in it. One of the user's
    /// own is asked first as `CloseWords.asks` says; an agent's is ending
    /// the agent, which is always asked, and the host ends its shells and
    /// closes its pages with it.
    func requestCloseGroup(_ group: String) {
        if let holder = TabID.holder(of: group) {
            if CloseWords.asks(holder.kind, count: members(of: group).count) { pendingGroupClose = group } else { closeGroup(group) }
        } else if let agent = session(forTab: group) {
            requestEnd(agent.id)
        }
    }

    /// Closes a tab of the user's own, once asked. A file with unsaved
    /// changes is asked about, and stays open until it is answered.
    func closeGroup(_ group: String) {
        guard let holder = TabID.holder(of: group) else { return }
        let project = holder.project
        switch holder.kind {
        case .shells:
            for shell in userShells(in: project) { close(shell.id) }
        case .browser:
            closeBrowser(in: project)
        case .diffs:
            for diff in userDiffs(in: project) { closeDiffTab(diff.tabID) }
        case .files:
            let theirs = Set(userFiles(in: project).map(\.path))
            files.closeAll(except: nil, keeping: Set(files.documents.map(\.path)).subtracting(theirs))
        }
    }

    func closeBrowser(in project: String) {
        // Another Mac's are closed there (#147).
        if isRemote { return userPages(in: project).forEach { askRemoteBrowser(.close(tab: $0.id)) } }
        for page in userPages(in: project) { browsers.close(page) }
        groupShown[TabID.holder(.browser, project)] = nil
        if let front = browserInFront, browsers.tab(forTab: front) == nil { browserInFront = nil }
        syncTabs()
        adoptFocusedFront()
    }

    // MARK: Keeping up with the tabs

    /// Puts each group in its project's layout, and takes out those that
    /// are gone.
    func syncPanes() {
        guard sessionsKnown, tabLayoutKnown else { return }
        let live = Set(liveTabIDs)
        var byProject: [String: [String]] = [:]
        var all = workspaces
        // The one Browser is in every project's strip (#148), where the
        // arrangement has it.
        let keys = Set(all.keys).union([shownProject]).union(tabLayout.order.filter { live.contains($0) && $0 != Self.theBrowser }.map { project(ofTab: $0) })
        for id in tabLayout.order where live.contains(id) {
            if id == Self.theBrowser {
                for key in keys { byProject[key, default: []].append(id) }
            } else {
                byProject[project(ofTab: id), default: []].append(id)
            }
        }
        for key in keys.union(byProject.keys) {
            var layout = all[key] ?? PaneLayout()
            // One pane each: the user does not split it, and one split by
            // an earlier build is put back together, its tab in front kept.
            if layout.isSplit {
                let front = layout.focusedPane.front
                layout = PaneLayout()
                if let front { layout.show(front) }
            }
            layout.sync(with: byProject[key] ?? [], behind: [Self.theBrowser])
            all[key] = layout
        }
        if all != workspaces { workspaces = all }
        // A group whose item picked is gone shows its first.
        let gone = groupShown.filter { !members(of: $0.key).contains($0.value) }.map(\.key)
        for group in gone { groupShown[group] = nil }
        // The keyboard was in a part of an agent's area that is no longer
        // shown, its last page closed or its last shell ended: the agent
        // has it. What the area remembered is kept for the next one.
        for (agent, focus) in agentAreaFocus where focus != .agent && !shownParts(of: agent).contains(focus) { agentAreaFocus[agent] = .agent }
        // A part shown alone that is no longer there: all of them again.
        for (agent, part) in agentAreaAlone where !hasArea(agent) || !shownParts(of: agent).contains(part) { agentAreaAlone[agent] = nil }
        // An item put in front before it was there, a file of another Mac
        // whose words were still on their way, comes to the front of its
        // pane once it is.
        if let front = frontTabID {
            let group = stripTab(of: front)
            guard live.contains(group) else { return }
            let layout = workspaces[project(ofTab: group)]
            let pane = layout?.pane(containing: group)
            if pane?.front != group || pane?.id != layout?.focused || shownMember(of: group) != front { place(front) }
        }
    }

    // MARK: The item in front

    /// The rest of the app put an item in front: its group shows it, comes
    /// to the front of its pane, in its project's layout, which is shown,
    /// and the keyboard goes there. A page or a shell of an agent's is shown
    /// in its part of the agent's area, which is shown if it was hidden.
    func frontChanged() {
        guard let front = frontTabID else { return }
        place(front)
    }

    private func place(_ item: String) {
        let group = stripTab(of: item)
        if TabID.holder(of: group) != nil {
            if groupShown[group] != item { groupShown[group] = item }
        } else {
            var part = AgentAreaPart.agent
            if group != item {
                var area = agentAreas[group] ?? AgentArea()
                if session(forTab: item) != nil {
                    area.shellFront = item
                    area.shellsHidden = false
                    part = .shells
                } else {
                    area.browserFront = item
                    area.browserHidden = false
                    part = .browser
                }
                if agentAreas[group] != area { agentAreas[group] = area }
            }
            if hasArea(group) {
                if (agentAreaFocus[group] ?? .agent) != part { agentAreaFocus[group] = part }
                // One part shown alone: the one the keyboard goes to, now.
                if let alone = agentAreaAlone[group], alone != part { agentAreaAlone[group] = part }
            }
        }
        let project = project(ofTab: group)
        if shownProject != project { shownProject = project }
        var layout = workspaces[project] ?? PaneLayout()
        layout.show(group)
        if workspaces[project] != layout { workspaces[project] = layout }
    }

    /// Sets what the rest of the app takes for the item in front to the one
    /// the group in front of the pane the keyboard is in shows, or to
    /// nothing.
    func adoptFocusedFront() {
        let pane = paneLayout.focusedPane
        guard let front = pane.front else {
            files.active = nil
            if diffInFront { closeDiffFront() }
            browserInFront = nil
            selectedSession = nil
            return
        }
        // In an agent's area, the part the keyboard was in.
        guard let member = shownMember(of: front) else { return }
        if member == front, session(forTab: front) == nil { return }
        selectTab(id: member)
    }

    /// Shows a project's panes, as they were left: picking its folder.
    func showProject(_ project: String) {
        shownProject = project
        adoptFocusedFront()
    }

    // MARK: Panes

    /// Puts the keyboard in a pane, and what it shows in front: in a part
    /// of the agent's area there, when one is named.
    func focusPane(_ id: String, part: AgentAreaPart? = nil) {
        var layout = paneLayout
        layout.focus(id)
        paneLayout = layout
        if let part, let front = layout.pane(id)?.front, (agentAreaFocus[front] ?? .agent) != part { agentAreaFocus[front] = part }
        adoptFocusedFront()
        focusKeyboard()
    }

    // MARK: An agent's area (#69)

    /// The agent's area in front, when what is in front is one.
    var agentAreaInFront: String? {
        guard let front = paneLayout.focusedPane.front, TabID.holder(of: front) == nil, hasArea(front) else { return nil }
        return front
    }

    /// The parts of an agent's area that are shown: the agent, its page
    /// unless hidden, its shells unless hidden.
    func shownParts(of agent: String) -> [AgentAreaPart] {
        let all = companions
        let area = agentAreas[agent] ?? AgentArea()
        var parts: [AgentAreaPart] = [.agent]
        if !(all.browsers[agent] ?? []).isEmpty, !area.browserHidden { parts.append(.browser) }
        if !(all.shells[agent] ?? []).isEmpty, !area.shellsHidden { parts.append(.shells) }
        return parts
    }

    /// What a part of an agent's area shows: the agent, the page picked,
    /// the shell picked.
    func focusedInner(agent: String, part: AgentAreaPart) -> String? {
        let all = companions
        let area = agentAreas[agent] ?? AgentArea()
        switch part {
        case .agent: return agent
        case .shells: return area.shownShell(among: all.shells[agent] ?? [])
        case .browser: return area.shownBrowser(among: all.browsers[agent] ?? [])
        }
    }

    /// The items of an agent's tab that are on show, as its row marks them:
    /// what each part shown shows, or the one part shown alone.
    func itemsOnShow(of agent: String) -> Set<String> {
        var parts = shownParts(of: agent)
        if let alone = agentAreaAlone[agent], parts.contains(alone) { parts = [alone] }
        return Set(parts.compactMap { focusedInner(agent: agent, part: $0) })
    }

    /// Hides a part of an agent's area, or shows it again, from the row
    /// under the strip (#127). Hidden, its pages stay open and its shells
    /// keep running, and stay in the row and in the list.
    func toggleAgentPart(_ part: AgentAreaPart, of agent: String) {
        var area = agentAreas[agent] ?? AgentArea()
        let hide = part == .shells ? !area.shellsHidden : !area.browserHidden
        if part == .shells { area.shellsHidden = hide }
        if part == .browser { area.browserHidden = hide }
        agentAreas[agent] = area
        guard hide else { return }
        if agentAreaAlone[agent] == part { agentAreaAlone[agent] = nil }
        if agentAreaFocus[agent] == part {
            agentAreaFocus[agent] = .agent
            adoptFocusedFront()
            focusKeyboard()
        }
    }

    /// Whether the agent's area in front shows that part.
    func canMoveKeyboard(to part: AgentAreaPart) -> Bool {
        agentAreaInFront.map { shownParts(of: $0).contains(part) } ?? false
    }

    /// Puts the keyboard in a part of the agent's area in front: the agent,
    /// its page, its shells. Shown alone, that part is shown alone instead.
    func moveKeyboard(to part: AgentAreaPart) {
        guard let agent = agentAreaInFront, shownParts(of: agent).contains(part) else { return }
        if agentAreaAlone[agent] != nil { agentAreaAlone[agent] = part }
        focusPane(paneLayout.focused, part: part)
    }

    /// Shows the part the keyboard is in alone, filling the agent's area,
    /// or all of them again.
    func toggleAlone() {
        guard let agent = agentAreaInFront else { return }
        agentAreaAlone[agent] = agentAreaAlone[agent] == nil ? (agentAreaFocus[agent] ?? .agent) : nil
        focusKeyboard()
    }

    func setAgentArea(_ agent: String, across: Double? = nil, down: Double? = nil) {
        var area = agentAreas[agent] ?? AgentArea()
        if let across { area.across = min(max(across, 0.15), 0.85) }
        if let down { area.down = min(max(down, 0.15), 0.9) }
        if agentAreas[agent] != area { agentAreas[agent] = area }
    }

    /// The groups of the pane the keyboard is in, in the order of its strip.
    var focusedPaneTabs: [String] {
        let pane = paneLayout.focusedPane
        let here = Set(pane.tabs)
        return tabLayout.visibleTabs(front: pane.front).filter(here.contains)
    }

    // MARK: Clicks and the keyboard

    /// A click in the middle of the window puts the keyboard in the pane,
    /// or the part of an agent's area, it landed in.
    func paneClicked(at point: CGPoint) {
        guard place == .sessions else { return }
        let parts = paneFrames.filter { if case .part = $0.key { return $0.value.contains(point) } else { return false } }
        if let (place, _) = parts.first, case .part(let agent, let part) = place {
            guard let pane = paneLayout.pane(containing: agent) else { return }
            if paneLayout.focused != pane.id || (agentAreaFocus[agent] ?? .agent) != part || frontTabID != focusedInner(agent: agent, part: part) {
                focusPane(pane.id, part: part)
            }
            return
        }
        let panes = paneFrames.filter { if case .pane = $0.key { return $0.value.contains(point) } else { return false } }
        if let (place, _) = panes.first, case .pane(let id) = place, id != paneLayout.focused {
            focusPane(id)
        }
    }

    /// Gives the keyboard to what is in front, once the window shows it.
    func focusKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A page in front first: the session picked before it is still
            // `selectedSession`, and took the keyboard from it (PANE-17).
            if let tab = self.frontTabID, let browser = self.browsers.tab(forTab: tab) {
                browser.focus()
            } else if let id = self.selectedSession, self.files.active == nil, !self.diffInFront, let controller = self.controller(for: id) {
                controller.view.window?.makeFirstResponder(controller.view)
            }
        }
    }

    private func closeDiffFront() {
        // Leaving the diff in its group, out of the front.
        showingNoDiff()
    }
}
