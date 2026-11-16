import AgentTermProtocol
import AgentTermTerminal
import AppKit
import SwiftUI

/// Hosts the terminal view of a session, in the pane that shows it.
struct TerminalPane: NSViewRepresentable {
    let controller: TerminalController
    /// The grid another device imposed, while it drives the session.
    let foreignSize: TermSize?
    /// Whether the keyboard is to be here: with several terminals on show
    /// (#69), only the one in front of the pane the keyboard is in.
    var focused = true

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.show(controller, foreignSize: foreignSize, focused: focused)
    }
}

/// Lays the terminal out in its pane.
///
/// Normally the terminal fills the pane. While another device drives the
/// session the emulator draws that device's grid, which is usually much
/// smaller than a Mac window. Left alone it would sit in the top-left corner
/// with the rest of the pane blank, which looks broken. Instead the terminal
/// view is made exactly as large as that grid, centered, and framed like a
/// preview of the other device's screen.
final class TerminalContainerView: NSView {
    private var controller: TerminalController?
    private var foreignSize: TermSize?
    private let dim = CAShapeLayer()
    private let frameLine = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TerminalStyle.background.cgColor
        layer?.masksToBounds = true

        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        frameLine.fillColor = nil
        frameLine.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        frameLine.lineWidth = 1
        for overlay in [dim, frameLine] {
            // Above the terminal view's own layer.
            overlay.zPosition = 10
            overlay.isHidden = true
            layer?.addSublayer(overlay)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Whether the keyboard was to be here, the last time it was asked.
    private var wasFocused = false

    /// The container last asked to show each terminal, which has it. One
    /// on its way out, asked once more after a new one took the terminal (a
    /// part of the agent's area shown), took it back and went with it, and
    /// the agent's terminal was left blank (#94).
    private static let owners = NSMapTable<TerminalController, TerminalContainerView>.weakToWeakObjects()
    private weak var shownController: TerminalController?

    // Whether it shows its terminal, for the tests (#94): told by its value.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityIdentifier() -> String { "terminal-view" }
    override func accessibilityValue() -> Any? { controller.map { $0.view.superview === self } == true ? "shown" : "empty" }

    func show(_ controller: TerminalController, foreignSize: TermSize?, focused: Bool = true) {
        if shownController !== controller || Self.owners.object(forKey: controller) == nil {
            shownController = controller
            Self.owners.setObject(self, forKey: controller)
        }
        guard Self.owners.object(forKey: controller) === self else { return }
        let terminal = controller.view
        if terminal.superview !== self {
            // A terminal moved to another pane, or into an agent's area,
            // keeps the keyboard it had (#69): an agent opening a shell
            // does not take it from where the user types.
            let hadKeyboard =
                terminal.window.map { window in
                    (window.firstResponder as? NSView).map { $0 === terminal || $0.isDescendant(of: terminal) } ?? false
                } ?? false
            subviews.forEach { $0.removeFromSuperview() }
            // Positioned in `layout`, not by autoresizing: its origin moves
            // while another device's grid is shown.
            terminal.autoresizingMask = []
            addSubview(terminal)
            self.controller = controller
            // Looking at a session is not using it: the Mac app shows every
            // session, including ones a phone is typing in. The size comes
            // here when the user types, or asks for it in the banner.
            if focused || hadKeyboard { giveKeyboard() }
        } else if focused && !wasFocused {
            // Its pane took the keyboard.
            giveKeyboard()
        }
        wasFocused = focused
        self.foreignSize = foreignSize
        needsLayout = true
    }

    /// The keyboard is to go to the terminal, once it is in the window: a
    /// session picked in place of another is shown by a view that SwiftUI
    /// puts in the window later, and the keyboard then went nowhere when the
    /// other's terminal left (PANE-16).
    private var keyboardWanted = false

    private func giveKeyboard() {
        keyboardWanted = true
        DispatchQueue.main.async { [weak self] in self?.takeKeyboardIfInWindow() }
    }

    private func takeKeyboardIfInWindow() {
        guard keyboardWanted, let terminal = controller?.view, terminal.superview === self, let window else { return }
        keyboardWanted = false
        window.makeFirstResponder(terminal)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.takeKeyboardIfInWindow() }
    }

    override func layout() {
        super.layout()
        guard let controller else { return }
        let terminal = controller.view

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard foreignSize != nil else {
            terminal.frame = bounds
            dim.isHidden = true
            frameLine.isHidden = true
            return
        }

        // The view is exactly as large as the grid it draws, placed in the
        // middle. What would fit this pane is worked out by the controller.
        controller.containerResized(to: bounds.size)
        let grid = controller.gridPixelSize
        let x = max(0, ((bounds.width - grid.width) / 2).rounded(.down))
        let y = max(0, ((bounds.height - grid.height) / 2).rounded(.down))
        // A little slack so rounding never costs the last column or row.
        let gridRect = NSRect(x: x, y: bounds.height - y - grid.height, width: grid.width + 0.5, height: grid.height + 0.5)
        terminal.frame = gridRect

        let card = gridRect.insetBy(dx: -10, dy: -10).intersection(bounds.insetBy(dx: 1, dy: 1))
        let outline = CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let surround = CGMutablePath()
        surround.addRect(bounds)
        surround.addPath(outline)
        dim.frame = bounds
        dim.path = surround
        dim.isHidden = false
        frameLine.frame = bounds
        frameLine.path = outline
        frameLine.isHidden = false
    }
}
