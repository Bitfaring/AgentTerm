import AgentTermProtocol
import SwiftUI

/// Names of the tabs of the middle pane, as `TabLayout` knows them.
enum TabID {
    static func session(_ session: SessionInfo) -> String { session.layoutID }

    static func file(_ path: String) -> String { "f:" + path }
}

extension AppModel {
    private static let tabLayoutKey = "tabLayout"

    static func savedTabLayout() -> TabLayout {
        guard let data = UserDefaults.standard.data(forKey: tabLayoutKey),
            let layout = try? JSONDecoder().decode(TabLayout.self, from: data)
        else { return TabLayout() }
        return layout
    }

    func saveTabLayout() {
        // Only this Mac's: another Mac's tabs are its host's to keep, and
        // must not take the place of the ones saved here.
        guard !isRemote else { return }
        if let data = try? JSONEncoder().encode(tabLayout) { UserDefaults.standard.set(data, forKey: Self.tabLayoutKey) }
    }

    /// Brings the arrangement up to date with the tabs that exist.
    /// Not before the host has said which sessions run: at launch there are
    /// none yet, and the pins and groups saved for them would be dropped.
    func syncTabs() {
        guard sessionsKnown, tabLayoutKnown else { return }
        var layout = tabLayout
        layout.sync(with: liveTabIDs)
        if layout != tabLayout { tabLayout = layout }
        syncPanes()
    }

    /// The tab shown in the middle pane.
    var frontTabID: String? {
        if let browser = browserInFront, browsers.tab(forTab: browser) != nil { return browser }
        if diffInFront, let diff = diffTab { return diff.tabID }
        if let path = files.active, files.documents.contains(where: { $0.path == path }) { return TabID.file(path) }
        return sessions.first { $0.id == selectedSession }.map(TabID.session)
    }

    /// The tabs on show in the pane the keyboard is in, in the order of
    /// its strip: what Command and a number counts (#69).
    var visibleTabs: [String] { stripTabs(of: paneLayout.focusedPane) }

    func session(forTab id: String) -> SessionInfo? { sessions.first { TabID.session($0) == id } }

    func document(forTab id: String) -> OpenDocument? {
        guard id.hasPrefix("f:") else { return nil }
        let path = String(id.dropFirst(2))
        return files.documents.first { $0.path == path }
    }

    func tabName(_ id: String) -> String {
        if let session = session(forTab: id) { return session.displayName }
        if let document = document(forTab: id) { return document.name }
        if let holder = TabID.holder(of: id) { return holder.kind.title }
        if let diff = diffTabs.first(where: { $0.tabID == id }) { return (diff.file.path as NSString).lastPathComponent }
        if let browser = browsers.tab(forTab: id) { return browser.displayTitle }
        return "Tab"
    }

    func selectTab(id: String) {
        listPicked = nil
        if let session = session(forTab: id) {
            select(session: session)
        } else if let document = document(forTab: id) {
            browserInFront = nil
            if files.active == document.path { frontChanged() }
            files.active = document.path
        } else if diffTabs.contains(where: { $0.tabID == id }) {
            files.active = nil
            browserInFront = nil
            showDiff(id)
        } else if TabID.holder(of: id) != nil {
            selectStripTab(id)
        } else if browsers.tab(forTab: id) != nil {
            files.active = nil
            showingNoDiff()
            if browserInFront == id { frontChanged() }
            browserInFront = id
            // Picked by the user: its page takes the keyboard (PANE-17).
            focusKeyboard()
        }
    }

    // MARK: Arranging

    func moveTab(_ id: String, before target: String?) {
        tabLayout.move(id, before: target)
    }

    /// Moves a tab one place left or right among the tabs of its pane's
    /// strip (#69), past none of another pane's.
    func moveTab(_ id: String, by offset: Int) {
        let visible = stripTabs(of: paneLayout.pane(containing: id))
        guard let index = visible.firstIndex(of: id), visible.indices.contains(index + offset) else { return }
        let neighbor = visible[index + offset]
        if offset < 0 { tabLayout.move(id, before: neighbor) } else { tabLayout.move(id, after: neighbor) }
    }

    /// A pane's tabs on show, in the order of its strip.
    func stripTabs(of pane: PaneLayout.Pane?) -> [String] {
        guard let pane else { return [] }
        let here = Set(pane.tabs)
        let live = Set(liveTabIDs)
        return tabLayout.visibleTabs(front: pane.front).filter { here.contains($0) && live.contains($0) }
    }

    func setTabPinned(_ id: String, _ pinned: Bool) {
        tabLayout.setPinned(id, pinned)
    }

    /// The paths of the files whose tabs are pinned. Closing many tabs at
    /// once leaves pinned ones open.
    var pinnedFilePaths: Set<String> {
        Set(files.documents.map(\.path).filter { tabLayout.isPinned(TabID.holder(.files, project(ofPath: $0))) })
    }
}
