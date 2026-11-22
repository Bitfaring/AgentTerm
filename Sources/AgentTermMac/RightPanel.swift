import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// The right side of the window: the folder's git changes, the history of
/// conversations each agent had in it, or its files.
struct RightPanel: View {
    @AppStorage("rightPanelTab") private var tab = "git"

    var body: some View {
        VStack(spacing: 0) {
            // The tabs do not always fit the panel with their names. A
            // name is never broken inside a word (#223): where they do not
            // all fit, only the tab on show keeps its name, and the others
            // are their symbols, named in their tooltips and to VoiceOver.
            ViewThatFits(in: .horizontal) {
                tabs(named: true)
                tabs(named: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Theme.hairline.frame(height: 1)
            WorktreePicker()
            if tab == "history" {
                HistoryView(ofFolder: true)
            } else if tab == "files" {
                FilesView()
            } else {
                DiffView()
            }
        }
        .background(Theme.panel)
    }

    /// The panel's tabs: each with its name, or only the one on show.
    private func tabs(named: Bool) -> some View {
        HStack(spacing: 4) {
            PanelTab(title: "Git", symbol: "arrow.triangle.branch", selected: tab != "history" && tab != "files", named: named) { tab = "git" }
            PanelTab(title: "History", symbol: "clock.arrow.circlepath", selected: tab == "history", named: named) { tab = "history" }
            PanelTab(title: "Files", symbol: "folder", selected: tab == "files", named: named) { tab = "files" }
            Spacer(minLength: 0)
        }
    }
}

private struct PanelTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    /// Whether its name shows when it is not the tab on show.
    var named = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                if named || selected {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("panel-" + title.lowercased())
    }
}
