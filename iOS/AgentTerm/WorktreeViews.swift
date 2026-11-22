import AgentTermProtocol
import SwiftUI

/// The folder's git worktrees (#34, #43), picked from a list like the
/// branches' (#217), as on the Mac. Outside it there is only the control
/// that opens it, which says the worktree on show and how many files are
/// changed in it. A touch on a row makes the folder's Git, History and
/// Files about that one.
struct WorktreePicker: View {
    @EnvironmentObject private var model: PhoneModel
    /// The folder the worktrees are of: the repository's own.
    let project: String
    let list: [WorktreeInfo]
    /// The worktree on show; nil for the folder itself.
    @Binding var picked: String?
    /// The folder whose changes are on show.
    let shownPath: String

    /// What is over the screen: the list, or the sheet of a new worktree,
    /// which takes the list's place.
    private enum Showing: String, Identifiable {
        case list, new
        var id: String { rawValue }
    }
    @State private var showing: Showing?

    private var shown: WorktreeInfo? { list.first { $0.path == shownPath } ?? list.first }

    var body: some View {
        if let shown {
            HStack(spacing: 8) {
                Button {
                    showing = .list
                } label: {
                    HStack(spacing: 5) {
                        // A folder, whichever it is, named by its folder, as on the Mac (#246).
                        Image(systemName: "folder")
                        Text(shown.chipTitle).lineLimit(1).truncationMode(.middle)
                        if !shown.pickerCounts.isEmpty {
                            Text(shown.pickerCounts).font(.caption.monospaced()).foregroundStyle(shown.missing ? Color.red : Color.orange)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown.pickerLabel)
                .accessibilityIdentifier("worktree-picker")
                .accessibilityAddTraits(.isButton)
                Spacer(minLength: 0)
            }
            .disabled(model.status != .connected)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
            .sheet(item: $showing) { which in
                switch which {
                case .list:
                    WorktreesSheet(project: project, list: list, shown: shown, picked: $picked) {
                        showing = nil
                    } add: {
                        showing = .new
                    }
                case .new:
                    NewWorktreeSheet(project: project, main: list.first, start: nil)
                }
            }
        }
    }
}

/// The worktrees of a folder on the Mac: a field that narrows them down,
/// New Worktree, and a row for each, the folder's own first, with what is
/// changed in it and, for one that is not the folder's own, "⋯": what to do
/// with it once its work is done.
private struct WorktreesSheet: View {
    @EnvironmentObject private var model: PhoneModel
    let project: String
    let list: [WorktreeInfo]
    let shown: WorktreeInfo
    @Binding var picked: String?
    let close: () -> Void
    let add: () -> Void

    @State private var search = ""
    @State private var discarding: WorktreeInfo?

    private var found: [WorktreeInfo] { list.matching(search: search) }

    /// What "⋯" does to its row's worktree. The screen goes back to the
    /// folder when the one on show is the one that goes away.
    private func finish(_ worktree: WorktreeInfo, _ how: WorktreeFinish, deleteBranch: Bool) {
        model.finishWorktree(worktree, of: project, how, deleteBranch: deleteBranch)
        if how != .pullRequest, worktree.path == shown.path { picked = project }
        close()
    }

    /// Whether a pull request can be opened for a worktree: the one on show
    /// only, whose changes are read and say whether its branch has
    /// somewhere to be pushed to. The rule is the Mac's too.
    private func canOpenPullRequest(_ worktree: WorktreeInfo) -> Bool {
        let diff = model.diffs[worktree.path]
        return worktree.canOpenPullRequest(onShow: worktree.path == shown.path, hasRemote: diff?.pushRemote != nil || diff?.upstream != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(found) { worktree in row(worktree, selected: worktree.path == shown.path) }
                if found.isEmpty { Text(WorktreeWords.noMatch(search)).foregroundStyle(.secondary) }
            }
            .searchable(text: $search, prompt: WorktreeWords.searchPrompt)
            .navigationTitle(WorktreeWords.listTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Asked first: what is thrown away does not come back.
            .confirmationDialog(
                discarding.map(WorktreeWords.discardTitle) ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                titleVisibility: .visible
            ) {
                Button(WorktreeWords.discardWithBranch, role: .destructive) { if let discarding { finish(discarding, .discard, deleteBranch: true) } }
                Button(WorktreeWords.discardKeepingBranch, role: .destructive) { if let discarding { finish(discarding, .discard, deleteBranch: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(discarding.map(WorktreeWords.discardMessage) ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: add) {
                        Label(WorktreeWords.newTitle, systemImage: "plus")
                    }
                    .accessibilityLabel(WorktreeWords.newTitle)
                    .accessibilityIdentifier("worktree-add")
                }
            }
        }
    }

    private func row(_ worktree: WorktreeInfo, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                picked = worktree.path
                close()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).opacity(selected ? 1 : 0)
                    Image(systemName: "folder").font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(worktree.chipTitle).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                        // The branch checked out in it, under its name.
                        Label(worktree.branchWords, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if !worktree.chipCounts.isEmpty {
                        Text(worktree.chipCounts).font(.caption.monospaced()).foregroundStyle(worktree.missing ? Color.red : Color.orange)
                    }
                    if worktree.inUse { Circle().fill(Color.green).frame(width: 6, height: 6) }
                }
                .foregroundStyle(worktree.missing ? Color.secondary : Color.primary)
                .contentShape(Rectangle())
            }
            // Its own touch, beside the menu's: a row's default takes the whole row.
            .buttonStyle(.plain)
            .disabled(worktree.missing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(worktree.chipTitle), \(worktree.chipHelp)")
            .accessibilityIdentifier("worktree-chip-" + worktree.identifierName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            // None for the folder's own; Throw Away… alone for one whose folder is missing.
            if !worktree.rowActions.isEmpty {
                Menu {
                    ForEach(worktree.rowActions, id: \.self) { action in
                        switch action {
                        case .merge:
                            Button(WorktreeWords.merge(into: list.first)) { finish(worktree, .merge, deleteBranch: worktree.isAgentTerm) }
                                .disabled(!worktree.canMerge)
                        case .pullRequest:
                            Button(WorktreeWords.pullRequest) { finish(worktree, .pullRequest, deleteBranch: false) }
                                .disabled(!canOpenPullRequest(worktree))
                        case .throwAway:
                            Button(WorktreeWords.throwAway, role: .destructive) { discarding = worktree }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(WorktreeWords.actions)
                .accessibilityIdentifier("worktree-more-" + worktree.identifierName)
            }
        }
    }
}

/// A new branch in a new worktree: its name, suggested and editable, the
/// branch it starts from, and what is started there.
struct NewWorktreeSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let project: String
    /// The folder's own worktree, when its worktrees are known.
    let main: WorktreeInfo?
    /// What is started there, when the sheet was opened for one: an agent,
    /// or a shell.
    let start: AgentInfo?
    var shell = false

    @State private var name = ""
    /// The name is the user's own once typed in, and no longer follows what is started.
    @State private var named = false
    @State private var from = ""
    /// The agent's id, or empty for a shell.
    @State private var starting = ""
    /// Carrying on a conversation of the folder's, handed off (#150), by its id.
    @State private var continuing = false
    @State private var conversationID = ""

    private var agent: AgentInfo? { model.installedAgents.first { $0.id == starting } }

    /// The conversations it can carry on: the folder's and its worktrees' (#165).
    private var conversations: [Conversation] {
        WorktreePath.conversations(of: project, own: model.histories[project] ?? [], all: model.histories[""] ?? [])
    }
    private var conversation: Conversation? { conversations.first { $0.id == conversationID } }
    private var branches: [BranchInfo] { model.branches[project] ?? [] }
    private var current: String? { main?.branch ?? branches.first { $0.isCurrent }?.name }
    private var suggested: String { WorktreePath.branchName(agent: agent?.id ?? "shell", taken: Set(branches.filter { !$0.isRemote }.map(\.name))) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Branch",
                        text: Binding(
                            get: { named ? name : suggested },
                            set: {
                                name = $0; named = true
                            })
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("worktree-branch")
                    Picker("From", selection: $from) {
                        Text(current.map { "\($0) (this folder)" } ?? "This folder's commit").tag("")
                        ForEach(branches.filter { $0.name != current || $0.isRemote }) { branch in Text(branch.name).tag(branch.name) }
                    }
                    .accessibilityIdentifier("worktree-from")
                    Picker("Start", selection: $starting) {
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
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if continuing, agent != nil { Text(WorktreeWords.continueAdvice) }
                        Text(WorktreeWords.newAdvice)
                        if model.diffs[project]?.files.isEmpty == false {
                            Label(WorktreeWords.uncommitted, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(WorktreeWords.newTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let branch = (named ? name : suggested).trimmingCharacters(in: .whitespaces)
                        if continuing, let agent, let conversation {
                            model.handoffInNewWorktree(conversation, to: agent, in: project, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from)
                        } else {
                            model.launchInWorktree(agent, in: project, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from)
                        }
                        dismiss()
                    }
                    .disabled(model.status != .connected || (continuing && agent != nil && conversation == nil))
                    .accessibilityIdentifier("worktree-create")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            starting = shell ? "" : start?.id ?? model.installedAgents.first?.id ?? ""
            model.loadBranches(project)
            model.loadHistory(project)
            model.loadHistory(nil)
        }
        // The newest of the folder's picked already, once they are read.
        .onChange(of: conversations.first?.id) { _, first in
            if conversation == nil { conversationID = first ?? "" }
        }
    }
}
