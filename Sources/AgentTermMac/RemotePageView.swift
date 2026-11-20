import AgentTermProtocol
import AppKit
import SwiftUI

/// A page of another Mac's browser (#147), as the iPhone shows one: the
/// pictures that Mac sends while it is watched, drawn as wide as the pane,
/// and what the mouse and the keyboard do sent there: the keys and the
/// wheel by the same requests a device makes (`press`, `text`, `scroll`),
/// the mouse by `pointer` (hover, click, drag, selecting text), a right
/// click by a menu of this Mac's made from `contextAt`, ⌘C by `copy`.
struct RemotePageView: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    let model: AppModel

    func makeNSView(context: Context) -> RemotePageNSView {
        let view = RemotePageNSView()
        view.tabID = tab.id
        view.project = tab.project
        view.send = { [weak model] request in model?.askRemoteBrowser(request) }
        view.ask = { [weak model] request, done in model?.askRemoteBrowser(request, done) }
        return view
    }

    func updateNSView(_ view: RemotePageNSView, context: Context) {
        view.frameImage = tab.remoteFrame
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: RemotePageNSView, coordinator: ()) { view.watch(false) }
}

final class RemotePageNSView: NSView {
    var tabID = ""
    var project = ""
    var send: ((BrowserRequest) -> Void)?
    /// A request whose answer is wanted.
    var ask: ((BrowserRequest, @escaping (BrowserResult) -> Void) -> Void)?
    /// The mouse's events, sent one at a time in their order: the next once
    /// the last is answered, moves meanwhile kept to the latest only.
    private var pointerQueue: [PagePointer] = []
    private var pointerInFlight = false
    var frameImage: (image: NSImage, width: Double, height: Double)?
    /// The width the pictures were asked at, in pixels; nil while not watched.
    private var watchedWidth: Int?
    /// Scrolling not sent yet, in the page's pixels: sent in steps.
    private var scrolled = CGSize.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch(window != nil)
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        // Asked again at the new width when it changed much.
        if let watched = watchedWidth, abs(pixelWidth - watched) > 80 { watch(true) }
    }

    private var pixelWidth: Int { max(320, Int(bounds.width * (window?.backingScaleFactor ?? 2))) }

    func watch(_ on: Bool) {
        guard !tabID.isEmpty else { return }
        if on {
            watchedWidth = pixelWidth
            send?(.watch(tab: tabID, on: true, width: pixelWidth))
        } else if watchedWidth != nil {
            watchedWidth = nil
            send?(.watch(tab: tabID, on: false, width: 0))
        }
    }

    /// Points of this view to one of the page's CSS pixels.
    private var scale: CGFloat {
        guard let frame = frameImage, frame.width > 0 else { return 1 }
        return bounds.width / CGFloat(frame.width)
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
        guard let frame = frameImage else {
            let words = "Loading the page from the other Mac…" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]
            let size = words.size(withAttributes: attributes)
            words.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2 - size.height / 2), withAttributes: attributes)
            return
        }
        let height = CGFloat(frame.height) * scale
        frame.image.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func pagePoint(_ event: NSEvent) -> (x: Double, y: Double)? {
        guard let frame = frameImage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let x = Double(point.x / scale), y = Double(point.y / scale)
        guard x >= 0, y >= 0, y < frame.height else { return nil }
        return (min(x, frame.width - 1), y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // Hover: the page sees the pointer pass while the window is in front.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Sends a mouse event after the ones before it.
    private func point(_ event: PagePointer) {
        if event.kind == .moved, let last = pointerQueue.last, last.kind == .moved { pointerQueue[pointerQueue.count - 1] = event } else { pointerQueue.append(event) }
        sendNextPointer()
    }

    private func sendNextPointer() {
        guard !pointerInFlight, !pointerQueue.isEmpty, let ask else { return }
        let event = pointerQueue.removeFirst()
        pointerInFlight = true
        ask(.pointer(tab: tabID, event: event)) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pointerInFlight = false
                self?.sendNextPointer()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let point = pagePoint(event) else { return }
        self.point(PagePointer(kind: .moved, x: point.x, y: point.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = pagePoint(event) else { return }
        self.point(PagePointer(kind: .moved, x: point.x, y: point.y))
        self.point(PagePointer(kind: .pressed, x: point.x, y: point.y, held: true, clicks: event.clickCount))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = pagePoint(event) else { return }
        // A drag: text selected, or something moved, as it is held.
        self.point(PagePointer(kind: .moved, x: point.x, y: point.y, held: true))
    }

    override func mouseUp(with event: NSEvent) {
        let point = pagePoint(event) ?? clampedPoint(event)
        guard let point else { return }
        self.point(PagePointer(kind: .released, x: point.x, y: point.y, clicks: event.clickCount))
    }

    /// A point of the page for an event outside it, as a release after a
    /// drag past its edge: brought to its nearest edge.
    private func clampedPoint(_ event: NSEvent) -> (x: Double, y: Double)? {
        guard let frame = frameImage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return (min(max(0, Double(point.x / scale)), frame.width - 1), min(max(0, Double(point.y / scale)), frame.height - 1))
    }

    /// A right click: this Mac's own menu, made from what is at that point
    /// there, never one opened on the Mac the browser runs on.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = pagePoint(event) else { return }
        showMenu(at: point, location: convert(event.locationInWindow, from: nil))
    }

    /// The menu for a point of the page, at a point of this view.
    private func showMenu(at point: (x: Double, y: Double), location: NSPoint) {
        guard let ask else { return }
        ask(.contextAt(tab: tabID, x: point.x, y: point.y)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .context(let link, let selection) = result else { return }
                self.showMenu(link: link, selection: selection, at: location)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func showMenu(link: String?, selection: String, at location: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(PageMenuAction.run), keyEquivalent: "")
            let target = PageMenuAction(action)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        if !selection.isEmpty {
            item(BrowserWords.PageMenu.copy) { Self.putOnPasteboard(selection) }
            menu.addItem(.separator())
        }
        if let link {
            item(BrowserWords.PageMenu.openLink) { [weak self] in
                guard let self else { return }
                self.send?(.newTab(project: self.project, url: link, profile: nil, private: false))
            }
            item(BrowserWords.PageMenu.copyLink) { Self.putOnPasteboard(link) }
            menu.addItem(.separator())
        }
        item(BrowserWords.PageMenu.back) { [weak self] in self.map { $0.send?(.history(tab: $0.tabID, step: -1)) } }
        item(BrowserWords.PageMenu.forward) { [weak self] in self.map { $0.send?(.history(tab: $0.tabID, step: 1)) } }
        item(BrowserWords.PageMenu.reload) { [weak self] in self.map { $0.send?(.history(tab: $0.tabID, step: 0)) } }
        menu.popUp(positioning: nil, at: location, in: self)
    }

    private static func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Edit > Copy, ⌘C: what is selected in the page there, on this Mac's
    /// pasteboard.
    @objc func copy(_ sender: Any?) {
        ask?(.copy(tab: tabID)) { result in
            guard case .text(let text) = result, !text.isEmpty else { return }
            DispatchQueue.main.async { Self.putOnPasteboard(text) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrolled.width -= event.scrollingDeltaX / scale
        scrolled.height -= event.scrollingDeltaY / scale
        guard abs(scrolled.width) >= 24 || abs(scrolled.height) >= 24 || event.phase == .ended else { return }
        send?(.scroll(tab: tabID, ref: nil, x: Double(scrolled.width), y: Double(scrolled.height)))
        scrolled = .zero
    }

    /// The keys a page is sent by name, as the iPhone sends them.
    private static let keys: [UInt16: String] = [
        36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown",
        126: "ArrowUp", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]

    override func keyDown(with event: NSEvent) {
        // The app's shortcuts are the app's.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        if let key = Self.keys[event.keyCode] { return send?(.press(tab: tabID, key: key)) ?? () }
        if let text = event.characters, !text.isEmpty { send?(.text(tab: tabID, text: text)) }
    }

    // For VoiceOver and anything else without a pointer: a picture of the
    // page, which a press clicks in the middle of.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "The page, from the other Mac" }
    /// The right click's menu, for what is in the middle of the page.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let frame = frameImage else { return false }
        let point = (x: frame.width / 2, y: min(frame.height, Double(bounds.height / scale)) / 2)
        showMenu(at: point, location: NSPoint(x: point.x * scale, y: point.y * scale))
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        // As a click: the keyboard, and Edit's commands, go to the page.
        window?.makeFirstResponder(self)
        guard let frame = frameImage else { return false }
        send?(.tap(tab: tabID, x: frame.width / 2, y: min(frame.height, Double(bounds.height / scale)) / 2))
        return true
    }

    /// Edit > Paste, ⌘V: what this Mac copied, typed into the page there.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send?(.text(tab: tabID, text: text))
    }
}

/// A menu item's action, kept by the item.
private final class PageMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
