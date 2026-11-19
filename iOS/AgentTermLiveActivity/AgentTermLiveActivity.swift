import ActivityKit
import AgentTermProtocol
import SwiftUI
import WidgetKit

/// The Live Activity of the agents on a Mac (#24), on the lock screen and in
/// the Dynamic Island. Touching it opens the app on the session that waits.
@main
struct AgentTermLiveActivities: WidgetBundle {
    var body: some Widget {
        AgentsLiveActivity()
    }
}

struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: mark(state)).foregroundStyle(tint(state))
                    Text("\(AgentsStatus.title) \(context.attributes.mac)").font(.headline)
                    Spacer(minLength: 0)
                    if context.isStale { Text("Not up to date").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 14) {
                    Count(value: state.working, label: "working", symbol: "circle.dotted", tint: .blue)
                    Count(value: state.permission, label: "permission", symbol: "lock.fill", tint: .orange)
                    Count(value: state.asking, label: "asking", symbol: "questionmark.bubble.fill", tint: .orange)
                    Count(value: state.done, label: "done", symbol: "checkmark.circle.fill", tint: .green)
                    if state.failed > 0 { Count(value: state.failed, label: "stopped", symbol: "exclamationmark.octagon.fill", tint: .red) }
                }
                if let first = state.waiting.first {
                    Text(state.waiting.count == 1 ? "\(first) waits" : "\(first) and \(state.waiting.count - 1) more wait")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding()
            .widgetURL(link(state))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: mark(state)).foregroundStyle(tint(state))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.summary).font(.subheadline).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.mac).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !state.waiting.isEmpty {
                        Text(state.waiting.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: mark(state)).foregroundStyle(tint(state))
            } compactTrailing: {
                Text("\(state.working + state.permission + state.asking)")
            } minimal: {
                Image(systemName: mark(state)).foregroundStyle(tint(state))
            }
            .widgetURL(link(state))
        }
    }

    private func waits(_ state: AgentsStatus) -> Bool { state.permission + state.asking > 0 }
    private func mark(_ state: AgentsStatus) -> String { waits(state) ? "hand.raised.fill" : state.failed > 0 ? "exclamationmark.octagon.fill" : "circle.dotted" }
    private func tint(_ state: AgentsStatus) -> Color { waits(state) ? .orange : state.failed > 0 ? .red : .blue }

    /// Opens the app, on the session that waits when one does.
    private func link(_ state: AgentsStatus) -> URL? {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "AppLinkScheme") as? String ?? "agentterm"
        return URL(string: "\(scheme)://session" + (state.firstWaiting.map { "?id=\($0)" } ?? ""))
    }
}

/// One kind's count, with its mark; nothing for none.
private struct Count: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        if value > 0 {
            Label("\(value) \(label)", systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}
