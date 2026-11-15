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
/// The user does not split it; an agent's shells and pages are shown beside
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

    private static var divider: CGFloat { 1 }

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
                Theme.hairline
                    .frame(width: axis == .sideBySide ? Self.divider : nil, height: axis == .stacked ? Self.divider : nil)
                    .overlay {
                        // A handle wider than the line, so it is easy to catch.
                        Color.clear
                            .frame(width: axis == .sideBySide ? 9 : nil, height: axis == .stacked ? 9 : nil)
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
    // What a pane shows is read through the model, but these say when it
    // changed: a file of another Mac whose words come later, a new page.
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
        if let front = pane.front, let session = model.session(forTab: front) {
            if model.hasArea(front) {
                AgentAreaView(agent: session, paneFocused: focused)
            } else {
                SessionContent(session: session, focused: focused)
            }
        } else if let front = pane.front, let document = model.document(forTab: front) {
            DocumentView(document: document)
        } else if pane.front == TabID.diff, let file = model.diffTabFile {
            DiffDocumentView(file: file)
        } else if let front = pane.front, let tab = model.browsers.tab(forTab: front) {
            BrowserPaneView(tab: tab, focused: focused)
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

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { model.paneFrames[place] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in model.paneFrames[place] = frame }
                .onDisappear { model.paneFrames[place] = nil }
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
        if let agent = session.agent {
            Theme.hairline.frame(height: 1)
            UsageBar(agent: agent, name: session.title, usage: session.usage, account: model.accountUsage[agent]) {
                showingUsage = true
            }
            .background(Theme.panel)
            .help("Show the account's usage")
            .popover(isPresented: $showingUsage, arrowEdge: .bottom) {
                ScrollView {
                    UsageDetails(agent: agent, name: session.title, usage: session.usage, account: model.accountUsage[agent]) {
                        model.refreshAccountUsage()
                    }
                }
                .frame(width: 380)
                .frame(maxHeight: 520)
            }
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

/// An agent with its own shells and browser beside it (#69): the agent on
/// the left, its browser on the right, its shells under both, the full
/// width. A part that is closed is hidden, and comes back from the bar.
struct AgentAreaView: View {
    @EnvironmentObject private var model: AppModel
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
        VStack(spacing: 0) {
            if showShells {
                SplitContainer(axis: .stacked, fraction: area.down, setFraction: { model.setAgentArea(agentTab, down: $0) }) {
                    top(showBrowser: showBrowser)
                } second: {
                    ShellsPart(agentTab: agentTab, shells: shells, shown: area.shownShell(among: shells), focused: paneFocused && focus == .shells)
                }
            } else {
                top(showBrowser: showBrowser)
            }
            HiddenPartsBar(agentTab: agentTab, hiddenShells: area.shellsHidden ? shells.count : 0, hiddenBrowser: area.browserHidden ? browserTabs.count : 0)
            // What the agent has used, at the very bottom, under its shells.
            SessionUsageBar(session: agent)
        }
    }

    /// The page beside the agent, shown as a device: as wide as its screen,
    /// and the agent gets the rest.
    private var emulatedWidth: CGFloat? {
        area.shownBrowser(among: browserTabs).flatMap { model.browserEmulation[$0] }.map { CGFloat($0) }
    }

    @ViewBuilder
    private func top(showBrowser: Bool) -> some View {
        if showBrowser {
            SplitContainer(
                axis: .sideBySide, fraction: area.across, secondLength: emulatedWidth, setFraction: { model.setAgentArea(agentTab, across: $0) }
            ) {
                agentPart
            } second: {
                BrowserPart(agentTab: agentTab, tabs: browserTabs, shown: area.shownBrowser(among: browserTabs), focused: paneFocused && focus == .browser)
            }
        } else {
            agentPart
        }
    }

    private var agentPart: some View {
        SessionContent(session: agent, focused: paneFocused && focus == .agent, showsUsage: false)
            .background(PaneFrameReader(place: .part(agent: agentTab, .agent)))
    }
}

/// The agent's shells, as tabs of one pane under it.
private struct ShellsPart: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let shells: [String]
    let shown: String?
    let focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PartStrip(title: "Shells", agentTab: agentTab, part: .shells, tabs: shells, shown: shown, focused: focused)
            if let shown, let session = model.session(forTab: shown) {
                SessionContent(session: session, focused: focused, showsUsage: false)
            } else {
                Theme.canvas
            }
        }
        .background(PaneFrameReader(place: .part(agent: agentTab, .shells)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-shells")
    }
}

/// The agent's browser tabs, on the right of it.
private struct BrowserPart: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let tabs: [String]
    let shown: String?
    let focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PartStrip(title: "Browser", agentTab: agentTab, part: .browser, tabs: tabs, shown: shown, focused: focused)
            if let shown, let tab = model.browsers.tab(forTab: shown) {
                BrowserPaneView(tab: tab, focused: focused)
            } else {
                Theme.canvas
            }
        }
        .background(PaneFrameReader(place: .part(agent: agentTab, .browser)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-browser")
    }
}

/// The strip of a part of an agent's area: its tabs, and closing the part.
private struct PartStrip: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let agentTab: String
    let part: AgentAreaPart
    let tabs: [String]
    let shown: String?
    let focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.self) { tab in
                        PartTab(tab: tab, selected: tab == shown)
                    }
                }
            }
            Button {
                model.hideAgentPart(part, of: agentTab)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(part == .shells ? "Hide the shells. They keep running, and stay in the list of sessions." : "Hide the browser. Its tabs stay open.")
            .accessibilityLabel(part == .shells ? "Hide Shells" : "Hide Browser")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.panel)
        .overlay(alignment: .top) { if focused { Color.accentColor.opacity(0.6).frame(height: 1.5) } }
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

private struct PartTab: View {
    @EnvironmentObject private var model: AppModel
    let tab: String
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let session = model.session(forTab: tab)
        HStack(spacing: 5) {
            Image(systemName: session != nil ? Theme.symbol(for: "shell") : "globe")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.tabName(tab))
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let session { AgentStateMark(session: session) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id: tab) }
        .contextMenu {
            if let session {
                Button("End Session") { model.requestEnd(session.id) }
            } else if let browser = model.browsers.tab(forTab: tab) {
                Button("Close Tab") { model.browsers.close(browser) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.tabName(tab))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(id: tab) }
    }
}

/// Under an agent's area, the parts that were closed, to show them again.
private struct HiddenPartsBar: View {
    @EnvironmentObject private var model: AppModel
    let agentTab: String
    let hiddenShells: Int
    let hiddenBrowser: Int

    var body: some View {
        if hiddenShells > 0 || hiddenBrowser > 0 {
            HStack(spacing: 8) {
                if hiddenShells > 0 {
                    Button("Show Shells (\(hiddenShells))") { model.showAgentPart(.shells, of: agentTab) }
                }
                if hiddenBrowser > 0 {
                    Button("Show Browser (\(hiddenBrowser))") { model.showAgentPart(.browser, of: agentTab) }
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.panel)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        }
    }
}
