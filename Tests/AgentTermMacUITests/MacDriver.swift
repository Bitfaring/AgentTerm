import AppKit
import ApplicationServices
import Foundation
import XCTest

/// One element of the Mac app's window as accessibility describes it.
struct Node {
    let element: AXUIElement
    let role: String
    let identifier: String
    let title: String
    let label: String
    let value: String
    let help: String
    let enabled: Bool
    let depth: Int

    /// Everything a person, or VoiceOver, would know it by.
    var text: String { [title, label, value].filter { !$0.isEmpty }.joined(separator: " | ") }
    /// What cannot be pressed says so: a button that did nothing may have
    /// been held just then (#116).
    var summary: String { "\(role) id=\(identifier) title=\(title) label=\(label) value=\(value.prefix(60))" + (enabled ? "" : " (disabled)") }
}

/// Starts the Mac app against a host of its own and drives it the way
/// VoiceOver would: by pressing and reading its accessibility elements. No
/// pointer is moved and no key is sent, so a run leaves the desktop alone.
final class MacDriver {
    /// Nil for an app that something else started and will stop.
    let process: Process?
    let pid: pid_t
    private let app: AXUIElement

    /// An app that is already running.
    init(pid: pid_t) {
        process = nil
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    /// Whether this process may use accessibility at all.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    init(executable: URL, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        // Its windows as when first opened, not as macOS saved them when an
        // earlier test's copy quit: a window minimized then would come
        // back minimized, and its sheets wait for it (#110).
        process.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        pid = process.processIdentifier
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    /// Closes the app's window with that title, as its close button does.
    func closeWindow(titled title: String, file: StaticString = #filePath, line: UInt = #line) {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        for window in windows {
            var name: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &name)
            guard name as? String == title else { continue }
            var button: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
            guard let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { break }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return
        }
        XCTFail("no window titled \(title) to close", file: file, line: line)
    }

    /// Minimizes the app's main window into the Dock, or brings it back,
    /// as its yellow button and a click on it in the Dock do.
    func minimize(_ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value)
        if value == nil {
            // A minimized window is no longer the main one.
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            value = (value as? [AXUIElement])?.first
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            XCTFail("no window to minimize", file: file, line: line)
            return
        }
        let window = value as! AXUIElement
        XCTAssertEqual(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, on as CFBoolean), .success, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    func quit() {
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    // MARK: Reading

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// Every element of the app's windows, in the order they are laid out.
    /// The menu bar is left out unless asked for: it is large and rarely wanted.
    func nodes(menus: Bool = false) -> [Node] {
        var found: [Node] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            let role = Self.string(element, kAXRoleAttribute)
            if !menus, role == kAXMenuBarRole { return }
            found.append(
                Node(
                    element: element, role: role, identifier: Self.string(element, kAXIdentifierAttribute),
                    title: Self.string(element, kAXTitleAttribute), label: Self.string(element, kAXDescriptionAttribute),
                    value: Self.string(element, kAXValueAttribute), help: Self.string(element, kAXHelpAttribute),
                    enabled: (Self.attribute(element, kAXEnabledAttribute) as? Bool) ?? true, depth: depth))
            guard depth < 40, let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child, depth + 1) }
        }
        walk(app, 0)
        return found
    }

    /// A way to pick an element: by identifier, or by what it says.
    enum Query: CustomStringConvertible {
        case id(String)
        /// An identifier that ends like this, and begins with `prefix`:
        /// for one that holds a path, which the same folder has more than
        /// one of, and the list, a tab's row and the Files panel each have
        /// one of (#127).
        case idEnding(String, prefix: String = "")
        /// A button, of whatever kind, that says exactly this.
        case button(String)
        /// Anything whose title, label or value is exactly this.
        case text(String)
        /// Anything whose title, label or value contains this.
        case containing(String)
        case role(String)

        var description: String {
            switch self {
            case .id(let id): return "id \(id)"
            case .idEnding(let end, let prefix): return "id \(prefix)… ending in \(end)"
            case .button(let name): return "button \"\(name)\""
            case .text(let text): return "\"\(text)\""
            case .containing(let text): return "something with \"\(text)\""
            case .role(let role): return "a \(role)"
            }
        }

        func matches(_ node: Node) -> Bool {
            switch self {
            case .id(let id): return node.identifier == id
            case .idEnding(let end, let prefix): return node.identifier.hasPrefix(prefix) && node.identifier.hasSuffix(end)
            case .button(let name):
                return [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole].contains(node.role)
                    && (node.title == name || node.label == name)
            case .text(let text): return node.title == text || node.label == text || node.value == text
            case .containing(let text): return node.title.contains(text) || node.label.contains(text) || node.value.contains(text)
            case .role(let role): return node.role == role
            }
        }
    }

    func all(_ query: Query, menus: Bool = false) -> [Node] { nodes(menus: menus).filter(query.matches) }
    func first(_ query: Query, menus: Bool = false) -> Node? { nodes(menus: menus).first(where: query.matches) }
    func exists(_ query: Query) -> Bool { first(query) != nil }

    /// Waits for something to be on screen, as a person would.
    @discardableResult
    func wait(for query: Query, timeout: TimeInterval = 10, menus: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Node? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = first(query, menus: menus) { return node }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("\(query) did not appear. On screen:\n\(screen())", file: file, line: line)
        return nil
    }

    /// Waits for something to hold.
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("timed out waiting for: \(what). On screen:\n\(screen())", file: file, line: line)
    }

    func waitGone(_ query: Query, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        wait("\(query) to go away", timeout: timeout, file: file, line: line) { !self.exists(query) }
    }

    /// What is on screen, one element a line, for a failure's message. The
    /// app in front is named first: when it is not this one, the Mac was
    /// used meanwhile, and a menu the app had open was closed by that
    /// (#135).
    func screen() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let inFront = "In front: \(front?.localizedName ?? "no app")" + (front?.processIdentifier == pid ? "" : ", not the app under test")
        return inFront + "\n"
            + nodes().filter { !$0.text.isEmpty || !$0.identifier.isEmpty }.map { String(repeating: " ", count: min($0.depth, 10)) + $0.summary }
            .joined(separator: "\n")
    }

    // MARK: Acting

    /// Presses a button, a row, a tab: whatever says it can be pressed.
    func press(_ query: Query, menus: Bool = false, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard wait(for: query, timeout: timeout, menus: menus, file: file, line: line) != nil else { return }
        // A button that is there may not be ready yet: a sheet's, until
        // what it needs has loaded.
        wait("\(query) to be enabled", timeout: timeout, file: file, line: line) { self.first(query, menus: menus)?.enabled ?? false }
        guard let node = first(query, menus: menus) else { return }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        // A button that closes what it is in, a sheet's, is gone before the
        // press is answered, and the press is then reported as failed.
        if result != .success, first(query, menus: menus) != nil {
            XCTFail("\(query) could not be pressed (\(result.rawValue))", file: file, line: line)
        }
    }

    /// Does one of an element's own named actions, as VoiceOver's actions
    /// menu would: "Resume" on a conversation, say.
    func perform(_ action: String, on query: Query, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard let node = wait(for: query, timeout: timeout, file: file, line: line) else { return }
        var names: CFArray?
        AXUIElementCopyActionNames(node.element, &names)
        let all = (names as? [String]) ?? []
        guard let name = all.first(where: { $0 == action || $0.contains("Name:\(action)\n") }) else {
            XCTFail("\(query) has no action \(action); it has \(all)", file: file, line: line)
            return
        }
        XCTAssertEqual(AXUIElementPerformAction(node.element, name as CFString), .success, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Whether an element offers one of its own named actions, without doing
    /// it: Copy, which would write to the user's pasteboard, say.
    func offers(_ action: String, on query: Query, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let node = wait(for: query, timeout: timeout, file: file, line: line) else { return false }
        var names: CFArray?
        AXUIElementCopyActionNames(node.element, &names)
        return ((names as? [String]) ?? []).contains { $0 == action || $0.contains("Name:\(action)\n") }
    }

    /// Picks an item of the app's menu bar, such as ["File", "New Shell"].
    func menu(_ path: [String], file: StaticString = #filePath, line: UInt = #line) {
        var current = nodes(menus: true).first { $0.role == kAXMenuBarRole }?.element
        for (index, name) in path.enumerated() {
            guard let parent = current else { break }
            var next: AXUIElement?
            // The first name is one of the menu bar's own: an item of the
            // Tab menu named after a tab, "Browser", is not the Browser menu.
            let deepest = index == 0 ? 1 : 4
            func search(_ element: AXUIElement, _ depth: Int) {
                guard next == nil, depth < deepest, let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
                for child in children where next == nil {
                    if Self.string(child, kAXTitleAttribute) == name { next = child } else { search(child, depth + 1) }
                }
            }
            search(parent, 0)
            current = next
        }
        guard let item = current else {
            XCTFail("no menu item \(path.joined(separator: " > "))", file: file, line: line)
            return
        }
        XCTAssertEqual(AXUIElementPerformAction(item, kAXPressAction as CFString), .success, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Writes into a text field or an editor, as typing would leave it.
    func write(_ text: String, into query: Query, confirm: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard let node = wait(for: query, file: file, line: line) else { return }
        AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, text as CFString)
        XCTAssertEqual(result, .success, "could not write into \(query)", file: file, line: line)
        if confirm { AXUIElementPerformAction(node.element, kAXConfirmAction as CFString) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func value(of query: Query) -> String? { first(query)?.value }

    // MARK: The mouse and the keyboard

    /// Where an element is, in points of the screen from its top left.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    func frame(of query: Query) -> CGRect? { first(query).flatMap { Self.frame($0.element) } }

    /// Whether an element says it is the one selected, as a row of a list does.
    func isSelected(_ query: Query) -> Bool {
        guard let node = first(query) else { return false }
        return (Self.attribute(node.element, kAXSelectedAttribute) as? Bool) ?? false
    }

    /// Where the element that has the keyboard is.
    func keyboardFrame() -> CGRect? { keyboardElement().flatMap(Self.frame) }

    private func keyboardElement() -> AXUIElement? {
        guard let focused = Self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// What the element that has the keyboard holds: a text view's text.
    func keyboardValue() -> String { keyboardElement().map { Self.string($0, kAXValueAttribute) } ?? "" }

    /// What has the keyboard, for a failure's message.
    func keyboardSummary() -> String {
        guard let element = keyboardElement() else { return "nothing" }
        return "\(Self.string(element, kAXRoleAttribute)) id=\(Self.string(element, kAXIdentifierAttribute)) "
            + "label=\(Self.string(element, kAXDescriptionAttribute)) at \(Self.frame(element).map { "\($0)" } ?? "?")"
    }

    /// The element with the keyboard: its role, and the identifiers of it
    /// and of the elements it is in, nearest first. A view that is no
    /// element of its own is told by the nearest that is.
    func keyboardPath() -> (role: String, ids: [String]) {
        guard var element = keyboardElement() else { return ("", []) }
        let role = Self.string(element, kAXRoleAttribute)
        var ids: [String] = []
        for _ in 0..<60 {
            let id = Self.string(element, kAXIdentifierAttribute)
            if !id.isEmpty { ids.append(id) }
            guard let parent = Self.attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return (role, ids)
    }

    /// Waits until the keyboard is in the element with that identifier. A
    /// page has it when what holds it is in the view the page is drawn in
    /// (`browser-page`) of that tab's pane: Chromium's own elements are not
    /// linked to the window's, and its view, which has the keyboard, is told
    /// by that one.
    func waitForKeyboard(in id: String, page: Bool = false, _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        func holds() -> Bool {
            let path = keyboardPath()
            guard page else { return path.ids.contains(id) }
            // Chromium's own: no identifier of the app's, in the view the
            // page is drawn in, below the tab's bar. Chromium's view is a
            // group until it builds the page's elements.
            guard path.ids.contains(id), let element = keyboardElement(), Self.string(element, kAXIdentifierAttribute).isEmpty,
                let frame = frame(of: .id("browser-page")) ?? frame(of: .id(id)), let keyboard = keyboardFrame()
            else { return false }
            return frame.insetBy(dx: -1, dy: -1).contains(keyboard)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if holds() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let path = keyboardPath()
        XCTFail("the keyboard is not in \(what) (\(id)): it is in \(keyboardSummary()) within \(path.ids)", file: file, line: line)
    }

    /// The rows of the list at the left that say they are selected: one
    /// at most.
    func selectedRows() -> [String] {
        nodes().filter { $0.identifier.hasPrefix("session-") || $0.identifier.hasPrefix("browser-row-") }
            .filter { (Self.attribute($0.element, kAXSelectedAttribute) as? Bool) ?? false }.map(\.identifier)
    }

    /// The colour the app's window shows at a point of the screen, from a
    /// picture of the window: what is drawn there, whatever accessibility
    /// says is there.
    func color(at point: CGPoint) -> NSColor? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard
            let info = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0 }),
            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-window-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        capture(to: file)
        guard let image = NSImage(contentsOf: file), let picture = image.representations.first as? NSBitmapImageRep, bounds.width > 0 else { return nil }
        let scale = CGFloat(picture.pixelsWide) / bounds.width
        let x = Int((point.x - bounds.minX) * scale), y = Int((point.y - bounds.minY) * scale)
        guard x >= 0, y >= 0, x < picture.pixelsWide, y < picture.pixelsHigh else { return nil }
        return picture.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// A picture of the app's window, for a failure that words do not explain.
    /// The one in front, a sheet when one is open, that is a window to look
    /// at: once a popover has been shown, the first in the list is one of
    /// two points by one that it leaves behind, and the picture was of that.
    /// - Parameter topmost: the app's window in front, whatever its level: an
    ///   alert run on its own (`NSAlert.runModal`), which is not a sheet of
    ///   the main window.
    func capture(to url: URL, topmost: Bool = false) {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        func isToLookAt(_ window: [String: Any]) -> Bool {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.width > 40 && frame.height > 40
        }
        guard
            let id = windows.first(where: {
                let layer = ($0[kCGWindowLayer as String] as? Int) ?? 1
                return ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (topmost ? (0...8).contains(layer) : layer == 0) && isToLookAt($0)
            })?[kCGWindowNumber as String] as? Int
        else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(id), url.path]
        try? capture.run()
        capture.waitUntilExit()
    }
}
