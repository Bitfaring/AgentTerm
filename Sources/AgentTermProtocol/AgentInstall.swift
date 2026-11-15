import Foundation

/// How an agent that is not installed on the Mac is installed, as its maker
/// says to: shown when its button in the Mac's header is pressed. The app
/// installs nothing by itself: it shows the command, copies it, or types it
/// into a new shell for the user to read and run.
///
/// Each command was read on its maker's own page on 2026-11-15, the first
/// one there for macOS: `docs`.
public struct AgentInstallGuide: Equatable, Identifiable, Sendable {
    /// The agent's id, as `AgentInfo.id`.
    public let agent: String
    public var id: String { agent }
    public let name: String
    /// The command its maker gives first for macOS.
    public let command: String
    /// Another way its maker gives, with Homebrew; nil when there is none.
    public let alternative: String?
    /// Where its maker says how to install it, and what it needs.
    public let docs: URL
    /// What it needs besides, in words; nil when its maker names nothing.
    public let needs: String?

    /// The guide for an agent AgentTerm knows; nil for any other.
    public static func forAgent(_ id: String, name: String) -> AgentInstallGuide? {
        switch id {
        case "claude":
            return AgentInstallGuide(
                agent: id, name: name, command: "curl -fsSL https://claude.ai/install.sh | bash", alternative: "brew install --cask claude-code",
                docs: URL(string: "https://code.claude.com/docs/en/setup")!,
                needs: "A Claude Pro, Max, Ultra, Team or Enterprise plan, or a Console account.")
        case "codex":
            return AgentInstallGuide(
                agent: id, name: name, command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh", alternative: "brew install --cask codex",
                docs: URL(string: "https://github.com/openai/codex")!, needs: nil)
        case "agy":
            return AgentInstallGuide(
                agent: id, name: name, command: "curl -fsSL https://antigravity.google/cli/install.sh | bash", alternative: nil,
                docs: URL(string: "https://antigravity.google/docs/getting-started?tab=cli")!, needs: nil)
        case "copilot":
            return AgentInstallGuide(
                agent: id, name: name, command: "curl -fsSL https://gh.io/copilot-install | bash", alternative: "brew install --cask copilot-cli",
                docs: URL(string: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli")!,
                needs: "An active GitHub Copilot subscription.")
        default:
            return nil
        }
    }

    public var title: String { "Install \(name)" }

    /// What is said first: where it is missing, and what to do.
    public func message(on mac: String) -> String {
        "\(name) is not installed on \(mac). Run its maker's install command in a terminal there, then look for it again."
    }

    /// Said of a button that stands for an agent that is not installed.
    public func help(on mac: String) -> String { "\(name) is not installed on \(mac). Click to see how to install it." }

    /// Said once it is found.
    public var installed: String { "\(name) is installed." }

    /// Said when it was looked for again and is still not found.
    public var stillMissing: String {
        "\(name) is still not found. It is looked for where your login shell looks: a command that changed your PATH in a shell's settings counts once a new shell starts."
    }
}
