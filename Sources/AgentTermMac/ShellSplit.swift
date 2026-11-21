import AgentTermProtocol
import SwiftUI

extension AppModel {
    // What a split Shells tab shows is `ShellSplit`'s (AgentTermProtocol),
    // given the tab's shells and the one picked, `groupShown`.

    /// Whether a Shells tab shows more than its one shell.
    func isShellsSplit(_ group: String) -> Bool { shownShellParts(of: group).count > 1 }

    /// The parts of a Shells tab that show a shell: its own, and the right
    /// and the one below while they are turned on with a shell still there.
    func shownShellParts(of group: String) -> [ShellPart] {
        guard TabID.holder(of: group)?.kind == .shells, let split = shellSplits[group] else { return [.main] }
        return split.parts(in: members(of: group))
    }

    /// The shell a part shows. Its own is the one picked, else the first
    /// not shown in another part.
    func shell(in part: ShellPart, of group: String) -> String? {
        (shellSplits[group] ?? ShellSplit()).shell(in: part, picked: groupShown[group], members: members(of: group))
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
            split.turnOff(part)
            shellSplits[group] = split
            if shellSplitFocus[group] == part { shellSplitFocus[group] = .main }
            adoptFocusedFront()
            focusKeyboard()
            return
        }
        lastShellPartLaunch += 1
        let request = lastShellPartLaunch
        switch split.turnOn(part, picked: groupShown[group], members: members(of: group), request: request) {
        case .shown:
            shellSplits[group] = split
            focusShellPart(part, of: group)
        case .waiting:
            // None left to show: a new one, launched with a number of its
            // own, which goes there once the host has given that number back
            // with it and it is in the row (#189); a shell started elsewhere
            // meanwhile is not taken. The part waits until then, or until
            // the host refuses that launch or goes, either of which is said.
            // Not connected, nothing is started and the part does not wait:
            // that is said at once (#202). The tab is not on screen while
            // not connected (CenterView shows why instead), so its part
            // buttons cannot be pressed then; the check is kept all the same.
            guard canStartSessions() else { return }
            shellSplits[group] = split
            launch(nil, request: request)
        }
    }

    /// The host made the shell launched for a part, and gave its request
    /// back with it (#189): that part, and no other, takes it.
    func shellPartLaunched(request: Int, session: SessionInfo) {
        for (group, split) in shellSplits where split.waits.contains(where: { $0.request == request }) {
            var launched = split
            if launched.launched(request: request, shell: TabID.session(session)) { shellSplits[group] = launched }
        }
    }

    /// The host refused the launch asked with this request: the part that
    /// waited for it waits no more, the others still do (#189).
    func stopShellPartWait(request: Int) {
        for (group, split) in shellSplits where split.waits.contains(where: { $0.request == request }) {
            var stopped = split
            stopped.stopWaiting(request: request)
            shellSplits[group] = stopped
        }
    }

    /// Shows a shell in a part, the part turned on if it was off, with the
    /// keyboard: from its menu in the row or dropped there. One shown in
    /// another part changes places with what the part showed; a shell is
    /// never in two parts (#188). The left's shell, with none free to take
    /// its place, stays, and the user is told why.
    func showShell(_ item: String, in part: ShellPart, of group: String) {
        guard TabID.holder(of: group)?.kind == .shells, members(of: group).contains(item) else { return }
        var split = shellSplits[group] ?? ShellSplit()
        var picked = groupShown[group]
        guard split.show(item, in: part, picked: &picked, members: members(of: group)) else {
            notice = ShellSplitWords.leftKeepsIt
            return
        }
        if groupShown[group] != picked { groupShown[group] = picked }
        shellSplits[group] = split
        focusShellPart(part, of: group)
    }

    /// No part of a Shells tab waits for a new shell any more: the
    /// connection went (#189).
    func stopShellPartWaits() {
        for (group, split) in shellSplits where !split.waits.isEmpty {
            var stopped = split
            stopped.stopWaiting()
            shellSplits[group] = stopped
        }
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
        // A new shell asked for by a part turned on: shown there. Only the
        // one launched for it, as the host said (#189).
        if var split = shellSplits[group], let part = split.takeNew(item, picked: groupShown[group], members: members(of: group)) {
            shellSplits[group] = split
            shellSplitFocus[group] = part
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

    /// Parts whose shell ended close, and the keyboard goes back to the
    /// left; a part waiting for the shell launched for it takes it once it
    /// is in the row, put in front or not (#189).
    func tidyShellSplits() {
        for (group, split) in shellSplits {
            var tidy = split
            var picked = groupShown[group]
            tidy.tidy(picked: &picked, members: members(of: group))
            if groupShown[group] != picked { groupShown[group] = picked }
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
