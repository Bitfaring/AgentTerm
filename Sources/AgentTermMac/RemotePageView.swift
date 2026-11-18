import AgentTermProtocol
import AppKit
import SwiftUI

/// A page of another Mac's browser (#147), as the iPhone shows one: the
/// pictures that Mac sends while it is watched, drawn as wide as the pane,
/// and what the mouse and the keyboard do sent there, by the same requests
/// a device makes (`tap`, `scroll`, `press`, `text`).
struct RemotePageView: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    let model: AppModel

    func makeNSView(context: Context) -> RemotePageNSView {
        let view = RemotePageNSView()
        view.tabID = tab.id
        view.send = { [weak model] request in model?.askRemoteBrowser(request) }
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
    var send: ((BrowserRequest) -> Void)?
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = pagePoint(event) else { return }
        send?(.tap(tab: tabID, x: point.x, y: point.y))
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
    override func accessibilityPerformPress() -> Bool {
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
