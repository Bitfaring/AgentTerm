#if DEBUG
import ObjectiveC
import UIKit

/// Writes down every touch the app receives, for a UI test to read (#83): a
/// touch XCUITest makes is now and then taken by nothing, and this says
/// whether it reached the app, in which window, and on which view.
///
/// Only in a debug build, and only when `AGENTTERM_TOUCH_LOG` names a file.
enum TouchLog {
    private static var file: FileHandle?
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func startIfAsked() {
        guard file == nil, let path = ProcessInfo.processInfo.environment["AGENTTERM_TOUCH_LOG"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        file = handle
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
            let logged = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.agentterm_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, logged)
        // When an open menu is made anew, and by whom (#83).
        if let update = class_getInstanceMethod(UIContextMenuInteraction.self, #selector(UIContextMenuInteraction.updateVisibleMenu(_:))),
            let noted = class_getInstanceMethod(UIContextMenuInteraction.self, #selector(UIContextMenuInteraction.agentterm_updateVisibleMenu(_:)))
        {
            method_exchangeImplementations(update, noted)
        }
        write("started")
    }

    fileprivate static func note(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.phase == .began || touch.phase == .ended || touch.phase == .cancelled {
            let phase = touch.phase == .began ? "began" : touch.phase == .ended ? "ended" : "cancelled"
            let place = touch.location(in: nil)
            var views: [String] = []
            var view = touch.view
            while let current = view, views.count < 6 {
                views.append(String(describing: type(of: current)))
                view = current.superview
            }
            let window = touch.window.map { "\(type(of: $0)) level \($0.windowLevel.rawValue) key \($0.isKeyWindow)" } ?? "no window"
            let recognizers = (touch.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ",")
            write(String(format: "%@ (%.0f, %.0f) in %@; on %@; recognizers %@", phase, place.x, place.y, window, views.joined(separator: " < "), recognizers))
        }
    }

    /// A message from the host, by its kind only: what it carries is not
    /// written down.
    static func received(_ message: Any) {
        guard file != nil else { return }
        let kind = Mirror(reflecting: message).children.first?.label ?? String(describing: message)
        write("message \(kind)")
    }

    /// Something the app did, by a name of its own.
    static func mark(_ what: String) {
        guard file != nil else { return }
        write(what)
    }

    private static func write(_ line: String) {
        file?.write(Data("\(clock.string(from: Date())) \(line)\n".utf8))
    }
}

extension UIContextMenuInteraction {
    @objc fileprivate func agentterm_updateVisibleMenu(_ block: @escaping (UIMenu) -> UIMenu) {
        let callers = Thread.callStackSymbols.dropFirst(1).prefix(14).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ").prefix(110)
        }
        TouchLog.mark("menu updated, from: " + callers.joined(separator: " | "))
        agentterm_updateVisibleMenu(block)
    }
}

extension UIApplication {
    @objc fileprivate func agentterm_sendEvent(_ event: UIEvent) {
        TouchLog.note(event)
        agentterm_sendEvent(event)
    }
}
#endif
