import AgentTermProtocol
import SwiftUI

/// The folder's git worktrees (#43), picked from a popup like the branch's
/// (#217). Outside it there is only the button that opens it, which says
/// the worktree on show and how many files are changed in it. Inside: a
/// field that narrows the worktrees down, New Worktree, and a row for each,
/// the folder's own first, with what is changed in it and, for one that is
/// not the folder's own, "⋯": what to do with it once its work is done (#23).
struct WorktreePicker: View {
    @EnvironmentObject private var model: AppModel
    @State private var showing = false
    @State private var adding = false

    private var folder: String? { model.selectedFolder }
    private var list: [WorktreeInfo] { folder.flatMap { model.worktrees[$0] } ?? [] }
    private var shown: WorktreeInfo? { list.first { $0.path == (model.shownWorktree ?? folder) } ?? list.first }

    var body: some View {
        // A folder that is no repository has no worktrees, its own included.
        if let folder, let shown, !list.isEmpty {
            HStack(spacing: 6) {
                Button {
                    showing = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown.isMain ? "folder" : "arrow.triangle.branch")
                        Text(shown.chipTitle).lineLimit(1).truncationMode(.middle)
                        if !shown.pickerCounts.isEmpty {
                            Text(shown.pickerCounts).font(.system(size: 10, design: .monospaced)).foregroundStyle(shown.missing ? Color.red : Color.orange)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shown.chipHelp + "\n" + (shown.path as NSString).abbreviatingWithTildeInPath)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown.pickerLabel)
                .accessibilityIdentifier("worktree-picker")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showing = true }
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    WorktreeList(folder: folder, list: list, shown: shown) {
                        showing = false
                    } add: {
                        showing = false
                        // Once the popup is on its way out: the sheet is the window's.
                        DispatchQueue.main.async { adding = true }
                    }
                    .environmentObject(model)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
            .sheet(isPresented: $adding) {
                NewWorktreeSheet(folder: folder, main: list.first) { adding = false }
            }
        }
    }
}

/// The popup: the field that narrows the worktrees down, New Worktree, and
/// the worktrees. Return picks the one the arrows are on, Escape closes it.
private struct WorktreeList: View {
    @EnvironmentObject private var model: AppModel
    let folder: String
    let list: [WorktreeInfo]
    let shown: WorktreeInfo
    let close: () -> Void
    let add: () -> Void

    @State private var search = ""
    /// The row the arrows are on, among those the search leaves.
    @State private var highlighted = 0
    @State private var discarding: WorktreeInfo?
    @FocusState private var searching: Bool

    private var found: [WorktreeInfo] { list.matching(search: search) }

    private func pick(_ worktree: WorktreeInfo) {
        guard !worktree.missing else { return }
        model.shownWorktree = worktree.isMain ? nil : worktree.path
        close()
    }

    /// What "⋯" does to its row's worktree. The panel goes back to the
    /// folder when the one on show is the one that goes away.
    private func finish(_ worktree: WorktreeInfo, _ how: WorktreeFinish, deleteBranch: Bool) {
        model.finishWorktree(worktree, of: folder, how, deleteBranch: deleteBranch)
        if how != .pullRequest, worktree.path == shown.path { model.shownWorktree = nil }
        close()
    }

    /// Whether a pull request can be opened for a worktree: its branch has
    /// somewhere to be pushed to. That is known of the worktree on show
    /// only, whose changes are read; of another it is not known, and the
    /// entry is off rather than guessed.
    private func canOpenPullRequest(_ worktree: WorktreeInfo) -> Bool {
        worktree.path == shown.path && (model.diff?.pushRemote != nil || model.diff?.upstream != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(WorktreeWords.searchPrompt, text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .onSubmit { if found.indices.contains(highlighted) { pick(found[highlighted]) } }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(found.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .accessibilityIdentifier("worktree-search")
                Button(action: add) {
                    Label(WorktreeWords.newTitle, systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .help(WorktreeWords.newHelp)
                .accessibilityLabel(WorktreeWords.newTitle)
                .accessibilityIdentifier("worktree-add")
                .disabled(model.status != .connected)
            }
            .padding(10)
            Theme.hairline.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, worktree in
                        WorktreeRow(
                            worktree: worktree, selected: worktree.path == shown.path, highlighted: index == highlighted, main: list.first,
                            canOpenPullRequest: canOpenPullRequest(worktree)
                        ) {
                            pick(worktree)
                        } finish: { how in
                            finish(worktree, how, deleteBranch: how == .merge && worktree.isAgentTerm)
                        } discard: {
                            discarding = worktree
                        }
                    }
                    if found.isEmpty {
                        Text(WorktreeWords.noMatch(search)).font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(6)
            }
            // As tall as its rows, up to where it scrolls.
            .frame(height: min(CGFloat(max(found.count, 1)) * 28 + 12, 300))
        }
        .frame(width: 340)
        .onAppear {
            highlighted = found.firstIndex { $0.path == shown.path } ?? 0
            searching = true
        }
        // What is typed is searched from the first it leaves.
        .onChange(of: search) { _, _ in highlighted = 0 }
        // Asked first: what is thrown away does not come back.
        .confirmationDialog(
            discarding.map(WorktreeWords.discardTitle) ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            titleVisibility: .visible
        ) {
            Button(WorktreeWords.discardWithBranch, role: .destructive) {
                if let discarding { finish(discarding, .discard, deleteBranch: true) }
            }
            Button(WorktreeWords.discardKeepingBranch, role: .destructive) {
                if let discarding { finish(discarding, .discard, deleteBranch: false) }
            }
        } message: {
            Text(discarding.map(WorktreeWords.discardMessage) ?? "")
        }
    }
}

/// One worktree of the popup: a mark when it is the one on show, its
/// branch, what is changed in it, and "⋯" when it is not the folder's own.
private struct WorktreeRow: View {
    let worktree: WorktreeInfo
    let selected: Bool
    /// The arrows of the search field are on it.
    let highlighted: Bool
    /// The folder's own, which a merge goes into.
    let main: WorktreeInfo?
    let canOpenPullRequest: Bool
    let pick: () -> Void
    let finish: (WorktreeFinish) -> Void
    let discard: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: pick) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(selected ? 1 : 0)
                        .frame(width: 12)
                    Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch").font(.system(size: 9.5))
                    Text(worktree.chipTitle)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !worktree.chipCounts.isEmpty {
                        Text(worktree.chipCounts).font(.system(size: 10, design: .monospaced)).foregroundStyle(worktree.missing ? Color.red : Color.orange)
                    }
                    if worktree.inUse { Circle().fill(Color.green).frame(width: 5, height: 5) }
                }
                .foregroundStyle(worktree.missing ? .secondary : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(worktree.missing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(worktree.chipTitle), \(worktree.chipHelp)")
            .accessibilityIdentifier("worktree-chip-" + worktree.chipTitle)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick() }
            if !worktree.isMain {
                Menu {
                    Button(WorktreeWords.merge(into: main)) { finish(.merge) }
                        .disabled(worktree.changed > 0 || worktree.ahead == 0)
                    Button(WorktreeWords.pullRequest) { finish(.pullRequest) }
                        .disabled(!canOpenPullRequest)
                    Button(WorktreeWords.throwAway, role: .destructive, action: discard)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(WorktreeWords.actionsHelp(worktree))
                .accessibilityLabel(WorktreeWords.actions)
                .accessibilityIdentifier("worktree-more-" + worktree.chipTitle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted || (hovering && !worktree.missing) ? Color.white.opacity(0.07) : .clear)
        )
        .onHover { hovering = $0 }
        .help(worktree.chipHelp + "\n" + (worktree.path as NSString).abbreviatingWithTildeInPath)
    }
}

/// A new branch in a new worktree: its name, suggested and editable, the
/// branch it starts from, and what is started there.
private struct NewWorktreeSheet: View {
    @EnvironmentObject private var model: AppModel
    let folder: String
    let main: WorktreeInfo?
    let close: () -> Void

    @State private var name = ""
    /// The name is the user's own once typed in, and no longer follows what is started.
    @State private var named = false
    @State private var from = ""
    /// The agent's id, or empty for a shell.
    @State private var start = ""
    /// Carrying on a conversation of the folder's, handed off (#150), by its id.
    @State private var continuing = false
    @State private var conversationID = ""

    private var agent: AgentInfo? { model.installedAgents.first { $0.id == start } }

    /// The conversations it can carry on: the folder's and its worktrees' (#165).
    private var conversations: [Conversation] {
        WorktreePath.conversations(of: model.selectedFolder ?? "", own: model.folderHistory ?? [], all: model.history ?? [])
    }
    private var conversation: Conversation? { conversations.first { $0.id == conversationID } }
    private var locals: [BranchInfo] { model.branches.filter { !$0.isRemote } }
    private var suggested: String { WorktreePath.branchName(agent: agent?.id ?? "shell", taken: Set(locals.map(\.name))) }
    private var uncommitted: Bool { model.shownWorktree == nil && model.diff?.files.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorktreeWords.newTitle).font(.headline)
            Text(WorktreeWords.newAdvice).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(
                    "Branch",
                    text: Binding(
                        get: { named ? name : suggested },
                        set: {
                            name = $0; named = true
                        })
                )
                .accessibilityIdentifier("worktree-branch")
                Picker("From", selection: $from) {
                    Text(main?.branch.map { "\($0) (this folder)" } ?? "This folder's commit").tag("")
                    ForEach(model.branches.filter { $0.name != main?.branch || $0.isRemote }) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .accessibilityIdentifier("worktree-from")
                Picker("Start", selection: $start) {
                    ForEach(model.installedAgents) { agent in Text(agent.name).tag(agent.id) }
                    Text("Shell").tag("")
                }
                .accessibilityIdentifier("worktree-start")
                // An agent only: a shell carries on no conversation.
                if agent != nil {
                    Picker(WorktreeWords.begin, selection: $continuing) {
                        Text(WorktreeWords.fresh).tag(false)
                        Text(WorktreeWords.continueConversation).tag(true)
                    }
                    .accessibilityIdentifier("worktree-begin")
                    if continuing {
                        Picker(WorktreeWords.conversation, selection: $conversationID) {
                            if conversations.isEmpty { Text(WorktreeWords.noConversation).tag("") }
                            ForEach(conversations, id: \.id) { conversation in
                                Text("\(conversation.title) · \(model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent)")
                                    .tag(conversation.id)
                            }
                        }
                        .accessibilityIdentifier("worktree-conversation")
                    }
                }
            }
            if continuing, agent != nil {
                Text(WorktreeWords.continueAdvice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if uncommitted {
                Label(WorktreeWords.uncommitted, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let branch = (named ? name : suggested).trimmingCharacters(in: .whitespaces)
                    if continuing, let agent, let conversation {
                        model.handoffInNewWorktree(conversation, to: agent, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from)
                    } else {
                        model.launchInWorktree(agent, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from, confirmed: true)
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(continuing && agent != nil && conversation == nil)
                .accessibilityIdentifier("worktree-create")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            start = model.installedAgents.first?.id ?? ""
            model.loadBranches()
            model.refreshHistory(ofFolder: true)
            model.refreshHistory()
        }
        // The newest of the folder's picked already, once they are read.
        .onChange(of: conversations.first?.id) { _, first in
            if conversation == nil { conversationID = first ?? "" }
        }
    }
}
