import AgentTermProtocol
import SwiftUI

/// The mark of an agent's session that says whether its hooks and
/// AgentTerm's MCP server talk to the host (#129): connected, one or both
/// missing, or not known yet. Touched or clicked, it says which, and what
/// to do; the same on the Mac and the iPhone (principle 9).
public struct AgentLinkMark: View {
    let link: AgentLink
    /// The agent typed by hand in a shell, by name, when it is one.
    let typed: String?
    /// Smaller, for a phone.
    let compact: Bool
    @State private var shown = false

    public init(link: AgentLink, typed: String? = nil, compact: Bool = false) {
        self.link = link
        self.typed = typed
        self.compact = compact
    }

    private var symbol: String {
        if link.isWhole { return "link.circle.fill" }
        if link.isMissing { return "exclamationmark.circle.fill" }
        return "circle.dotted"
    }

    private var color: Color {
        if link.isWhole { return .green }
        if link.isMissing { return .orange }
        return .secondary
    }

    private var lines: [String] {
        (typed.map { [AgentLinkWords.typed($0)] } ?? []) + [AgentLinkWords.hooks(link.hooks), AgentLinkWords.mcp(link.mcp)]
            + (link.isMissing ? [AgentLinkWords.fix] : [])
    }

    /// A row's look (#172): a green check when it is so, a red cross when
    /// it is missing, a spinner while it is checked, a neutral mark for
    /// what cannot be told.
    private enum Look { case good, bad, checking, neutral }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let status: String
        let detail: String?
        let look: Look
    }

    private static func look(_ value: Bool?) -> Look {
        switch value {
        case true?: return .good
        case false?: return .bad
        case nil: return .checking
        }
    }

    private var rows: [Row] {
        let prompt: Look
        switch link.prompt {
        case .given?: prompt = .good
        case .missing?: prompt = .bad
        case .disabled?, .unverified?: prompt = .neutral
        case nil: prompt = .checking
        }
        return [
            Row(
                id: "hooks", name: AgentLinkWords.hooksRow, status: AgentLinkWords.hooksStatus(link.hooks),
                detail: link.hooks == false ? AgentLinkWords.hooks(false) : nil, look: Self.look(link.hooks)),
            Row(
                id: "mcp", name: AgentLinkWords.mcpRow, status: AgentLinkWords.mcpStatus(link.mcp),
                detail: link.mcp == false ? AgentLinkWords.mcp(false) : nil, look: Self.look(link.mcp)),
            Row(
                id: "prompt", name: AgentLinkWords.promptRow, status: AgentLinkWords.promptStatus(link.prompt),
                detail: AgentLinkWords.promptDetail(link.prompt), look: prompt),
        ]
    }

    @ViewBuilder
    private func mark(_ look: Look) -> some View {
        switch look {
        case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .checking: ProgressView().controlSize(.small)
        case .neutral: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    public var body: some View {
        Button {
            shown = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 13 : 13.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AgentLinkWords.summary(link)).font(.headline)
                if let typed { Text(AgentLinkWords.typed(typed)).font(.callout).foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mark(row.look).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.name).font(.callout.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(row.status).font(.callout).foregroundStyle(.secondary)
                            }
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent-link-\(row.id)")
                }
                if link.isMissing { Text(AgentLinkWords.fix).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding()
            .frame(width: 320, alignment: .leading)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
        .accessibilityLabel(AgentLinkWords.summary(link))
        .accessibilityValue((lines + rows.map { "\($0.name): \($0.status)" }).joined(separator: " "))
        .accessibilityIdentifier("agent-link")
    }
}
