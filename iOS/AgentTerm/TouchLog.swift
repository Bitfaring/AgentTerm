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

    private static func write(_ line: String) {
        file?.write(Data("\(clock.string(from: Date())) \(line)\n".utf8))
    }
}

extension UIApplication {
    @objc fileprivate func agentterm_sendEvent(_ event: UIEvent) {
        TouchLog.note(event)
        agentterm_sendEvent(event)
    }
}
#endif
