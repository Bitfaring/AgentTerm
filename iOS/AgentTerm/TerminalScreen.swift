import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// A session's terminal, sized to this screen, with a key bar and a compose
/// field. An agent with shells or pages of its own has them here too, as on
/// the Mac: Agent, Shells, Browser, each with its tabs (#76, #69).
struct TerminalScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionID
    /// What to show first: one of the agent's shells ("s:<id>") or pages ("b:<id>").
    var initial: String?
    @State private var confirmingEnd = false
    @State private var showingUsage = false
    @State private var part = Part.agent
    @State private var shellID: SessionID?
    @State private var pageID: String?
    /// The room the screen has, for the iPad's layout.
    @State private var room = CGSize.zero
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.dismiss) private var dismiss

    enum Part: Hashable { case agent, shells, browser }

    /// A phone on its side: far wider than it is high, and with the
    /// keyboard up there is hardly any height left. The navigation bar, the
    /// key bar and the message field would take all of it between them, so
    /// there they share one row and the terminal has the rest.
    private var isOnItsSide: Bool { verticalSize == .compact }

    /// An iPad on its side, the app on all of its screen: the agent's page
    /// beside it, as on the Mac, and its terminal or one of its shells on
    /// the left (#76). Upright, or sharing the screen, it is as on the iPhone.
    private var sideBySide: Bool {
        horizontalSize == .regular && verticalSize == .regular && room.width > room.height && page != nil
    }

    private var companions: (shells: [SessionInfo], pages: [BrowserTabInfo]) { model.companions(of: session) }

    /// The session whose terminal is on screen: the agent's, or one of its shells.
    private var shown: SessionID {
        guard part == .shells else { return session }
        let shells = companions.shells
        return shellID.flatMap { id in shells.contains { $0.id == id } ? id : nil } ?? shells.first?.id ?? session
    }

    private var page: String? {
        let pages = companions.pages
        return pageID.flatMap { id in pages.contains { $0.id == id } ? id : nil } ?? pages.first?.id
    }

    private var controller: TerminalController? {
        model.controller?.session == shown ? model.controller : nil
    }

    /// Agent | Shells | Browser, and the tabs of the one picked; beside
    /// the page, Agent | Shells only.
    @ViewBuilder private var partBar: some View {
        let (shells, pages) = companions
        let withPages = !pages.isEmpty && !sideBySide
        if !shells.isEmpty || withPages {
            VStack(spacing: 6) {
                Picker("Part", selection: $part) {
                    Text(AgentPartWords.agent).tag(Part.agent)
                    if !shells.isEmpty { Text("Shells (\(shells.count))").tag(Part.shells) }
                    if withPages { Text("Browser (\(pages.count))").tag(Part.browser) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("agent-parts")
                if part == .shells, shells.count > 1 {
                    chips(shells.map { ($0.id.description, $0.displayName) }, selected: shown.description) { id in shellID = SessionID(id) }
                }
                if part == .browser, withPages, pages.count > 1 {
                    pageChips
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel)
        }
    }

    private var pageChips: some View {
        chips(companions.pages.map { ($0.id, $0.displayTitle) }, selected: page ?? "") { id in pageID = id }
    }

    /// The agent's page, live, with its tabs over it when it has several.
    @ViewBuilder private var pageColumn: some View {
        if let page {
            VStack(spacing: 0) {
                if sideBySide, companions.pages.count > 1 {
                    pageChips
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.panel)
                }
                LivePageView(tabID: page)
                    .id(page)
            }
        }
    }

    private func chips(_ items: [(id: String, name: String)], selected: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    Button(item.name) { pick(item.id) }
                        .font(.footnote.weight(item.id == selected ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(item.id == selected ? Palette.tint.opacity(0.25) : Color.white.opacity(0.06)))
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// Text size, handing off and ending the session.
    private var sessionMenu: some View {
        Menu {
            Button {
                model.changeFontSize(by: 1)
            } label: {
                Label("Larger Text", systemImage: "textformat.size.larger")
            }
            Button {
                model.changeFontSize(by: -1)
            } label: {
                Label("Smaller Text", systemImage: "textformat.size.smaller")
            }
            if let info = model.session(session), model.folders.contains(model.project(ofWorktree: info.cwd) ?? info.cwd) {
                // The session's folder, on the worktree it runs in (#34).
                Divider()
                Button {
                    model.path.append(.folder(info.cwd))
                } label: {
                    Label("Changes, History and Files", systemImage: "square.stack.3d.up")
                }
            }
            if let info = model.session(session), model.canHandOff(info) {
                Divider()
                Button {
                    model.requestHandoff(session: info)
                } label: {
                    Label("Hand Off…", systemImage: "arrowshape.turn.up.right")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmingEnd = true
            } label: {
                Label("End Session", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("session-menu")
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.status != .connected {
                // The session is still running on the Mac. The app is
                // getting back to it by itself; nothing to do but wait.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting to \(model.pairing?.name ?? "the Mac")…")
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    Button("Try Now") { model.retry() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.panel)
                .accessibilityIdentifier("reconnecting")
            }
            if sideBySide {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        partBar
                        terminalColumn
                    }
                    Palette.hairline.frame(width: 1)
                    pageColumn
                        .frame(width: room.width * 0.5)
                }
            } else {
                // On its side, the iPhone has no room for the bar, but for
                // the way back from a page.
                if !isOnItsSide || part == .browser { partBar }
                if part == .browser, page != nil {
                    pageColumn
                } else {
                    terminalColumn
                }
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { room = geometry.size }
                    .onChange(of: geometry.size) { _, size in room = size }
            }
        }
        // With what its agent is doing, when that is known (#3).
        .navigationTitle(model.session(session).map { info in info.state.map { "\(info.displayName) · \($0.name)" } ?? info.displayName } ?? "Session")
        // The terminal needs the room, and its own bars are under it.
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isOnItsSide ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sessionMenu
            }
        }
        .confirmationDialog(CloseWords.endQuestion("this session"), isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button(CloseWords.endButton, role: .destructive) { model.end(session) }
        } message: {
            // An agent's shells and pages end with it (#145).
            let own = model.companions(of: session)
            Text(CloseWords.endMessage(shells: own.shells.count, pages: own.pages.count))
        }
        .onAppear {
            // Shown first as asked: one of the agent's shells, or pages.
            if let initial, initial.hasPrefix("s:") {
                part = .shells
                shellID = SessionID(initial.dropFirst(2))
            } else if let initial, initial.hasPrefix("b:") {
                part = .browser
                pageID = String(initial.dropFirst(2))
            }
            model.open(shown)
        }
        .onChange(of: shown) { old, new in
            // One terminal at a time on the phone: the other one is left.
            model.leave(old)
            model.open(new)
        }
        .onChange(of: sideBySide) { _, beside in
            // The page has a side of its own: the left shows the agent.
            if beside, part == .browser { part = .agent }
        }
        .onDisappear { model.leave(shown) }
    }

    /// The terminal on screen, the agent's or a shell's, with its bars.
    @ViewBuilder private var terminalColumn: some View {
        VStack(spacing: 0) {
            if let size = model.foreignSize {
                ForeignSizeBanner(size: size)
            }
            if let controller {
                TerminalPane(controller: controller, foreignSize: model.foreignSize)
                    .id(ObjectIdentifier(controller))
                    .accessibilityIdentifier("terminal")
                    .overlay {
                        // The session's earlier output is on its way, up to
                        // megabytes of it: a terminal racing through all of
                        // that says less than a word that it is loading.
                        if model.replaying == shown {
                            LoadingView("Loading the session…", cover: Palette.canvas.opacity(0.92))
                        }
                    }
                    .overlay(alignment: .top) {
                        // Earlier lines on their way, scrolled to the top of
                        // what was loaded: a strip, the screen stays (HIST-6).
                        if model.loadingHistory == shown {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading earlier lines…").font(.footnote)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Palette.panel))
                            .padding(.top, 6)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("loading-history")
                        }
                        // How many earlier lines were asked for, for the tests:
                        // a strip may come and go faster than they can look.
                        Color.clear.frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("history-loaded")
                            .accessibilityValue(model.historyLoaded.map(String.init) ?? "")
                    }
                    // Room around the text, so it does not sit on the
                    // screen's edges; under the last row too, which can
                    // otherwise sit right on what is below.
                    .padding(.horizontal, model.foreignSize == nil ? TerminalInsets.horizontal(onItsSide: isOnItsSide) : 0)
                    .padding(.vertical, model.foreignSize == nil ? TerminalInsets.vertical : 0)
                if isOnItsSide {
                    HStack(spacing: 0) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("terminal-back")
                        KeyBar(controller: controller)
                            .containerRelativeFrame(.horizontal) { width, _ in width * 0.36 }
                        ComposeBar(controller: controller, isOnItsSide: true)
                        sessionMenu
                            .frame(width: 40, height: 40)
                    }
                    .background(Palette.panel)
                    .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
                } else {
                    // An agent typed by hand in a shell has one too, while it runs (#129).
                    if part == .agent, let info = model.session(session), let agent = info.agent ?? info.typedAgent {
                        HStack(spacing: 0) {
                            UsageBar(agent: agent, name: info.agent == nil ? model.agentName(agent) : info.title, usage: info.usage, account: model.accountUsage[agent], compact: true) {
                                showingUsage = true
                            }
                            // Whether its hooks and AgentTerm's MCP server talk to the Mac.
                            if let link = info.link {
                                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 22)
                                AgentLinkMark(link: link, agent: agent, typed: info.agent == nil ? model.agentName(agent) : nil, compact: true)
                            }
                        }
                        .frame(height: 38)
                        .background(Palette.panel)
                        .sheet(isPresented: $showingUsage) {
                            ScrollView {
                                UsageDetails(agent: agent, name: info.title, usage: info.usage, account: model.accountUsage[agent]) {
                                    model.refreshAccountUsage()
                                }
                            }
                            .background(Palette.canvas.ignoresSafeArea())
                            .presentationDetents([.medium, .large])
                            .preferredColorScheme(.dark)
                        }
                    }
                    KeyBar(controller: controller)
                    ComposeBar(controller: controller)
                }
            } else {
                LoadingView("Opening the session…")
            }
        }
    }
}

/// Hosts the SwiftTerm view.
private struct TerminalPane: UIViewRepresentable {
    let controller: TerminalController
    /// The grid another device imposed, while it drives the session.
    let foreignSize: TermSize?

    func makeUIView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.show(controller, foreignSize: foreignSize)
    }
}

/// Lays the terminal out in the room above the key bar.
///
/// Normally the terminal fills it, and its size decides the grid. While
/// the Mac drives the session the grid is the Mac's, far larger than a phone
/// screen. Showing it at full size would leave only its top-left corner on
/// screen. Instead the whole grid is scaled down to fit, like a picture of
/// the Mac's terminal, until the user takes the session back.
final class TerminalContainerView: UIView {
    private var controller: TerminalController?
    private var foreignSize: TermSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TerminalStyle.background
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ controller: TerminalController, foreignSize: TermSize?) {
        let terminal = controller.view
        if terminal.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            terminal.autoresizingMask = []
            addSubview(terminal)
            self.controller = controller
            // Opening a session here means using it here, so take over its size.
            DispatchQueue.main.async { controller.claimSize() }
        }
        self.foreignSize = foreignSize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller else { return }
        let terminal = controller.view
        // Geometry is set through bounds and center, which stay meaningful
        // under a transform. `frame` does not.
        terminal.transform = .identity

        guard foreignSize != nil else {
            terminal.bounds = CGRect(origin: terminal.bounds.origin, size: bounds.size)
            terminal.center = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }

        controller.containerResized(to: bounds.size)
        let grid = controller.gridPixelSize
        guard grid.width > 0, grid.height > 0 else { return }
        let scale = min(1, bounds.width / grid.width, bounds.height / grid.height)
        // A little slack so rounding never costs the last column or row.
        terminal.bounds = CGRect(origin: terminal.bounds.origin, size: CGSize(width: grid.width + 0.5, height: grid.height + 0.5))
        // Centered across, against the top: a terminal reads from the top.
        terminal.center = CGPoint(x: bounds.midX, y: grid.height * scale / 2)
        terminal.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

private struct ForeignSizeBanner: View {
    @EnvironmentObject private var model: PhoneModel
    let size: TermSize

    var body: some View {
        HStack(spacing: 8) {
            // The device's own icon; none for a Mac (#157).
            if let symbol = SizeDriver.symbol(for: model.sizeDriver) { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(SizeDriver.inUse(by: model.sizeDriver, size: size))
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button(StateWords.useThisSize) { model.takeControl() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.panel)
    }
}

/// Keys a phone keyboard does not have.
private struct KeyBar: View {
    let controller: TerminalController
    @StateObject private var keyboard = KeyboardWatcher()

    private struct Key: Identifiable {
        let label: String
        let name: String
        let action: (TerminalController) -> Void
        var id: String { name }
    }

    private static let keys: [Key] = [
        Key(label: "esc", name: "Escape") { $0.type([0x1b]) },
        Key(label: "tab", name: "Tab") { $0.type([0x09]) },
        Key(label: "⇧tab", name: "Shift Tab") { $0.type([0x1b, 0x5b, 0x5a]) },
        Key(label: "^C", name: "Control C") { $0.type([0x03]) },
        Key(label: "↑", name: "Up") { $0.view.sendKeyUp() },
        Key(label: "↓", name: "Down") { $0.view.sendKeyDown() },
        Key(label: "←", name: "Left") { $0.view.sendKeyLeft() },
        Key(label: "→", name: "Right") { $0.view.sendKeyRight() },
        Key(label: "⏎", name: "Return") { $0.type([0x0d]) },
        Key(label: "^D", name: "Control D") { $0.type([0x04]) },
        Key(label: "^L", name: "Control L") { $0.type([0x0c]) },
        Key(label: "^R", name: "Control R") { $0.type([0x12]) },
        Key(label: "^Z", name: "Control Z") { $0.type([0x1a]) },
    ]

    var body: some View {
        HStack(spacing: 0) {
            keys
            if keyboard.isUp {
                // Stays in place at the end of the bar while the keys
                // scroll: the keyboard covers half of the terminal, and
                // this is the way to have it back.
                HideKeyboardButton()
                    .font(.system(size: 17, weight: .medium))
                    .frame(minWidth: 44, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
            }
        }
        .background(Palette.panel)
        .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
    }

    private var keys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.keys) { key in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        key.action(controller)
                    } label: {
                        Text(key.label)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .frame(minWidth: 40, minHeight: 36)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key.name)
                    .accessibilityIdentifier("key-\(key.name)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }
}

/// Text is written here with the normal iOS keyboard and input methods, then
/// sent to the terminal as finished text. Composition (Vietnamese Telex, for
/// one) never happens inside the terminal emulator this way.
///
/// What is written and not sent yet is kept for the session: it is there
/// again when the terminal, or the app, is opened the next time.
///
/// The prompt and the answer to what the agent asks are two texts (#232):
/// while the agent asks, a button opens the place to answer it, and Send in
/// the prompt does not send, or the agent would take the prompt as its
/// answer (`ComposeSend`).
private struct ComposeBar: View {
    @EnvironmentObject private var model: PhoneModel
    let controller: TerminalController
    /// In the one row a phone on its side has for everything.
    var isOnItsSide = false
    @State private var text = ""
    @State private var answer = ""
    @State private var picked = ComposeSend.Side.prompt
    /// The state an answer was sent to from here, while the agent is in it.
    @State private var answered: AgentState?
    /// Why the last Send did not send, until the agent's state changes.
    @State private var held: String?
    @FocusState private var focused: Bool

    private var state: AgentState? { model.session(controller.session)?.state }
    private var side: ComposeSend.Side { ComposeSend.side(picked, state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if side == .answer, let state, let question = ComposeSend.question(of: state) {
                answerPlace(state: state, question: question)
            } else if state?.isWaiting == true {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let held {
                        Text(held)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .lineLimit(isOnItsSide ? 1 : 3)
                            .accessibilityIdentifier("compose-held")
                    }
                    Spacer(minLength: 0)
                    Button {
                        show(.answer)
                    } label: {
                        Label(ComposeWords.answerButton, systemImage: "questionmark.bubble")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                    .accessibilityIdentifier("compose-answer-button")
                }
            } else if let held {
                // Why the last Send did not send, with no question asked:
                // the Mac is not connected (#280).
                Text(held)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(isOnItsSide ? 1 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("compose-held")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if side == .answer {
                        TextField(ComposeWords.answerField, text: $answer, axis: .vertical)
                            .accessibilityIdentifier("compose-answer")
                    } else {
                        TextField("Message", text: $text, axis: .vertical)
                            .accessibilityIdentifier("compose")
                    }
                }
                .lineLimit(isOnItsSide ? 1...2 : 1...5)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, isOnItsSide ? 7 : 9)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Palette.raised))
                Button {
                    if side == .answer { sendAnswer(answer) } else { send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: isOnItsSide ? 30 : 34))
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, isOnItsSide ? 6 : 10)
        .padding(.top, 4)
        .padding(.bottom, isOnItsSide ? 4 : 8)
        .background(Palette.panel)
        .onAppear {
            text = model.composeDraft(for: controller.session)
            if let state, state.isWaiting { answer = model.answerDraft(for: controller.session, to: state) }
        }
        .onChange(of: text) { _, written in model.setComposeDraft(written, for: controller.session) }
        .onChange(of: answer) { _, written in
            if let state, state.isWaiting { model.setAnswerDraft(written, for: controller.session, to: state) }
        }
        .onChange(of: model.status) { _, now in
            // The Mac back: what was said of a Send it was away for goes.
            if now == .connected { held = nil }
        }
        .onChange(of: state) { _, now in
            // Another question, or none: what was said of the last Send
            // goes, and so does the answer to what is no longer asked. The
            // prompt is as it was.
            held = nil
            if answered != now { answered = nil }
            if let now, now.isWaiting {
                answer = model.answerDraft(for: controller.session, to: now)
            } else {
                answer = ""
                picked = .prompt
            }
        }
    }

    /// What the agent asks, its choices, and the way back to the prompt.
    private func answerPlace(state: AgentState, question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ComposeWords.asks(state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button {
                    show(.prompt)
                } label: {
                    Label(ComposeWords.promptButton, systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("compose-prompt-button")
            }
            if !question.text.isEmpty {
                Text(question.text)
                    .font(.footnote)
                    .lineLimit(isOnItsSide ? 1 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("compose-question")
            }
            if !question.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                            Button(choice) { sendAnswer(choice) }
                                .font(.footnote)
                                .lineLimit(1)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("compose-choice-\(index)")
                        }
                    }
                }
            } else if case .waitingForPermission = state {
                Text(ComposeWords.choicesInTerminal).font(.caption).foregroundStyle(.secondary)
            }
            if let held {
                Text(held).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("compose-held")
            }
        }
    }

    /// The prompt or the answer shown, the other kept as it is; the
    /// keyboard stays up if it was.
    private func show(_ shown: ComposeSend.Side) {
        let typing = focused
        held = nil
        picked = shown
        if typing { DispatchQueue.main.async { focused = true } }
    }

    /// An answer, typed or one of the choices, sent with the state it
    /// answers: the host types it only while the agent still asks that,
    /// and says so when it no longer does.
    private func sendAnswer(_ written: String) {
        let reply = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        switch ComposeSend.send(state: state, side: .answer, answered: answered) {
        case .answer(let to):
            model.answer(session: controller.session, to: to, text: reply)
            answered = to
            answer = ""
            model.setAnswerDraft("", for: controller.session, to: to)
            held = nil
            picked = .prompt
        case .held(let why):
            held = why
        case .prompt:
            break
        }
    }

    private func send() {
        switch ComposeSend.send(state: state, side: .prompt, answered: answered) {
        case .prompt: break
        case .held(let why):
            // The agent asks something: the prompt is kept, and why it was
            // not sent is said.
            held = why
            return
        case .answer: return
        }
        // Never into a connection that is not there: the message is kept,
        // and why it was not sent is said (#280).
        guard model.status == .connected else {
            held = ComposeWords.notConnected(model.pairing?.name ?? "the Mac")
            return
        }
        let message = text
        text = ""
        guard !message.isEmpty else {
            controller.type([0x0d])
            return
        }
        // A long or multi-line message goes as a paste to a program that
        // takes one (`SentText`). An answer to a question goes the
        // answer's way, as the host types it.
        controller.type(Array(SentText.text(message, bracketedPaste: controller.bracketedPasteMode).utf8))
        // Sent separately: agents treat a burst that ends in Return as a
        // paste and would not submit it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            controller.type([0x0d])
        }
    }
}

/// Room around the terminal. A new session's size is worked out with it
/// taken off (`PhoneModel.startingSize`), so it starts at the size it is shown at.
enum TerminalInsets {
    static func horizontal(onItsSide: Bool) -> CGFloat { onItsSide ? 8 : 10 }
    static let vertical: CGFloat = 6
}
