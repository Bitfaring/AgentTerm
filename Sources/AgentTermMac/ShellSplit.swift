import AgentTermProtocol
import SwiftUI

/// The parts of a split Shells tab (the owner's request, 2026-11-21): the
/// shell picked on the left, as an agent is in its area, a shell on the
/// right and one below, each turned on and off from the end of the row.
/// Shells only: the Browser tab is not split.
enum ShellPart: String, Hashable {
    case main, right, below
}

/// What a split Shells tab shows besides its shell picked, and the shares
/// its dividers give.
struct ShellSplit: Equatable {
    /// The shell on the right, by its tab id.
    var right: String?
    /// The shell below the others.
    var below: String?
    /// The left's share of the width, beside the right.
    var across = 0.5
    /// The share of the height above the one below.
    var down = 0.62
}

extension AppModel {
    /// Whether a Shells tab shows more than its one shell.
    func isShellsSplit(_ group: String) -> Bool { shownShellParts(of: group).count > 1 }

    /// The parts of a Shells tab that show a shell: its own, and the right
    /// and the one below while they are turned on with a shell still there.
    func shownShellParts(of group: String) -> [ShellPart] {
        guard TabID.holder(of: group)?.kind == .shells, let split = shellSplits[group] else { return [.main] }
        let list = Set(members(of: group))
        var parts: [ShellPart] = [.main]
        if let right = split.right, list.contains(right) { parts.append(.right) }
        if let below = split.below, list.contains(below) { parts.append(.below) }
        return parts
    }

    /// The shell a part shows. Its own is the one picked, else the first
    /// not shown in another part.
    func shell(in part: ShellPart, of group: String) -> String? {
        let list = members(of: group)
        let split = shellSplits[group] ?? ShellSplit()
        switch part {
        case .right: return split.right.flatMap { list.contains($0) ? $0 : nil }
        case .below: return split.below.flatMap { list.contains($0) ? $0 : nil }
        case .main:
            if let shown = groupShown[group], list.contains(shown) { return shown }
            let others = Set([split.right, split.below].compactMap { $0 })
            return list.first { !others.contains($0) } ?? list.first
        }
    }

    /// The shells on show, as the row marks them.
    func shellsOnShow(of group: String) -> Set<String> {
        Set(shownShellParts(of: group).compactMap { shell(in: $0, of: group) })
    }

    /// Whether a part is turned on, for its button.
    func isShellPartOn(_ part: ShellPart, of group: String) -> Bool { shownShellParts(of: group).contains(part) }

    /// Turns the right or the one below on, with a shell not shown yet, or
    /// a new one when there is none; or off, its shell still running and
    /// still in the row.
    func toggleShellPart(_ part: ShellPart, of group: String) {
        guard part != .main, let holder = TabID.holder(of: group), holder.kind == .shells else { return }
        var split = shellSplits[group] ?? ShellSplit()
        if isShellPartOn(part, of: group) {
            if part == .right { split.right = nil } else { split.below = nil }
            shellSplits[group] = split
            if shellSplitFocus[group] == part { shellSplitFocus[group] = .main }
            adoptFocusedFront()
            focusKeyboard()
            return
        }
        let shown = shellsOnShow(of: group)
        if let free = members(of: group).first(where: { !shown.contains($0) }) {
            if part == .right { split.right = free } else { split.below = free }
            shellSplits[group] = split
            focusShellPart(part, of: group)
        } else {
            // None left to show: a new one, which goes there once it runs.
            shellSplits[group] = split
            shellPartWaiting = (group, part)
            launch(nil)
            // Not waited for for ever: a shell that opened elsewhere, or
            // never, leaves the next one to be picked as any other.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.shellPartWaiting?.group == group, self?.shellPartWaiting?.part == part { self?.shellPartWaiting = nil }
            }
        }
    }

    /// Shows a shell in a part, the part turned on if it was off, with the
    /// keyboard: from its menu in the row or dropped there. One shown in
    /// another part changes places with what the part showed.
    func showShell(_ item: String, in part: ShellPart, of group: String) {
        guard TabID.holder(of: group)?.kind == .shells, members(of: group).contains(item) else { return }
        var split = shellSplits[group] ?? ShellSplit()
        let before = shell(in: part, of: group)
        let from = shownShellParts(of: group).first { shell(in: $0, of: group) == item }
        func set(_ part: ShellPart, _ shell: String?) {
            switch part {
            case .main: groupShown[group] = shell
            case .right: split.right = shell
            case .below: split.below = shell
            }
        }
        if let from, from != part, let before { set(from, before) }
        set(part, item)
        shellSplits[group] = split
        focusShellPart(part, of: group)
    }

    /// A shell picked up from the row: dropped on a part, it is shown there.
    /// Forgotten once the mouse is let go, dropped or not, so that the
    /// parts' drop areas do not stay over their shells.
    func startShellDrag(_ item: String) {
        draggedShell = item
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.draggedShell == item else { return }
                if NSEvent.pressedMouseButtons == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.draggedShell == item { self?.draggedShell = nil } }
                } else {
                    look()
                }
            }
        }
        look()
    }

    /// Puts the keyboard in a part of a split Shells tab, as a click there does.
    func focusShellPart(_ part: ShellPart, of group: String) {
        guard let pane = paneLayout.pane(containing: group) else { return }
        if shellSplitFocus[group] != part { shellSplitFocus[group] = part }
        if paneLayout.focused != pane.id {
            focusPane(pane.id)
        } else {
            adoptFocusedFront()
            focusKeyboard()
        }
    }

    /// An item of a Shells tab put in front: in a split one, the part it is
    /// shown in has the keyboard, or it is shown in the part that has it.
    /// False when the tab is not split, nor about to be.
    func placeInShellSplit(_ item: String, group: String) -> Bool {
        guard TabID.holder(of: group)?.kind == .shells else { return false }
        // A new shell asked for by a part turned on: shown there.
        if let waiting = shellPartWaiting, waiting.group == group, !shellsOnShow(of: group).contains(item) {
            shellPartWaiting = nil
            var split = shellSplits[group] ?? ShellSplit()
            if waiting.part == .right { split.right = item } else { split.below = item }
            shellSplits[group] = split
            shellSplitFocus[group] = waiting.part
            return true
        }
        guard isShellsSplit(group) else { return false }
        if let part = shownShellParts(of: group).first(where: { shell(in: $0, of: group) == item }) {
            if shellSplitFocus[group] != part { shellSplitFocus[group] = part }
            return true
        }
        let part = shellSplitFocus[group] ?? .main
        var split = shellSplits[group] ?? ShellSplit()
        switch part {
        case .main: groupShown[group] = item
        case .right: split.right = item
        case .below: split.below = item
        }
        if shellSplits[group] != split { shellSplits[group] = split }
        return true
    }

    /// Parts whose shell ended close; the keyboard goes back to the left.
    func tidyShellSplits() {
        for (group, split) in shellSplits {
            let list = Set(members(of: group))
            var tidy = split
            if let right = tidy.right, !list.contains(right) { tidy.right = nil }
            if let below = tidy.below, !list.contains(below) { tidy.below = nil }
            if tidy != split { shellSplits[group] = tidy }
            if let focus = shellSplitFocus[group], !shownShellParts(of: group).contains(focus) { shellSplitFocus[group] = .main }
        }
    }

    func setShellSplit(_ group: String, across: Double? = nil, down: Double? = nil) {
        var split = shellSplits[group] ?? ShellSplit()
        if let across { split.across = min(max(across, 0.15), 0.85) }
        if let down { split.down = min(max(down, 0.15), 0.9) }
        if shellSplits[group] != split { shellSplits[group] = split }
    }
}

/// A Shells tab split (the owner's request, 2026-11-21): the shell picked
/// on the left, one on the right, one below the full width, laid out and
/// framed as an agent's area is.
struct ShellsSplitView: View {
    @EnvironmentObject private var model: AppModel
    let group: String
    let paneFocused: Bool

    private var split: ShellSplit { model.shellSplits[group] ?? ShellSplit() }
    private var parts: [ShellPart] { model.shownShellParts(of: group) }
    private var focus: ShellPart { model.shellSplitFocus[group] ?? .main }

    var body: some View {
        if parts.contains(.below) {
            SplitContainer(axis: .stacked, fraction: split.down, setFraction: { model.setShellSplit(group, down: $0) }) {
                top
            } second: {
                part(.below)
            }
        } else {
            top
        }
    }

    @ViewBuilder
    private var top: some View {
        if parts.contains(.right) {
            SplitContainer(axis: .sideBySide, fraction: split.across, setFraction: { model.setShellSplit(group, across: $0) }) {
                part(.main)
            } second: {
                part(.right)
            }
        } else {
            part(.main)
        }
    }

    private func part(_ part: ShellPart) -> some View {
        let focused = paneFocused && focus == part
        return ZStack {
            Theme.canvas
            if let shell = model.shell(in: part, of: group), let session = model.session(forTab: shell) {
                SessionContent(session: session, focused: focused, showsUsage: session.typedAgent != nil).id(session.id)
            }
        }
        .modifier(PartRing(on: focused))
        // While a shell of the row is dragged: dropped here, shown here.
        .overlay {
            if model.draggedShell != nil {
                ShellDropArea(group: group, part: part)
            }
        }
        .background(PaneFrameReader(place: .shellPart(group: group, part)))
    }
}

/// Where a shell dragged from the row is dropped, over a part.
private struct ShellDropArea: View {
    @EnvironmentObject private var model: AppModel
    let group: String
    let part: ShellPart
    @State private var targeted = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(targeted ? 0.18 : 0.001))
            .overlay { if targeted { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
            .onDrop(of: [TabDrag.type], isTargeted: $targeted) { _ in
                guard let shell = model.draggedShell else { return false }
                model.draggedShell = nil
                model.showShell(shell, in: part, of: group)
                return true
            }
    }
}

/// The buttons at the end of a Shells tab's row that turn its right and
/// its lower shell on and off.
struct ShellSplitToggles: View {
    @EnvironmentObject private var model: AppModel
    let group: String

    var body: some View {
        HStack(spacing: 2) {
            toggle(.right, symbol: "rectangle.righthalf.inset.filled", on: "Hide the shell on the right", off: "Show a shell on the right")
            toggle(.below, symbol: "rectangle.bottomhalf.inset.filled", on: "Hide the shell below", off: "Show a shell below")
        }
    }

    private func toggle(_ part: ShellPart, symbol: String, on: String, off: String) -> some View {
        let isOn = model.isShellPartOn(part, of: group)
        return Button {
            model.toggleShellPart(part, of: group)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? on : off)
        .accessibilityLabel(isOn ? on : off)
        .accessibilityValue(isOn ? "shown" : "hidden")
        .accessibilityIdentifier("shells-part-\(part.rawValue)")
    }
}

/// What a shell's menu in the row says.
enum ShellSplitWords {
    static let left = "Show on the Left"
    static let right = "Show on the Right"
    static let below = "Show Below"
}
