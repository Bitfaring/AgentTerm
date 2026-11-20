import Highlightr
import MarkdownUI
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

/// Names highlight.js knows, by file name. Anything else is shown as plain text.
public enum FileLanguage {
    private static let byExtension: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python", "pyi": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala", "groovy": "groovy", "gradle": "gradle",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php", "dart": "dart", "lua": "lua", "luau": "lua",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ps1": "powershell",
        "json": "json", "jsonc": "json", "jsonl": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
        "xml": "xml", "plist": "xml", "svg": "xml", "html": "xml", "htm": "xml", "vue": "xml", "xib": "xml", "storyboard": "xml",
        "css": "css", "scss": "scss", "less": "less", "sql": "sql", "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "r": "r", "pl": "perl", "tex": "latex", "diff": "diff", "patch": "diff", "proto": "protobuf", "graphql": "graphql",
        "cmake": "cmake", "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell", "clj": "clojure", "nim": "nim", "zig": "zig",
    ]
    private static let byName: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", "cmakelists.txt": "cmake", "gemfile": "ruby", "podfile": "ruby",
        "rakefile": "ruby", ".zshrc": "bash", ".bashrc": "bash", ".profile": "bash", ".env": "bash", ".gitignore": "bash",
        "package.swift": "swift",
    ]

    public static func forFile(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        return byName[name] ?? byExtension[(name as NSString).pathExtension] ?? "plaintext"
    }

    public static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A file that is one Mermaid diagram.
    public static func isMermaid(_ path: String) -> Bool {
        ["mmd", "mermaid"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// Colors the editor and the previews share: the terminal's background, so a
/// file next to a terminal does not look like another app.
public enum EditorStyle {
    public static let background = PlatformColor(red: 0.075, green: 0.078, blue: 0.098, alpha: 1)
    public static let text = PlatformColor(white: 0.86, alpha: 1)
}

/// One highlighter for the app: it loads highlight.js into a JavaScript
/// context, which is not worth doing per file.
@MainActor
enum Highlighting {
    nonisolated static let theme = "atom-one-dark"

    static let shared: Highlightr? = {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: theme)
        return highlightr
    }()

    static func font(size: CGFloat) -> PlatformFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// The largest text that is colored, in UTF-16 units: about half a
    /// megabyte. Coloring a file of 5 MB held the window for five seconds
    /// when it opened, and a quarter of a second at each key (#21).
    static let largestColored = 512 * 1024

    /// Whether a file's text is colored: one in a language the highlighter
    /// knows, and not too large.
    static func colors(_ path: String, length: Int) -> Bool {
        length <= largestColored && FileLanguage.forFile(path) != "plaintext"
    }

    /// Text storage that recolors what is edited; a plain one for text
    /// that is not colored, or if the highlighter could not be loaded.
    static func storage(for path: String, fontSize: CGFloat, length: Int) -> NSTextStorage {
        guard colors(path, length: length), let highlightr = shared else { return NSTextStorage() }
        highlightr.theme.setCodeFont(font(size: fontSize))
        let highlighted = CodeAttributedString(highlightr: highlightr)
        highlighted.language = FileLanguage.forFile(path)
        return highlighted
    }

    /// Gives a layout the storage that fits the text it is about to show,
    /// when the one it has does not (#50): the text came after the editor
    /// was made, as on the iPhone, or another file was opened in it, and
    /// is too large to color, or is small enough now. Called before the
    /// text is set, which the new storage then holds.
    static func fit(_ layout: NSLayoutManager, path: String, fontSize: CGFloat, length: Int) {
        guard let current = layout.textStorage else { return }
        let wanted = colors(path, length: length) ? FileLanguage.forFile(path) : nil
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard (current is CodeAttributedString) != (wanted != nil && shared != nil) else {
            // Told again only when it changed: each time it is told, all of it is colored again.
            if let coloring = current as? CodeAttributedString, coloring.language != wanted { coloring.language = wanted }
            return
        }
        layout.replaceTextStorage(storage(for: path, fontSize: fontSize, length: length))
        #else
        // UIKit's layout manager cannot be given another storage: the
        // editor's colors when it has a language, and does nothing more
        // than a plain one without (`editableStorage`).
        if let coloring = current as? CodeAttributedString, coloring.language != wanted { coloring.language = wanted }
        #endif
    }

    #if !(canImport(AppKit) && !targetEnvironment(macCatalyst))
    /// The iPhone's editor's storage: one that colors, with no language for
    /// a text that is not colored, so that `fit` can turn its colors on
    /// and off as the text that comes changes; a plain one if the
    /// highlighter could not be loaded.
    static func editableStorage(for path: String, fontSize: CGFloat, length: Int) -> NSTextStorage {
        guard let highlightr = shared else { return NSTextStorage() }
        highlightr.theme.setCodeFont(font(size: fontSize))
        let highlighted = CodeAttributedString(highlightr: highlightr)
        highlighted.language = colors(path, length: length) ? FileLanguage.forFile(path) : nil
        return highlighted
    }
    #endif
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// The line breaks of a text, as the layout makes lines of it. Tried on
/// macOS 27.2 with the editor's font, lines not wrapped: a line feed, a
/// carriage return (with a line feed after it, one break), a vertical tab,
/// a form feed, U+0085, U+2028 and U+2029 each start a new line, and a text
/// has one line more than it has breaks, an empty one after a break at its
/// end.
enum LineBreaks {
    static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    /// Those of part of a text, unit by unit: for the few about a change.
    static func count(in text: NSString, range: NSRange) -> Int {
        var count = 0
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = text.character(at: index)
            // A carriage return and the line feed after it are one break.
            if unit == 0x0D, index + 1 < end, text.character(at: index + 1) == 0x0A { index += 1 }
            if isBreak(unit) { count += 1 }
            index += 1
        }
        return count
    }

    /// Those of a whole text, and its longest line's length, by
    /// Foundation's own search for line ends: about 16 ms for 5 MB, where
    /// a loop over its units takes 390 ms in a build that is not optimized.
    /// Foundation leaves out the vertical tab and the form feed; `odd`
    /// counts those too, 14 ms more, which is done off the main thread.
    static func measure(_ text: NSString, odd: Bool) -> (breaks: Int, longest: Int) {
        var breaks = 0
        var longest = 0
        var at = 0
        let length = text.length
        while at < length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
            longest = max(longest, contentsEnd - start)
            if end > contentsEnd { breaks += 1 }
            at = end
        }
        guard odd else { return (breaks, longest) }
        let others = CharacterSet(charactersIn: "\u{0B}\u{0C}")
        var from = 0
        while from < length {
            let found = text.rangeOfCharacter(from: others, options: [], range: NSRange(location: from, length: length - from))
            guard found.location != NSNotFound else { break }
            breaks += 1
            from = NSMaxRange(found)
        }
        return (breaks, longest)
    }
}

/// The editor's text view. A large file's (#104) is not resized by AppKit:
/// for that AppKit works out the room the whole text takes again at each
/// key (`usedRectForTextContainer`, which goes through every line laid
/// out), a frame or more for a file of 5 MB. It sizes itself.
///
/// Its lines are not wrapped, each is one line of the layout (`paragraphs`),
/// and all are of one height whatever is on them (tried with Vietnamese,
/// Chinese and Japanese, emoji and tabs: 15 points each at 12.5), so its
/// height is its lines' count times that. The count is
/// taken when the text is given, follows each change by the breaks about
/// where it was made, and is taken again off the main thread a second after
/// the last change: should a change have been missed, it is put right then.
///
/// Its width is its longest line's, taken as so many letters of the font,
/// and is made wider by any line on show, or typed in, that is wider than
/// that: a tab and a wide letter take more room than a letter of the
/// font, and how much is read from the layout made to show the line.
final class EditorTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        KeyboardTargets.arrived(self)
    }

    /// From this length, in UTF-16 units, the view sizes itself.
    static let selfSizedFrom = 1024 * 1024
    /// The longest change whose breaks are counted unit by unit as it is
    /// made; for a longer one the whole text is counted again.
    static let largestCounted = 16 * 1024

    private(set) var selfSized = false
    /// The text's lines: its breaks and one.
    private(set) var lines = 1
    /// How far right the widest line known goes, in the text container.
    private var widest: CGFloat = 0

    /// A change about to be made to the text.
    private enum Change {
        /// None to its characters.
        case none
        /// One counted here: the units about it, and their breaks before it.
        case counted(around: NSRange, breaks: Int, grows: Int)
        /// One too long to count here, or several at once.
        case uncounted
    }
    private var change = Change.none
    /// Goes up with every change, for a count made off the main thread to
    /// be of the text as it still is.
    private var changes = 0
    private var check: DispatchWorkItem?
    /// What the lines on show were last measured for: the part of the view
    /// on show, and the text as it was. Measuring them takes 1 to 3 ms, and
    /// the view is drawn again for more than a change of either.
    private var measured: (shown: NSRect, changes: Int)?

    /// Every line's paragraph style: tabs at AppKit's own distance, with no
    /// end to them. AppKit's own style has twelve tab stops and none after,
    /// and the layout breaks a line at its thirteenth tab (tried on macOS
    /// 27.2: thirty tabs and a word were three lines, #132), in an editor
    /// whose lines are not wrapped. A text without the style as an attribute
    /// is laid out with AppKit's own, whatever the view's default is.
    static let paragraphs: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = 28
        return style
    }()

    /// Sizes for a whole new text, which the view was just given.
    func fit() {
        // Whatever storage holds it now: `Highlighting.fit` may have given
        // the layout another.
        if let storage = textStorage, storage.delegate !== self {
            storage.delegate = self
            storage.addAttribute(.paragraphStyle, value: Self.paragraphs, range: NSRange(location: 0, length: storage.length))
        }
        let was = selfSized
        selfSized = (textStorage?.length ?? 0) >= Self.selfSizedFrom
        isVerticallyResizable = !selfSized
        isHorizontallyResizable = !selfSized
        change = .none
        changes += 1
        measured = nil
        check?.cancel()
        guard selfSized, let text = whole() else {
            // AppKit's own sizing again, after a text that was large.
            if was { sizeToFit() }
            return
        }
        let found = LineBreaks.measure(text, odd: false)
        lines = found.breaks + 1
        widest = CGFloat(found.longest) * characterWidth + 2 * (textContainer?.lineFragmentPadding ?? 0)
        resize()
        // With its vertical tabs and form feeds, if it has any.
        countAgain(text)
    }

    /// The whole text as it is now, apart from the storage: its line ends
    /// are found three times as fast in it as through the storage (7 ms
    /// and 20 for 5 MB, the copy 4), and it can be read off the main thread.
    private func whole() -> NSString? { textStorage?.mutableString.copy() as? NSString }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        change = .none
        // Without strings it is a change of attributes: the lines stay.
        guard selfSized, let replacementStrings, let text = textStorage?.mutableString else { return true }
        change = .uncounted
        if affectedRanges.count == 1, replacementStrings.count == 1 {
            let range = affectedRanges[0].rangeValue
            let given = (replacementStrings[0] as NSString).length
            if range.length <= Self.largestCounted, given <= Self.largestCounted {
                // One unit more on each side: a carriage return and a line
                // feed that the change parts, or brings together, are both
                // in what is counted before it and after.
                let from = max(range.location - 1, 0)
                let around = NSRange(location: from, length: min(NSMaxRange(range) + 1, text.length) - from)
                change = .counted(around: around, breaks: LineBreaks.count(in: text, range: around), grows: given - range.length)
            }
        }
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        guard selfSized else { return }
        let made = change
        change = .none
        changes += 1
        let before = frame.size
        switch made {
        case .counted(let around, let breaks, let grows):
            let text: NSString = textStorage?.mutableString ?? ""
            let now = NSRange(location: around.location, length: around.length + grows)
            if now.length >= 0, NSMaxRange(now) <= text.length {
                lines = max(1, lines + LineBreaks.count(in: text, range: now) - breaks)
            } else {
                lines = LineBreaks.measure(whole() ?? "", odd: true).breaks + 1
            }
        case .uncounted:
            lines = LineBreaks.measure(whole() ?? "", odd: true).breaks + 1
        case .none:
            break
        }
        widenToInsertionPoint()
        resize()
        // The insertion point may be past where the room ended.
        if frame.size != before { scrollRangeToVisible(selectedRange()) }
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let text = self.whole() else { return }
            self.countAgain(text)
        }
        check = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        guard selfSized else { return }
        let shown = visibleRect
        if measured?.shown != shown || measured?.changes != changes {
            measured = (shown, changes)
            widenToShown()
        }
        // And the window's own size may have changed.
        resize()
    }

    /// Counts the whole text again, off the main thread, and takes the
    /// count if the text is still the one counted: `text`, as it is now.
    private func countAgain(_ text: NSString) {
        check = nil
        guard selfSized else { return }
        let counted = changes
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LineBreaks.measure(text, odd: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selfSized, self.changes == counted else { return }
                self.lines = found.breaks + 1
                self.resize()
            }
        }
    }

    private var characterWidth: CGFloat { (font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)).maximumAdvancement.width }

    private var lineHeight: CGFloat {
        guard let layout = layoutManager, let font else { return 16 }
        return layout.defaultLineHeight(for: font)
    }

    /// The lines on show, measured: the room is made as wide as the widest.
    private func widenToShown() {
        guard let layout = layoutManager, let container = textContainer, (textStorage?.length ?? 0) > 0 else { return }
        let origin = textContainerOrigin
        let shown = layout.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        layout.enumerateLineFragments(forGlyphRange: shown) { _, used, _, _, _ in
            self.widest = max(self.widest, used.maxX)
        }
    }

    /// The line the insertion point is on, measured: it may have grown
    /// wider than the room.
    private func widenToInsertionPoint() {
        guard let layout = layoutManager, let length = textStorage?.length, length > 0 else { return }
        let glyph = layout.glyphIndexForCharacter(at: min(selectedRange().location, length - 1))
        widest = max(widest, layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX)
    }

    private func resize() {
        let inset = textContainerInset
        let room = enclosingScrollView?.contentSize ?? .zero
        let size = NSSize(width: max(widest + 2 * inset.width, room.width), height: max(CGFloat(lines) * lineHeight + 2 * inset.height, room.height))
        if frame.size != size { setFrameSize(size) }
    }
}

extension EditorTextView: NSTextStorageDelegate {
    /// What was just put in, or given attributes, keeps the lines'
    /// paragraph style: what is typed at the end of a text comes with
    /// AppKit's own, and a storage that colors gives what it colored
    /// attributes that have none.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedRange.location != NSNotFound, editedRange.length > 0, NSMaxRange(editedRange) <= textStorage.length else { return }
        var same = NSRange(location: 0, length: 0)
        let style = textStorage.attribute(.paragraphStyle, at: editedRange.location, longestEffectiveRange: &same, in: editedRange) as? NSParagraphStyle
        if style != Self.paragraphs || NSMaxRange(same) < NSMaxRange(editedRange) {
            textStorage.addAttribute(.paragraphStyle, value: Self.paragraphs, range: editedRange)
        }
    }
}

/// The text views on show that the keyboard can be given to: a file's
/// editor, a diff. Picked by number or by the shortcuts that move by one
/// (#171), the one in front gets the keyboard, as a terminal does.
@MainActor public enum KeyboardTargets {
    private static let views = NSMapTable<NSString, NSView>.strongToWeakObjects()

    public static func file(_ path: String) -> String { "file:" + path }
    public static func diff(_ id: String) -> String { "diff:" + id }

    /// The key asked for whose view was not in a window yet: a file's
    /// editor is made again when its file is picked, after it is asked for.
    private static var pending: String?

    /// A view made for a key. One asked for before it was made gets the
    /// keyboard once SwiftUI has put it in the window, right after.
    public static func register(_ view: NSView, as key: String) {
        views.setObject(view, forKey: key as NSString)
        guard pending == key else { return }
        DispatchQueue.main.async { if pending == key { focus(key) } }
    }

    /// Gives the keyboard to the view of that key, now or once it is made.
    @discardableResult public static func focus(_ key: String) -> Bool {
        guard let view = views.object(forKey: key as NSString), let window = view.window else {
            pending = key
            return false
        }
        pending = nil
        return window.firstResponder === view || window.makeFirstResponder(view)
    }

    /// The keyboard went elsewhere: nothing waits for it any more.
    public static func cancel() { pending = nil }

    /// A view put in a window. One is registered when it is made, before
    /// SwiftUI puts it in the window: the keyboard asked for in between
    /// waited for it, and nothing gave it once it was there, now and then
    /// (#184). Its views call this as they move into a window.
    public static func arrived(_ view: NSView) {
        guard let key = pending, view.window != nil, views.object(forKey: key as NSString) === view else { return }
        focus(key)
    }
}

/// A plain text editor with syntax coloring.
public struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// What the text belongs to. A change means another file was opened.
    let path: String
    var fontSize: CGFloat

    /// The line to show, when one was asked for.
    var target: LineTarget?

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 12.5, target: LineTarget? = nil) {
        _text = text
        self.path = path
        self.fontSize = fontSize
        self.target = target
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let storage = Highlighting.storage(for: path, fontSize: fontSize, length: text.utf16.count)
        let layout = NSLayoutManager()
        // Only what is on show is laid out: a file of megabytes opens at once.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        // Lines are not wrapped: code reads better scrolled sideways.
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Highlighting.font(size: fontSize)
        textView.textColor = EditorStyle.text
        textView.backgroundColor = EditorStyle.background
        textView.insertionPointColor = .white
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        // Code is not prose: none of the typing aids.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // No text checking at all, links and data included: left on, the
        // first file opened started the spelling checker on the main
        // thread, about 25 ms (#178).
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorStyle.background
        // In its scroll view, whose room it fills at least.
        textView.fit()
        context.coordinator.textView = textView
        context.coordinator.path = path
        context.coordinator.held = text
        context.coordinator.go(to: target)
        KeyboardTargets.register(textView, as: KeyboardTargets.file(path))
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.path != path {
            // Another file: its own language, colored or not by its own
            // size, and no undo into the last one.
            context.coordinator.path = path
            if let layout = textView.layoutManager { Highlighting.fit(layout, path: path, fontSize: fontSize, length: text.utf16.count) }
            textView.string = text
            (textView as? EditorTextView)?.fit()
            context.coordinator.held = text
            textView.undoManager?.removeAllActions()
            textView.scrollToBeginningOfDocument(nil)
        } else if context.coordinator.held != text {
            // Changed from outside the editor, such as discarding edits, or
            // the file read after the editor was made. Told by what the
            // editor last gave or was given, which is the same text in
            // memory when nothing changed: asking the view for all of its
            // text at each key is what made typing in a large file slow.
            context.coordinator.held = text
            if let layout = textView.layoutManager { Highlighting.fit(layout, path: path, fontSize: fontSize, length: text.utf16.count) }
            if textView.string != text {
                textView.string = text
                (textView as? EditorTextView)?.fit()
            }
        }
        context.coordinator.go(to: target)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var path = ""
        /// The text the editor last gave its owner, or was given by it.
        var held = ""
        private var shown: Int?

        /// Scrolls to a line and marks it, once for each time it is asked
        /// for; after the view was laid out, which it is not yet when made.
        func go(to target: LineTarget?) {
            guard let target, target.token != shown, textView?.string.isEmpty == false else { return }
            shown = target.token
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView else { return }
                let range = LineTarget.range(ofLine: target.line, in: textView.string as NSString)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
            }
        }

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // What the view holds now, kept as the one text both sides
            // have: the view is not asked for it again, nor compared with
            // it, when this change comes back round as an update (#21).
            let now = textView.string
            held = now
            parent.text = now
        }
    }
}
#else
/// A plain text editor with syntax coloring.
public struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    /// What the text belongs to. A change means another file was opened.
    let path: String
    var fontSize: CGFloat

    /// The line to show, when one was asked for.
    var target: LineTarget?

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 13, target: LineTarget? = nil) {
        _text = text
        self.path = path
        self.fontSize = fontSize
        self.target = target
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> UITextView {
        // Made before the file's text is here: colored or not once it is (`Highlighting.fit`).
        let storage = Highlighting.editableStorage(for: path, fontSize: fontSize, length: text.utf16.count)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // Lines wrap: a phone is too narrow to scroll code sideways while typing.
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.font = Highlighting.font(size: fontSize)
        textView.textColor = EditorStyle.text
        textView.backgroundColor = EditorStyle.background
        textView.tintColor = .white
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.keyboardAppearance = .dark
        // Code is not prose: none of the typing aids.
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityIdentifier = "code-editor"
        textView.text = text
        context.coordinator.path = path
        // A bar above the keyboard with a button that hides it: a phone's
        // keyboard has no key for that, and it covers half of the file.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let hide = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: textView,
            action: #selector(UIResponder.resignFirstResponder))
        hide.accessibilityLabel = "Hide Keyboard"
        hide.accessibilityIdentifier = "hide-keyboard"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), hide]
        bar.sizeToFit()
        textView.inputAccessoryView = bar
        context.coordinator.go(to: target, in: textView)
        return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.path != path {
            // Another file: colored or not by its own size.
            context.coordinator.path = path
            Highlighting.fit(textView.layoutManager, path: path, fontSize: fontSize, length: text.utf16.count)
            textView.text = text
            textView.undoManager?.removeAllActions()
            textView.setContentOffset(.zero, animated: false)
        } else if textView.text != text, textView.markedTextRange == nil {
            // Changed from outside the editor, such as discarding edits, or
            // the file, which is read after the editor is shown: colored or
            // not by its size (#50). Not while a character is being
            // composed, which this would break.
            Highlighting.fit(textView.layoutManager, path: path, fontSize: fontSize, length: text.utf16.count)
            textView.text = text
        }
        context.coordinator.go(to: target, in: textView)
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var path = ""
        private var shown: Int?

        /// Scrolls to a line and selects it, once for each time it is asked
        /// for, and not before the file's text is there.
        func go(to target: LineTarget?, in textView: UITextView) {
            guard let target, target.token != shown, !textView.text.isEmpty else { return }
            shown = target.token
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                let range = LineTarget.range(ofLine: target.line, in: textView.text as NSString)
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
            }
        }

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        public func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }
    }
}
#endif

/// Colors code blocks in a Markdown preview with the editor's highlighter.
struct PreviewCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        // SwiftUI builds views on the main thread, where the highlighter lives.
        let attributed = MainActor.assumeIsolated { () -> AttributedString? in
            guard let highlightr = Highlighting.shared else { return nil }
            let name = language?.lowercased()
            let known = name.flatMap { highlightr.supportedLanguages().contains($0) ? $0 : nil }
            guard let highlighted = highlightr.highlight(code, as: known ?? "plaintext") else { return nil }
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return try? AttributedString(highlighted, including: \.appKit)
            #else
            return try? AttributedString(highlighted, including: \.uiKit)
            #endif
        }
        return attributed.map { Text($0) } ?? Text(code)
    }
}

/// MarkdownUI's look for Markdown shown in place (`MarkdownText`): the
/// preview of a file is a web page since #126 (`MarkdownPreview`).
enum MarkdownLook {
    /// GitHub's look, with code blocks marked "mermaid" drawn as diagrams.
    static let theme = MarkdownUI.Theme.gitHub
        .text { BackgroundColor(nil) }
        .codeBlock { configuration in
            if configuration.language?.lowercased() == "mermaid" {
                MermaidView(code: configuration.content)
                    .markdownMargin(top: 0, bottom: 16)
            } else {
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.225))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                        }
                        .padding(14)
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 16)
            }
        }

}

/// Markdown shown in place among other things, as the preview of a file
/// shows it but without a scroll view of its own: what an agent said in a
/// transcript (#50), at the size of the text around it.
public struct MarkdownText: View {
    let text: String
    let size: CGFloat

    public init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Markdown(MarkdownHTML.flatten(text))
            .markdownTheme(MarkdownLook.theme)
            .markdownTextStyle {
                FontSize(size)
                BackgroundColor(nil)
            }
            .markdownCodeSyntaxHighlighter(PreviewCodeHighlighter())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line of the file to go to (#45): the editor scrolls to it and marks
/// it. `token` changes each time one is asked for, the same line too.
public struct LineTarget: Equatable, Sendable {
    public var line: Int
    public var token: Int

    public init(line: Int, token: Int) {
        self.line = line
        self.token = token
    }

    /// Where a line is in a text, by its number from 1; the last line for
    /// a number past the end.
    public static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var start = 0
        var current = 1
        while current < line, start < text.length {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            guard NSMaxRange(range) > start, NSMaxRange(range) < text.length else { break }
            start = NSMaxRange(range)
            current += 1
        }
        var range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        // Without the line break at its end.
        while range.length > 0, let last = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(last) { range.length -= 1 }
        return range
    }
}
