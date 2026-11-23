#if os(macOS)
import AgentTermProtocol
import CAgentTermPTY
import Darwin
import Foundation

public enum PTYError: Error, CustomStringConvertible {
    case openFailed(Int32)
    case spawnFailed(Int32)

    public var description: String {
        switch self {
        case .openFailed(let code): return "could not open a pseudo terminal: \(String(cString: strerror(code)))"
        case .spawnFailed(let code): return "could not start the process: \(String(cString: strerror(code)))"
        }
    }
}

// These ioctl request codes are function-like macros in C and are not
// imported into Swift.
private let ioctlSetWindowSize: UInt = 0x8008_7467  // TIOCSWINSZ
private let ioctlGetWindowSize: UInt = 0x4008_7468  // TIOCGWINSZ

/// A child process attached to a pseudo terminal.
///
/// The child runs in its own session with the pseudo terminal as its
/// controlling terminal, so it is told about resizes (SIGWINCH) and job
/// control and Ctrl-C work as in any terminal. See `agentterm_spawn_pty` for
/// why starting it takes a small piece of C.
///
/// `onOutput` and `onExit` are called on the queue given at init. `onExit` is
/// called once, after all remaining output has been delivered.
public final class PTYProcess {
    public let pid: pid_t
    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private let master: Int32
    private let queue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "agentterm.pty.write")
    /// Whether `master` is still this terminal's, read and changed on
    /// `writeQueue` only: it is closed there, after every write asked
    /// before, so that no write reaches the number once it is another
    /// terminal's or file's (#275).
    private final class Descriptor { var isOpen = true }
    private let descriptor = Descriptor()
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var finished = false

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        size: TermSize,
        queue: DispatchQueue
    ) throws {
        self.queue = queue

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        let clamped = size.clamped
        var master: Int32 = -1
        var failure: Int32 = 0
        let pid = agentterm_spawn_pty(&master, &failure, executable, argv, envp, cwd, UInt16(clamped.rows), UInt16(clamped.cols))
        guard pid > 0 else { throw PTYError.spawnFailed(failure) }
        self.master = master
        self.pid = pid

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        let writeQueue = writeQueue, descriptor = descriptor
        readSource.setCancelHandler {
            writeQueue.async {
                descriptor.isOpen = false
                close(master)
            }
        }
        self.readSource = readSource
        readSource.resume()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in self?.childExited() }
        self.exitSource = exitSource
        exitSource.resume()
    }

    deinit {
        exitSource?.cancel()
        readSource?.cancel()
    }

    /// Sends bytes to the program as if they were typed.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = master, descriptor = descriptor
        // Writes can block when the program is not reading. They run on their
        // own queue so output keeps flowing meanwhile.
        writeQueue.async {
            // Once the program has ended its terminal is closed, and its
            // number may be another's: nothing more is written (#275).
            guard descriptor.isOpen else { return }
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n > 0 {
                        offset += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    /// Changes the terminal size. The kernel sends SIGWINCH to the program.
    /// The command the program in front of the terminal was started by:
    /// the leader of its foreground process group (#129). The shell itself
    /// at its prompt; nil when it cannot be told.
    public var foregroundCommand: String? {
        // Asked of an ended program's terminal, the number may be another's.
        guard !finished else { return nil }
        let group = tcgetpgrp(master)
        guard group > 0 else { return nil }
        return ProcessNames.command(of: group)
    }

    public func resize(_ size: TermSize) {
        guard !finished else { return }
        Self.setSize(size, on: master)
    }

    public var size: TermSize? {
        guard !finished else { return nil }
        var ws = winsize()
        guard ioctl(master, ioctlGetWindowSize, &ws) == 0 else { return nil }
        return TermSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    /// Asks the program to quit the way closing a terminal window does.
    public func hangUp() {
        guard !finished else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    public func forceKill() {
        guard !finished else { return }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    private static func setSize(_ size: TermSize, on fd: Int32) {
        let clamped = size.clamped
        var ws = winsize(ws_row: UInt16(clamped.rows), ws_col: UInt16(clamped.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, ioctlSetWindowSize, &ws)
    }

    /// Reads once. The read source only fires when data is ready, so this
    /// does not block. Returns false at end of file.
    @discardableResult
    private func readAvailable() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(master, &buffer, buffer.count)
        if n > 0 {
            onOutput?(Data(buffer[0..<n]))
            return true
        }
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return true }
        return false
    }

    private func childExited() {
        guard !finished else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        // Deliver whatever the program wrote just before exiting.
        var pending = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        while poll(&pending, 1, 0) > 0, pending.revents & Int16(POLLIN) != 0, readAvailable() {}

        finished = true
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()
        readSource = nil

        let exited = (status & 0x7f) == 0
        let code = exited ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit?(code)
    }
}
#endif
