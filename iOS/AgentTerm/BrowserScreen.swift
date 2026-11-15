import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// The pages of the browser in AgentTerm on the Mac (#76) that no folder
/// shows: an agent's are under it, the user's in their project's folder.
struct BrowserSection: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var shown: BrowserTabInfo?

    var body: some View {
        let pages = model.loosePages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Browser on the Mac")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(pages) { tab in
                        Button {
                            shown = tab
                        } label: {
                            BrowserTabRow(tab: tab)
                        }
                        .buttonStyle(.plain)
                        if tab.id != pages.last?.id { Divider().padding(.leading, 44) }
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

/// A page's row in a list: its title, and whose it is unless it is shown
/// under its agent.
struct BrowserTabRow: View {
    @EnvironmentObject private var model: PhoneModel
    let tab: BrowserTabInfo
    /// Set in under its agent, which it is shown under: it is not named.
    var nested = false

    private var owner: String {
        guard let agent = tab.openedBy else { return "Yours" }
        let name = model.sessions.first { $0.id == agent }?.displayName ?? "An agent"
        if nested { return tab.userHasIt ? "You have it" : "Its agent's" }
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
        .padding(.leading, nested ? 38 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser-tab-\(tab.id)")
    }
}

/// One page of the user's, in a sheet: live, and used by touch.
struct BrowserTabSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let tabID: String

    private var tab: BrowserTabInfo? { model.browserTabs.first { $0.id == tabID } }

    var body: some View {
        NavigationStack {
            Group {
                if tab != nil {
                    LivePageView(tabID: tabID)
                } else {
                    Text("This tab was closed on the Mac.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(tab?.displayTitle ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A page of the Mac's browser as it is now, sent a few times a second
/// while it is on screen, and used by touch: a touch is a click where it
/// lands, a drag scrolls, and text is typed into what has the keyboard. An
/// agent's tab becomes the user's at the first touch, as a click on the Mac
/// makes it; its agent waits until it is given back (#76).
struct LivePageView: View {
    @EnvironmentObject private var model: PhoneModel
    let tabID: String
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var tab: BrowserTabInfo? { model.browserTabs.first { $0.id == tabID } }

    var body: some View {
        VStack(spacing: 0) {
            if let tab, let agent = tab.openedBy.flatMap({ id in model.sessions.first { $0.id == id } }) {
                HStack {
                    Text(tab.userHasIt ? BrowserWords.userHas(agent.displayName) : BrowserWords.agentDrives(agent.displayName))
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer()
                    Button(tab.userHasIt ? BrowserWords.giveBack(agent.displayName) : BrowserWords.takeOver) {
                        model.setUserHas(tab.id, !tab.userHasIt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser-control")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((tab.userHasIt ? Color.orange : Color.accentColor).opacity(0.14))
            }
            page
            if let problem = model.browserProblems[tabID] {
                Text(problem).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
            }
            controls
        }
        .onAppear { model.watch(tabID, true) }
        .onDisappear { model.watch(tabID, false) }
    }

    private var page: some View {
        GeometryReader { room in
            if let frame = model.browserFrames[tabID], frame.width > 0, frame.height > 0 {
                // The page fitted to the room, top first; its CSS pixels
                // to this screen's points.
                let scale = min(room.size.width / frame.width, room.size.height / frame.height)
                Image(uiImage: frame.image)
                    .resizable()
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { touch in
                            model.useBrowser(.tap(tab: tabID, x: touch.location.x / scale, y: touch.location.y / scale))
                        }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 14).onEnded { drag in
                            model.useBrowser(.scroll(tab: tabID, ref: nil, x: -drag.translation.width / scale, y: -drag.translation.height / scale))
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityLabel("The page, live")
                    .accessibilityIdentifier("browser-live")
            } else {
                LoadingView("Asking the Mac for the page…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
    }

    /// Typing, and going back or loading again.
    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                model.useBrowser(.history(tab: tabID, step: -1))
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back")
            Button {
                model.useBrowser(.history(tab: tabID, step: 0))
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Reload")
            TextField("Type into the page", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit {
                    guard !typed.isEmpty else { return }
                    model.useBrowser(.text(tab: tabID, text: typed))
                    typed = ""
                    typing = true
                }
                .accessibilityIdentifier("browser-type")
            Button {
                model.useBrowser(.press(tab: tabID, key: "Backspace"))
            } label: {
                Image(systemName: "delete.left")
            }
            .accessibilityLabel("Delete")
            Button {
                model.useBrowser(.press(tab: tabID, key: "Enter"))
            } label: {
                Image(systemName: "return")
            }
            .accessibilityLabel("Return")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.panel)
    }
}
