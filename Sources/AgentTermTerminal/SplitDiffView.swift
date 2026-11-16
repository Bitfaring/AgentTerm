import AgentTermProtocol
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file's diff as two panels: what it was on the left, what it is now on
/// the right, changed lines facing each other. The two panels scroll down
/// together and sideways each on its own. Shared by the Mac and the iPhone.
///
/// Each panel is one text view (#82), as the Mac's one-panel diff is
/// (`PatchView`, #21): rows of views held the window up for 60 ms at each
/// step of scrolling a diff of 20,000 lines, and only the first 2,500 rows
/// were shown. A text view lays out only what is on show. Every row is one
/// line of one height on both sides, never wrapped, so that the panels
/// scrolled to the same height show the same rows; a line's number and its
/// tint are drawn by the layout, not put in its text, so that what is
/// selected and copied is the file's own.
public struct SplitDiffView: View {
    private let patch: String
    private let fontSize: CGFloat

    public init(patch: String, fontSize: CGFloat = 11.5) {
        self.patch = patch
        self.fontSize = fontSize
    }

    public var body: some View {
        SplitDiffPanels(patch: patch, fontSize: fontSize)
    }
}

// MARK: The texts

/// The two panels' texts, worked out from a patch off the main thread.
struct SplitDiffTexts: @unchecked Sendable {
    let left: NSAttributedString
    let right: NSAttributedString
    /// How many rows each side has.
    let rows: Int
    /// How wide each side's longest line is, its number with it.
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    /// Where the lines start, after their numbers.
    let gutter: CGFloat

    /// A line's number in its file, drawn before it.
    static let number = NSAttributedString.Key("agentterm.splitDiffNumber")
    /// A line's tint, drawn across the whole panel.
    static let tint = NSAttributedString.Key("agentterm.splitDiffTint")

    static let added = PlatformColor(red: 0.36, green: 0.80, blue: 0.52, alpha: 1)
    static let removed = PlatformColor(red: 0.96, green: 0.45, blue: 0.47, alpha: 1)
    static let hunk = PlatformColor(red: 0.55, green: 0.67, blue: 0.98, alpha: 1)
    static let same = PlatformColor(white: 1, alpha: 0.75)

    static func font(_ size: CGFloat) -> PlatformFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func rowHeight(_ size: CGFloat) -> CGFloat { (size * 1.45).rounded() }

    /// - Parameters:
    ///   - advance: How wide a character of the font is, measured on the
    ///     main thread.
    ///   - lineHeight: The font's own line height, measured there too.
    init(patch: String, fontSize: CGFloat, advance: CGFloat, lineHeight: CGFloat) {
        // Tabs as four blanks: a diff's lines start with a mark, which
        // would put every tab stop one off.
        let all = SplitDiff.rows(for: patch.replacingOccurrences(of: "\t", with: "    "))
        rows = all.count
        let font = Self.font(fontSize)
        let height = Self.rowHeight(fontSize)
        let digits = max(3, String(all.reduce(0) { max($0, $1.left?.number ?? 0, $1.right?.number ?? 0) }).count)
        let gutter = Self.gutter(digits: digits, advance: advance)
        self.gutter = gutter
        func paragraph(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            // Never wrapped: a row is one line on both sides, or they would
            // stop facing each other.
            style.lineBreakMode = .byClipping
            return style
        }
        let base: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: max(0, (height - lineHeight) / 2)]
        let numbered = base.merging([.paragraphStyle: paragraph(indent: gutter)]) { $1 }
        let header = base.merging([.paragraphStyle: paragraph(indent: 8), .foregroundColor: Self.hunk, Self.tint: PlatformColor(white: 1, alpha: 0.04)]) { $1 }
        // Nothing on this side where the other has a line: hatched in other
        // tools, here dimmer than the page.
        let missing = numbered.merging([Self.tint: PlatformColor(white: 0, alpha: 0.18)]) { $1 }

        func side(_ line: KeyPath<SplitDiffRow, SplitDiffRow.Line?>, tint: PlatformColor, hunks: Bool) -> (NSAttributedString, CGFloat) {
            let text = NSMutableAttributedString()
            var longest = 0
            text.beginEditing()
            for row in all {
                if let hunk = row.hunk {
                    // The header is said once, on the left; the right keeps the row.
                    text.append(NSAttributedString(string: (hunks ? hunk : "") + "\n", attributes: header))
                    if hunks { longest = max(longest, Self.columns(hunk) + 1) }
                } else if let line = row[keyPath: line] {
                    var attributes = numbered
                    attributes[Self.number] = line.number
                    attributes[.foregroundColor] = line.changed ? tint : Self.same
                    if line.changed { attributes[Self.tint] = tint.withAlphaComponent(0.11) }
                    text.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
                    longest = max(longest, Self.columns(line.text) + Int((gutter / advance).rounded(.up)))
                } else {
                    text.append(NSAttributedString(string: "\n", attributes: missing))
                }
            }
            text.endEditing()
            return (text, CGFloat(longest + 2) * advance)
        }
        (left, leftWidth) = side(\.left, tint: Self.removed, hunks: true)
        (right, rightWidth) = side(\.right, tint: Self.added, hunks: false)
    }

    /// Room for the numbers before the lines.
    static func gutter(digits: Int, advance: CGFloat) -> CGFloat { CGFloat(digits) * advance + 14 }

    /// How many columns a line takes: two for a wide character, so that a
    /// line of them is not cut short.
    static func columns(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
    }

    /// How wide a character of the font is, and its line height: measured
    /// on the main thread, where text is measured.
    static func metrics(_ fontSize: CGFloat) -> (advance: CGFloat, lineHeight: CGFloat) {
        let font = font(fontSize)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        return (advance, NSLayoutManager().defaultLineHeight(for: font))
    }
}

/// Draws each line's tint across the whole panel, behind its text, and its
/// number before it: neither is in the text.
final class SplitDiffLayout: NSLayoutManager {
    var numberFontSize: CGFloat = 10.5
    /// Where the numbers end, from the line's left edge.
    var gutter: CGFloat = 0
    /// How wide the panel is, for the tints to reach its right edge.
    var width: () -> CGFloat = { 0 }

    private var numberAttributes: [NSAttributedString.Key: Any] {
        [.font: SplitDiffTexts.font(numberFontSize), .foregroundColor: PlatformColor(white: 1, alpha: 0.32)]
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        #if os(macOS)
        let context = NSGraphicsContext.current?.cgContext
        #else
        let context = UIGraphicsGetCurrentContext()
        #endif
        guard let storage = textStorage, let context else { return }
        let width = width()
        let attributes = numberAttributes
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
            let index = self.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length else { return }
            let top = rect.minY + origin.y
            if let tint = storage.attribute(SplitDiffTexts.tint, at: index, effectiveRange: nil) as? PlatformColor {
                context.setFillColor(tint.cgColor)
                context.fill(CGRect(x: 0, y: top, width: width, height: rect.height))
            }
            if let number = storage.attribute(SplitDiffTexts.number, at: index, effectiveRange: nil) as? Int {
                // As digits only: a number put in a text gets the separators
                // of the language, 1,176.
                let digits = String(number) as NSString
                let size = digits.size(withAttributes: attributes)
                digits.draw(
                    at: CGPoint(x: origin.x + rect.minX + self.gutter - 8 - size.width, y: top + (rect.height - size.height) / 2), withAttributes: attributes)
            }
        }
    }

    /// Lays out the text from `start` until `deadline`, a small piece at a
    /// time, and says where it got to: the whole of it laid out, where
    /// every row is is known rather than guessed, and the two panels put
    /// the same row at the same height.
    func layOut(from start: Int, until deadline: Date) -> Int {
        guard let storage = textStorage else { return 0 }
        var at = start
        while at < storage.length, Date() < deadline {
            let length = min(2_000, storage.length - at)
            ensureLayout(forCharacterRange: NSRange(location: at, length: length))
            at += length
        }
        return at
    }
}

/// The two sides' storages, made off the main thread and handed to it.
private struct SplitDiffStorages: @unchecked Sendable {
    let left: NSTextStorage
    let right: NSTextStorage
}

/// One panel's text, as both platforms hold it.
private final class SplitDiffSide {
    private(set) var storage = NSTextStorage()
    let layout = SplitDiffLayout()
    let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    /// How wide its longest line is.
    var contentWidth: CGFloat = 0

    init() {
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
    }

    /// Shows a text made off the main thread: the storage it is in takes
    /// the place of the one shown, which leaves only its layout to be done.
    func show(_ text: NSTextStorage) {
        layout.replaceTextStorage(text)
        storage = text
    }
}

/// What the views of both platforms share: the patch shown, worked out off
/// the main thread, and put into the two sides.
private final class SplitDiffContent {
    let left = SplitDiffSide()
    let right = SplitDiffSide()
    var sides: [SplitDiffSide] { [left, right] }
    private(set) var rows = 0
    private(set) var fontSize: CGFloat = 0
    private var patch: String?
    private var generation = 0

    static let inset: CGFloat = 6

    /// The height of both texts: every row, the empty line after the last
    /// and the insets.
    var textHeight: CGFloat { CGFloat(rows + 1) * SplitDiffTexts.rowHeight(fontSize) + 2 * Self.inset }

    /// Shows a patch when it is another than the one shown, and calls
    /// `shown` once it is in, and `laidOut` once every row is placed.
    func show(patch: String, fontSize: CGFloat, shown: @escaping () -> Void, laidOut: @escaping () -> Void) {
        guard patch != self.patch || fontSize != self.fontSize else { return }
        self.patch = patch
        generation += 1
        let mine = generation
        let (advance, lineHeight) = SplitDiffTexts.metrics(fontSize)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texts = SplitDiffTexts(patch: patch, fontSize: fontSize, advance: advance, lineHeight: lineHeight)
            // Each text put in its storage here too: on the main thread that
            // is a stall of its own for a long diff.
            let storages = SplitDiffStorages(left: NSTextStorage(attributedString: texts.left), right: NSTextStorage(attributedString: texts.right))
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                self.rows = texts.rows
                self.fontSize = fontSize
                for (side, storage, width) in [(self.left, storages.left, texts.leftWidth), (self.right, storages.right, texts.rightWidth)] {
                    side.layout.numberFontSize = fontSize - 1
                    side.layout.gutter = texts.gutter
                    side.contentWidth = width
                    side.show(storage)
                }
                shown()
                self.layOut(generation: mine, from: [0, 0], done: laidOut)
            }
        }
    }

    /// Lays both sides out for at most 8 ms at each turn of the main
    /// thread, between which the window answers: a frame is 16.
    private func layOut(generation mine: Int, from starts: [Int], done: @escaping () -> Void) {
        guard generation == mine else { return }
        let deadline = Date().addingTimeInterval(0.008)
        let reached = zip(sides, starts).map { side, start in side.layout.layOut(from: start, until: deadline) }
        if zip(sides, reached).allSatisfy({ $0.storage.length <= $1 }) { return done() }
        DispatchQueue.main.async { [weak self] in self?.layOut(generation: mine, from: reached, done: done) }
    }
}

// MARK: The Mac

#if os(macOS)
private struct SplitDiffPanels: NSViewRepresentable {
    let patch: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> SplitDiffMacView { SplitDiffMacView() }

    func updateNSView(_ view: SplitDiffMacView, context: Context) { view.show(patch: patch, fontSize: fontSize) }
}

/// The two panels side by side, each a text view in a view that scrolls
/// both ways; scrolled down, the other follows.
final class SplitDiffMacView: NSView {
    private let content = SplitDiffContent()
    private var scrolls: [NSScrollView] = []
    private var texts: [NSTextView] = []
    private let divider = NSView()
    private var following = false
    private var watching: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("split-diff")
        for (index, side) in content.sides.enumerated() {
            let text = NSTextView(frame: .zero, textContainer: side.container)
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 0, height: SplitDiffContent.inset)
            text.isVerticallyResizable = false
            text.isHorizontallyResizable = false
            text.setAccessibilityIdentifier(index == 0 ? "split-diff-before" : "split-diff-after")
            side.layout.width = { [weak text] in max(text?.bounds.width ?? 0, text?.enclosingScrollView?.contentView.bounds.width ?? 0) }
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            // Down, the panels scroll together: one bar, on the right.
            // Sideways each has its own, always there, so that both see as
            // much of their height and the rows stay facing at the bottom.
            scroll.hasVerticalScroller = index == 1
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false
            scroll.contentView.postsBoundsChangedNotifications = true
            addSubview(scroll)
            scrolls.append(scroll)
            texts.append(text)
        }
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        addSubview(divider)
        for (index, scroll) in scrolls.enumerated() {
            watching.append(
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.follow(index) }
                })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    deinit {
        for observer in watching { NotificationCenter.default.removeObserver(observer) }
    }

    func show(patch: String, fontSize: CGFloat) {
        content.show(patch: patch, fontSize: fontSize, shown: { [weak self] in self?.fit() }, laidOut: { [weak self] in self?.fit() })
    }

    override func layout() {
        super.layout()
        let half = max(60, ((bounds.width - 1) / 2).rounded(.down))
        scrolls[0].frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        divider.frame = CGRect(x: half, y: 0, width: 1, height: bounds.height)
        scrolls[1].frame = CGRect(x: half + 1, y: 0, width: max(0, bounds.width - half - 1), height: bounds.height)
        fit()
    }

    /// Each text as wide as its longest line or its panel, and as high as
    /// every row: the same on both sides.
    private func fit() {
        for (side, (text, scroll)) in zip(content.sides, zip(texts, scrolls)) {
            let size = CGSize(width: max(side.contentWidth, scroll.contentSize.width), height: max(content.textHeight, scroll.contentSize.height))
            if text.frame.size != size { text.frame = CGRect(origin: .zero, size: size) }
            text.needsDisplay = true
        }
    }

    /// The other panel scrolled down as far as this one.
    private func follow(_ index: Int) {
        guard !following else { return }
        following = true
        defer { following = false }
        let moved = scrolls[index].contentView.bounds.origin.y
        let other = scrolls[1 - index]
        guard other.contentView.bounds.origin.y != moved else { return }
        other.contentView.scroll(to: CGPoint(x: other.contentView.bounds.origin.x, y: moved))
        other.reflectScrolledClipView(other.contentView)
    }
}

// MARK: The iPhone

#else
private struct SplitDiffPanels: UIViewRepresentable {
    let patch: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> SplitDiffPhoneView { SplitDiffPhoneView() }

    func updateUIView(_ view: SplitDiffPhoneView, context: Context) { view.show(patch: patch, fontSize: fontSize) }
}

/// The two panels side by side: each a text view that scrolls down, in a
/// view that scrolls it sideways; scrolled down, the other follows.
final class SplitDiffPhoneView: UIView, UITextViewDelegate {
    private let content = SplitDiffContent()
    private var acrosses: [UIScrollView] = []
    private var texts: [UITextView] = []
    private let divider = UIView()
    private var following = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityIdentifier = "split-diff"
        for (index, side) in content.sides.enumerated() {
            let text = UITextView(frame: .zero, textContainer: side.container)
            text.isEditable = false
            text.isSelectable = true
            text.backgroundColor = .clear
            text.textContainerInset = UIEdgeInsets(top: SplitDiffContent.inset, left: 0, bottom: SplitDiffContent.inset, right: 0)
            text.showsVerticalScrollIndicator = index == 1
            text.showsHorizontalScrollIndicator = false
            text.alwaysBounceVertical = true
            text.isDirectionalLockEnabled = true
            text.delegate = self
            side.layout.width = { [weak text] in text?.bounds.width ?? 0 }
            let across = UIScrollView()
            across.backgroundColor = .clear
            across.showsVerticalScrollIndicator = false
            across.isDirectionalLockEnabled = true
            across.alwaysBounceHorizontal = false
            across.accessibilityIdentifier = index == 0 ? "split-diff-before" : "split-diff-after"
            across.addSubview(text)
            addSubview(across)
            acrosses.append(across)
            texts.append(text)
        }
        divider.backgroundColor = UIColor(white: 1, alpha: 0.10)
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(patch: String, fontSize: CGFloat) {
        content.show(patch: patch, fontSize: fontSize, shown: { [weak self] in self?.setNeedsLayout() }, laidOut: { [weak self] in self?.setNeedsLayout() })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = max(60, ((bounds.width - 1) / 2).rounded(.down))
        acrosses[0].frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        divider.frame = CGRect(x: half, y: 0, width: 1, height: bounds.height)
        acrosses[1].frame = CGRect(x: half + 1, y: 0, width: max(0, bounds.width - half - 1), height: bounds.height)
        for (side, (text, across)) in zip(content.sides, zip(texts, acrosses)) {
            // The text no narrower than its longest line: the view around it
            // scrolls it sideways, and it scrolls itself down.
            let width = max(side.contentWidth, across.bounds.width)
            let frame = CGRect(x: 0, y: 0, width: width, height: across.bounds.height)
            if text.frame != frame { text.frame = frame }
            side.container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            across.contentSize = frame.size
            text.setNeedsDisplay()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !following, let index = texts.firstIndex(where: { $0 === scrollView }) else { return }
        following = true
        defer { following = false }
        let other = texts[1 - index]
        let y = scrollView.contentOffset.y
        if other.contentOffset.y != y { other.contentOffset = CGPoint(x: other.contentOffset.x, y: y) }
    }
}
#endif
