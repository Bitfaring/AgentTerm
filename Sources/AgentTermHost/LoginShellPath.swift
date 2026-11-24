#if os(macOS)
import Foundation

/// The `PATH` the user's login shell has.
///
/// The host is started by the app or by launchd, so its own `PATH` is the
/// system's short one: nothing from Homebrew, nvm or whatever the user's
/// shell adds. Sessions do not mind, since they are started through that
/// shell. What the host runs itself does: git starts credential helpers,
/// hooks and `git-lfs` by name.
final class LoginShellPath: @unchecked Sendable {
    static let shared = LoginShellPath()

    private static let marker = "AGENTTERM_PATH:"

    private let shell: (() -> String)?
    private let lock = NSLock()
    private var asked = false
    private var known: String?
    private var knownVariables: [String: String] = [:]

    /// - Parameter shell: the program asked. Nil for the user's login shell,
    ///   which is never started under XCTest: there it answers nothing, so a
    ///   test that does not stand a shell of its own in leaves the `PATH` as
    ///   it is, and reads none of the user's startup files.
    init(shell: (() -> String)? = nil) {
        self.shell = shell
    }

    /// True in a process that runs XCTest's tests.
    static let underTests = NSClassFromString("XCTestCase") != nil

    private static let refusalLock = NSLock()
    nonisolated(unsafe) private static var refusals = 0

    /// How many times the user's shell was not started because tests run.
    static var refusedUnderTests: Int {
        refusalLock.lock()
        defer { refusalLock.unlock() }
        return refusals
    }

    /// The shell's `PATH`, asked for once and kept. Nil when the shell did
    /// not say. The first call blocks for as long as the shell takes to start.
    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !asked {
            (known, knownVariables) = ask()
            asked = true
        }
        return known
    }

    /// What the shell has of `AgentFolders.variables`, asked with its
    /// `PATH`: only those it has, not empty.
    func variables() -> [String: String] {
        _ = value()
        lock.lock()
        defer { lock.unlock() }
        return knownVariables
    }

    /// Asks again, since a tool may have been installed since. True when the
    /// answer is another one than before.
    func refresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = asked ? known : nil
        let (found, variables) = ask()
        asked = true
        // A shell that fails to answer once does not take away what is known.
        if let found {
            known = found
            knownVariables = variables
        }
        return found != nil && found != before
    }

    private func ask() -> (String?, [String: String]) {
        // Interactive too, as sessions are: what the user adds to PATH is
        // often in the file only an interactive shell reads. The variables
        // that move the agents' folders come with it (#264).
        let script =
            "printf '\(Self.marker)%s\\n' \"$PATH\"; "
            + AgentFolders.variables.map { "printf '\(Self.variableMarker)\($0)=%s\\n' \"$\($0)\"" }.joined(separator: "; ")
        let program: String
        if let shell {
            program = shell()
        } else if Self.underTests {
            Self.refusalLock.lock()
            Self.refusals += 1
            Self.refusalLock.unlock()
            return (nil, [:])
        } else {
            program = HostEnvironment.shell
        }
        guard let result = Subprocess.run(program, ["-l", "-i", "-c", script], cwd: HostEnvironment.homeDirectory, timeout: 8) else { return (nil, [:]) }
        let output = String(decoding: result.output, as: UTF8.self)
        return (Self.parse(output), Self.parseVariables(output))
    }

    private static let variableMarker = "AGENTTERM_VARIABLE:"

    /// The variables in what the shell printed, the empty ones left out.
    static func parseVariables(_ output: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: variableMarker) else { continue }
            let pair = line[range.upperBound...]
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals]), value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if AgentFolders.variables.contains(name), !value.isEmpty { found[name] = value }
        }
        return found
    }

    /// The path in what the shell printed, which may hold anything else the
    /// user's startup files print.
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: marker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}
#endif
