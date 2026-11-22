import AgentTermProtocol
import SwiftTerm
import XCTest

@testable import AgentTermHost

/// #235: what a device draws from the live output, which comes in pieces cut
/// anywhere, after the screen it was sent on attaching, is the host's screen.
final class LiveScreenTests: XCTestCase {
    private final class Emulator: TerminalDelegate {
        private(set) var terminal: Terminal!
        init(size: TermSize, scrollback: Int = 1000) {
            terminal = Terminal(delegate: self, options: TerminalOptions(cols: size.cols, rows: size.rows, scrollback: scrollback))
        }
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func feed(_ bytes: ArraySlice<UInt8>) { terminal.feed(buffer: bytes) }
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Output like Claude Code's while subagents work: lines above that stay,
    /// and below them a part drawn again in place, many times, inside
    /// synchronized output: a line per subagent with a spinner, what each
    /// does, and the prompt's box.
    private func agentOutput(cols: Int, frames: Int, seed: UInt64) -> [UInt8] {
        var random = Generator(state: seed)
        let e = "\u{1b}["
        let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let stars = ["✻", "✽", "✶", "✳", "✢", "·"]
        var out = "\(e)?2004h\(e)?1004h\(e)?25l"
        out += "\(e)38;5;174m╭\(String(repeating: "─", count: cols - 2))╮\(e)39m\r\n"
        out += "\(e)38;5;174m│\(e)39m ✻ Welcome to the agent".padding(toLength: cols - 1 + 20, withPad: " ", startingAt: 0) + "\(e)38;5;174m│\(e)39m\r\n"
        out += "\(e)38;5;174m╰\(String(repeating: "─", count: cols - 2))╯\(e)39m\r\n\r\n"
        var previous = 0
        for frame in 0..<frames {
            var lines: [String] = []
            let agents = 1 + Int(random.next() % 4)
            if random.next() % 7 == 0 {
                // A line that stays above, as a tool's result.
                lines.append("\(e)1m⏺\(e)22m Read(\(e)2mSources/File\(frame).swift\(e)22m) 🙂 done")
            }
            for agent in 0..<agents {
                let spin = spinner[(frame + agent) % spinner.count]
                lines.append("\(e)38;5;\(170 + agent)m\(spin)\(e)39m Task(agent \(agent)) · \(frame % 60)s · ↓ \(frame * 7) tokens")
                lines.append("  \(e)2m⎿  Searching for \(String(repeating: "x", count: Int(random.next() % UInt64(cols))))\(e)22m")
            }
            lines.append("\(e)38;5;214m\(stars[frame % stars.count]) Working… \(e)2m(esc to interrupt · \(frame)s)\(e)22m\(e)39m")
            lines.append("\(e)2m╭\(String(repeating: "─", count: cols - 2))╮\(e)22m")
            lines.append("\(e)2m│\(e)22m > " + String(repeating: " ", count: cols - 5) + "\(e)2m│\(e)22m")
            lines.append("\(e)2m╰\(String(repeating: "─", count: cols - 2))╯\(e)22m")
            lines.append("  \(e)2m⏵⏵ accept edits on\(e)22m")
            var drawn = "\(e)?2026h"
            for _ in 0..<previous { drawn += "\(e)2K\(e)1A" }
            drawn += "\(e)2K\(e)G"
            drawn += lines.joined(separator: "\r\n")
            drawn += "\(e)?2026l"
            out += drawn
            // What wrapped takes more rows: a line of more characters than
            // columns is drawn again from its first row.
            previous = lines.map { rowsTaken(by: $0, cols: cols) }.reduce(0, +) - 1
        }
        return Array(out.utf8)
    }

    private func rowsTaken(by line: String, cols: Int) -> Int {
        let plain = line.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let width = plain.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1F300 ? 2 : 1) }
        return max(1, (width + cols - 1) / cols)
    }

    private func screen(_ terminal: Terminal) -> [String] {
        terminal.contentSnapshot(region: .all).rows.map(\.text)
    }

    private func cursor(_ terminal: Terminal) -> [Int] {
        let content = terminal.contentSnapshot(region: .history(maximumScrollbackRows: 0))
        return [content.cursorRow - content.liveTopRow, content.cursorColumn]
    }

    private func pieces(_ bytes: [UInt8], random: inout Generator, largest: Int) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + 1 + Int(random.next() % UInt64(largest)))
            result.append(bytes[start..<end])
            start = end
        }
        return result
    }

    func testOutputInPiecesDrawsWhatItDrawsWhole() {
        let size = TermSize(cols: 44, rows: 30)
        for seed in UInt64(1)...20 {
            let bytes = agentOutput(cols: size.cols, frames: 200, seed: seed)
            let whole = Emulator(size: size)
            whole.feed(bytes[...])
            var random = Generator(state: seed &* 31)
            let cut = Emulator(size: size)
            for piece in pieces(bytes, random: &random, largest: 64) { cut.feed(piece) }
            XCTAssertEqual(screen(cut.terminal), screen(whole.terminal), "seed \(seed)")
            XCTAssertEqual(cursor(cut.terminal), cursor(whole.terminal), "seed \(seed)")
        }
    }

    func testAttachedInTheMiddleTheLiveOutputDrawsTheHostsScreen() {
        let size = TermSize(cols: 44, rows: 30)
        for seed in UInt64(1)...20 {
            let bytes = agentOutput(cols: size.cols, frames: 300, seed: seed)
            var random = Generator(state: seed &* 17)
            let mirror = ScreenMirror(size: size, scrollback: 1000)
            let at = Int(random.next() % UInt64(bytes.count))
            mirror.feed(Data(bytes[..<at]))
            let device = Emulator(size: size, scrollback: 20_000)
            device.feed(ArraySlice([UInt8](mirror.snapshot(linesAbove: 300))))
            for piece in pieces(Array(bytes[at...]), random: &random, largest: 4096) {
                mirror.feed(Data(piece))
                device.feed(piece)
            }
            let host = Emulator(size: size, scrollback: 20_000)
            host.feed(ArraySlice([UInt8](mirror.snapshot(linesAbove: 300))))
            XCTAssertEqual(Array(screen(device.terminal).suffix(size.rows)), Array(screen(host.terminal).suffix(size.rows)), "seed \(seed) cut at \(at)")
            XCTAssertEqual(cursor(device.terminal), cursor(host.terminal), "seed \(seed)")
        }
    }
}
