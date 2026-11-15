import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// The tabs of the browser in AgentTerm on the Mac (#76): which there are,
/// whose each is and what it shows. The iPhone does not browse: a tab is
/// looked at, and taken from its agent or given back (principle 1).
struct BrowserSection: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var shown: BrowserTabInfo?

    var body: some View {
        if !model.browserTabs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Browser on the Mac")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(model.browserTabs) { tab in
                        Button {
                            shown = tab
                        } label: {
                            BrowserTabRow(tab: tab)
                        }
                        .buttonStyle(.plain)
                        if tab.id != model.browserTabs.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            }
            .sheet(item: $shown) { tab in
                BrowserTabSheet(tabID: tab.id)
            }
            .accessibilityIdentifier("browser-tabs")
        }
    }
}

private struct BrowserTabRow: View {
    @EnvironmentObject private var model: PhoneModel
    let tab: BrowserTabInfo

    private var owner: String {
        guard let agent = tab.openedBy else { return "Yours" }
        let name = model.sessions.first { $0.id == agent }?.displayName ?? "An agent"
        return tab.userHasIt ? "\(name)'s · you have it" : "\(name)'s"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.loading ? "arrow.triangle.2.circlepath" : "globe")
                .foregroundStyle(tab.openedBy != nil ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle).font(.body).lineLimit(1)
                Text(owner + (tab.emulating.map { " · as \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser-tab-\(tab.id)")
    }
}

/// One tab: a picture of what it shows, and its agent's control of it.
struct BrowserTabSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let tabID: String

    private var tab: BrowserTabInfo? { model.browserTabs.first { $0.id == tabID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let tab {
                        Text(tab.url).font(.footnote).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        if let agent = tab.openedBy.flatMap({ id in model.sessions.first { $0.id == id } }) {
                            HStack {
                                Text(tab.userHasIt ? BrowserWords.userHas(agent.displayName) : BrowserWords.agentDrives(agent.displayName))
                                    .font(.subheadline)
                                Spacer()
                                Button(tab.userHasIt ? BrowserWords.giveBack(agent.displayName) : BrowserWords.takeOver) {
                                    model.setUserHas(tab.id, !tab.userHasIt)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("browser-control")
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill((tab.userHasIt ? Color.orange : Color.accentColor).opacity(0.14)))
                        }
                        if let data = model.browserPictures[tab.id], let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
                                .accessibilityLabel("A picture of the page")
                                .accessibilityIdentifier("browser-picture")
                        } else if let problem = model.browserProblems[tab.id] {
                            Text(problem).font(.callout).foregroundStyle(.secondary)
                        } else {
                            LoadingView("Asking the Mac for a picture…").frame(height: 160)
                        }
                        Text("The page is browsed on the Mac. Here you look at it, and take it from its agent or give it back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("This tab was closed on the Mac.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle(tab?.displayTitle ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.refreshPicture(of: tabID)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("New Picture")
                }
            }
        }
        .onAppear { model.refreshPicture(of: tabID) }
    }
}
