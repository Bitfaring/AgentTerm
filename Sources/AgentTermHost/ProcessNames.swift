#if os(macOS)
import Darwin
import Foundation

/// The names programs were started by (#129): the first word of their
/// command line, as typed. Not the file's own name: Claude Code's command
/// is a link to a file named for its version (`2.1.326`), which `proc_name`
/// gives.
public enum ProcessNames {
    /// The last part of the first word of a process's command line.
    public static func command(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The count of the arguments, the path of the program and the nulls
        // after it, then the arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        let first = String(decoding: buffer[start..<index], as: UTF8.self)
        let name = (first as NSString).lastPathComponent
        // A login shell's is "-zsh".
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    /// The process that started one.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// Whether a process is run in a terminal: it has a controlling one.
    /// Nil when the process cannot be asked, as one that ended.
    public static func hasTerminal(_ pid: pid_t) -> Bool? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // NODEV: no terminal.
        return info.kp_eproc.e_tdev != -1
    }

    /// How the processes of this Mac are asked; a test stands its own in.
    public struct Lookup {
        public var command: (pid_t) -> String?
        public var parent: (pid_t) -> pid_t?
        public var hasTerminal: (pid_t) -> Bool?

        public init(command: @escaping (pid_t) -> String?, parent: @escaping (pid_t) -> pid_t?, hasTerminal: @escaping (pid_t) -> Bool?) {
            self.command = command
            self.parent = parent
            self.hasTerminal = hasTerminal
        }

        public static let live = Lookup(command: ProcessNames.command(of:), parent: ProcessNames.parent(of:), hasTerminal: ProcessNames.hasTerminal)
    }

    /// The agent's own process among a process and its forebears, the
    /// nearest first, a few at most: the one an MCP server or a hook was
    /// started by.
    public static func agentProcess(above pid: pid_t, known: (String) -> String?, lookup: Lookup = .live) -> (pid: pid_t, agent: String)? {
        var current: pid_t? = pid
        for _ in 0..<6 {
            guard let process = current else { return nil }
            if let name = lookup.command(process), let agent = known(name) { return (process, agent) }
            current = lookup.parent(process)
        }
        return nil
    }

    /// The agent among a process's own and its forebears' commands, the
    /// nearest first, a few at most: the agent an MCP server or a hook was
    /// started by.
    public static func agent(above pid: pid_t, known: (String) -> String?) -> String? {
        agentProcess(above: pid, known: known)?.agent
    }

    /// The shells, which only pass a command line on: what one of them runs
    /// was started by whatever started the shell.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "env"]

    /// The agent that started a process, when that agent runs in no
    /// terminal (#140): then what the process's environment says of its
    /// session is not its own, and is not gone by.
    ///
    /// A session's variables are in the environment of everything started
    /// from it, and stay there in a program that goes on in the background
    /// and serves other terminals after. Codex 0.169 runs its sessions
    /// through one app server they share (`codex app-server`, started by
    /// the first of them, in no terminal), which starts each session's MCP
    /// server and hooks in the environment of that first one: every session
    /// after spoke to AgentTerm as the first. What an agent in a session
    /// starts itself is started by that agent, in the session's terminal:
    /// so it was with all four on 2026-11-18, whether the hook or the
    /// server itself has the terminal (Copilot CLI's and Antigravity's
    /// have) or not (the hooks of Claude Code and of Codex have none).
    /// `docs/AGENT-CLIS.md` has what was found.
    ///
    /// `pid` is the process that started it, looked at past the shells that
    /// only ran its command line. Nil when that is no agent, as for a
    /// server a test starts itself, or when the agent has a terminal or
    /// cannot be asked: then the environment is gone by, as before.
    public static func agentInNoTerminal(startedBy pid: pid_t, known: (String) -> String?, lookup: Lookup = .live) -> String? {
        var current: pid_t? = pid
        for _ in 0..<6 {
            guard let process = current, let name = lookup.command(process) else { return nil }
            if let agent = known(name) { return lookup.hasTerminal(process) == false ? agent : nil }
            guard shells.contains(name) else { return nil }
            current = lookup.parent(process)
        }
        return nil
    }
}
#endif
