import AgentTermEditor
import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// What the agents saved by themselves (#220), of one folder only, or
/// every memory on the Mac when `folder` is nil (the Memory tab), one
/// section per agent: where History is, and as History is. One is read,
/// changed and deleted in a sheet, as on the Mac.
struct MemoryList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?
    @State private var selected: AgentMemory?
    @State private var collapsed: Set<String> = []
    @State private var deleting: AgentMemory?

    private var showsAll: Bool { folder == nil }
    private var key: String { showsAll ? "" : (folder ?? "") }
    private var groups: [AgentMemory.Group] {
        AgentMemory.groups(model.memories[key] ?? [], agentNames: model.agents.map { ($0.id, $0.name) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.memories[key] != nil {
                HStack(spacing: 14) {
                    Text(MemoryWords.count(groups.reduce(0) { $0 + $1.memories.count }))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("memory-summary")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if groups.isEmpty {
                            Text(showsAll ? MemoryWords.noneAnywhere : MemoryWords.noneInFolder)
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 40)
                                .accessibilityIdentifier("memory-none")
                        }
                        ForEach(groups) { group in groupView(group) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { load() }
            } else {
                LoadingView(MemoryWords.loadingList) { load() }
            }
        }
        .onAppear(perform: load)
        // Forgotten with the connection: asked again once the Mac is reached again.
        .onChange(of: model.status) { _, status in if status == .connected { load() } }
        .sheet(item: $selected) { memory in
            NavigationStack {
                MemoryScreen(memory: memory) { selected = nil }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
        }
        .modifier(DeleteMemoryAsk(asked: $deleting))
    }

    private func groupView(_ group: AgentMemory.Group) -> some View {
        let expanded = !collapsed.contains(group.id)
        let agent = String(group.id.dropFirst("agent:".count))
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Image(systemName: AgentStyle.symbol(for: agent)).font(.system(size: 12, weight: .semibold)).foregroundStyle(AgentStyle.accent(for: agent))
                    Text(group.title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .accessibilityLabel("\(group.title), \(MemoryWords.count(group.memories.count)), \(expanded ? "expanded" : "collapsed")")
            if expanded { card(group.memories) }
        }
    }

    /// Rows of memories in one panel, each with its menu.
    private func card(_ list: [AgentMemory]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { memory in
                Button {
                    selected = memory
                } label: {
                    MemoryRow(memory: memory, showsFolder: showsAll)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memory-" + memory.name)
                .contextMenu {
                    Button(role: .destructive) {
                        deleting = memory
                    } label: {
                        Label(MemoryWords.delete, systemImage: "trash")
                    }
                }
                if memory.id != list.last?.id {
                    Palette.hairline.frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
    }

    private func load() {
        model.loadMemories(showsAll ? nil : folder)
    }
}

private struct MemoryRow: View {
    let memory: AgentMemory
    /// In the list of everything, each row says which folder it is about.
    let showsFolder: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(memoryRelativeTime(memory.modifiedAt)).lineLimit(1)
                    if showsFolder {
                        Text("·")
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(MemoryWords.folder(of: memory)).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private func memoryRelativeTime(_ date: Date) -> String {
    if date.timeIntervalSinceNow > -60 { return "now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// One memory, whole: whose it is, of which folder, where it is and when it changed, and
/// its text, as it is written, to be changed and saved, or with its
/// Markdown rendered. As on the Mac.
struct MemoryScreen: View {
    @EnvironmentObject private var model: PhoneModel
    /// As it was listed.
    let memory: AgentMemory
    /// Closes the sheet this is in.
    let close: () -> Void
    /// The text as edited here.
    @State private var text = ""
    /// What the edits started from, with the date the file had then: a
    /// change is sent back with it. Nil until the memory was read.
    @State private var base: AgentMemoryContent?
    @State private var deleting: AgentMemory?
    @State private var askingToLeave = false
    @State private var leaveWhenSaved = false
    /// Its Markdown rendered, in History's words for the two, as on the Mac.
    @AppStorage("memoryMarkdown") private var markdown = false

    private var agentName: String { model.agents.first { $0.id == memory.agent }?.name ?? memory.agent }
    /// As it is now: saved, its date and size change.
    private var current: AgentMemory {
        guard var read = model.memoryContents[memory.path]?.memory else { return memory }
        read.folder = memory.folder
        return read
    }
    private var isDirty: Bool { base != nil && text != base?.text }
    private var isSaving: Bool { model.savingMemories[memory.path] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(memory.name)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissButton()
        // Leaving with a change that is not saved asks first.
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    if isDirty { askingToLeave = true } else { close() }
                }
                .accessibilityIdentifier("memory-close")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // A memory is changed as text only: Save is with the
                // editor, not in the preview, where nothing is typed.
                if isDirty, !markdown {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(MemoryWords.save) { save() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("memory-save")
                    }
                }
                // In view, not in a menu, as on the Mac.
                Button(role: .destructive) {
                    deleting = current
                } label: {
                    Label(MemoryWords.delete, systemImage: "trash")
                }
                .accessibilityLabel(MemoryWords.delete)
                .accessibilityIdentifier("memory-delete")
            }
        }
        .confirmationDialog("Save changes to “\(memory.name)”?", isPresented: $askingToLeave, titleVisibility: .visible) {
            Button(MemoryWords.save) {
                leaveWhenSaved = true
                save()
            }
            Button("Don't Save", role: .destructive) { close() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: memory.path) {
            adopt(model.memoryContents[memory.path])
            model.readMemory(memory)
        }
        .onChange(of: model.memoryContents[memory.path]) { _, content in adopt(content) }
        .onChange(of: isSaving) { _, saving in
            // A save that was refused leaves the edits here, and the screen open.
            if !saving, isDirty { leaveWhenSaved = false }
        }
        // Deleted, here or on another device: there is nothing left to show.
        .onChange(of: model.deletedMemories) { _, deleted in if deleted.contains(memory.path) { close() } }
        .modifier(DeleteMemoryAsk(asked: $deleting))
        // The alert on the main screen cannot appear over this sheet, so
        // what the Mac refused is said here.
        .alert("AgentTerm", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(AgentStyle.accent(for: current.agent)).frame(width: 7, height: 7)
                Text(agentName).font(.footnote.weight(.semibold))
                Text("· " + memoryRelativeTime(current.modifiedAt) + " · " + MemoryWords.size(current.size))
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Label(MemoryWords.folder(of: current), systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("memory-folder")
            Text(current.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
                .accessibilityIdentifier("memory-path")
            HStack(spacing: 14) {
                Button {
                    markdown.toggle()
                } label: {
                    Label(markdown ? ConversationDetails.showAsText : ConversationDetails.previewMarkdown, systemImage: markdown ? "text.alignleft" : "doc.richtext")
                }
                .accessibilityIdentifier("memory-markdown")
                if isDirty, !markdown {
                    Button(MemoryWords.revert) { revert() }
                        .accessibilityIdentifier("memory-revert")
                }
                if isDirty {
                    Text(MemoryWords.unsaved).foregroundStyle(Color.orange).accessibilityIdentifier("memory-unsaved")
                } else if markdown {
                    Text(MemoryWords.changeAsText).foregroundStyle(.secondary).fontWeight(.regular).accessibilityIdentifier("memory-change-as-text")
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let problem = model.memoryProblems[memory.path] {
            Text(problem)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("memory-problem")
        } else if base == nil {
            LoadingView(MemoryWords.loadingOne) { model.readMemory(memory) }
        } else if markdown {
            // A note's front matter is not Markdown: what a reader wants of
            // it comes first, quietly, then only the body is rendered, as on the Mac.
            let parts = MemoryText(text)
            let facts = parts.facts(fileName: memory.name)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let description = parts.description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("memory-description")
                    }
                    if !facts.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(facts, id: \.name) { fact in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(fact.name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                    Text(fact.value).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .font(.footnote)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                        .accessibilityIdentifier("memory-facts")
                    }
                    MarkdownText(parts.body, size: 15)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory-preview")
        } else {
            // The iPhone's own editor, as a file of the Files tab has.
            // Framed, so that it is seen to be a field that is typed into,
            // which the preview is not (the owner, 2026-11-22).
            CodeEditor(text: $text, path: memory.path)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
                .padding(8)
                .accessibilityIdentifier("memory-text")
        }
    }

    /// Takes in what the Mac has. Edits made here are kept, with what they
    /// started from.
    private func adopt(_ content: AgentMemoryContent?) {
        guard let content else { return }
        if base == nil || !isDirty || text == content.text {
            text = content.text
            base = content
        }
        if leaveWhenSaved, !isDirty {
            leaveWhenSaved = false
            close()
        }
    }

    private func save() {
        guard let base else { return }
        model.saveMemory(current, text: text, seen: base.memory.modifiedAt)
    }

    /// Drops what was changed, and reads the memory again.
    private func revert() {
        base = nil
        adopt(model.memoryContents[memory.path])
        model.readMemory(memory)
    }
}

/// The question before a memory is deleted (#220), in the same words as on
/// the Mac: once, since it goes to the Trash.
struct DeleteMemoryAsk: ViewModifier {
    @EnvironmentObject private var model: PhoneModel
    @Binding var asked: AgentMemory?

    private var question: DeleteMemoryQuestion? {
        asked.map { asked in DeleteMemoryQuestion(asked, agentName: model.agents.first { $0.id == asked.agent }?.name ?? asked.agent) }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(question?.title ?? "", isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), titleVisibility: .visible) {
                Button(question?.confirm ?? "Delete", role: .destructive) {
                    if let asked { model.deleteMemory(asked) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(question?.message ?? "")
            }
    }
}
