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
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.dismiss) private var dismiss

    enum Part: Hashable { case agent, shells, browser }

    /// A phone on its side: far wider than it is high, and with the
    /// keyboard up there is hardly any height left. The navigation bar, the
    /// key bar and the message field would take all of it between them, so
    /// there they share one row and the terminal has the rest.
    private var isOnItsSide: Bool { verticalSize == .compact }

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

    /// Agent | Shells | Browser, and the tabs of the one picked.
    @ViewBuilder private var partBar: some View {
        let (shells, pages) = companions
        if !shells.isEmpty || !pages.isEmpty {
            VStack(spacing: 6) {
                Picker("Part", selection: $part) {
                    Text("Agent").tag(Part.agent)
                    if !shells.isEmpty { Text("Shells (\(shells.count))").tag(Part.shells) }
                    if !pages.isEmpty { Text("Browser (\(pages.count))").tag(Part.browser) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("agent-parts")
                if part == .shells, shells.count > 1 {
                    chips(shells.map { ($0.id.description, $0.displayName) }, selected: shown.description) { id in shellID = SessionID(id) }
                }
                if part == .browser, pages.count > 1 {
                    chips(pages.map { ($0.id, $0.displayTitle) }, selected: page ?? "") { id in pageID = id }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel)
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
            if !isOnItsSide { partBar }
            if part == .browser, let page {
                LivePageView(tabID: page)
                    .id(page)
            } else if let size = model.foreignSize {
                ForeignSizeBanner(size: size)
            }
            if part == .browser, page != nil {
                // The page has its own controls.
            } else if let controller {
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
                    if part == .agent, let info = model.session(session), let agent = info.agent {
                        UsageBar(agent: agent, name: info.title, usage: info.usage, account: model.accountUsage[agent], compact: true) {
                            showingUsage = true
                        }
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
        .background(Palette.canvas.ignoresSafeArea())
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
        .confirmationDialog("End this session?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Session", role: .destructive) { model.end(session) }
        } message: {
            Text("The program running in it is stopped.")
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
        .onDisappear { model.leave(shown) }
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
            Image(systemName: "macbook").foregroundStyle(.secondary)
            Text("In use on the Mac · \(size.cols)×\(size.rows) · scaled to fit")
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("Fit This Screen") { model.takeControl() }
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
private struct ComposeBar: View {
    @EnvironmentObject private var model: PhoneModel
    let controller: TerminalController
    /// In the one row a phone on its side has for everything.
    var isOnItsSide = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(isOnItsSide ? 1...2 : 1...5)
                .focused($focused)
                .accessibilityIdentifier("compose")
                .padding(.horizontal, 14)
                .padding(.vertical, isOnItsSide ? 7 : 9)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Palette.raised))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: isOnItsSide ? 30 : 34))
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, isOnItsSide ? 6 : 10)
        .padding(.top, 4)
        .padding(.bottom, isOnItsSide ? 4 : 8)
        .background(Palette.panel)
        .onAppear { text = model.composeDraft(for: controller.session) }
        .onChange(of: text) { _, written in model.setComposeDraft(written, for: controller.session) }
    }

    private func send() {
        let message = text
        text = ""
        guard !message.isEmpty else {
            controller.type([0x0d])
            return
        }
        // A long or multi-line message goes as a paste to a program that
        // takes one (`SentText`), unless the agent asks something: what
        // its question takes was tried typed only.
        let asks: Bool
        switch model.session(controller.session)?.state {
        case .waitingForAnswer, .waitingForPermission: asks = true
        default: asks = false
        }
        controller.type(Array(SentText.text(message, bracketedPaste: controller.bracketedPasteMode && !asks).utf8))
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
