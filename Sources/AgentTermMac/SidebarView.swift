import AgentTermProtocol
import AgentTermTerminal
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    /// The browser's pages, listed under their projects (#76).
    @EnvironmentObject private var browsers: BrowserModel
    /// What a dragged folder is over: a folder's path, or "end".
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FOLDERS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addFolder()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // The user's pages, of no folder: one Browser row above
                    // the folders, its pages under it (#148).
                    let userPages = model.userPages(in: "")
                    if !userPages.isEmpty {
                        BrowserGroupRow(project: "", pages: userPages, loose: true)
                        ForEach(userPages) { tab in BrowserRow(tab: tab, leading: 24) }
                        Color.clear.frame(height: 6)
                    }
                    ForEach(model.folders) { folder in
                        FolderRow(folder: folder)
                            .overlay(alignment: .top) {
                                // Where a dragged folder will land.
                                if dropTarget == folder.path { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.horizontal, 2) }
                            }
                            .onDrag {
                                model.draggedTab = nil
                                model.draggedFolder = folder.path
                                // Plain data: a terminal does not take it for text to insert.
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { done in
                                    done(Data(folder.path.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(of: [.data, .fileURL], delegate: FolderDropDelegate(before: folder.path, model: model, dropTarget: $dropTarget))
                        rows(sessions: model.sessions(in: folder), pages: browsers.tabs.filter { $0.project == folder.path }, project: folder.path, loose: false)
                    }
                    if !model.folders.isEmpty {
                        // Room under the last folder to drop one at the end.
                        Color.clear.frame(height: 18)
                            .overlay(alignment: .top) {
                                if dropTarget == "end" { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.horizontal, 2) }
                            }
                            .contentShape(Rectangle())
                            .onDrop(of: [.data, .fileURL], delegate: FolderDropDelegate(before: nil, model: model, dropTarget: $dropTarget))
                    }
                    // An agent's, of no listed folder: the user's are above (#148).
                    let looseTabs = browsers.tabs.filter { tab in tab.owner != nil && !model.folders.contains { $0.path == tab.project } }
                    if !model.looseSessions.isEmpty || !looseTabs.isEmpty {
                        Text("OTHER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        rows(sessions: model.inTabOrder(model.looseSessions), pages: looseTabs, project: "", loose: true)
                    }
                    if model.folders.isEmpty && model.looseSessions.isEmpty {
                        Text("No folders yet.\nAdd one to keep its agents and changes together.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(Theme.panel)
        // A folder dragged in from the Finder is added to the list.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FolderDropDelegate.addFolders(from: providers, to: model)
        }
    }

    /// A folder's rows, or those of no folder, as its strip holds them
    /// (#127): each agent, its own pages and shells right under it, set in;
    /// then the user's shells, pages, diffs and files, each under one row of
    /// their kind.
    @ViewBuilder
    private func rows(sessions: [SessionInfo], pages: [BrowserTab], project: String, loose: Bool) -> some View {
        let companions = model.companions
        let inner: CGFloat = (loose ? 8 : 24) + 16
        ForEach(sessions.filter { $0.agent != nil && companions.owner[TabID.session($0)] == nil }) { session in
            SessionRow(session: session, showsPath: loose)
                .modifier(SessionArranging(session: session, dropTarget: $dropTarget))
            let tab = TabID.session(session)
            ForEach((companions.browsers[tab] ?? []).compactMap { browsers.tab(forTab: $0) }) { page in
                BrowserRow(tab: page, leading: inner)
            }
            ForEach((companions.shells[tab] ?? []).compactMap { model.session(forTab: $0) }) { shell in
                SessionRow(session: shell, leading: inner)
            }
        }
        // The user's shells, one Shells row a project with them under it.
        let shells = sessions.filter { $0.agent == nil && companions.owner[TabID.session($0)] == nil }
        if !shells.isEmpty {
            HolderListRow(kind: .shells, project: loose ? (shells.first.map { model.project(ofTab: TabID.session($0)) } ?? "") : project, count: shells.count, loose: loose)
            ForEach(shells) { shell in
                SessionRow(session: shell, leading: inner)
                    .contextMenu { Button("End Session") { model.requestEnd(shell.id) } }
            }
        }
        // The project's pages that are the user's (#76), one Browser row a
        // project with its pages under it (#122).
        // Not the project's path for an identity: its folder's row has it.
        ForEach(Self.byProject(pages.filter { companions.owner[$0.tabID] == nil }), id: \.id) { group in
            BrowserGroupRow(project: group.project, pages: group.pages, loose: loose)
            ForEach(group.pages) { tab in
                BrowserRow(tab: tab, leading: inner)
            }
        }
        if !loose {
            let diffs = model.userDiffs(in: project)
            if !diffs.isEmpty {
                HolderListRow(kind: .diffs, project: project, count: diffs.count, loose: loose)
                ForEach(diffs, id: \.tabID) { diff in
                    ItemListRow(item: diff.tabID, symbol: "plus.forwardslash.minus", title: (diff.file.path as NSString).lastPathComponent, leading: inner)
                }
            }
            let documents = model.userFiles(in: project)
            if !documents.isEmpty {
                HolderListRow(kind: .files, project: project, count: documents.count, loose: loose)
                ForEach(documents, id: \.path) { document in
                    ItemListRow(item: TabID.file(document.path), symbol: document.isMarkdown ? "doc.text" : "doc", title: document.name, leading: inner)
                }
            }
        }
    }
}

extension SidebarView {
    /// Pages by their project, in the order the first of each was opened.
    static func byProject(_ pages: [BrowserTab]) -> [(id: String, project: String, pages: [BrowserTab])] {
        var order: [String] = []
        var grouped: [String: [BrowserTab]] = [:]
        for page in pages {
            if grouped[page.project] == nil { order.append(page.project) }
            grouped[page.project, default: []].append(page)
        }
        return order.map { ("browser:" + $0, $0, grouped[$0] ?? []) }
    }
}

/// The row of one of a project's groups of the user's own in the list
/// (#127), as its strip holds them: what it holds is under it. Picking it
/// shows what that group shows.
private struct HolderListRow: View {
    @EnvironmentObject private var model: AppModel
    let kind: HolderKind
    let project: String
    let count: Int
    var loose = false
    @State private var hovering = false

    private var id: String { TabID.holder(kind, project) }

    /// Marked when it is the one picked in the list (#152).
    private var selected: Bool { model.listPicked == id }

    /// Its group in front, its row the one picked, not the item it shows.
    private func pick() {
        model.selectStripTab(id)
        model.listPicked = id
    }

    /// Closing it from its menu, as from its tab of the strip (#145).
    private var closing: String { CloseWords.groupAction(kind) + (CloseWords.asks(kind, count: count) ? "…" : "") }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(kind.label(count))
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, loose ? 8 : 24)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .modifier(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { pick() }
        .contextMenu {
            if kind == .shells { Button("New Shell") { model.launch(nil) } }
            Button(closing) { model.requestCloseGroup(id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.spoken(count))
        .accessibilityIdentifier("sidebar-\(kind.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityAction(named: CloseWords.groupAction(kind)) { model.requestCloseGroup(id) }
    }
}

/// A diff or a file in the list, under its group's row.
private struct ItemListRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    let item: String
    let symbol: String
    let title: String
    let leading: CGFloat
    @State private var hovering = false

    private var selected: Bool { model.listPicked == nil && model.frontTabID == item }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .modifier(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id: item) }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar-\(item)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(id: item) }
        .accessibilityAction(named: closing) { close() }
    }

    // A right click on it (#152): closing it, and where its file is.

    private var diff: AppModel.OpenDiff? { model.diffTabs.first { $0.tabID == item } }

    /// The file it shows, on the Mac it is on.
    private var path: String? {
        if let document = model.document(forTab: item) { return document.path }
        return diff.map { ($0.folder as NSString).appendingPathComponent($0.file.path) }
    }

    private var closing: String { diff == nil ? "Close File" : "Close Diff" }

    private func close() {
        if diff != nil {
            model.closeDiffTab(item)
        } else if let path {
            files.requestClose(path)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(closing, action: close)
        if diff != nil, let path { Button("Open File") { files.open(path) } }
        if let path {
            Divider()
            // A file of another Mac is not in this Mac's Finder.
            if !model.isRemote { Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

/// The user's pages of a project in the list (#122), as its strip's Browser
/// tab holds them: its pages are under it. Picking it shows the page that
/// tab shows.
private struct BrowserGroupRow: View {
    @EnvironmentObject private var model: AppModel
    let project: String
    let pages: [BrowserTab]
    var loose = false
    @State private var hovering = false

    private func show() {
        guard !pages.isEmpty else { return }
        model.selectStripTab(TabID.holder(.browser, project))
        model.listPicked = TabID.holder(.browser, project)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(HolderKind.browser.label(pages.count))
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    model.requestCloseBrowser(in: project)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(pages.count > 1 ? "Close the browser's \(pages.count) pages" : "Close the browser")
            }
        }
        .padding(.leading, loose ? 8 : 24)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        // Marked when it is the one picked, not the page it shows (#152).
        .modifier(RowBackground(selected: model.listPicked == TabID.holder(.browser, project), hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { show() }
        .help(model.shownPage(in: project)?.displayTitle ?? "Browser")
        .contextMenu {
            Button("Close Browser") { model.requestCloseBrowser(in: project) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HolderKind.browser.spoken(pages.count))
        .accessibilityIdentifier("sidebar-browser")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { show() }
        .accessibilityAction(named: "Close Browser") { model.requestCloseBrowser(in: project) }
    }
}

/// An agent's session in the list can be dragged onto another to go before
/// it. That is the same move as dragging its tab in the strip: it takes on
/// the place it lands in, pinned or not, and the phones see the new order.
private struct SessionArranging: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @Binding var dropTarget: String?

    private var id: String { TabID.session(session) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if dropTarget == id { Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.leading, 22).padding(.trailing, 2) }
            }
            .onDrag {
                model.draggedFolder = nil
                model.draggedTab = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { done in
                    done(Data(id.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.data], delegate: SessionRowDropDelegate(target: id, model: model, dropTarget: $dropTarget))
            .contextMenu {
                // Among the agents beside it, the tabs of the strip (#127).
                let shown = model.inTabOrder(model.sessions.filter { $0.cwd == session.cwd && $0.agent != nil && $0.openedBy == nil }).map(TabID.session)
                let index = shown.firstIndex(of: id)
                Button("Move Up") { if let index, index > 0 { model.moveTab(id, before: shown[index - 1]) } }
                    .disabled(index == nil || index == 0)
                Button("Move Down") { if let index, index < shown.count - 1 { model.tabLayout.move(id, after: shown[index + 1]) } }
                    .disabled(index == nil || index == shown.count - 1)
                Divider()
                Button(model.tabLayout.isPinned(id) ? "Unpin" : "Pin") { model.setTabPinned(id, !model.tabLayout.isPinned(id)) }
                Divider()
                Button("End Session") { model.requestEnd(session.id) }
            }
    }
}

private struct SessionRowDropDelegate: DropDelegate {
    let target: String
    let model: AppModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedTab != nil && model.draggedFolder == nil }

    func dropEntered(info: DropInfo) {
        if model.draggedTab != target { dropTarget = target }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedTab else { return false }
        model.draggedTab = nil
        withAnimation(.easeOut(duration: 0.15)) { model.moveTab(id, before: target) }
        return true
    }
}

/// A folder of the list dropped on another goes before it. A folder dragged
/// in from elsewhere, the Finder for one, is added.
private struct FolderDropDelegate: DropDelegate {
    /// The folder to go before; nil is the end of the list.
    let before: String?
    let model: AppModel
    @Binding var dropTarget: String?

    private var key: String { before ?? "end" }

    func validateDrop(info: DropInfo) -> Bool {
        model.draggedFolder != nil || (model.draggedTab == nil && info.hasItemsConforming(to: [.fileURL]))
    }

    func dropEntered(info: DropInfo) {
        if model.draggedFolder != nil, model.draggedFolder != before { dropTarget = key }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == key { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.draggedFolder != nil ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        if let path = model.draggedFolder {
            model.draggedFolder = nil
            model.moveFolder(path, before: before)
            return true
        }
        return Self.addFolders(from: info.itemProviders(for: [.fileURL]), to: model)
    }

    @discardableResult
    static func addFolders(from providers: [NSItemProvider], to model: AppModel) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.addFolders([url]) }
            }
        }
        return true
    }
}

private struct RowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
    }
}

struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: Folder
    @State private var hovering = false

    private func select() {
        model.selectedFolder = folder.path
        // Its panes, as they were left (#69), or its launch screen; the
        // side panel and the list's mark are the folder's own (#152).
        model.showProject(folder.path)
        model.shownWorktree = nil
        model.listPicked = folder.path
    }

    /// Picked itself (#152): not an item of it, which its panes still show.
    private var isSelected: Bool { model.listPicked == folder.path }

    /// Sessions of this folder whose agent waits for the user.
    private var waiting: Int { model.sessions.filter { WorktreePath.belongs($0.cwd, to: folder.path) && $0.state?.isWaiting == true }.count }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(model.selectedFolder == folder.path ? Color.accentColor : .secondary)
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if waiting > 0 {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(waiting == 1 ? "A session waits for you" : "\(waiting) sessions wait for you")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .modifier(RowBackground(selected: isSelected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { select() }
        // One thing to press, for VoiceOver and anything else without a pointer.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), folder" + (waiting == 0 ? "" : waiting == 1 ? ", a session waits" : ", \(waiting) sessions wait"))
        .accessibilityIdentifier("folder-" + folder.path)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .help(folder.path)
        .contextMenu {
            // A folder of another Mac is not in this Mac's Finder.
            if !model.isRemote {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
                Divider()
            }
            Button("Move Up") { model.moveFolder(folder, by: -1) }
                .disabled(model.folders.first == folder)
            Button("Move Down") { model.moveFolder(folder, by: 1) }
                .disabled(model.folders.last == folder)
            Divider()
            Button("Remove from List") { model.remove(folder) }
        }
        .padding(.top, 4)
    }
}

/// A page of the browser in the list (#76), under its project: whose it is
/// and which profile it uses. Picking it shows it, beside its agent when an
/// agent opened it.
struct BrowserRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profiles: BrowserProfiles
    @ObservedObject var tab: BrowserTab
    var loose = false
    /// Set in under its agent, which it is shown under: it is not named.
    var leading: CGFloat?
    @State private var hovering = false

    private var agent: SessionInfo? { tab.owner.flatMap { id in model.sessions.first { $0.id == id } } }
    private var selected: Bool { model.listPicked == nil && model.browserInFront == tab.tabID }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.loading ? "arrow.triangle.2.circlepath" : "globe")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(agent != nil ? Color.accentColor : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    if let agent, leading == nil {
                        Label(agent.displayName, systemImage: "sparkles").lineLimit(1).truncationMode(.tail)
                    }
                    Text(profiles.profile(tab.profile)?.name ?? "").lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if tab.userHasIt {
                Image(systemName: "hand.raised.fill").font(.system(size: 9.5)).foregroundStyle(.orange).help("You have it: its agent waits")
            }
            if hovering {
                Button {
                    model.closeBrowserTab(tab)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close this tab")
            }
        }
        .padding(.leading, leading ?? (loose ? 8 : 24))
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .modifier(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id: tab.tabID) }
        .help(tab.url)
        .contextMenu {
            Button("Close Tab") { model.closeBrowserTab(tab) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tab.displayTitle), page" + (agent.map { ", opened by \($0.displayName)" } ?? ""))
        .accessibilityIdentifier("browser-row-\(tab.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(id: tab.tabID) }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    var showsPath = false
    /// Set in under its agent, which it is shown under: it is not named.
    var leading: CGFloat?
    @State private var hovering = false

    private var agentID: String { session.agent ?? session.typedAgent ?? "shell" }
    /// One row of the list is selected at a time: a page in front is its
    /// own row's, not the session's that was in front before it (PANE-17).
    private var selected: Bool { model.listPicked == nil && model.selectedSession == session.id && model.browserInFront == nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(for: agentID))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: agentID))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                // The conversation's title once the agent has saved one,
                // the agent's name until then.
                Text(session.displayName)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = session.branch {
                    // In a worktree of its own (#23).
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if leading == nil, let owner = session.openedByName(among: model.sessions) {
                    // A shell an agent opened: whose it is, since only that
                    // agent types into it (#61).
                    Label(owner, systemImage: "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Opened by \(owner): only that agent types into it, others may read it")
                }
                if showsPath {
                    Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let schedule = session.schedule {
                // A run of a schedule, and whether its agent asks (#11).
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 9.5))
                    .foregroundStyle(session.schedulePermissions == .skipAll ? .orange : .secondary)
                    .help(
                        "A run of “\(schedule)”"
                            + (session.schedulePermissions == .skipAll ? ": it runs without asking for permission" : ", \(session.schedulePermissions?.label.lowercased() ?? "")"))
            }
            AgentStateMark(session: session)
            // Sized for another device: its own icon, none for a Mac (#157).
            if model.foreignSizes[session.id] != nil, let symbol = SizeDriver.symbol(for: model.sizeDrivers[session.id]) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Sized for \(model.sizeDrivers[session.id]?.name ?? "another device")")
            }
            if hovering, let agent = model.agentID(of: session), !model.handoffTargets(from: agent).isEmpty {
                Button {
                    model.requestHandoff(session: session)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Give this session's work to another agent")
            }
            if hovering {
                Button {
                    // Asks first, as everything that ends a session does.
                    model.requestEnd(session.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("End this session")
            }
        }
        .padding(.leading, leading ?? (showsPath ? 8 : 24))
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .modifier(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session: session) }
        .help(session.summary.map { "\(session.title): \($0)" } ?? session.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AgentStateMark.label(
                "\(session.displayName), session" + (session.branch.map { ", in worktree \($0)" } ?? "") + (session.openedByName(among: model.sessions).map { ", opened by \($0)" } ?? ""),
                session)
        )
        .accessibilityIdentifier("session-\(session.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(session: session) }
    }
}
