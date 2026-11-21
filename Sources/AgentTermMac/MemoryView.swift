import AgentTermEditor
import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// The agents' memory (#220), shown as History is: every listed folder's
/// and the user's own in Memory, each folder a group; the folder on show's
/// and the user's own in the side panel, as two groups, where picking one
/// shows it in a sheet.
struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    /// The side panel's: the folder on show's only.
    var ofFolder = false

    var body: some View {
        MemoryList(store: model.memoryStore, ofFolder: ofFolder)
    }
}

/// The names both apps call the agents by, for the words about a memory.
private var memoryAgentNames: [(id: String, name: String)] { AgentDetector.known.map { ($0.id, $0.name) } }

private struct MemoryList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: MemoryStore
    let ofFolder: Bool
    @State private var collapsed: Set<String> = []
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var listed: [AgentMemory]? { ofFolder ? store.ofFolder : store.all }
    private var groups: [AgentMemory.Group] {
        guard let listed else { return [] }
        if ofFolder { return model.panelFolder.map { AgentMemory.groups(listed, ofFolder: $0) } ?? [] }
        return AgentMemory.groups(listed, folders: model.folders.map(\.path))
    }

    private var summary: String {
        guard listed != nil else { return "Loading…" }
        return MemoryWords.count(groups.reduce(0) { $0 + $1.memories.count })
    }

    private func ask() { store.refresh(ofFolder: ofFolder, path: model.panelFolder) }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
            Theme.hairline.frame(height: 1)
            content
        }
        // When it is opened, and when the side panel shows another folder.
        .task(id: ofFolder ? model.panelFolder : nil) { ask() }
        .onReceive(refresh) { _ in
            if NSApp.isActive { ask() }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier(ofFolder ? "memory-summary-folder" : "memory-summary")
            Spacer(minLength: 0)
            Button(action: ask) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 14)
        // Under the list's title at the window's left, under the tabs in
        // the side panel, which have no title between.
        .padding(.top, ofFolder ? 8 : 2)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var content: some View {
        if ofFolder && model.panelFolder == nil {
            placeholder(MemoryWords.selectFolder)
        } else if listed == nil {
            LoadingView(MemoryWords.loadingList)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if groups.isEmpty {
                        Text(ofFolder ? MemoryWords.noneInFolder : MemoryWords.noneAnywhere)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier(ofFolder ? "memory-none-folder" : "memory-none")
                    }
                    ForEach(groups) { group in
                        let expanded = !collapsed.contains(group.id)
                        MemoryGroupHeader(group: group, expanded: expanded)
                            .onTapGesture {
                                if expanded { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                            }
                        if expanded {
                            ForEach(group.memories) { memory in
                                MemoryRow(memory: memory, store: store, inSheet: ofFolder)
                            }
                        }
                    }
                    notShown
                }
                .padding(6)
            }
        }
    }

    /// What is not listed, and why: an agent whose memory is not known is
    /// said to be so, under the list.
    private var notShown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MemoryWords.notShownTitle).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(MemoryWords.notShown) { note in
                Text(note.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(ofFolder ? "memory-not-shown-folder" : "memory-not-shown")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A group's title: a folder, or the user's own.
private struct MemoryGroupHeader: View {
    let group: AgentMemory.Group
    let expanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: group.id == AgentMemory.userGroup ? "person" : "folder").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(group.title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title), \(MemoryWords.count(group.memories.count)), \(expanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier(group.id == AgentMemory.userGroup ? "memory-group-user" : "memory-group-folder")
        .accessibilityAddTraits(.isButton)
    }
}

private struct MemoryRow: View {
    let memory: AgentMemory
    @ObservedObject var store: MemoryStore
    /// The side panel's: picked, it opens in a sheet over Sessions.
    var inSheet = false
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let hoverFill = Color(red: 0.152, green: 0.156, blue: 0.178)

    private var when: String {
        memory.modifiedAt.timeIntervalSinceNow > -60 ? "now" : Self.relative.localizedString(for: memory.modifiedAt, relativeTo: Date())
    }

    private var selected: Bool { !inSheet && store.selection?.path == memory.path }
    private var fill: Color { selected ? Color.white.opacity(0.11) : (hovering ? Self.hoverFill : .clear) }
    private var place: String { (memory.path as NSString).abbreviatingWithTildeInPath }
    private var readers: String { MemoryWords.readers(of: memory, agentNames: memoryAgentNames) }

    private func pick() {
        if inSheet { store.panelMemory = memory } else { store.selection = memory }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    ForEach(memory.agents, id: \.self) { agent in
                        Circle().fill(Theme.accent(for: agent)).frame(width: 6, height: 6)
                    }
                    Text(readers).lineLimit(1)
                    Text("·")
                    Text(when)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                if let writer = MemoryWords.writer(of: memory, agentNames: memoryAgentNames) {
                    Text(writer).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if store.isChanged(memory) {
                    Text(MemoryWords.unsaved).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .contextMenu {
            Button(MemoryWords.delete, role: .destructive) { store.deleting = memory }
        }
        .help(place)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(memory.name), \(readers), \(place)")
        .accessibilityIdentifier("memory-" + memory.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityAction(named: "Delete") { store.deleting = memory }
    }
}

/// Memory's list, every listed folder's memories and the user's own.
struct MemorySidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            SidebarTitle("MEMORY")
            MemoryView()
        }
        .background(Theme.panel)
    }
}

/// The memory picked in Memory, in the middle of the window.
struct MemoryDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MemoryPicked(store: model.memoryStore)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
    }
}

private struct MemoryPicked: View {
    @ObservedObject var store: MemoryStore

    var body: some View {
        // Only one that is still listed: a refresh may have dropped it.
        if let picked = store.selection, store.all?.contains(where: { $0.path == picked.path }) != false {
            MemoryCard(store: store, memory: picked)
                .padding(28)
                .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .id(picked.path)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(MemoryWords.choose).font(.system(size: 14, weight: .semibold))
                Text(MemoryWords.chooseWhy).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One memory, whole: who reads it, where it is and when it changed, and
/// its text, as it is written, to be changed and saved, or with its
/// Markdown rendered. In Memory's middle, or in a sheet over Sessions when
/// picked in the side panel.
struct MemoryCard: View {
    @ObservedObject var store: MemoryStore
    let memory: AgentMemory
    /// Its Markdown rendered, in History's words for the two. Kept for the
    /// next memory, on this Mac.
    @AppStorage("memoryMarkdown") private var markdown = false

    private var changed: Bool { store.isChanged(memory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch store.loaded[memory.path] {
            case .none:
                LoadingView(MemoryWords.loadingOne).frame(height: 80)
            case .some(.problem(let problem)):
                Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory-problem")
            case .some(.content):
                buttons
                if let refused = store.refused[memory.path] {
                    // What the host refused, said where the memory is.
                    Label(refused, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memory-refused")
                }
                text
            }
        }
        .task(id: memory.path) { store.read(memory) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(memory.agents, id: \.self) { agent in
                    Circle().fill(Theme.accent(for: agent)).frame(width: 8, height: 8)
                }
                Text(MemoryWords.readers(of: memory, agentNames: memoryAgentNames)).font(.system(size: 12, weight: .semibold))
                Text("· " + memory.modifiedAt.formatted(.relative(presentation: .named)) + " · " + MemoryWords.size(memory.size))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("memory-readers")
            Text(memory.name)
                .font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Label((memory.path as NSString).abbreviatingWithTildeInPath, systemImage: memory.scope == .user ? "person" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("memory-path")
            if let writer = MemoryWords.writer(of: memory, agentNames: memoryAgentNames) {
                Text(writer).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(MemoryWords.save) { store.save(memory) }
                .buttonStyle(.borderedProminent)
                .disabled(!changed)
                .help(changed ? "Write the change to the file the agents read" : "Nothing was changed")
                .accessibilityIdentifier("memory-save")
            if changed {
                Button(MemoryWords.revert) { store.revert(memory) }
                    .help("Drop the change and read the memory again")
                    .accessibilityIdentifier("memory-revert")
                Text(MemoryWords.unsaved).font(.system(size: 11)).foregroundStyle(Color.orange)
                    .accessibilityIdentifier("memory-unsaved")
            }
            Button {
                markdown.toggle()
            } label: {
                Label(markdown ? ConversationDetails.showAsText : ConversationDetails.previewMarkdown, systemImage: markdown ? "text.alignleft" : "doc.richtext")
            }
            .help(markdown ? "Show the memory as it is written, to change it" : "Show the memory with its Markdown rendered")
            .accessibilityIdentifier("memory-markdown")
            Spacer(minLength: 0)
            // In view, not in a menu: there is room for it here.
            Button(MemoryWords.delete, role: .destructive) {
                // Asked over the window, not over the sheet this may be in.
                store.panelMemory = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.deleting = memory }
            }
            .accessibilityIdentifier("memory-delete")
        }
        .controlSize(.small)
    }

    @ViewBuilder private var text: some View {
        if markdown {
            ScrollView {
                MarkdownText(store.text(of: memory) ?? "", size: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory-preview")
        } else {
            // The app's own editor, as a file of the Files tab has.
            CodeEditor(
                text: Binding(get: { store.text(of: memory) ?? "" }, set: { store.setText($0, for: memory) }),
                path: memory.path
            )
            .id(memory.path)
            .frame(minHeight: 240, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("memory-text")
        }
    }
}

/// A memory picked in the side panel's Memory, over Sessions.
private struct MemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MemoryStore
    let memory: AgentMemory

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 14)
            // As it is now: saved, its date and size change.
            MemoryCard(store: store, memory: store.panelMemory ?? memory)
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
        }
        .frame(width: 680, height: 740)
    }
}

/// The side panel's memory in its sheet, and the question before a memory
/// is deleted (#220), over the whole window: asked from a row's menu or from
/// the memory itself, once, since it goes to the Trash.
struct MemoryWindow: ViewModifier {
    @ObservedObject var store: MemoryStore

    private var question: DeleteMemoryQuestion? {
        store.deleting.map { DeleteMemoryQuestion($0, agentNames: memoryAgentNames) }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.panelMemory) { memory in
                MemorySheet(store: store, memory: memory)
            }
            .confirmationDialog(
                question?.title ?? "", isPresented: Binding(get: { store.deleting != nil }, set: { if !$0 { store.deleting = nil } }), titleVisibility: .visible
            ) {
                Button(question?.confirm ?? "Delete", role: .destructive) { store.deleteConfirmed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(question?.message ?? "")
            }
    }
}
