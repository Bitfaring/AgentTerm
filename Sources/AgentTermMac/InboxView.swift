import AgentTermProtocol
import SwiftUI

/// The Inbox's list, at the window's left (#67): the agents that wait for
/// the user, what stopped, and the agents done and not seen, on the Mac on
/// show. The item picked is shown in the middle (`InboxDetail`).
struct InboxList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.inboxItems
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(Inbox.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.inbox.unread > 0 {
                    Text("\(model.inbox.unread)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("inbox-unread")
                }
                Spacer()
                // Deleted here only, kept on the other devices (#66).
                Menu {
                    Button(InboxWords.deleteRead) { model.deleteReadInbox() }
                    Button(InboxWords.deleteAll, role: .destructive) { askingAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(items.isEmpty)
                .accessibilityIdentifier("inbox-menu")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        InboxRow(item: item, selected: model.inboxShown?.id == item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(Theme.panel)
        .confirmationDialog(InboxWords.deleteAllQuestion, isPresented: $askingAll) {
            Button(InboxWords.deleteAll, role: .destructive) { model.deleteAllInbox() }
                .accessibilityIdentifier("inbox-delete-all")
        }
    }

    @State private var askingAll = false
}

/// An item of the Inbox: whose it is, why it is there, and what was said.
private struct InboxRow: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let words = ItemWords(item: item, model: model)
        HStack(alignment: .top, spacing: 8) {
            InboxIcon(item: item)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                // All of what was said, not a few lines (the owner's
                // decision, 2026-11-21).
                Text(words.title)
                    .font(.system(size: 12.5, weight: item.read ? .regular : .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(words.why)
                    .font(.system(size: 11))
                    .foregroundStyle(words.waits ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = words.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if hovering, item.canBeDismissed {
                Button {
                    model.dismiss(item)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(InboxWords.deleteOne)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.pick(item) }
        .contextMenu {
            if case .session = item.kind { Button(Inbox.open) { model.openInSessions(item) } }
            if item.canBeDismissed { Button(InboxWords.deleteOne) { model.dismiss(item) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([words.title, words.why, words.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("inbox-\(item.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.pick(item) }
    }
}

/// The middle of the window in the Inbox: the item picked, all of what its
/// agent said or asks, and what can be done with it. Its session is opened
/// in Sessions.
struct InboxDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let item = model.inboxShown {
            let words = ItemWords(item: item, model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        InboxIcon(item: item)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 22)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(words.title)
                                .font(.system(size: 17, weight: .semibold))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("inbox-detail-title")
                            Text(words.why)
                                .font(.system(size: 13))
                                .foregroundStyle(words.waits ? Color.orange : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    actions(item)
                    content(item)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(item.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(Inbox.empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inbox-empty")
        }
    }

    private func actions(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            if item.notice.map({ notice in model.sessions.contains { $0.id == notice.session } }) == true {
                Button(Inbox.open) { model.openInSessions(item) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("inbox-open")
            }
            if case .session(let info) = item.kind, case .done? = info.state {
                if model.turnResults[info.id]?.changes?.files.isEmpty == false {
                    Button(TurnResult.openDiff) { model.openDiff(of: item) }
                        .accessibilityIdentifier("inbox-open-diff")
                }
                Button(TurnResult.handOff) { model.handOff(item) }
                    .accessibilityIdentifier("inbox-hand-off")
            }
            if item.canBeDismissed {
                Button(InboxWords.deleteOne) { model.dismiss(item) }
                    .accessibilityIdentifier("inbox-dismiss")
            }
        }
    }

    @ViewBuilder
    private func content(_ item: InboxItem) -> some View {
        switch item.kind {
        case .session(let info):
            switch info.state {
            case .done(let said)?:
                let result = model.turnResults[info.id]
                if result?.end == .stopped { note(TurnResult.stopped, warning: true) }
                if let request = result?.request?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty {
                    section(TurnResult.asked, text: request, or: "", id: "inbox-request")
                }
                let text = (result?.reply ?? said)?.trimmingCharacters(in: .whitespacesAndNewlines)
                section(Inbox.said, text: text?.isEmpty == false ? text : nil, or: Inbox.nothingSaid)
                if let result {
                    TurnCommands(result: result)
                    TurnChanges(result: result)
                }
                ContinueField(item: item)
            case .waitingForPermission(let question)?, .waitingForAnswer(let question)?:
                section(Inbox.asks, text: question.text, or: "")
                if !question.choices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        heading(Inbox.choices)
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                            Text("\(index + 1). \(choice)")
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                    }
                }
            default:
                EmptyView()
            }
        case .failure(let failure):
            section(nil, text: failure.details.isEmpty ? nil : failure.details, or: "")
        case .notice(let notice):
            // Over: as it was told, and how it was handled.
            section(notice.state.map { $0.isWaiting ? Inbox.asks : Inbox.said }, text: notice.fullBody.isEmpty ? nil : notice.fullBody, or: "")
            if let handled = notice.handledWords { note(handled) }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(warning ? Color.orange : .secondary)
    }

    private func section(_ title: String?, text: String?, or missing: String, id: String = "inbox-detail-text") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { heading(title) }
            if let text {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(id)
            } else if !missing.isEmpty {
                Text(missing)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("inbox-detail-text")
            }
        }
    }
}

/// The heading of a part of the middle.
private struct InboxHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// The commands a turn ran, each with its exit code as the agent's record
/// has it (#71).
private struct TurnCommands: View {
    let result: TurnResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InboxHeading(text: TurnResult.ran)
            if let commands = result.commands {
                if commands.isEmpty {
                    Text(TurnResult.noCommand).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                    let outcome = TurnResult.outcome(of: command)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(command))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color(command))
                        Text(command.command)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(outcome ?? TurnResult.outcomeNotKnown)
                            .font(.system(size: 11.5))
                            .foregroundStyle(color(command))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("inbox-command")
                }
                if !commands.isEmpty {
                    Text(TurnResult.commandsNote).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else {
                Text(TurnResult.commandsNotKnown).font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
    }

    private func symbol(_ command: TurnResult.Command) -> String {
        if command.exitCode == 0 { return "checkmark.circle.fill" }
        return command.exitCode != nil || command.failed == true ? "xmark.circle.fill" : "questionmark.circle"
    }

    private func color(_ command: TurnResult.Command) -> Color {
        if command.exitCode == 0 { return Theme.added }
        return command.exitCode != nil || command.failed == true ? Theme.removed : .secondary
    }
}

/// What changed in the folder while the agent worked (#71).
private struct TurnChanges: View {
    let result: TurnResult
    /// No more are listed; the diff has them all.
    private let shown = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InboxHeading(text: TurnResult.changed)
            if let changes = result.changes {
                if changes.files.isEmpty {
                    Text(TurnResult.nothingChanged).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                ForEach(Array(changes.files.prefix(shown).enumerated()), id: \.offset) { _, file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(file.status ?? "–")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .leading)
                        Text(file.path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if file.changedBefore == true {
                            Text("(\(TurnResult.changedBefore))").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        if let added = file.added { Text("+\(added)").font(.system(size: 11.5)).foregroundStyle(Theme.added) }
                        if let removed = file.removed { Text("−\(removed)").font(.system(size: 11.5)).foregroundStyle(Theme.removed) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("inbox-file")
                }
                if changes.files.count > shown {
                    Text(TurnResult.andMore(changes.files.count - shown)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if changes.shared {
                    Label(TurnResult.shared, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("inbox-shared")
                } else if changes.ownWorktree {
                    Label(TurnResult.ownWorktree, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(TurnResult.changesNotKnown).font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The next instruction for a done agent, sent from the Inbox (#71).
private struct ContinueField: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InboxHeading(text: TurnResult.continuePrompt)
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text(TurnResult.nextInstruction), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit(send)
                    .accessibilityIdentifier("inbox-continue")
                Button(TurnResult.send, action: send)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("inbox-send")
            }
        }
    }

    private func send() {
        model.continueTurn(of: item, with: text)
        text = ""
    }
}

/// The agent's mark, or a warning for what stopped.
private struct InboxIcon: View {
    let item: InboxItem

    var body: some View {
        switch item.kind {
        case .session(let info):
            let agent = info.agent ?? info.typedAgent ?? "shell"
            Image(systemName: Theme.symbol(for: agent)).foregroundStyle(Theme.accent(for: agent))
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .notice(let notice):
            if case .failure = notice.kind {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

/// What an item says, in the list and in the middle alike.
@MainActor
private struct ItemWords {
    let title: String
    let why: String
    let detail: String?
    let waits: Bool

    init(item: InboxItem, model: AppModel) {
        switch item.kind {
        case .session(let info):
            title = (info.cwd as NSString).lastPathComponent + " · " + info.displayName
            why = model.agentName(info.agent ?? info.typedAgent ?? "shell") + " " + (item.notice?.why ?? "")
            // All of it: `detail`, the end of it, is a notification's (#66).
            detail = item.notice?.full.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            waits = info.state?.isWaiting == true
        case .failure(let failure):
            title = failure.headline()
            why = Inbox.stopped
            detail = failure.details.isEmpty ? nil : failure.details
            waits = false
        case .notice(let notice):
            title = notice.folder.isEmpty ? notice.title() : (notice.folder as NSString).lastPathComponent + " · " + notice.name
            why = [notice.agentNotice?.why, notice.handledWords].compactMap { $0 }.joined(separator: " · ")
            detail = notice.fullBody.isEmpty ? nil : notice.fullBody
            waits = false
        }
    }
}
