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

    /// The agent among a process's own and its forebears' commands, the
    /// nearest first, a few at most: the agent an MCP server or a hook was
    /// started by.
    public static func agent(above pid: pid_t, known: (String) -> String?) -> String? {
        var current: pid_t? = pid
        for _ in 0..<6 {
            guard let process = current else { return nil }
            if let name = command(of: process), let agent = known(name) { return agent }
            current = parent(of: process)
        }
        return nil
    }
}
#endif
