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
            VStack(alignment: .leading, spacing: 8) {
                Text(AgentLinkWords.summary(link)).font(.headline)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .frame(width: 320, alignment: .leading)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
        .accessibilityLabel(AgentLinkWords.summary(link))
        .accessibilityValue(lines.joined(separator: " "))
        .accessibilityIdentifier("agent-link")
    }
}
