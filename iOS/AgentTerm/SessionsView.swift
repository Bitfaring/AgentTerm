import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI
import UniformTypeIdentifiers

/// The paired Mac's folders and the sessions running in them.
struct SessionsView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.status != .connected {
                        StatusCard()
                    } else if model.hostMatch != .same {
                        VersionCard(match: model.hostMatch)
                    }
                    if model.status == .connected {
                        // What needs the user (#67): the agents that wait,
                        // what stopped (said in words, rather than shown as
                        // a list that emptied), the agents done and not seen.
                        InboxSection()
                    }
                    if model.status == .connected {
                        // How the Mac is doing: the Mac this phone is
                        // connected to, not the phone itself.
                        SystemStatsPanel(store: model.system, large: true) { figures in
                            figures
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                        }
                    }
                    if model.status == .connected && !model.sessionsKnown {
                        // Connected, and the Mac has not said yet what is on it.
                        LoadingView("Loading the sessions…").frame(height: 120)
                    }
                    ForEach(model.groups) { group in
                        FolderSection(group: group)
                    }
                    if model.status == .connected {
                        // The Mac's pages that no folder shows (#76).
                        BrowserSection()
                    }
                    if model.status == .connected {
                        // Any folder on the Mac, not only the listed ones.
                        Button {
                            model.showBrowser = true
                        } label: {
                            Label("Open Another Folder…", systemImage: "folder.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                        }
                    }
                    if model.status == .connected && model.folders.isEmpty {
                        Text("Add project folders in AgentTerm on your Mac and they show up here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    if model.status == .connected && model.agentsLoaded && model.installedAgents.isEmpty {
                        Text("No agent CLI was found on the Mac. You can still open a shell.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    Text("\(AppVersion.label) · protocol \(agenttermProtocolVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .accessibilityIdentifier("app-version")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .readableWidth()
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(model.pairing?.name ?? "AgentTerm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Back to the list of Macs, to look at another one.
                    Button {
                        model.showMacs()
                    } label: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("Macs")
                    .accessibilityIdentifier("mac-menu")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let id):
                    TerminalScreen(session: id)
                case .result(let id):
                    TurnResultScreen(session: id)
                case .companion(let agent, let item):
                    TerminalScreen(session: agent, initial: item)
                case .folder(let folder):
                    FolderScreen(folder: folder)
                case .file(let folder, let file, let staged):
                    PatchScreen(folder: folder, file: file, staged: staged)
                case .document(let path):
                    DocumentScreen(path: path)
                case .documentLine(let path, let line):
                    DocumentScreen(path: path, line: line)
                case .commits(let folder):
                    CommitsScreen(folder: folder)
                case .commit(let folder, let hash):
                    CommitScreen(folder: folder, hash: hash)
                case .commitFile(let folder, let hash, let file):
                    CommitFileScreen(folder: folder, hash: hash, file: file)
                case .stashes(let folder):
                    StashesScreen(folder: folder)
                case .stash(let folder, let hash):
                    StashScreen(folder: folder, hash: hash)
                case .stashFile(let folder, let hash, let file):
                    StashFileScreen(hash: hash, file: file)
                }
            }
            .sheet(isPresented: $model.showBrowser) {
                BrowseSheet()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// Shown when the Mac's AgentTerm and this app are of different versions.
private struct VersionCard: View {
    @EnvironmentObject private var model: PhoneModel
    let match: ProtocolMatch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(match == .hostOlder ? "AgentTerm on \(model.pairing?.name ?? "the Mac") is an older version" : "This app is older than AgentTerm on \(model.pairing?.name ?? "the Mac")")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    match == .hostOlder
                        ? "Update AgentTerm on the Mac. If it was just updated, restart its host there. Until then some things will not work."
                        : "Update this app to the version that goes with the Mac's. Until then some things will not work."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.yellow.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("version-card")
    }
}

/// A part of AgentTerm on the Mac that stopped without being asked to.
/// The Inbox, at the top of the Sessions list (#67), when something needs
/// the user: the same items as the Mac's Inbox, in the same order.
private struct InboxSection: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        let items = model.inboxItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(Inbox.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox-title")
                ForEach(items) { item in
                    switch item.kind {
                    case .failure(let failure): FailureCard(failure: failure)
                    case .session: InboxRow(item: item)
                    }
                }
            }
        }
    }
}

/// A session of the Inbox: whose it is, why it is there and what was said.
/// Touched, it opens; a done one can be dismissed from its menu.
private struct InboxRow: View {
    @EnvironmentObject private var model: PhoneModel
    let item: InboxItem

    var body: some View {
        if case .session(let info) = item.kind {
            let agent = info.agent ?? info.typedAgent ?? "shell"
            let waits = info.state?.isWaiting == true
            Button {
                model.open(item)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: AgentStyle.symbol(for: agent))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AgentStyle.accent(for: agent))
                        .frame(width: 22)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((info.cwd as NSString).lastPathComponent + " · " + info.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(model.agentName(agent) + " " + (item.notice?.why ?? ""))
                            .font(.footnote)
                            .foregroundStyle(waits ? Color.orange : .secondary)
                            .lineLimit(1)
                        if let detail = item.notice?.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if item.canBeDismissed {
                    Button(Inbox.dismiss, systemImage: "xmark") { model.dismiss(item) }
                }
            }
            .accessibilityIdentifier("inbox-\(item.id)")
        }
    }
}

private struct FailureCard: View {
    @EnvironmentObject private var model: PhoneModel
    let failure: PartFailure

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.headline(on: model.pairing?.name ?? "the Mac"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("failure-card")
            Spacer(minLength: 0)
            Button("Dismiss") { model.dismiss(failure) }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("failure-dismiss")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// What AgentTerm reports to its developer, and the switches for it.
/// Which agent writes commit messages on the Mac, and how it is asked: the
/// same settings as the Mac's Settings > Git, kept by the Mac.
struct CommitWriterSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var modelName = ""
    @State private var prompt = ""

    private var writerID: String? { CommitWriterSettings(agent: agent.isEmpty ? nil : agent).writer(among: model.agents)?.id }

    private func save() {
        let name = modelName.trimmingCharacters(in: .whitespaces)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCommitWriter(
            CommitWriterSettings(
                agent: agent.isEmpty ? nil : agent, model: name.isEmpty ? nil : name,
                prompt: text.isEmpty || text == CommitWriterSettings.defaultPrompt ? nil : text))
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Agent",
                        selection: Binding(
                            get: { agent },
                            set: {
                                // A model belongs to an agent: another agent starts on its own.
                                if $0 != agent { modelName = "" }
                                agent = $0
                            })
                    ) {
                        Text(model.installedAgents.first.map { "First installed (\($0.name))" } ?? "First installed").tag("")
                        ForEach(model.installedAgents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                        // One that was chosen and is gone since still has to
                        // be among the choices, or the picker shows none.
                        if !agent.isEmpty, !model.installedAgents.contains(where: { $0.id == agent }) {
                            Text("\(model.agents.first { $0.id == agent }?.name ?? agent) (not installed)").tag(agent)
                        }
                    }
                    TextField(writerID.flatMap(CommitWriterSettings.defaultModel) ?? "Agent's default model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("commit-writer-model")
                } footer: {
                    Text("The Write button of a folder's Git tab asks this agent, on the Mac, for the message of what is staged. It never commits by itself.")
                }
                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .font(.callout)
                        .accessibilityIdentifier("commit-writer-prompt")
                    Button("Reset to Default") { prompt = CommitWriterSettings.defaultPrompt }
                        .disabled(prompt == CommitWriterSettings.defaultPrompt)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("What the agent is told, before the staged changes. Say here which style and language you want.")
                }
            }
            .navigationTitle("Commit Messages")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                agent = model.commitWriter.agent ?? ""
                modelName = model.commitWriter.model ?? ""
                prompt = model.commitWriter.effectivePrompt
            }
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack(spacing: 12) {
            if model.status == .connecting {
                ProgressView()
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status == .connecting ? "Connecting to your Mac…" : "Can't reach your Mac")
                    .font(.subheadline.weight(.semibold))
                if model.status != .connecting {
                    Text("Check that Tailscale is connected here and on the Mac, and that AgentTerm is open there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.status != .connecting {
                Button("Retry") { model.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
    }
}

private struct FolderSection: View {
    @EnvironmentObject private var model: PhoneModel
    let group: FolderGroup
    /// The folder a dragged folder is over.
    @State private var folderDropTarget: String?
    /// The session a dragged session is over.
    @State private var dropTarget: String?
    /// Ending a session asks first, as everywhere else.
    @State private var ending: SessionInfo?
    /// A page of the user's, shown live.
    @State private var shownPage: BrowserTabInfo?

    @ViewBuilder
    private func arrangeMenu(_ session: SessionInfo) -> some View {
        let id = session.layoutID
        let layout = model.sessionLayout
        Button {
            withAnimation { model.sessionLayout.setPinned(id, !layout.isPinned(id)) }
        } label: {
            Label(layout.isPinned(id) ? "Unpin" : "Pin", systemImage: layout.isPinned(id) ? "pin.slash" : "pin")
        }
        Button {
            withAnimation { model.move(session, by: -1, in: group) }
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!model.canMove(session, by: -1, in: group))
        Button {
            withAnimation { model.move(session, by: 1, in: group) }
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!model.canMove(session, by: 1, in: group))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.path == nil ? "house.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tint)
                Text(group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("folder-name")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                // Where a dragged folder will land.
                if let path = group.path, folderDropTarget == path { Palette.tint.frame(height: 2.5).offset(y: -6) }
            }
            .modifier(FolderArranging(path: group.path, dropTarget: $folderDropTarget))

            VStack(spacing: 0) {
                if let path = group.path {
                    // One way in to what the Mac's side panel holds for the
                    // folder. Its screen has the tabs: Git, History, Files.
                    NavigationLink(value: Route.folder(path)) {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.tint)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Changes, History and Files")
                                    .font(.body)
                                    .lineLimit(1)
                                Text("Commit and push, past conversations, edit files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Changes, History and Files of \(group.name)")
                    .accessibilityIdentifier("folder-details")
                    Palette.hairline.frame(height: 1)
                }
                ForEach(model.items(for: group)) { item in
                    switch item {
                    case .session(let session):
                        SessionRowLink(session: session)
                            .overlay(alignment: .top) {
                                // Where a dragged session will land.
                                if dropTarget == session.layoutID { Palette.tint.frame(height: 2.5) }
                            }
                            .onDrag {
                                model.draggedFolder = nil
                                model.draggedSession = session.layoutID
                                return NSItemProvider(object: session.layoutID as NSString)
                            }
                            .onDrop(of: [.text], delegate: SessionDropDelegate(before: session.layoutID, model: model, dropTarget: $dropTarget))
                            .contextMenu {
                                arrangeMenu(session)
                                Divider()
                                if model.canHandOff(session) {
                                    Button {
                                        model.requestHandoff(session: session)
                                    } label: {
                                        Label("Hand Off…", systemImage: "arrowshape.turn.up.right")
                                    }
                                }
                                Button(role: .destructive) {
                                    ending = session
                                } label: {
                                    Label("End Session…", systemImage: "xmark.circle")
                                }
                            }
                        Palette.hairline.frame(height: 1).padding(.leading, 38)
                    case .part(_, let title):
                        // The agent's own, under it: its shells, its pages.
                        Text(title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 50)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    case .heading(let kind, _, let count):
                        // The user's own shells or pages, under one heading,
                        // as the Mac's strip holds them in one tab (#127).
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(kind.label(count)).font(.body.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(kind.spoken(count))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("heading-\(kind.title)")
                    case .shell(let shell):
                        NavigationLink(value: Route.companion(agent: shell.openedBy ?? shell.id, item: "s:\(shell.id)")) {
                            SessionRow(session: shell, nested: true)
                        }
                        .buttonStyle(.plain)
                        Palette.hairline.frame(height: 1).padding(.leading, 64)
                    case .userShell(let shell):
                        SessionRowLink(session: shell, nested: true)
                            .contextMenu {
                                Button(role: .destructive) {
                                    ending = shell
                                } label: {
                                    Label("End Session…", systemImage: "xmark.circle")
                                }
                            }
                        Palette.hairline.frame(height: 1).padding(.leading, 64)
                    case .page(let tab):
                        if let agent = tab.openedBy {
                            NavigationLink(value: Route.companion(agent: agent, item: "b:\(tab.id)")) { BrowserTabRow(tab: tab, nested: true) }
                                .buttonStyle(.plain)
                            Palette.hairline.frame(height: 1).padding(.leading, 64)
                        }
                    case .userPage(let tab):
                        Button {
                            shownPage = tab
                        } label: {
                            BrowserTabRow(tab: tab, indented: true)
                        }
                        .buttonStyle(.plain)
                        Palette.hairline.frame(height: 1).padding(.leading, 64)
                    }
                }
                LaunchGrid(folder: group.path)
                    .padding(.horizontal, 6)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .confirmationDialog(
                        CloseWords.endQuestion(ending?.title ?? "this session"), isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                        titleVisibility: .visible, presenting: ending
                    ) { session in
                        Button(CloseWords.endButton, role: .destructive) { model.end(session.id) }
                    } message: { session in
                        // An agent's shells and pages end with it (#145).
                        let own = model.companions(of: session.id)
                        Text(CloseWords.endMessage(shells: own.shells.count, pages: own.pages.count))
                    }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .sheet(item: $shownPage) { tab in
                BrowserTabSheet(tabID: tab.id)
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// What the agent in a session is doing (#3): working, waiting for
/// permission or an answer, done. Nothing when that is not known; when
/// something keeps it from being known, a mark whose label says why.
private struct StateMark: View {
    let session: SessionInfo

    var body: some View {
        if let state = session.state {
            let (symbol, color): (String, Color) = {
                switch state {
                case .working: return ("circle.dotted", .blue)
                case .waitingForPermission: return ("hand.raised.fill", .orange)
                case .waitingForAnswer: return ("questionmark.bubble.fill", .orange)
                case .done: return ("checkmark.circle.fill", .green)
                }
            }()
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityLabel(state.name)
                .accessibilityIdentifier("state-\(session.id)")
        }
        // A note, when the state is not known, is `NoteMark`'s, beside the
        // row's link rather than in it (`SessionRowLink`).
    }
}

/// A session's row: a link to its terminal. When a note says why its
/// agent's state is not known, the note's mark stands between two parts of
/// the link, a button of its own: inside the link's label, or laid over the
/// link, touching the mark opened the session (on the iPhone a button
/// inside it, on the iPad also one laid over it; tried 2026-11-15, #87, #88).
private struct SessionRowLink: View {
    let session: SessionInfo
    /// Set in under a heading: a shell of the user's (#127).
    var nested = false

    var body: some View {
        if let note = session.stateNote, session.state == nil {
            HStack(spacing: 12) {
                NavigationLink(value: Route.session(session.id)) { SessionRow(session: session, part: .main, nested: nested) }
                NoteMark(note: note, session: session.id)
                // The same link again, for the rest of the row; said once
                // to assistive tools.
                NavigationLink(value: Route.session(session.id)) { SessionRow(session: session, part: .end, nested: nested) }
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: Route.session(session.id)) { SessionRow(session: session, part: .whole, nested: nested) }
                .buttonStyle(.plain)
        }
    }
}

/// Why an agent's state is not known, read by touching its mark: what the
/// Mac shows when the pointer rests on it, in the same words (#87).
private struct NoteMark: View {
    let note: String
    let session: SessionID
    @State private var shown = false

    var body: some View {
        Button {
            shown = true
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note)
        .accessibilityIdentifier("state-note-\(session)")
        .popover(isPresented: $shown) {
            Text(note)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .padding()
                .presentationCompactAdaptation(.popover)
                .accessibilityIdentifier("state-note-text")
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionInfo
    /// The whole row, or one of the two parts it has on each side of a
    /// note's mark (`SessionRowLink`).
    var part = Part.whole
    /// Set in under its agent, which it is shown under: it is not named.
    var nested = false

    enum Part { case whole, main, end }

    var body: some View {
        HStack(spacing: 12) {
            if part != .end { main }
            if part != .main { end }
        }
        .padding(.leading, part == .end ? 0 : (nested ? 38 : 12))
        .padding(.trailing, part == .main ? 0 : 12)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// The size and the way in.
    @ViewBuilder private var end: some View {
        Text("\(session.size.cols)×\(session.size.rows)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.tertiary)
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// What the session is, and what its agent is doing.
    @ViewBuilder private var main: some View {
        Image(systemName: AgentStyle.symbol(for: model.agentID(for: session)))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AgentStyle.accent(for: model.agentID(for: session)))
            .frame(width: 18)
        if model.sessionLayout.isPinned(session.layoutID) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pinned")
        }
        // The conversation's title once the agent has saved one, the
        // agent's name until then.
        VStack(alignment: .leading, spacing: 1) {
            Text(session.displayName)
                .font(.body)
                .lineLimit(1)
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !nested, let owner = session.openedByName(among: model.sessions) {
                // A shell an agent opened: whose it is (#61).
                Label(owner, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Opened by \(owner)")
            }
        }
        Spacer(minLength: 8)
        if session.schedule != nil {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 12))
                .foregroundStyle(session.schedulePermissions == .skipAll ? .orange : .secondary)
                .accessibilityLabel(session.schedulePermissions == .skipAll ? "A scheduled run, without asking for permission" : "A scheduled run")
        }
        StateMark(session: session)
    }
}

/// A listed folder's heading can be dragged onto another's, to go before
/// it, and has a menu to move it a place up or down or take it off the list.
private struct FolderArranging: ViewModifier {
    @EnvironmentObject private var model: PhoneModel
    let path: String?
    @Binding var dropTarget: String?

    func body(content: Content) -> some View {
        if let path, model.folders.contains(path) {
            content
                .onDrag {
                    model.draggedSession = nil
                    model.draggedFolder = path
                    return NSItemProvider(object: path as NSString)
                }
                .onDrop(of: [.text], delegate: FolderDropDelegate(before: path, model: model, dropTarget: $dropTarget))
                .contextMenu {
                    Button {
                        model.moveFolder(path, by: -1)
                    } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(!model.canMoveFolder(path, by: -1))
                    Button {
                        model.moveFolder(path, by: 1)
                    } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(!model.canMoveFolder(path, by: 1))
                    Button(role: .destructive) {
                        model.removeFolder(path)
                    } label: {
                        Label("Remove from List", systemImage: "minus.circle")
                    }
                }
        } else {
            content
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let before: String
    let model: PhoneModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedFolder != nil }

    func dropEntered(info: DropInfo) {
        if model.draggedFolder != before { dropTarget = before }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == before { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let path = model.draggedFolder else { return false }
        model.draggedFolder = nil
        model.moveFolder(path, before: before)
        return true
    }
}

/// An agent's session dragged in the list is dropped on another, to go
/// before it and take on its place, pinned or not.
private struct SessionDropDelegate: DropDelegate {
    let before: String
    let model: PhoneModel
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { model.draggedSession != nil }

    func dropEntered(info: DropInfo) {
        if before != model.draggedSession { dropTarget = before }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == before { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let id = model.draggedSession else { return false }
        model.draggedSession = nil
        withAnimation { model.sessionLayout.move(id, before: before) }
        return true
    }
}
