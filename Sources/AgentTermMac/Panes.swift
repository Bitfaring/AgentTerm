import AgentTermProtocol
import AppKit
import SwiftUI

/// A place in the middle of the window a click can land in (#69): a pane,
/// or a part of an agent's area inside one.
enum PanePlace: Hashable {
    case pane(String)
    case part(agent: String, AgentAreaPart)
    /// The page of a browser tab (#76).
    case page(String)
}

/// The parts of an agent's area: the agent, its browser, its shells.
enum AgentAreaPart: String, Hashable {
    case agent, browser, shells
}

/// The panes of the middle of the window (#69). Each project has a layout of
/// its own: the panes and which of its tabs each holds. The project on show
/// is the one of the tab in front; picking a folder shows its own.
///
/// What the rest of the app calls the tab in front (`selectedSession`,
/// `files.active`, `diffInFront`) is the front of the pane the keyboard is
/// in: setting it brings that tab to the front of its pane and puts the
/// keyboard there, and focusing a pane sets it to that pane's front.
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

    /// The project a tab is in. A session is its folder's as the list at
    /// the left has it: started in the folder or in one of its worktrees.
    func project(ofTab id: String) -> String {
        if let session = session(forTab: id) {
            return folders.first { WorktreePath.belongs(session.cwd, to: $0.path) }?.path ?? ""
        }
        if let document = document(forTab: id) { return project(ofPath: document.path) }
        if id == TabID.diff, let tab = diffTab { return project(ofPath: tab.folder) }
        if let tab = browsers.tab(forTab: id) { return tab.project }
        return ""
    }

    /// The layout of the project on show.
    var paneLayout: PaneLayout {
        get { workspaces[shownProject] ?? PaneLayout() }
        set { workspaces[shownProject] = newValue }
    }

    // MARK: An agent's own shells and browser

    /// The agents whose shells and browser are laid out beside them, with
    /// those shells and tabs, by the tab ids of the agents' sessions; and
    /// for each of those, its agent. They are always shown so, never as
    /// tabs of their own. A shell whose agent has ended is a tab like any
    /// other.
    var companions: (shells: [String: [String]], browsers: [String: [String]], owner: [String: String]) {
        var shells: [String: [String]] = [:]
        var owner: [String: String] = [:]
        let order = Dictionary(tabLayout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for shell in sessions where shell.openedBy != nil {
            guard let agent = sessions.first(where: { $0.id == shell.openedBy }) else { continue }
            let agentTab = TabID.session(agent), shellTab = TabID.session(shell)
            shells[agentTab, default: []].append(shellTab)
            owner[shellTab] = agentTab
        }
        for (agent, list) in shells { shells[agent] = list.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) } }
        var browserTabs: [String: [String]] = [:]
        for tab in browsers.tabs {
            guard let agentTab = tab.ownerTab, sessions.contains(where: { TabID.session($0) == agentTab }) else { continue }
            browserTabs[agentTab, default: []].append(tab.tabID)
            owner[tab.tabID] = agentTab
        }
        return (shells, browserTabs, owner)
    }

    /// Whether an agent's session is shown as an area with its shells or
    /// browser beside it.
    func hasArea(_ agentTab: String) -> Bool {
        let all = companions
        return all.shells[agentTab] != nil || all.browsers[agentTab] != nil
    }

    // MARK: Keeping up with the tabs

    /// Puts each tab in a pane of its project's layout, takes out those
    /// that are gone, and drops what is shown in an agent's area.
    func syncPanes() {
        guard sessionsKnown, tabLayoutKnown else { return }
        let owner = companions.owner
        let live = Set(liveTabIDs)
        var byProject: [String: [String]] = [:]
        for id in tabLayout.order where live.contains(id) && owner[id] == nil {
            byProject[project(ofTab: id), default: []].append(id)
        }
        var all = workspaces
        for key in Set(all.keys).union(byProject.keys) {
            var layout = all[key] ?? PaneLayout()
            // One pane each: the user does not split it, and one split by
            // an earlier build is put back together, its tab in front kept.
            if layout.isSplit {
                let front = layout.focusedPane.front
                layout = PaneLayout()
                if let front { layout.show(front) }
            }
            layout.sync(with: byProject[key] ?? [])
            all[key] = layout
        }
        if all != workspaces { workspaces = all }
        // An agent's area that lost its last shell and tab is a plain
        // terminal again; what it remembered is kept for the next one.
        for (agent, focus) in agentAreaFocus where focus != .agent && !hasArea(agent) { agentAreaFocus[agent] = .agent }
        // A part shown alone that is no longer there: all of them again.
        for (agent, part) in agentAreaAlone where !hasArea(agent) || !shownParts(of: agent).contains(part) { agentAreaAlone[agent] = nil }
        // A tab put in front before it was there, a file of another Mac
        // whose words were still on their way, comes to the front of its
        // pane once it is.
        if let front = frontTabID, owner[front] == nil, live.contains(front) {
            let layout = workspaces[project(ofTab: front)]
            if layout?.pane(containing: front)?.front != front || layout?.pane(containing: front)?.id != layout?.focused { place(front) }
        }
    }

    // MARK: The tab in front

    /// The rest of the app put a tab in front: it comes to the front of
    /// its pane, in its project's layout, which is shown, and the keyboard
    /// goes there. A shell or browser tab of an agent's area brings that
    /// area, with it in front.
    func frontChanged() {
        guard let front = frontTabID else { return }
        place(front)
    }

    private func place(_ tab: String) {
        var target = tab
        if let agent = companions.owner[tab] {
            var area = agentAreas[agent] ?? AgentArea()
            if session(forTab: tab) != nil {
                area.shellFront = tab
                area.shellsHidden = false
                agentAreaFocus[agent] = .shells
            } else {
                area.browserFront = tab
                area.browserHidden = false
                agentAreaFocus[agent] = .browser
            }
            if agentAreas[agent] != area { agentAreas[agent] = area }
            target = agent
        } else if hasArea(tab), selectedSession.map({ id in sessions.first { $0.id == id }.map(TabID.session) }) == tab {
            agentAreaFocus[tab] = .agent
        }
        let project = project(ofTab: target)
        if shownProject != project { shownProject = project }
        var layout = workspaces[project] ?? PaneLayout()
        layout.show(target)
        if workspaces[project] != layout { workspaces[project] = layout }
    }

    /// Sets what the rest of the app takes for the tab in front to the
    /// front of the pane the keyboard is in, or to nothing.
    func adoptFocusedFront() {
        let pane = paneLayout.focusedPane
        guard let front = pane.front else {
            files.active = nil
            if diffInFront { closeDiffFront() }
            browserInFront = nil
            selectedSession = nil
            return
        }
        if hasArea(front), let part = agentAreaFocus[front], part != .agent {
            let all = companions
            let area = agentAreas[front] ?? AgentArea()
            let inner = part == .shells ? area.shownShell(among: all.shells[front] ?? []) : area.shownBrowser(among: all.browsers[front] ?? [])
            if let inner {
                selectTab(id: inner)
                return
            }
        }
        selectTab(id: front)
    }

    /// Shows a project's panes, as they were left: picking its folder.
    func showProject(_ project: String) {
        shownProject = project
        adoptFocusedFront()
    }

    // MARK: Panes

    /// Puts the keyboard in a pane, and what it shows in front.
    func focusPane(_ id: String, part: AgentAreaPart? = nil) {
        var layout = paneLayout
        layout.focus(id)
        paneLayout = layout
        if let part, let front = layout.pane(id)?.front { agentAreaFocus[front] = part }
        adoptFocusedFront()
        focusKeyboard()
    }

    /// Hides one part of an agent's area (#69): closing it. Its shells keep
    /// running and stay in the list of sessions.
    func hideAgentPart(_ part: AgentAreaPart, of agent: String) {
        var area = agentAreas[agent] ?? AgentArea()
        if part == .shells { area.shellsHidden = true }
        if part == .browser { area.browserHidden = true }
        agentAreas[agent] = area
        if agentAreaAlone[agent] == part { agentAreaAlone[agent] = nil }
        if agentAreaFocus[agent] == part {
            agentAreaFocus[agent] = .agent
            adoptFocusedFront()
        }
    }

    // MARK: Moving about an agent's area (#69)

    /// The agent's area in front, when what is in front is one.
    var agentAreaInFront: String? {
        guard let front = paneLayout.focusedPane.front, hasArea(front) else { return nil }
        return front
    }

    /// The parts of an agent's area that are shown, or could be: the
    /// agent, its page unless hidden, its shells unless hidden.
    func shownParts(of agent: String) -> [AgentAreaPart] {
        let all = companions
        let area = agentAreas[agent] ?? AgentArea()
        var parts: [AgentAreaPart] = [.agent]
        if !(all.browsers[agent] ?? []).isEmpty, !area.browserHidden { parts.append(.browser) }
        if !(all.shells[agent] ?? []).isEmpty, !area.shellsHidden { parts.append(.shells) }
        return parts
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

    func showAgentPart(_ part: AgentAreaPart, of agent: String) {
        var area = agentAreas[agent] ?? AgentArea()
        if part == .shells { area.shellsHidden = false }
        if part == .browser { area.browserHidden = false }
        agentAreas[agent] = area
    }

    func setAgentArea(_ agent: String, across: Double? = nil, down: Double? = nil) {
        var area = agentAreas[agent] ?? AgentArea()
        if let across { area.across = min(max(across, 0.15), 0.85) }
        if let down { area.down = min(max(down, 0.15), 0.9) }
        if agentAreas[agent] != area { agentAreas[agent] = area }
    }

    /// The tabs of the pane the keyboard is in, in the order of its strip.
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
            if paneLayout.focused != pane.id || agentAreaFocus[agent] != part || frontTabID != focusedInner(agent: agent, part: part) {
                focusPane(pane.id, part: part)
            }
            return
        }
        let panes = paneFrames.filter { if case .pane = $0.key { return $0.value.contains(point) } else { return false } }
        if let (place, _) = panes.first, case .pane(let id) = place, id != paneLayout.focused {
            focusPane(id)
        }
    }

    private func focusedInner(agent: String, part: AgentAreaPart) -> String? {
        let all = companions
        let area = agentAreas[agent] ?? AgentArea()
        switch part {
        case .agent: return agent
        case .shells: return area.shownShell(among: all.shells[agent] ?? [])
        case .browser: return area.shownBrowser(among: all.browsers[agent] ?? [])
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
        // Leaving the diff in its pane, out of the front.
        showingNoDiff()
    }
}
