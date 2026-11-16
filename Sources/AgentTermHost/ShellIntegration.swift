#if os(macOS)
import Foundation

/// Finds the marks a shell writes of its commands (OSC 133: `ESC ] 133 ; X
/// [; parameter] BEL` or `ESC \`) in a session's output, as it comes, in
/// pieces of any size: a mark cut in two is found in the piece it ends in.
struct CommandMarks {
    struct Mark: Equatable {
        /// A, B, C or D.
        let kind: Character
        /// What follows the kind, an exit code after D.
        let parameter: Substring
        /// Where in the piece the mark ends, just past it.
        let end: Int
    }

    private enum State {
        case text, escape, body, bodyEscape
    }

    private var state = State.text
    private var body: [UInt8] = []
    /// No mark is longer: what is, is some other string, not looked at.
    private let longest = 64

    mutating func scan(_ bytes: [UInt8]) -> [Mark] {
        // Most output holds no escape at all, and nothing is cut in two.
        if state == .text, !bytes.contains(0x1b) { return [] }
        var found: [Mark] = []
        for (index, byte) in bytes.enumerated() {
            switch state {
            case .text:
                if byte == 0x1b { state = .escape }
            case .escape:
                if byte == 0x5d {
                    state = .body
                    body.removeAll(keepingCapacity: true)
                } else {
                    state = byte == 0x1b ? .escape : .text
                }
            case .body:
                if byte == 0x07 {
                    finish(at: index + 1, into: &found)
                } else if byte == 0x1b {
                    state = .bodyEscape
                } else if body.count < longest {
                    body.append(byte)
                } else {
                    state = .text
                }
            case .bodyEscape:
                if byte == 0x5c {
                    finish(at: index + 1, into: &found)
                } else {
                    state = byte == 0x1b ? .escape : .text
                }
            }
        }
        return found
    }

    private mutating func finish(at end: Int, into found: inout [Mark]) {
        state = .text
        let text = String(decoding: body, as: UTF8.self)
        guard text.hasPrefix("133;"), let kind = text.dropFirst(4).first else { return }
        let rest = text.dropFirst(5)
        found.append(Mark(kind: kind, parameter: rest.hasPrefix(";") ? rest.dropFirst() : rest, end: end))
    }
}

/// Sets up a shell an agent opens to say when each command starts and ends,
/// with its exit code (OSC 133), so that `shell_run` answers with the
/// command's output and exit code once it has ended (#10). Only zsh is set
/// up, the shell of a Mac; fish says so by itself; another shell is used as
/// it is, and its commands are waited for until the screen is still.
///
/// zsh reads its startup files from `ZDOTDIR`: it is pointed at a folder of
/// the host's whose files read the user's own, as zsh would have, then add
/// the marks, and point zsh back at the user's folder. The user's own
/// sessions are never set up.
enum ShellIntegration {
    /// What a session of `shell` is given, or nil for a shell that is not
    /// set up.
    /// - Parameter startup: What is run before the first prompt (Settings >
    ///   Shell), so that it is not taken for a command of the agent's.
    static func environment(shell: String, current: [String: String], startup: String? = nil) -> [String: String]? {
        guard (shell as NSString).lastPathComponent == "zsh", let folder = try? zshFolder() else { return nil }
        let own = current["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
        var environment = [
            "ZDOTDIR": folder.path,
            "AGENTTERM_USER_ZDOTDIR": own ?? current["HOME"] ?? HostEnvironment.homeDirectory,
            "AGENTTERM_ZDOTDIR_WAS_SET": own == nil ? "0" : "1",
        ]
        if let startup { environment["AGENTTERM_STARTUP"] = startup }
        return environment
    }

    /// The host's folder of zsh startup files, written each time, so that a
    /// new build's take the place of an older one's.
    static func zshFolder() throws -> URL {
        let folder = HostEnvironment.supportDirectory.appendingPathComponent("shell-integration/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text) in zshFiles {
            let file = folder.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) != text { try Data(text.utf8).write(to: file, options: .atomic) }
        }
        return folder
    }

    /// Reads the user's file of that name from their folder, as zsh would.
    /// The user's file may itself set `ZDOTDIR`: that is their folder from
    /// then on.
    private static func reading(_ name: String) -> String {
        """
        __agentterm_zdotdir=$ZDOTDIR
        ZDOTDIR=$AGENTTERM_USER_ZDOTDIR
        [[ -f $ZDOTDIR/\(name) ]] && builtin source $ZDOTDIR/\(name)
        AGENTTERM_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$__agentterm_zdotdir

        """
    }

    private static let header = """
        # AgentTerm: a shell an agent opened says when each command starts
        # and ends, with its exit code (OSC 133), so that the agent knows.
        # The user's own startup files are read as zsh would read them.

        """

    static let zshFiles: [String: String] = [
        ".zshenv": header + reading(".zshenv"),
        ".zprofile": header + reading(".zprofile"),
        ".zshrc": header + reading(".zshrc") + """
            # From here on zsh reads the user's own files: .zlogin, and those
            # of a zsh started from this one.
            if [[ $AGENTTERM_ZDOTDIR_WAS_SET == 1 ]]; then
              export ZDOTDIR=$AGENTTERM_USER_ZDOTDIR
            else
              unset ZDOTDIR
            fi
            unset __agentterm_zdotdir AGENTTERM_USER_ZDOTDIR AGENTTERM_ZDOTDIR_WAS_SET
            # What Settings > Shell runs first in an agent's shell, before
            # its first prompt: not one of the agent's commands.
            if [[ -n $AGENTTERM_STARTUP ]]; then
              eval "$AGENTTERM_STARTUP"
            fi
            unset AGENTTERM_STARTUP
            __agentterm_preexec() { builtin print -n '\\e]133;C\\a' }
            __agentterm_precmd() { local s=$?; builtin print -n "\\e]133;D;$s\\a\\e]133;A\\a" }
            # First, to see the command's exit code before another hook runs.
            precmd_functions=(__agentterm_precmd ${precmd_functions[@]})
            preexec_functions+=(__agentterm_preexec)

            """,
    ]
}
#endif
