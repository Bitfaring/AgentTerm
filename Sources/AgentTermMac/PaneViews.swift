import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// The pane a view is in, for its strip of tabs and what it shows (#69).
private struct PaneIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// The tab in front of the pane a tab is shown in.
private struct PaneFrontKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var paneID: String? {
        get { self[PaneIDKey.self] }
        set { self[PaneIDKey.self] = newValue }
    }

    var paneFront: String? {
        get { self[PaneFrontKey.self] }
        set { self[PaneFrontKey.self] = newValue }
    }
}

/// The middle of the window in Sessions: the project on show's one pane.
/// The user does not split it; an agent's page and shell are shown beside
/// it, in its area.
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PaneView(pane: model.paneLayout.focusedPane)
    }
}

/// Two views side by side or one above the other, with a divider between
/// them that is dragged to give one more room: an agent's area.
struct SplitContainer<First: View, Second: View>: View {
    let axis: PaneLayout.Axis
    let fraction: Double
    /// How long the second side is, when it is to be just that: a page
    /// shown as a device, as wide as its screen. The first gets the rest,
    /// a quarter at least.
    var secondLength: CGFloat?
    /// For an agent's area, which keeps its own shares: called as it is dragged.
    var setFraction: ((Double) -> Void)?
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragging: Double?

    /// A gutter rather than a line, so that the parts read as parts.
    private static var divider: CGFloat { 6 }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .sideBySide ? proxy.size.width : proxy.size.height
            let share = CGFloat(dragging ?? fraction)
            let fixed = dragging == nil ? self.secondLength.map { max(total * 0.25, total - Self.divider - $0) } : nil
            let firstLength = fixed ?? max(0, (total - Self.divider) * share)
            let secondLength = max(0, total - Self.divider - firstLength)
            let layout = axis == .sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first()
                    .frame(width: axis == .sideBySide ? firstLength : nil, height: axis == .stacked ? firstLength : nil)
                // Lighter than the parts on both sides, edged by a line on
                // each, so that where one ends is seen at once.
                Color(white: 0.17)
                    .frame(width: axis == .sideBySide ? Self.divider : nil, height: axis == .stacked ? Self.divider : nil)
                    .overlay {
                        let edge = Color.white.opacity(0.10)
                        if axis == .sideBySide {
                            HStack(spacing: 0) {
                                edge.frame(width: 1); Spacer(minLength: 0); edge.frame(width: 1)
                            }
                        } else {
                            VStack(spacing: 0) {
                                edge.frame(height: 1); Spacer(minLength: 0); edge.frame(height: 1)
                            }
                        }
                    }
                    // A grip in the middle, which says it can be dragged.
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: axis == .sideBySide ? 2 : 28, height: axis == .stacked ? 2 : 28)
                    }
                    .overlay {
                        // A handle wider than the gutter, so it is easy to catch.
                        Color.clear
                            .frame(width: axis == .sideBySide ? 12 : nil, height: axis == .stacked ? 12 : nil)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { (axis == .sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named(SplitSpace.name))
                                    .onChanged { value in
                                        let at = axis == .sideBySide ? value.location.x : value.location.y
                                        dragging = min(max(Double(at / max(total, 1)), 0.1), 0.9)
                                    }
                                    .onEnded { _ in
                                        if let dragging { setFraction?(dragging) }
                                        dragging = nil
                                    }
                            )
                            .accessibilityLabel("Divider")
                    }
                    // Over both sides, so that its handle can be caught on either.
                    .zIndex(1)
                second()
                    .frame(width: axis == .sideBySide ? secondLength : nil, height: axis == .stacked ? secondLength : nil)
            }
            .coordinateSpace(name: SplitSpace.name)
        }
    }
}

private enum SplitSpace {
    static let name = "split"
}

/// One pane: its strip of tabs, and the tab in front.
struct PaneView: View {
    @EnvironmentObject private var model: AppModel
    // Which of a tab's items is shown is read through the model, but these
    // say when it changed: a file opened, a new page.
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let pane: PaneLayout.Pane

    private var focused: Bool { model.paneLayout.focused == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            SessionTabs(pane: pane)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaneFrameReader(place: .pane(pane.id)))
        .environment(\.paneID, pane.id)
        .environment(\.paneFront, pane.front)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-\(pane.id)")
    }

    @ViewBuilder
    private var content: some View {
        if let front = pane.front, let item = model.shownMember(of: front) {
            VStack(spacing: 0) {
                GroupRow(group: front)
                if TabID.holder(of: front) == nil, model.hasArea(front), let agent = model.session(forTab: front) {
                    AgentAreaView(agent: agent, paneFocused: focused)
                } else if model.isShellsSplit(front) {
                    ShellsSplitView(group: front, paneFocused: focused)
                } else {
                    MemberContent(group: front, item: item, focused: focused)
                }
            }
        } else {
            EmptyPaneView(pane: pane)
        }
    }
}

/// Tells the model where a pane, or a part of an agent's area, is in the
/// window, for a click to find it.
struct PaneFrameReader: View {
    @EnvironmentObject private var model: AppModel
    let place: PanePlace
    /// Which reader wrote the place's frame. When a part is made again, as
    /// when a page or a shell comes beside the agent, the new reader
    /// appears before the old one goes: the old one then took the new
    /// one's frame away, and a click in the agent found no part and left
    /// the keyboard where it was (the owner's report, 2026-11-21).
    @State private var token = UUID()

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { model.setPaneFrame(proxy.frame(in: .global), for: place, by: token) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in model.setPaneFrame(frame, for: place, by: token) }
                .onDisappear { model.setPaneFrame(nil, for: place, by: token) }
        }
    }
}

/// A session's terminal, with what goes with it: the banner while another
/// device sizes it, and what an agent has used under it.
struct SessionContent: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    /// Whether the keyboard is to be in it: its pane's, and its part's.
    let focused: Bool
    /// Its usage under it: not for a shell in an agent's area.
    var showsUsage = true

    var body: some View {
        if let controller = model.controller(for: session.id) {
            VStack(spacing: 0) {
                let foreign = model.foreignSizes[session.id]
                if let foreign {
                    ForeignSizeBanner(size: foreign, session: session.id)
                }
                TerminalPane(controller: controller, foreignSize: foreign, focused: focused && model.selectedSession == session.id)
                    .id(controller.session)
                    // Which terminal has the keyboard is told by the element
                    // that holds it (PANE-16).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal-\(session.id)")
                    .overlay {
                        // The session's earlier output is on its way,
                        // megabytes of it: a terminal racing through that
                        // says less than a word that it is loading.
                        if model.replaying.contains(controller.session) {
                            LoadingView("Loading the session…", cover: Theme.canvas.opacity(0.92))
                        }
                    }
                    // The framed preview of another device's screen is
                    // centered, so it gets no one-sided padding.
                    .padding(.horizontal, foreign == nil ? TerminalInsets.horizontal : 0)
                    .padding(.top, foreign == nil ? TerminalInsets.top : 0)
                    // Room under the last row: the rows fill the pane from
                    // the top, so what is left over is anything from nothing
                    // to almost a row, and the last line could sit on the edge.
                    .padding(.bottom, foreign == nil ? TerminalInsets.bottom : 0)
                    .background(Theme.canvas)
                    .background(TerminalAreaReader(insets: foreign == nil ? TerminalInsets.total : CGSize(width: 10, height: 12), reports: focused))
                if showsUsage {
                    // What the agent's session has used, under its terminal.
                    SessionUsageBar(session: session)
                }
            }
        } else {
            LoadingView("Loading the session…", cover: Theme.canvas)
        }
    }
}

/// What an agent's session has used, at the bottom of what shows it: under
/// its terminal, or under its whole area, its shells included.
struct SessionUsageBar: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @State private var showingUsage = false

    var body: some View {
        // An agent typed by hand in a shell has one too, while it runs (#129).
        if let agent = session.agent ?? session.typedAgent {
            let name = session.agent == nil ? model.agentName(agent) : session.title
            Theme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                UsageBar(agent: agent, name: name, usage: session.usage, account: model.accountUsage[agent]) {
                    showingUsage = true
                }
                .help("Show the account's usage")
                .popover(isPresented: $showingUsage, arrowEdge: .bottom) {
                    ScrollView {
                        UsageDetails(agent: agent, name: name, usage: session.usage, account: model.accountUsage[agent]) {
                            model.refreshAccountUsage()
                        }
                    }
                    .frame(width: 380)
                    .frame(maxHeight: 520)
                }
                // Whether its hooks and AgentTerm's MCP server talk to the host.
                if let link = session.link {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 24)
                    AgentLinkMark(link: link, typed: session.agent == nil ? name : nil)
                }
            }
            .frame(height: 46)
            .background(Theme.panel)
        }
    }
}

/// The project's pane with no tab in it: the launch screen.
private struct EmptyPaneView: View {
    let pane: PaneLayout.Pane

    var body: some View {
        WelcomeView().frame(maxWidth: .infinity, maxHeight: .infinity)
            // Where a terminal would go, less its padding, and less the
            // strip of tabs it will have then.
            .background(TerminalAreaReader(insets: TerminalInsets.total, stripShown: false, reports: true))
    }
}

/// What one of the user's groups shows (#127): the item picked in its row,
/// the whole pane for it. An agent with nothing of its own beside it is
/// shown so too.
struct MemberContent: View {
    @EnvironmentObject private var model: AppModel
    // What is shown is read through the model, but these say when it
    // changed: a file of another Mac whose words come later, a page. Its
    // pane's watching them is not enough: with the same group, item and
    // focus, SwiftUI does not make this view's body again.
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let group: String
    let item: String
    let focused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let session = model.session(forTab: item) {
            SessionContent(session: session, focused: focused, showsUsage: session.agent != nil || session.typedAgent != nil).id(session.id)
        } else if let tab = model.browsers.tab(forTab: item) {
            BrowserPaneView(tab: tab, focused: focused).id(tab.id)
        } else if let diff = model.diffTabs.first(where: { $0.tabID == item }) {
            DiffDocumentView(file: diff.file)
        } else if let document = model.document(forTab: item) {
            DocumentView(document: document)
        } else {
            Theme.canvas
        }
    }
}

/// An agent with its own page and shell beside it (#69): the agent on the
/// left, its page on the right, its shell under both, the full width. Which
/// page and which shell, and whether each part is shown, is picked in the
/// row under the strip (#127), where the parts' own strips were.
struct AgentAreaView: View {
    @EnvironmentObject private var model: AppModel
    // What it shows is read through the model, but this says when its
    // pages changed.
    @EnvironmentObject private var browsers: BrowserModel
    let agent: SessionInfo
    let paneFocused: Bool

    private var agentTab: String { TabID.session(agent) }
    private var area: AgentArea { model.agentAreas[agentTab] ?? AgentArea() }
    private var shells: [String] { model.companions.shells[agentTab] ?? [] }
    private var browserTabs: [String] { model.companions.browsers[agentTab] ?? [] }
    private var focus: AgentAreaPart { model.agentAreaFocus[agentTab] ?? .agent }

    var body: some View {
        let showShells = !shells.isEmpty && !area.shellsHidden
        let showBrowser = !browserTabs.isEmpty && !area.browserHidden
        let alone = model.agentAreaAlone[agentTab].flatMap { part in model.shownParts(of: agentTab).contains(part) ? part : nil }
        VStack(spacing: 0) {
            if let alone {
                // One part for a while, filling the area (#69).
                switch alone {
                case .agent: agentPart
                case .browser: browserPart
                case .shells: shellsPart
                }
                AloneBar(agentTab: agentTab, part: alone)
            } else if showShells {
                SplitContainer(axis: .stacked, fraction: area.down, setFraction: { model.setAgentArea(agentTab, down: $0) }) {
                    top(showBrowser: showBrowser)
                } second: {
                    shellsPart
                }
            } else {
                top(showBrowser: showBrowser)
            }
            // What the agent has used, at the very bottom, under its shell.
            SessionUsageBar(session: agent)
        }
    }

    private var shellsPart: some View {
        ShellsPart(agentTab: agentTab, shown: area.shownShell(among: shells), focused: paneFocused && focus == .shells, ringed: severalShown)
    }

    private var browserPart: some View {
        BrowserPart(agentTab: agentTab, shown: area.shownBrowser(among: browserTabs), focused: paneFocused && focus == .browser, ringed: severalShown)
    }

    /// The page beside the agent, shown as a device: as wide as its screen,
    /// and the agent gets the rest; never narrower than its bar needs for
    /// its buttons, the page then in the middle of its part.
    private var emulatedWidth: CGFloat? {
        area.shownBrowser(among: browserTabs).flatMap { model.browserEmulation[$0] }.map { max(CGFloat($0), BrowserPaneView.barWidth) }
    }

    @ViewBuilder
    private func top(showBrowser: Bool) -> some View {
        if showBrowser {
            SplitContainer(
                axis: .sideBySide, fraction: area.across, secondLength: emulatedWidth, setFraction: { model.setAgentArea(agentTab, across: $0) }
            ) {
                agentPart
            } second: {
                browserPart
            }
        } else {
            agentPart
        }
    }

    private var agentPart: some View {
        SessionContent(session: agent, focused: paneFocused && focus == .agent, showsUsage: false)
            .id(agent.id)
            .modifier(PartRing(on: paneFocused && focus == .agent && severalShown))
            .background(PaneFrameReader(place: .part(agent: agentTab, .agent)))
    }

    /// More than the agent on show, side by side or one above the other:
    /// the part the keyboard is in is then framed.
    private var severalShown: Bool {
        model.agentAreaAlone[agentTab] == nil && ((!shells.isEmpty && !area.shellsHidden) || (!browserTabs.isEmpty && !area.browserHidden))
    }
}

/// The frame of the part of an agent's area the keyboard is in, when the
/// area shows more than one (owner's request, 2026-11-21): a line at its
/// top was hard to see, and the agent had none.
struct PartRing: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The agent's shell picked, under it. The part the keyboard is in is
/// framed (`PartRing`).
private struct ShellsPart: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let shown: String?
    let focused: Bool
    /// Framed when it has the keyboard: not when it is shown alone.
    let ringed: Bool

    var body: some View {
        ZStack {
            Theme.canvas
            if let shown, let session = model.session(forTab: shown) {
                SessionContent(session: session, focused: focused, showsUsage: false).id(session.id)
            }
        }
        .modifier(PartRing(on: focused && ringed))
        .background(PaneFrameReader(place: .part(agent: agentTab, .shells)))
        .background(PartName(label: "Its shells", identifier: "agent-shells"))
    }
}

/// The agent's page picked, on the right of it.
private struct BrowserPart: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let shown: String?
    let focused: Bool
    /// Framed when it has the keyboard: not when it is shown alone.
    let ringed: Bool

    var body: some View {
        ZStack {
            Theme.canvas
            if let shown, let tab = model.browsers.tab(forTab: shown) {
                BrowserPaneView(tab: tab, focused: focused).id(tab.id)
            }
        }
        .modifier(PartRing(on: focused && ringed))
        .background(PaneFrameReader(place: .part(agent: agentTab, .browser)))
        .background(PartName(label: "Its page", identifier: "agent-browser"))
    }
}

/// The name of a part of an agent's area for assistive tools, "Its page"
/// or "Its shells", as an element of its own behind the part, the part's
/// size. A container about the part cannot have it: with the part's strip
/// gone (#127) it holds one container only, what the part shows, and
/// SwiftUI makes one element of the two, with the outer one's name; the
/// terminal's or the page's own was lost (seen in the accessibility tree).
private struct PartName: View {
    let label: String
    let identifier: String

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }
}

/// Says that one part of an agent's area is shown alone, and gives the
/// others back (#69).
private struct AloneBar: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let part: AgentAreaPart

    private var words: String {
        switch part {
        case .agent: return "Only the agent is shown."
        case .browser: return "Only its page is shown."
        case .shells: return "Only its shells are shown."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(words).foregroundStyle(.secondary)
            Button("Show All") { model.toggleAlone() }
                .help("Shows the agent, its page and its shells again (⇧⌘Return)")
            Spacer()
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-alone")
    }
}
