#if os(macOS)
import AgentTermProtocol
import AppKit
import SwiftTerm

/// The Mac's terminal, which takes files as Terminal.app does (#160): a
/// file dropped on it, or copied in the Finder and pasted, has its path
/// typed into the session, quoted for the shell, as a paste, not
/// submitted. A picture on the clipboard, a screenshot say, is not a file:
/// ⌘V sends Control V, with which an agent such as Claude Code takes the
/// clipboard's picture itself. Nothing is saved.
public final class FileTakingTerminalView: TerminalView {
    /// Says why nothing was typed, where nothing else would.
    public var refused: ((String) -> Void)?
    /// Whether this Mac's files and clipboard mean anything to the session:
    /// not to another Mac's, whose agent would read that Mac's.
    public var takesFiles = true

    public override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Pasting

    public override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        // Files copied in the Finder: their paths, rather than their names.
        let files = Self.fileURLs(on: board)
        if !files.isEmpty { return take(files: files) }
        // A picture and no text: the agent takes it from the clipboard.
        if board.string(forType: .string) == nil, board.availableType(from: [.png, .tiff]) != nil {
            guard takesFiles else { return refused?(Self.notHere) ?? () }
            return terminalDelegate?.send(source: self, data: [0x16][...]) ?? ()
        }
        super.paste(sender)
    }

    // MARK: Dropping

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = Self.fileURLs(on: sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        take(files: files)
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Typing them in

    private func take(files: [URL]) {
        guard takesFiles else { return refused?(Self.notHere) ?? () }
        type(paths: files.map(\.path))
    }

    /// The paths, quoted, a space after each, as a paste: what the program
    /// asked for (bracketed) is kept.
    private func type(paths: [String]) {
        let text = paths.map(Self.quoted).joined(separator: " ") + " "
        let bracketed = terminalInputStateSnapshot()?.bracketedPasteMode ?? false
        let bytes = Array(SentText.text(text, bracketedPaste: bracketed).utf8)
        terminalDelegate?.send(source: self, data: bytes[...])
    }

    /// Why nothing is given to another Mac's session.
    public static let notHere =
        "Files and pictures are given to a session of this Mac only: on another Mac, its agent would look for them on that Mac."

    /// Quoted for a POSIX shell when it has to be, as Terminal.app does.
    static func quoted(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,@%:"))
        if path.unicodeScalars.allSatisfy({ plain.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func fileURLs(on board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
#endif
