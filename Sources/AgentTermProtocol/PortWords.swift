import Foundation

/// What the Mac app says when the program listening on its host's port is
/// not an AgentTerm host (#204): a proxy, a test runner, anything else.
/// Written here, where both apps take what they say from (principle 9).
public enum PortWords {
    /// The banner's sentence: the port, and the program by its name.
    public static func inUse(port: UInt16, by program: String) -> String {
        "Port \(port) is in use by \(program), which is not an AgentTerm host."
    }

    /// What it means, under the sentence: AgentTerm leaves it alone.
    public static let inUseDetail =
        "This app reaches its host through it, and does not stop it. To use this app's own host, quit that program."
}
