import AgentTermProtocol
import AppKit
import Foundation

/// What is sent of the pages the devices watch, written down while
/// `AGENTTERM_LOG_FRAMES` is set (#107): for each picture its path, the
/// pixels it really has, the size sent with it, and what the page is shown
/// as. To stderr; or, when the variable is a path (it starts with `/`), at
/// the end of that file, for an app whose stderr nobody reads. A line a
/// second at most for each tab and path; nothing of what the page shows,
/// nor its address.
@MainActor
enum FrameLog {
    private static let setting = ProcessInfo.processInfo.environment["AGENTTERM_LOG_FRAMES"] ?? ""
    static let on = !setting.isEmpty

    /// How a picture came to be: streamed as the Mac draws the page
    /// (`Page.screencastFrame`); taken of a streamed page that stood still;
    /// taken while the Mac does not draw the page (both
    /// `Page.captureScreenshot`).
    enum Path: String {
        case screencast
        case still
        case capture
    }

    private static var last: [String: Date] = [:]

    static func sent(_ path: Path, tab: BrowserTab, jpeg: Data, width: Double, height: Double, asked: Int, streamed: DevToolsSession.StreamedSize? = nil) {
        guard on else { return }
        let key = tab.id + " " + path.rawValue
        let now = Date()
        if let before = last[key], now.timeIntervalSince(before) < 1 { return }
        last[key] = now
        let pane = tab.container.bounds.size
        let line = line(
            path, tab: tab.id, pixels: DevToolsSession.pixels(of: jpeg), bytes: jpeg.count, width: width, height: height, asked: asked,
            device: tab.emulating, pane: (Double(pane.width), Double(pane.height)), screen: tab.container.window.map { Double($0.backingScaleFactor) },
            streamed: streamed)
        write(Data((line + "\n").utf8))
    }

    private static func write(_ line: Data) {
        guard setting.hasPrefix("/") else { return FileHandle.standardError.write(line) }
        if !FileManager.default.fileExists(atPath: setting) { FileManager.default.createFile(atPath: setting, contents: nil) }
        guard let file = FileHandle(forWritingAtPath: setting) else { return FileHandle.standardError.write(line) }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: line)
    }

    /// The pictures of a tab are no longer sent: its next is written at once.
    static func forget(tab: String) {
        for path in [Path.screencast, .still, .capture] { last[tab + " " + path.rawValue] = nil }
    }

    /// One line. `shape` says whether the picture is in the shape of the
    /// size sent with it, within 3 %: `differs` is a picture a device that
    /// trusted the size would draw squeezed, and one whose touches land
    /// beside the finger.
    nonisolated static func line(
        _ path: Path, tab: String, pixels: (width: Int, height: Int)?, bytes: Int, width: Double, height: Double, asked: Int, device: BrowserDevice?,
        pane: (width: Double, height: Double), screen: Double?, streamed: DevToolsSession.StreamedSize?
    ) -> String {
        func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value) }
        var words = ["AgentTerm frame", "tab=\(tab)", "path=\(path.rawValue)"]
        if let pixels {
            words.append("pixels=\(pixels.width)x\(pixels.height)")
            words.append("sent=\(number(width))x\(number(height))")
            let real = Double(pixels.width) / Double(pixels.height), said = height > 0 ? width / height : 0
            words.append("shape=\(said > 0 && abs(real - said) <= said * 0.03 ? "same" : "differs")")
            if width > 0 { words.append("pixels-to-a-point=\(String(format: "%.2f", Double(pixels.width) / width))") }
        } else {
            words.append("pixels=unreadable")
            words.append("sent=\(number(width))x\(number(height))")
        }
        if let device, device.width > 0, device.height > 0 {
            words.append("emulated=\(device.width)x\(device.height)@\(number(device.scale))")
            words.append("device=\"\(device.name)\"")
        } else {
            words.append("emulated=no")
        }
        words.append("pane=\(number(pane.width))x\(number(pane.height))")
        words.append("screen=\(screen.map { "@" + number($0) } ?? "none")")
        if let streamed { words.append("chromium-says=\(number(streamed.width))x\(number(streamed.height))*\(number(streamed.pageScale))") }
        words.append("asked=\(asked)")
        words.append("bytes=\(bytes)")
        return words.joined(separator: " ")
    }
}
