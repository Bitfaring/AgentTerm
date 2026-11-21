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
    /// What is in front, which it shows (#178).
    @EnvironmentObject private var front: FrontState
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    @EnvironmentObject private var browsers: BrowserModel
    let group: String

    /// Its height, which a terminal does not have.
    static let height: CGFloat = 30

    /// The keys that pick the item of that number in the row in front.
    static func shortcut(_ number: Int) -> String { "⌥⌘\(number)" }

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
        let split = model.isShellsSplit(group)
        // An agent's area, or a split Shells tab: several on show, one with the keyboard.
        let area = (TabID.holder(of: group) == nil && model.hasArea(group)) || split
        let onShow =
            split ? model.shellsOnShow(of: group) : area ? model.itemsOnShow(of: group) : Set([keyboard].compactMap { $0 })
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        GroupItemChip(
                            group: group, item: item, selected: onShow.contains(item), keyboard: area && item == keyboard,
                            shortcut: index < 9 ? Self.shortcut(index + 1) : nil
                        )
                        // Its shortcut, told on the pointer too (#171).
                        .help(index < 9 ? "\(Self.shortcut(index + 1)) shows it" : "")
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
            if TabID.holder(of: group)?.kind == .shells {
                ShellSplitToggles(group: group)
            } else if area {
                AgentPartToggles(agent: group)
            }
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
    /// The keys that pick it, for the first nine (#171).
    var shortcut: String?

    var body: some View {
        if let tab = model.browsers.tab(forTab: item) {
            PageItemChip(tab: tab, selected: selected, keyboard: keyboard, shortcut: shortcut)
        } else {
            ItemChip(look: look, selected: selected, keyboard: keyboard, shortcut: shortcut, places: places) { model.selectTab(id: item) }
                // A shell of the user's: dragged to a part of the split tab.
                .modifier(ShellDrag(item: item, enabled: TabID.holder(of: group)?.kind == .shells))
        }
    }

    /// Where a shell of the user's may be shown in its tab split in three
    /// (the owner's request, 2026-11-21): its menu says each.
    private var places: [ItemPlace] {
        guard TabID.holder(of: group)?.kind == .shells else { return [] }
        return [(ShellPart.main, ShellSplitWords.left), (.right, ShellSplitWords.right), (.below, ShellSplitWords.below)].map { part, title in
            ItemPlace(title: title) { model.showShell(item, in: part, of: group) }
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
    var shortcut: String?

    var body: some View {
        let look = ItemLook(
            symbol: tab.loading ? "arrow.triangle.2.circlepath" : "globe", title: tab.displayTitle, closing: "Close Tab", identifier: "item-b\(tab.id)"
        ) { model.closeBrowserTab(tab) }
        ItemChip(look: look, selected: selected, keyboard: keyboard, shortcut: shortcut) { model.selectTab(id: tab.tabID) }
    }
}

private struct ItemChip: View {
    let look: ItemLook
    let selected: Bool
    /// The one the keyboard is in, of several on show: a line under it.
    var keyboard = false
    /// The keys that pick it, at its end as a tab of the strip has its ⌘
    /// and number (#171, the owner's decision, 2026-11-21): the close
    /// button takes their place under the pointer.
    var shortcut: String?
    /// Where else it may be shown, from its menu: a shell of a Shells tab.
    var places: [ItemPlace] = []
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
            .modifier(PlaceActions(places: places))
            // Drawn over the place kept for it at the chip's end: over the
            // chip, it is an element of its own, which the chip's one
            // element would take in otherwise.
            .overlay(alignment: .trailing) {
                if let shortcut {
                    shortcutText(shortcut)
                        .opacity(hovering ? 0 : 1)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(shortcutIdentifier)
                }
            }
    }

    /// As a tab of the strip shows its ⌘ and number.
    private func shortcutText(_ shortcut: String) -> some View {
        Text(shortcut)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    private var spoken: String { look.dirty ? "\(look.title), unsaved changes" : look.title }
    /// "row-shortcut-1" for ⌥⌘1, for the tests.
    private var shortcutIdentifier: String { "row-shortcut-" + String(shortcut?.last.map(String.init) ?? "") }
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
            if shortcut != nil || look.close != nil {
                ZStack {
                    // Its place: the shortcut is drawn over it (`body`).
                    if let shortcut { shortcutText(shortcut).hidden() }
                    if let close = look.close {
                        CloseButton(help: look.closing, glyph: 8.5, action: close)
                            .opacity(shortcut == nil ? (hovering || selected ? 1 : 0) : (hovering ? 1 : 0))
                            .accessibilityLabel("\(look.closing) \(look.title)")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            ForEach(places) { place in Button(place.title, action: place.action) }
            if !places.isEmpty { Divider() }
            if let close = look.close { Button(look.closing, action: close) }
        }
    }
}

/// Somewhere an item of the row may be shown, offered in its menu.
struct ItemPlace: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}

/// An item's places as actions of its own, for VoiceOver and the tests,
/// as its menu has them.
private struct PlaceActions: ViewModifier {
    let places: [ItemPlace]

    func body(content: Content) -> some View {
        places.reduce(AnyView(content)) { view, place in AnyView(view.accessibilityAction(named: place.title, place.action)) }
    }
}

/// A shell of a Shells tab's row, picked up to be dropped on a part of it.
private struct ShellDrag: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let item: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                model.draggedTab = nil
                model.startShellDrag(item)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: TabDrag.type.identifier, visibility: .ownProcess) { done in
                    done(Data(item.utf8), nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}
