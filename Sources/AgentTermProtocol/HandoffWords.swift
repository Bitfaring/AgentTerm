/// What both apps say when a conversation cannot be handed off (#307,
/// principle 9): written once, shown by both.
public enum HandoffWords {
    /// The agent of a session has not saved its conversation yet.
    public static func noConversation(_ agent: String) -> String {
        "\(agent) has no conversation to hand off in this session yet. It saves one after your first message."
    }

    public static let noOtherAgent = "No other agent is installed to hand this off to."
}
