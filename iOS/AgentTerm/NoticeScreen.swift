import AgentTermEditor
import AgentTermProtocol
import SwiftUI

/// The button that shows what an agent said with its Markdown rendered, or
/// as it was written (#218): the same in a notice's screen and in what a
/// turn came to, in History's words (#50), kept for the next item on this
/// iPhone apart from History's own.
struct InboxMarkdownButton: View {
    static let key = "inboxMarkdown"
    @Binding var markdown: Bool

    var body: some View {
        Button {
            markdown.toggle()
        } label: {
            Label(markdown ? ConversationDetails.showAsText : ConversationDetails.previewMarkdown, systemImage: markdown ? "text.alignleft" : "doc.richtext")
                .font(.footnote)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("inbox-markdown")
    }
}

/// One item of the Inbox, all of it, as the Mac shows the item picked
/// (`InboxDetail`; the owner's decision, 2026-11-21): touching an item
/// opens this, whatever it is, and its session is opened from here. An
/// agent done whose session runs still shows what its turn came to
/// (`TurnResultScreen`), as on the Mac.
struct NoticeScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let id: UInt64
    @AppStorage(InboxMarkdownButton.key) private var markdown = false

    private var entry: InboxBook.Entry? { model.inbox.entries.first { $0.id == id } }

    var body: some View {
        if let entry, let agent = entry.notice.agentNotice, case .done = agent.state, entry.notice.handled == nil,
            model.sessions.contains(where: { $0.id == agent.session })
        {
            TurnResultScreen(session: agent.session)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let entry {
                        content(entry.notice)
                    } else {
                        Text(InboxWords.empty).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(Inbox.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("notice-screen")
        }
    }

    @ViewBuilder
    private func content(_ notice: Notice) -> some View {
        let waiting = notice.state?.isWaiting == true && notice.handled == nil
        VStack(alignment: .leading, spacing: 4) {
            Text(notice.title(on: model.pairing?.name))
                .font(.headline)
                .foregroundStyle(waiting ? Color.orange : .primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("notice-title")
            Text(
                [notice.place(macName: model.pairing?.name ?? "the Mac"), notice.at.formatted(date: .abbreviated, time: .shortened)]
                    .joined(separator: " · ")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let session = notice.session, model.sessions.contains(where: { $0.id == session }) {
            Button {
                model.path.append(.session(session))
            } label: {
                Label(Inbox.open, systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notice-open")
        } else if notice.session != nil {
            Text(TurnResult.sessionEnded).font(.footnote).foregroundStyle(.secondary)
        }
        // What an agent said is Markdown, and can be shown rendered (#218);
        // what it asks, and what a failure says, stay as written.
        let previews = notice.state.map { !$0.isWaiting } == true && !notice.fullBody.isEmpty
        part(notice.state.map { $0.isWaiting ? Inbox.asks : Inbox.said } ?? Inbox.said) {
            if notice.fullBody.isEmpty {
                Text(Inbox.nothingSaid).foregroundStyle(.tertiary)
            } else {
                if previews { InboxMarkdownButton(markdown: $markdown) }
                if previews, markdown {
                    MarkdownText(notice.fullBody, size: 15).accessibilityIdentifier("notice-body-markdown")
                } else {
                    Text(notice.fullBody).textSelection(.enabled).accessibilityIdentifier("notice-body")
                }
            }
        }
        if let question = Self.question(of: notice.state), !question.choices.isEmpty {
            part(Inbox.choices) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                        Text("\(index + 1). \(choice)").textSelection(.enabled)
                    }
                }
            }
        }
        if let handled = notice.handledWords {
            Label(handled, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What an agent that waits asks.
    private static func question(of state: AgentState?) -> AgentQuestion? {
        switch state {
        case .waitingForPermission(let question)?, .waitingForAnswer(let question)?: return question
        default: return nil
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
}
