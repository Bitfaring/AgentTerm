import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// What an agent's last turn came to (#71), opened from the Inbox: what it
/// was asked, what it answered, the commands it ran, what changed in its
/// folder; its terminal, the diff, a handoff and the next instruction a
/// touch away. The terminal is where the session is seen.
struct TurnResultScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionID
    @State private var next = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let info = model.sessions.first(where: { $0.id == session }) {
                    content(info)
                } else {
                    Text(TurnResult.sessionEnded)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(TurnResult.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ info: SessionInfo) -> some View {
        let item = InboxItem(.session(info))
        let agent = info.agent ?? "shell"
        let result = model.turnResults[session]
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AgentStyle.symbol(for: agent))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AgentStyle.accent(for: agent))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text((info.cwd as NSString).lastPathComponent + " · " + info.displayName)
                    .font(.headline)
                    .accessibilityIdentifier("result-title")
                Text(model.agentName(agent) + " " + (item.notice?.why ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 10) {
            Button {
                model.path.append(.session(session))
            } label: {
                Label(Inbox.open, systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("result-open")
            if result?.changes?.files.isEmpty == false {
                Button {
                    model.path.append(.folder(info.cwd))
                } label: {
                    Label(TurnResult.openDiff, systemImage: "plus.forwardslash.minus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("result-diff")
            }
            Menu {
                Button(TurnResult.handOff) { model.requestHandoff(session: info) }
                if item.canBeDismissed {
                    Button(Inbox.dismiss) {
                        model.dismiss(item)
                        if model.path.last == .result(session) { model.path.removeLast() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("result-more")
        }
        if result?.end == .stopped {
            Label(TurnResult.stopped, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if let request = result?.request?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty {
            part(TurnResult.asked) {
                Text(request).textSelection(.enabled).accessibilityIdentifier("result-request")
            }
        }
        let said: String? = {
            if case .done(let said)? = info.state { return said }
            return nil
        }()
        let reply = (result?.reply ?? said)?.trimmingCharacters(in: .whitespacesAndNewlines)
        part(Inbox.said) {
            if let reply, !reply.isEmpty {
                Text(reply).textSelection(.enabled).accessibilityIdentifier("result-said")
            } else {
                Text(Inbox.nothingSaid).foregroundStyle(.tertiary).accessibilityIdentifier("result-said")
            }
        }
        if let result {
            commands(result)
            changes(result)
        }
        if case .done? = info.state {
            part(TurnResult.continuePrompt) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(TurnResult.nextInstruction, text: $next, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel))
                        .accessibilityIdentifier("result-continue")
                    Button(TurnResult.send) {
                        guard let state = info.state else { return }
                        model.answer(session: session, to: state, text: next)
                        next = ""
                        if model.path.last == .result(session) { model.path.removeLast() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("result-send")
                }
            }
        }
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commands(_ result: TurnResult) -> some View {
        part(TurnResult.ran) {
            VStack(alignment: .leading, spacing: 8) {
                if let commands = result.commands {
                    if commands.isEmpty { Text(TurnResult.noCommand).foregroundStyle(.tertiary) }
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                        let failed = command.exitCode.map { $0 != 0 } ?? (command.failed == true)
                        let known = command.exitCode != nil || command.failed == true
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: !known ? "questionmark.circle" : failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(!known ? Color.secondary : failed ? Color.red : Color.green)
                            Text(command.command)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(3)
                            Spacer(minLength: 6)
                            Text(TurnResult.outcome(of: command) ?? TurnResult.outcomeNotKnown)
                                .font(.footnote)
                                .foregroundStyle(!known ? Color.secondary : failed ? Color.red : Color.green)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("result-command")
                    }
                    if !commands.isEmpty {
                        Text(TurnResult.commandsNote).font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(TurnResult.commandsNotKnown).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func changes(_ result: TurnResult) -> some View {
        part(TurnResult.changed) {
            VStack(alignment: .leading, spacing: 8) {
                if let changes = result.changes {
                    if changes.files.isEmpty { Text(TurnResult.nothingChanged).foregroundStyle(.tertiary) }
                    ForEach(Array(changes.files.prefix(40).enumerated()), id: \.offset) { _, file in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(file.status ?? "–")
                                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.path)
                                    .font(.system(.footnote, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if file.changedBefore == true {
                                    Text(TurnResult.changedBefore).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 6)
                            if let added = file.added { Text("+\(added)").font(.footnote).foregroundStyle(.green) }
                            if let removed = file.removed { Text("−\(removed)").font(.footnote).foregroundStyle(.red) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("result-file")
                    }
                    if changes.files.count > 40 {
                        Text(TurnResult.andMore(changes.files.count - 40)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if changes.shared {
                        Label(TurnResult.shared, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if changes.ownWorktree {
                        Label(TurnResult.ownWorktree, systemImage: "arrow.triangle.branch")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(TurnResult.changesNotKnown).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
