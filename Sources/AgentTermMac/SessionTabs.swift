import AgentTermProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The tabs of one pane (#69, #127): each agent, and the user's shells,
/// pages, diffs and files, one tab of each, to switch between them with one
/// click, or Command and a number in the pane the keyboard is in. What a
/// tab holds is in the row under the strip (`GroupRow`).
struct SessionTabs: View {
    @EnvironmentObject private var model: AppModel
    // The tabs that exist are read through the model, but these say when
    // they changed: the user's pages and files make tabs of their own.
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let pane: PaneLayout.Pane

    /// A tab's 25 points and 6 above and below.
    private static let stripHeight: CGFloat = 37

    /// What a dragged tab is over: a tab's id, or "end".
    @State private var dropTarget: String?

    private var focused: Bool { model.paneLayout.focused == pane.id }

    /// The pane's tabs on show, in the order of its strip.
    private var visible: [String] {
        let here = Set(pane.tabs)
        let live = Set(model.liveTabIDs)
        return model.tabLayout.visibleTabs(front: pane.front).filter { here.contains($0) && live.contains($0) }
    }

    @ViewBuilder
    private func tab(_ id: String, visible: [String]) -> some View {
        // The shortcuts are the pane the keyboard is in's: with several
        // panes, only its strip shows them.
        let number = focused || !model.paneLayout.isSplit ? (visible.firstIndex(of: id) ?? 99) + 1 : 99
        Group {
            if let holder = TabID.holder(of: id) {
                HolderTabLabel(id: id, kind: holder.kind, project: holder.project, number: number)
            } else if let session = model.session(forTab: id) {
                SessionTab(session: session, number: number)
            }
        }
        .modifier(TabChrome(id: id, pane: pane.id, dropTarget: $dropTarget))
    }

    var body: some View {
        if !pane.tabs.isEmpty || model.paneLayout.isSplit {
            let visible = visible
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(model.tabLayout.strip(among: Set(pane.tabs)), id: \.self) { id in
                                if model.liveTabIDs.contains(id) { tab(id, visible: visible).id(id) }
                            }
                            // Room after the last tab to drop one at the end.
                            Color.clear.frame(width: 28, height: 24)
                                .overlay(alignment: .leading) { if dropTarget == "end" { InsertionMark() } }
                                .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(place: .end, pane: pane.id, model: model, dropTarget: $dropTarget))
                        }
                        .padding(.horizontal, 8)
                        // One fixed height for the row and for the strip:
                        // the strip scrolls sideways only, and with nothing
                        // taller than it there is nothing to move up or down.
                        .frame(height: Self.stripHeight)
                        .background(WheelScrollsSideways())
                    }
                    .frame(height: Self.stripHeight)
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .onChange(of: pane.front) { _, front in
                        if let front { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(front) } }
                    }
                }
                // No button of its own to start or split: sessions and
                // pages start from the header, and one more of what a tab
                // holds from the row under it.
            }
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            // How tall it is, for the room a first session will have when
            // it is started while the strip is not there yet.
            .background(GeometryReader { proxy in Color.clear.onAppear { model.tabStripHeight = proxy.size.height } })
        }
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    let session: SessionInfo
    /// Place in the strip, counted from 1. The first nine have a shortcut.
    let number: Int
    @State private var hovering = false
    @Environment(\.paneFront) private var paneFront
    @Environment(\.paneID) private var paneID

    /// The tab in front of its pane (#69).
    private var selected: Bool { paneFront == TabID.session(session) }
    private var agentID: String { session.agent ?? session.typedAgent ?? "shell" }

    /// What its × does: an agent's shells and pages end with it (#145).
    private var endHelp: String {
        let tab = TabID.session(session)
        let own = model.companions
        let more = (own.shells[tab]?.count ?? 0) + (own.browsers[tab]?.count ?? 0)
        return more == 0 ? "End this session" : "End this session, with its shells and pages"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.symbol(for: agentID))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: agentID))
            Text(session.displayName)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            AgentStateMark(session: session)
            // Sized for another device: its own icon, none for a Mac (#157).
            if model.foreignSizes[session.id] != nil, let symbol = SizeDriver.symbol(for: model.sizeDrivers[session.id]) {
                Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            // The close button takes the shortcut's place under the pointer,
            // so the tab does not change width.
            TabTrailing(id: TabID.session(session), number: number, hovering: hovering, closeHelp: endHelp) { model.requestEnd(session.id) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The agent's tab shows what it showed: the agent, or one of its
        // pages or shells (#127).
        .onTapGesture { model.selectStripTab(TabID.session(session)) }
        .help("\(session.summary.map { "\(session.title): \($0)" } ?? session.title)\n\((session.cwd as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            TabArrangeMenu(id: TabID.session(session))
            Divider()
            Button("End Session") { model.requestEnd(session.id) }
            CloseOthersButton(request: .init(keepGroup: TabID.session(session), pane: paneID))
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AgentStateMark.label(session.displayName, session))
        .accessibilityIdentifier("tab-\(session.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // The tab's menu opens under the pointer only: what it holds is
        // offered as the tab's own actions too.
        .accessibilityAction { model.selectStripTab(TabID.session(session)) }
        .accessibilityAction(named: "End Session") { model.requestEnd(session.id) }
        .accessibilityAction(named: "Close Other Tabs") { model.closeTabs(.init(keepGroup: TabID.session(session), pane: paneID)) }
        .accessibilityAction(named: "Close All Tabs") { model.closeTabs(.init(pane: paneID)) }
        .accessibilityAction(named: "Hand Off") { model.requestHandoff(session: session) }
    }
}

/// The tab of one of a project's groups of the user's own (#127): its
/// shells, its pages, its diffs or its files, with how many it holds. The
/// row under the strip has them, each with its own ×. The tab's × closes
/// all it holds, asked first as `CloseWords.asks` says (#145), as Chrome's
/// window closes its tabs.
private struct HolderTabLabel: View {
    /// What is in front, which it shows (#178).
    @EnvironmentObject private var front: FrontState
    @EnvironmentObject private var model: AppModel
    // What it holds is read through the model, but these say when it
    // changed: a page closed from a phone, a file opened, which need not
    // change what is shown.
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let id: String
    let kind: HolderKind
    let project: String
    let number: Int
    @State private var hovering = false
    @Environment(\.paneFront) private var paneFront
    @Environment(\.paneID) private var paneID

    private var selected: Bool { paneFront == id }

    private func close() { model.requestCloseGroup(id) }

    /// What its × and its menu say: "End Shells", "Close Browser…".
    private func closing(_ count: Int) -> String { CloseWords.groupAction(kind) + (CloseWords.asks(kind, count: count) ? "…" : "") }

    var body: some View {
        let members = model.members(of: id)
        let count = members.count
        let dirty = kind == .files && model.userFiles(in: project).contains { $0.isDirty }
        let title = kind.label(count)
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if dirty { Circle().fill(Color.orange).frame(width: 6, height: 6) }
            TabTrailing(id: id, number: number, hovering: hovering, closeHelp: closing(count), close: close)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectStripTab(id) }
        .help(model.shownMember(of: id).map(model.tabName) ?? kind.title)
        .contextMenu {
            TabArrangeMenu(id: id)
            Divider()
            if kind == .shells { Button("New Shell") { model.launch(nil) } }
            if kind == .browser { Button("New Page") { model.openBrowserTab() } }
            Button(closing(model.members(of: id).count), action: close)
            CloseOthersButton(request: .init(keepGroup: id, pane: paneID))
            TabStripMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind.spoken(count))
        .accessibilityIdentifier("strip-\(kind.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectStripTab(id) }
        .accessibilityAction(named: CloseWords.groupAction(kind), close)
        .accessibilityAction(named: "Close Other Tabs") { model.closeTabs(.init(keepGroup: id, pane: paneID)) }
        .accessibilityAction(named: "Close All Tabs") { model.closeTabs(.init(pane: paneID)) }
    }
}

/// What the menu of every tab ends with: closing many tabs at once. With
/// "close this one" and "close the others" before it, that makes four ways
/// to close, each with a different reach, and no two that do the same.
struct TabStripMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    @Environment(\.paneID) private var paneID

    /// The tabs of the pane the menu is in (#69): what it closes.
    private var count: Int { paneID.flatMap { model.paneLayout.pane($0)?.tabs.count } ?? model.tabCount }

    var body: some View {
        Button("Close All Files") { model.closeFileTabs(pane: paneID) }
            .disabled(files.documents.isEmpty && model.diffTabFile == nil)
            .help("Close every file and diff of this pane. The terminals stay.")
        Button(model.sessionsEnded(by: .init(pane: paneID)).isEmpty ? "Close All Tabs" : "Close All Tabs…") { model.closeTabs(.init(pane: paneID)) }
            .disabled(count == 0)
            .help("Close every tab of this pane, ending its sessions. Pinned tabs stay.")
    }
}

/// Closes every other tab of the pane, sessions included, keeping the one named.
struct CloseOthersButton: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.CloseRequest

    private var count: Int { request.pane.flatMap { model.paneLayout.pane($0)?.tabs.count } ?? model.tabCount }

    var body: some View {
        // The dots say a question follows, which it does when sessions would end.
        Button(model.sessionsEnded(by: request).isEmpty ? "Close Other Tabs" : "Close Other Tabs…") { model.closeTabs(request) }
            .disabled(count < 2)
            .help("Close every other tab of this pane, ending the other sessions. Pinned tabs stay.")
    }
}

// MARK: Arranging tabs

enum TabDrag {
    /// What a dragged tab carries: plain data, which a terminal or an editor
    /// does not take for text to insert. A type of the app's own would have
    /// to be declared in the bundle to be accepted by a drop at all, and
    /// the tab is known from `AppModel.draggedTab` anyway.
    static let type = UTType.data
}

/// The end of a tab: its shortcut, which gives way to the close button under
/// the pointer. A pinned tab shows a pin instead and is closed from its menu.
private struct TabTrailing: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let number: Int
    let hovering: Bool
    let closeHelp: String
    let close: () -> Void

    var body: some View {
        ZStack {
            if model.tabLayout.isPinned(id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(45))
                    .help("Pinned. Closing many tabs at once leaves it open.")
            } else {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                CloseButton(help: closeHelp, action: close)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .frame(minWidth: model.tabLayout.isPinned(id) ? 14 : 22)
    }
}

/// Where a dragged tab will land.
private struct InsertionMark: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(width: 2.5, height: 20).offset(x: -3.25)
    }
}

/// What every tab has on top of its own looks: being dragged and dropped on.
private struct TabChrome: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let id: String
    let pane: String
    @Binding var dropTarget: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) { if dropTarget == id { InsertionMark() } }
            .onDrag {
                model.draggedFolder = nil
                model.draggedTab = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: TabDrag.type.identifier, visibility: .ownProcess) { done in
                    done(Data(id.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(place: .before(id), pane: pane, model: model, dropTarget: $dropTarget))
    }
}

private struct TabDropDelegate: DropDelegate {
    enum Place {
        case before(String), end

        var key: String {
            switch self {
            case .before(let id): return id
            case .end: return "end"
            }
        }
    }

    let place: Place
    /// The pane whose strip it is: a tab dropped there moves into it (#69).
    let pane: String
    let model: AppModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedTab != nil }

    func dropEntered(info: DropInfo) {
        if case .before(let id) = place, id == model.draggedTab { return }
        dropTarget = place.key
    }

    func dropExited(info: DropInfo) {
        if dropTarget == place.key { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedTab else { return false }
        model.draggedTab = nil
        withAnimation(.easeOut(duration: 0.15)) {
            switch place {
            case .before(let target): model.moveTab(id, before: target)
            case .end: model.moveTab(id, before: nil)
            }
        }
        return true
    }
}

/// The part of a tab's menu that arranges it: pin, move.
struct TabArrangeMenu: View {
    @EnvironmentObject private var model: AppModel
    let id: String

    var body: some View {
        let layout = model.tabLayout
        let visible = model.stripTabs(of: model.paneLayout.pane(containing: id))
        let index = visible.firstIndex(of: id)
        Button(layout.isPinned(id) ? "Unpin Tab" : "Pin Tab") { model.setTabPinned(id, !layout.isPinned(id)) }
        Divider()
        Button("Move Left") { model.moveTab(id, by: -1) }.disabled(index == nil || index == 0)
        Button("Move Right") { model.moveTab(id, by: 1) }.disabled(index == nil || index == visible.count - 1)
    }
}

/// Lets a mouse wheel move the strip of tabs sideways.
///
/// The strip scrolls sideways only, and a wheel turns up and down: with a
/// mouse there was no way to reach the tabs past the edge. A turn of the
/// wheel over the strip now moves it sideways, as in a browser. A trackpad's
/// own sideways swipe is left to the scroll view.
private struct WheelScrollsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Returns nil for an event that was used here.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let scrollView = enclosingScrollView, event.window === window, let document = scrollView.documentView else { return event }
            let place = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(place) else { return event }
            // Mostly up and down: that is a wheel, or a swipe that was not
            // meant sideways. Sideways motion is the scroll view's own.
            let vertical = event.scrollingDeltaY
            guard abs(vertical) > abs(event.scrollingDeltaX), vertical != 0 else { return event }
            let step = event.hasPreciseScrollingDeltas ? vertical : vertical * 12
            let clip = scrollView.contentView
            let furthest = max(0, document.frame.width - clip.bounds.width)
            var origin = clip.bounds.origin
            origin.x = min(max(0, origin.x - step), furthest)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return nil
        }
    }
}
