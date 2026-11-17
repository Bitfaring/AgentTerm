import ObjectiveC
import UIKit

/// Keeps an open menu as it is while a finger is on the screen (#83).
///
/// Once a menu is shown, SwiftUI asks UIKit to make it anew
/// (`updateVisibleMenu`), and does so at its next drawing of the view the
/// menu belongs to: the Mac's figures, which come every few seconds, or
/// anything else drawn there. When that drawing came while a finger was on
/// an entry, the entry under it was replaced, the touch chose nothing and
/// the menu stayed open. Such an update now waits until the finger is
/// lifted, and is made at once when no finger is down.
///
/// Fingers are read from every touch the app is sent, as UIApplication sends
/// it on: a gesture recognizer is told a touch was cancelled when a menu
/// takes it over, with the finger still down, and the SwiftUI app does not
/// take a UIApplication of its own (`NSPrincipalClass` is not read).
@MainActor
enum FingerWatch {
    private(set) static var isDown = false
    /// What waits for every finger to be lifted.
    private static var waiting: [() -> Void] = []
    private static var started = false

    /// Starts watching, once, before anything is shown.
    static func start() {
        guard !started else { return }
        started = true
        exchange(UIApplication.self, #selector(UIApplication.sendEvent(_:)), #selector(UIApplication.agentterm_watchFingers(_:)))
        exchange(
            UIContextMenuInteraction.self, #selector(UIContextMenuInteraction.updateVisibleMenu(_:)),
            #selector(UIContextMenuInteraction.agentterm_updateVisibleMenuWhenLifted(_:)))
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let original = class_getInstanceMethod(type, original), let replacement = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Runs `work` now, or once no finger is on the screen.
    static func whenLifted(_ work: @escaping () -> Void) {
        if isDown { waiting.append(work) } else { work() }
    }

    fileprivate static func sent(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        let down = touches.contains { $0.phase != .ended && $0.phase != .cancelled }
        guard down != isDown else { return }
        isDown = down
        #if DEBUG
        TouchLog.mark(down ? "finger down" : "fingers lifted, \(waiting.count) waiting")
        #endif
        guard !down else { return }
        // After the lifted finger has done what it does: an entry chosen.
        DispatchQueue.main.async {
            guard !isDown else { return }
            let ready = waiting
            waiting = []
            ready.forEach { $0() }
        }
    }
}

extension UIApplication {
    /// UIApplication's own `sendEvent(_:)`, once `FingerWatch` has started.
    @objc fileprivate func agentterm_watchFingers(_ event: UIEvent) {
        // Down before the touch is handed on, lifted after.
        if event.allTouches?.contains(where: { $0.phase == .began }) == true { MainActor.assumeIsolated { FingerWatch.sent(event) } }
        agentterm_watchFingers(event)
        MainActor.assumeIsolated { FingerWatch.sent(event) }
    }
}

extension UIContextMenuInteraction {
    /// UIKit's own `updateVisibleMenu(_:)`, once `FingerWatch` has started.
    @objc fileprivate func agentterm_updateVisibleMenuWhenLifted(_ update: @escaping (UIMenu) -> UIMenu) {
        guard MainActor.assumeIsolated({ FingerWatch.isDown }) else { return agentterm_updateVisibleMenuWhenLifted(update) }
        // SwiftUI's update is made now, as it requires, but the menu shown
        // stays as it is; what it made is shown once the finger is lifted.
        var updated: UIMenu?
        agentterm_updateVisibleMenuWhenLifted { current in
            updated = update(current)
            return current
        }
        guard let updated else { return }
        MainActor.assumeIsolated {
            FingerWatch.whenLifted { [weak self] in self?.updateVisibleMenu { _ in updated } }
        }
    }
}
