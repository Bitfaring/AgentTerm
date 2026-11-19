import AgentTermProtocol
import SwiftUI

/// One more item for a group, from its row: a page or a shell.
struct GroupPlus: Identifiable {
    let label: String
    let symbol: String
    let id: String
    let action: () -> Void
}

/// The row under the strip (#127): the items of the group in front, those
/// on show marked; a + where one more can be made. An agent's row has the
/// agent first, then its pages and its shells, a page and a shell more for
/// it, and at its end what shows and hides the page and the shell beside
/// the agent: its area's parts are managed here, not in the area.
struct GroupRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let group: String

    /// Its height, which a terminal does not have.
    static let height: CGFloat = 30

    private var pluses: [GroupPlus] {
        if let holder = TabID.holder(of: group) {
            switch holder.kind {
            case .shells: return [GroupPlus(label: "New Shell", symbol: "plus", id: "shells-new") { model.launch(nil) }]
            case .browser: return [GroupPlus(label: "New Page", symbol: "plus", id: "browser-new-page") { model.openBrowserTab() }]
            case .diffs, .files: return []
            }
        }
        return [
            GroupPlus(label: "Page", symbol: "plus", id: "agent-new-page") { model.openBrowserTab(besideAgent: group) },
            GroupPlus(label: "Shell", symbol: "plus", id: "agent-new-shell") { model.newShell(besideAgent: group) },
        ]
    }

    var body: some View {
        let items = model.members(of: group)
        // The item the keyboard is in; an agent's area shows more than it.
        let keyboard = model.shownMember(of: group)
        let area = TabID.holder(of: group) == nil && model.hasArea(group)
        let onShow = area ? model.itemsOnShow(of: group) : Set([keyboard].compactMap { $0 })
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        GroupItemChip(group: group, item: item, selected: onShow.contains(item), keyboard: area && item == keyboard)
                            // Its number while ⌥ and ⌘ are held (#171): ⌥⌘ and it picks it.
                            .overlay(alignment: .topTrailing) {
                                if model.itemNumbersShown, index < 9 {
                                    Text("\(index + 1)")
                                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                                        .padding(.horizontal, 3)
                                        .background(Capsule().fill(Color.accentColor))
                                        .foregroundStyle(.white)
                                        .offset(x: 3, y: -3)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
            }
            ForEach(pluses) { plus in
                Button(action: plus.action) {
                    Label(plus.label, systemImage: plus.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(plus.id == "agent-new-shell" ? "New shell for this agent, which it can read and type into" : plus.label)
                .accessibilityLabel(plus.id.hasPrefix("agent-") ? "New \(plus.label) for the Agent" : plus.label)
                .accessibilityIdentifier(plus.id)
            }
            Spacer(minLength: 0)
            if area { AgentPartToggles(agent: group) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group-row")
    }
}

/// Shows and hides the page and the shell beside an agent, at the end of
/// its row (#127), where each part had a button to close it (#69). Hidden,
/// a part's pages stay open and its shells keep running.
private struct AgentPartToggles: View {
    @EnvironmentObject private var model: AppModel
    let agent: String

    var body: some View {
        let all = model.companions
        let area = model.agentAreas[agent] ?? AgentArea()
        HStack(spacing: 2) {
            if !(all.browsers[agent] ?? []).isEmpty {
                toggle(.browser, hidden: area.browserHidden, symbol: "rectangle.righthalf.inset.filled", name: "Its Page")
                    .help(area.browserHidden ? "Show its page beside the agent" : "Hide its page. Its tabs stay open.")
            }
            if !(all.shells[agent] ?? []).isEmpty {
                toggle(.shells, hidden: area.shellsHidden, symbol: "rectangle.bottomhalf.inset.filled", name: "Its Shells")
                    .help(area.shellsHidden ? "Show its shell under the agent" : "Hide its shells. They keep running, and stay in the list of sessions.")
            }
        }
    }

    private func toggle(_ part: AgentAreaPart, hidden: Bool, symbol: String, name: String) -> some View {
        Button {
            model.toggleAgentPart(part, of: agent)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hidden ? .tertiary : .primary)
        .accessibilityLabel(hidden ? "Show \(name)" : "Hide \(name)")
        .accessibilityValue(hidden ? "hidden" : "shown")
        .accessibilityIdentifier("agent-part-\(part.rawValue)")
    }
}

/// What an item of a group's row shows, and what closing it does.
private struct ItemLook {
    var symbol: String
    var tint: Color = .secondary
    var title: String
    var dirty = false
    var session: SessionInfo?
    /// What closing it is called, in its menu: "Close Tab" for a page.
    var closing = "Close"
    /// Its name for assistive tools: "item-" and its session's number, or
    /// "item-b" and its page's; not the strip's name for an agent's tab, as
    /// the agent is in both.
    var identifier: String
    var close: (() -> Void)?
}

/// One item of a group's row: a page follows its tab, whose title and
/// loading change without the rest of the app hearing of it.
private struct GroupItemChip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    let group: String
    let item: String
    /// On show: the one item of a group of the user's, or one of those an
    /// agent's area shows.
    let selected: Bool
    /// The one the keyboard is in, of those an agent's area shows.
    var keyboard = false

    var body: some View {
        if let tab = model.browsers.tab(forTab: item) {
            PageItemChip(tab: tab, selected: selected, keyboard: keyboard)
        } else {
            ItemChip(look: look, selected: selected, keyboard: keyboard) { model.selectTab(id: item) }
        }
    }

    private var look: ItemLook {
        let id = item
        if let session = model.session(forTab: item) {
            if let agent = session.agent {
                // "Agent", not its name, which its tab above says: the two
                // would read as one tab twice (#146).
                return ItemLook(
                    symbol: Theme.symbol(for: agent), tint: Theme.accent(for: agent), title: AgentPartWords.agent, session: session,
                    identifier: "item-\(session.id)")
            }
            return ItemLook(symbol: "terminal", title: session.displayName, session: session, closing: "End Session", identifier: "item-\(session.id)") {
                model.requestEnd(session.id)
            }
        }
        if let diff = model.diffTabs.first(where: { $0.tabID == item }) {
            return ItemLook(symbol: "plus.forwardslash.minus", title: (diff.file.path as NSString).lastPathComponent, closing: "Close Diff", identifier: "item-\(id)") {
                model.closeDiffTab(id)
            }
        }
        if let document = model.document(forTab: item) {
            return ItemLook(symbol: document.isMarkdown ? "doc.text" : "doc", title: document.name, dirty: document.isDirty, closing: "Close File", identifier: "item-\(id)") {
                files.requestClose(document.path)
            }
        }
        return ItemLook(symbol: "questionmark", title: item, identifier: "item-\(id)")
    }
}

private struct PageItemChip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    var keyboard = false

    var body: some View {
        let look = ItemLook(
            symbol: tab.loading ? "arrow.triangle.2.circlepath" : "globe", title: tab.displayTitle, closing: "Close Tab", identifier: "item-b\(tab.id)"
        ) { model.closeBrowserTab(tab) }
        ItemChip(look: look, selected: selected, keyboard: keyboard) { model.selectTab(id: tab.tabID) }
    }
}

private struct ItemChip: View {
    let look: ItemLook
    let selected: Bool
    /// The one the keyboard is in, of several on show: a line under it.
    var keyboard = false
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        chip
            .overlay(alignment: .bottom) { if keyboard { Color.accentColor.opacity(0.7).frame(height: 1.5).padding(.horizontal, 6) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityValue(keyboard ? "has the keyboard" : "")
            .accessibilityIdentifier(look.identifier)
            .accessibilityAddTraits(traits)
            .accessibilityAction { select() }
            .accessibilityAction(named: look.closing) { look.close?() }
    }

    private var spoken: String { look.dirty ? "\(look.title), unsaved changes" : look.title }
    private var traits: AccessibilityTraits { selected ? [.isButton, .isSelected] : .isButton }
    private var fill: Color { selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear) }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: look.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(look.tint)
            Text(look.title)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let session = look.session { AgentStateMark(session: session) }
            if look.dirty { Circle().fill(Color.orange).frame(width: 6, height: 6) }
            if let close = look.close {
                CloseButton(help: look.closing, glyph: 8.5, action: close)
                    .opacity(hovering || selected ? 1 : 0)
                    .accessibilityLabel("\(look.closing) \(look.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            if let close = look.close { Button(look.closing, action: close) }
        }
    }
}
