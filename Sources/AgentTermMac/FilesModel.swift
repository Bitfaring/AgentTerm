import AgentTermEditor
import AgentTermHost
import AgentTermProtocol
import AppKit
import SwiftUI

/// The text of an open file as it is being edited, in a box of its own: a
/// key in the editor changes what the box holds, and no view is told. Kept
/// in the document itself, every view that watches the open files was told
/// at each key, and the whole window was laid out again (#104). What views
/// show of it is whether it differs from the disk's, which the document says.
final class EditedText {
    var text: String
    init(_ text: String) { self.text = text }
}

/// A file open in the Files tab.
struct OpenDocument: Equatable {
    var path: String
    var content: FileContent
    /// The text as edited, for text content. `FilesModel` changes it.
    fileprivate let edited: EditedText
    /// The text as it is on disk.
    fileprivate(set) var savedText: String
    /// Whether the text as edited differs from the disk's: kept true to
    /// both by `FilesModel`, which is what changes them.
    fileprivate(set) var isDirty = false
    /// A file on another Mac that was asked for and is not here yet.
    var isLoading = false
    /// The bytes of an image on another Mac: there is no file here to read it from.
    var imageData: Data?

    init(path: String, content: FileContent, text: String, savedText: String, isLoading: Bool = false, imageData: Data? = nil) {
        self.path = path
        self.content = content
        edited = EditedText(text)
        self.savedText = savedText
        self.isLoading = isLoading
        self.imageData = imageData
        isDirty = differs
    }

    /// The text as edited. Only meaningful for text content.
    var text: String { edited.text }

    /// Whether the text as edited differs from the disk's, worked out.
    fileprivate var differs: Bool { isText && !Self.same(edited.text, savedText) }

    /// Whether two texts are the same, unit for unit. Their lengths first,
    /// which is all it takes after a letter typed: Swift's own `==` reads
    /// both through to where they differ, megabytes at each key (#104).
    fileprivate static func same(_ left: String, _ right: String) -> Bool {
        let one = left as NSString
        return one.length == (right as NSString).length && one.isEqual(to: right)
    }

    /// The disk has `text` now, written from here: the text as edited may
    /// have gone on since.
    fileprivate mutating func wasSaved(as text: String) {
        savedText = text
        isDirty = differs
    }

    /// Its edits thrown away: the text as it is on disk again.
    fileprivate mutating func revert() {
        edited.text = savedText
        isDirty = false
    }

    /// The same document: its text as edited is the same box, whatever it
    /// holds at the moment.
    static func == (left: OpenDocument, right: OpenDocument) -> Bool {
        left.path == right.path && left.isDirty == right.isDirty && left.isLoading == right.isLoading && left.edited === right.edited
            && left.imageData == right.imageData && left.content == right.content && left.savedText == right.savedText
    }

    var name: String { (path as NSString).lastPathComponent }
    var isText: Bool { if case .text = content { return true } else { return false } }
    var isMarkdown: Bool { FileLanguage.isMarkdown(path) }
    /// A file that is one Mermaid diagram.
    var isMermaid: Bool { FileLanguage.isMermaid(path) }
    /// Text that has a rendered form to look at besides its source.
    var hasPreview: Bool { isText && (isMarkdown || isMermaid) }
}

/// State of the Files tab and of the files open in the middle pane.
@MainActor
final class FilesModel: ObservableObject {
    @Published private(set) var root: String?
    /// Loaded contents of folders, by path.
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    /// Files open as tabs next to the sessions, in tab order. They belong to
    /// the window, not to the folder being browsed.
    @Published var documents: [OpenDocument] = []
    /// The file shown in the middle pane. Nil while a terminal is shown.
    @Published var active: String?
    @Published var error: String?
    /// A file with unsaved changes that the user asked to close.
    @Published var pendingClose: String?

    private static let openFilesKey = "openFiles"

    /// Set while another Mac is on screen: its files are not on this
    /// disk, and are asked for through its host instead. Every request is
    /// answered with a message that `handle` takes.
    private var remote: ((ClientMessage) -> Void)?
    var isRemote: Bool { remote != nil }
    /// False while there is no connection to the other Mac: what is asked
    /// of it then goes nowhere.
    var isOnline = true
    /// The text sent to the other Mac to be written, by path, until it
    /// says the file is saved. Until then the file's changes are not saved.
    private var saving: [String: String] = [:]
    /// Files saved again while the other Mac was still writing them.
    private var saveAgain: Set<String> = []
    /// Files whose tab closes once the other Mac has saved them.
    private var closeWhenSaved: Set<String> = []
    /// How many times a file was asked for and not yet answered.
    private var readsDue: [String: Int] = [:]
    /// Files saved while a read was on its way: the answer to that read
    /// may be the file as it was before, and is not shown.
    private var staleReads: Set<String> = []

    init() {
        restoreOpenFiles()
    }

    /// The files that were open last time come back as tabs, behind the terminal.
    /// Read off the main thread (#304): a file on a volume that does not
    /// answer would otherwise stop the app as it starts.
    private func restoreOpenFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.openFilesKey) ?? []
        guard !paths.isEmpty else { return }
        let started = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { Self.load($0) }
            DispatchQueue.main.async {
                guard let self, self.generation == started, !self.isRemote else { return }
                let opened = self.documents
                self.documents = loaded.filter { document in !opened.contains { $0.path == document.path } } + opened
                self.rememberOpenFiles()
            }
        }
    }

    /// Goes up at every `reset`: what was read for the Mac that was left is
    /// not taken.
    private var generation = 0
    /// A pass of `refresh` is on its way: another is not started, or a
    /// volume that does not answer would gather one stuck pass every few
    /// seconds.
    private var refreshing = false

    /// Whether a file has changes that are not saved.
    var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }

    /// Starts over for another Mac, or for this one again (nil). The files
    /// that were open belong to the Mac that is left.
    func reset(remote: ((ClientMessage) -> Void)?) {
        self.remote = remote
        generation += 1
        refreshing = false
        root = nil
        children = [:]
        expanded = []
        documents = []
        active = nil
        error = nil
        pendingClose = nil
        forgetRequests()
        if remote == nil { restoreOpenFiles() }
    }

    /// The connection to the other Mac is gone, and with it the answers
    /// that were on their way. A file that was being saved keeps its changes.
    func connectionLost() {
        isOnline = false
        forgetRequests()
    }

    /// The other Mac said something went wrong. It does not say with what,
    /// so no file that was being saved is taken as saved.
    func requestFailed() {
        // A rename refused leaves what is open where it was (#305).
        renamesDue = [:]
        saving = [:]
        saveAgain = []
        closeWhenSaved = []
    }

    private func forgetRequests() {
        requestFailed()
        readsDue = [:]
        staleReads = []
    }

    private func read(_ path: String, anyway: Bool = false) {
        guard let remote else { return }
        readsDue[path, default: 0] += 1
        remote(.readFile(path: path, anyway: anyway ? true : nil))
    }

    /// Opens a text file that is over the size it is opened at by itself,
    /// as the user asked (#21).
    func openAnyway(_ path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        if isRemote {
            // Shown as loading until it comes.
            documents[index].content = .text("")
            documents[index].isLoading = true
            read(path, anyway: true)
        } else {
            documents[index] = Self.load(path, anyway: true)
        }
    }

    /// What another Mac's host answered about its files.
    func handle(_ message: ServerMessage) {
        guard isRemote else { return }
        switch message {
        case .files(let directory, let entries):
            // A rename the other Mac took: the folder now has the new name
            // and not the old one (#305).
            for (old, target) in renamesDue where (old as NSString).deletingLastPathComponent == directory {
                guard entries.contains(where: { $0.path == target }), !entries.contains(where: { $0.path == old }) else { continue }
                renamesDue[old] = nil
                moved(old, to: target)
            }
            guard root != nil, directory == root || expanded.contains(directory) else { return }
            if children[directory] != entries { children[directory] = entries }
        case .file(let path, let content, let data):
            let due = max((readsDue[path] ?? 0) - 1, 0)
            readsDue[path] = due == 0 ? nil : due
            if staleReads.contains(path) {
                // Asked for before the file was saved from here. The next
                // look at the files reads it again.
                if due == 0 { staleReads.remove(path) }
                return
            }
            guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
            // One with edits of our own keeps them, as with a file on this disk.
            if documents[index].isDirty { return }
            var text = ""
            if case .text(let loaded) = content { text = loaded }
            if documents[index].isLoading || documents[index].savedText != text || documents[index].content != content {
                documents[index] = OpenDocument(path: path, content: content, text: text, savedText: text, isLoading: false, imageData: data)
            }
        case .fileCreated(let path, let isDirectory):
            let directory = (path as NSString).deletingLastPathComponent
            if directory != root { expanded.insert(directory) }
            if isDirectory { expanded.insert(path) } else { open(path) }
            refresh()
        case .fileSaved(let path):
            guard let text = saving.removeValue(forKey: path) else { return }
            let index = documents.firstIndex(where: { $0.path == path })
            if let index { documents[index].wasSaved(as: text) }
            let again = saveAgain.remove(path) != nil
            let closing = closeWhenSaved.remove(path) != nil
            guard let index else { return }
            if documents[index].isDirty {
                // Changed again since: what closes it is the next save.
                if again || closing { saveAndClose(path, closing: closing) }
            } else if closing {
                close(path)
            }
        default:
            break
        }
    }

    var activeDocument: OpenDocument? { documents.first { $0.path == active } }

    /// A row of the tree as shown: folders that are open are followed by
    /// what is in them.
    struct Row: Identifiable, Equatable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        func add(_ directory: String, depth: Int) {
            for entry in children[directory] ?? [] {
                result.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        return result
    }

    // MARK: Tree

    func setRoot(_ folder: String?) {
        guard folder != root else { return }
        root = folder
        children = [:]
        expanded = []
        if let folder { load(folder) }
    }

    func toggle(_ directory: String) {
        if expanded.contains(directory) {
            expanded.remove(directory)
        } else {
            expanded.insert(directory)
            load(directory)
        }
    }

    /// Reads again what is on disk: every folder that is showing, and the
    /// open files, which an agent may have rewritten meanwhile.
    func refresh() {
        if let remote {
            if let root { for directory in [root] + expanded.sorted() { remote(.files(path: directory)) } }
            for document in documents where document.isText && !document.isDirty && !document.isLoading && !staleReads.contains(document.path) {
                read(document.path)
            }
            return
        }
        // Only files without edits of our own follow the disk. One with
        // unsaved changes keeps them; saving then overwrites the disk. All
        // that touches the disk is off the main thread, and only a file
        // whose date or size changed since it was last looked at is read
        // (#304): every few seconds, a dozen large files, or one on a slow
        // volume, held the window up.
        guard !refreshing else { return }
        let directories = root.map { [$0] + expanded.sorted() } ?? []
        let looked = documents.filter { $0.isText && !$0.isDirty }.map { DiskFollow.Looked(path: $0.path, saved: $0.savedText) }
        guard !directories.isEmpty || !looked.isEmpty else { return }
        refreshing = true
        let known = diskStamps
        let started = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gone = Set(directories.filter { !FileManager.default.fileExists(atPath: $0) })
            let (stamps, changed) = DiskFollow.look(at: looked, known: known)
            DispatchQueue.main.async {
                guard let self, self.generation == started else { return }
                self.refreshing = false
                for directory in directories {
                    if gone.contains(directory) {
                        self.expanded.remove(directory)
                        self.children[directory] = nil
                    } else {
                        self.load(directory)
                    }
                }
                for (path, stamp) in stamps { self.diskStamps[path] = stamp }
                for found in changed {
                    // Not if it was edited, saved or closed meanwhile.
                    guard let index = self.documents.firstIndex(where: { $0.path == found.path }),
                        DiskFollow.takes(found, now: (self.documents[index].isDirty, self.documents[index].savedText))
                    else { continue }
                    self.documents[index] = OpenDocument(path: found.path, content: .text(found.text), text: found.text, savedText: found.text)
                }
            }
        }
    }

    /// Each open file's `DiskStamp` when it was last looked at.
    private var diskStamps: [String: DiskStamp] = [:]

    private func load(_ directory: String) {
        if let remote {
            remote(.files(path: directory))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = FileBrowser.list(directory)
            DispatchQueue.main.async {
                guard let self, self.root != nil else { return }
                if self.children[directory] != entries { self.children[directory] = entries }
            }
        }
    }

    // MARK: Documents

    nonisolated private static func load(_ path: String, anyway: Bool = false) -> OpenDocument {
        let content = FileBrowser.read(path, anyway: anyway)
        var text = ""
        if case .text(let loaded) = content { text = loaded }
        return OpenDocument(path: path, content: content, text: text, savedText: text)
    }

    /// Shows a file in the middle pane, opening a tab for it if it has none.
    /// The line each file was last asked to be shown at (#45).
    @Published private(set) var lineTargets: [String: LineTarget] = [:]
    private var lineTokens = 0

    /// Opens a file at a line: the editor scrolls to it and marks it.
    func open(_ path: String, line: Int) {
        lineTokens += 1
        lineTargets[path] = LineTarget(line: line, token: lineTokens)
        open(path)
    }

    func open(_ path: String) {
        if !documents.contains(where: { $0.path == path }) {
            if isRemote {
                documents.append(OpenDocument(path: path, content: .text(""), text: "", savedText: "", isLoading: true))
                read(path)
            } else {
                documents.append(Self.load(path))
            }
            rememberOpenFiles()
        }
        active = path
    }

    /// Closes a file's tab, asking first when it has unsaved changes.
    func requestClose(_ path: String) {
        guard let document = documents.first(where: { $0.path == path }) else { return }
        if document.isDirty {
            active = path
            pendingClose = path
        } else {
            close(path)
        }
    }

    func close(_ path: String) {
        pendingClose = nil
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        documents.remove(at: index)
        if active == path {
            // The tab that takes its place, or the terminal when it was the last file.
            active = documents.indices.contains(index) ? documents[index].path : documents.last?.path
        }
        rememberOpenFiles()
    }

    /// Closes every file's tab but the one given. A file with unsaved
    /// changes stays open, and the first of them asks what to do with it.
    /// `keeping` names files that stay open whatever else is closed.
    func closeAll(except kept: String? = nil, keeping: Set<String> = []) {
        for document in documents where document.path != kept && !keeping.contains(document.path) && !document.isDirty {
            close(document.path)
        }
        if let unsaved = documents.first(where: { $0.path != kept && !keeping.contains($0.path) && $0.isDirty }) {
            requestClose(unsaved.path)
        } else if let kept, active != nil {
            active = kept
        }
    }

    @discardableResult
    func save(_ path: String? = nil) -> Bool {
        guard let path = path ?? active, let index = documents.firstIndex(where: { $0.path == path }), documents[index].isDirty else { return true }
        if let remote {
            guard isOnline else {
                error = "The other Mac is not connected, so the file could not be saved. Its changes are kept: save again once it is back."
                return false
            }
            // One write at a time: two on their way could be done in either order.
            if saving[path] != nil {
                saveAgain.insert(path)
                return true
            }
            // Not saved until the other Mac says so. If it cannot write
            // the file it says that instead, and the changes stay changes.
            saving[path] = documents[index].text
            if readsDue[path] != nil { staleReads.insert(path) }
            remote(.writeFile(path: path, text: documents[index].text))
            return true
        }
        do {
            let text = documents[index].text
            try FileBrowser.write(text, to: path)
            documents[index].wasSaved(as: text)
            return true
        } catch {
            self.error = "\(error)"
            return false
        }
    }

    /// Saves a file and closes its tab. A file on another Mac closes once
    /// that Mac has it: if it cannot be saved, it stays open with its changes.
    func saveAndClose(_ path: String, closing: Bool = true) {
        guard save(path) else { return }
        guard closing else { return }
        if isRemote, documents.first(where: { $0.path == path })?.isDirty == true {
            pendingClose = nil
            closeWhenSaved.insert(path)
        } else {
            close(path)
        }
    }

    func discardChanges(_ path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }), documents[index].isDirty else { return }
        documents[index].revert()
    }

    /// The editor's text after a change in it. No view is told of it,
    /// unless it is the change that makes the file differ from the disk's,
    /// or no longer differ (#104).
    func setText(_ text: String, for path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        let document = documents[index]
        document.edited.text = text
        let dirty = document.differs
        if dirty != document.isDirty { documents[index].isDirty = dirty }
    }

    private func rememberOpenFiles() {
        // Only this Mac's: another Mac's files are not here to come back to.
        guard !isRemote else { return }
        UserDefaults.standard.set(documents.map(\.path), forKey: Self.openFilesKey)
    }

    // MARK: Changing files

    func createFile(named name: String, in directory: String) {
        if let remote {
            remote(.createFile(directory: directory, name: name, isDirectory: false))
            return
        }
        perform {
            let path = try FileBrowser.createFile(named: name, in: directory)
            self.reveal(directory)
            self.open(path)
        }
    }

    func createFolder(named name: String, in directory: String) {
        if let remote {
            remote(.createFile(directory: directory, name: name, isDirectory: true))
            return
        }
        perform {
            let path = try FileBrowser.createFolder(named: name, in: directory)
            self.reveal(directory)
            self.expanded.insert(path)
        }
    }

    func rename(_ entry: FileEntry, to name: String) {
        perform {
            if let remote {
                // Where it will be, if the other Mac takes the name: it
                // answers with the folder as it is then, and only then do
                // the open files move (#305). Refused, nothing moved.
                let target = ((entry.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
                guard target != entry.path else { return }
                self.renamesDue[entry.path] = target
                remote(.renameFile(path: entry.path, name: name))
                return
            }
            self.moved(entry.path, to: try FileBrowser.rename(entry.path, to: name))
        }
    }

    /// Renames asked of another Mac and not answered yet: by the old path,
    /// where it is to be.
    private var renamesDue: [String: String] = [:]

    /// What was open or expanded under a path that was renamed moves with it.
    private func moved(_ path: String, to target: String) {
        guard target != path else { return }
        func under(_ old: String) -> Bool { old == path || old.hasPrefix(path + "/") }
        for index in documents.indices where under(documents[index].path) {
            let old = documents[index].path
            let moved = target + old.dropFirst(path.count)
            documents[index].path = moved
            if active == old { active = moved }
        }
        rememberOpenFiles()
        expanded = Set(expanded.map { under($0) ? target + $0.dropFirst(path.count) : $0 })
        children = [:]
        refresh()
    }

    func trash(_ entry: FileEntry) {
        // Its unsaved changes would go with it, without a word (#305).
        if let unsaved = documents.first(where: { ($0.path == entry.path || $0.path.hasPrefix(entry.path + "/")) && $0.isDirty }) {
            error = "Save or discard the changes in \((unsaved.path as NSString).lastPathComponent) before putting it in the Trash."
            return
        }
        perform {
            if let remote { remote(.trashFile(path: entry.path)) } else { try FileBrowser.trash(entry.path) }
            for document in self.documents where document.path == entry.path || document.path.hasPrefix(entry.path + "/") {
                self.close(document.path)
            }
            self.expanded.remove(entry.path)
            self.refresh()
        }
    }

    private func reveal(_ directory: String) {
        if directory != root { expanded.insert(directory) }
        refresh()
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            self.error = "\(error)"
        }
    }
}
