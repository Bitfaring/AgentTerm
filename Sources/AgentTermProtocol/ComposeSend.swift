import Foundation

/// Where what is written under a session's terminal goes (#232): the
/// iPhone's message field, and anything else that sends a prompt of the
/// user's own into a session that may be asking something meanwhile.
///
/// The owner was writing his next prompt; the agent asked a question; Send
/// typed the prompt into the session, and the agent took it as the answer.
/// So the prompt and the answer are two texts kept apart (the owner's
/// decision, 2026-11-22): while the agent asks, a prompt is not sent, and
/// the answer is written in a place of its own, sent with the state it
/// answers (`ClientMessage.answer`), which the host types only while the
/// agent still asks that.
public enum ComposeSend: Equatable, Sendable {
    /// Typed into the session as the next prompt: the agent asks nothing.
    case prompt
    /// Sent as the answer to what the agent asks, naming that state: the
    /// host refuses it once the agent has moved on.
    case answer(to: AgentState)
    /// Not sent, for the reason given; what is written stays.
    case held(String)

    /// Which of the two texts is written: the next prompt, or the answer to
    /// what the agent asks.
    public enum Side: Equatable, Sendable {
        case prompt
        case answer
    }

    /// The side on screen: the answer only while the agent asks, whatever
    /// was picked. When the agent no longer asks, the prompt is shown again.
    public static func side(_ picked: Side, state: AgentState?) -> Side {
        state?.isWaiting == true ? picked : .prompt
    }

    /// What Send does with what is written on `side`, the agent being in
    /// `state` (nil: not known, as for a shell). `answered` is the state an
    /// answer was sent to from here, while the agent is still in it.
    public static func send(state: AgentState?, side: Side, answered: AgentState? = nil) -> ComposeSend {
        guard let state, state.isWaiting else {
            return side == .prompt ? .prompt : .held(ComposeWords.movedOn)
        }
        switch side {
        case .answer: return .answer(to: state)
        case .prompt: return .held(answered == state ? ComposeWords.heldAfterAnswer : ComposeWords.held(state))
        }
    }

    /// What the agent asks, when it asks something.
    public static func question(of state: AgentState?) -> AgentQuestion? {
        switch state {
        case .waitingForPermission(let question)?, .waitingForAnswer(let question)?: return question
        default: return nil
        }
    }
}

/// The words of the place to answer an agent from, and of a prompt held
/// while it asks (#232), in both apps (principle 9).
public enum ComposeWords {
    /// The button over the message field while the agent asks.
    public static let answerButton = "Answer the Agent"
    /// The button that goes back from the answer to the prompt.
    public static let promptButton = "Back to Your Prompt"
    /// The answer's own field.
    public static let answerField = "Your answer"
    /// Over what the agent asks.
    public static func asks(_ state: AgentState) -> String {
        if case .waitingForPermission = state { return "It asks for permission" }
        return "It asks"
    }
    /// A permission's choices are the agent's own, not told to AgentTerm.
    public static let choicesInTerminal = "Its choices are in the terminal above: write the one you pick."
    /// A prompt not sent while the agent asks.
    public static func held(_ state: AgentState) -> String {
        "The agent is \(state.name): this prompt is not sent, as it would be taken as the answer. It can be sent once the agent has its answer."
    }
    /// A prompt not sent after an answer was sent, before the agent goes on.
    public static let heldAfterAnswer = "The answer was sent: this prompt can be sent once the agent goes on."
    /// An answer to an agent that no longer asks.
    public static let movedOn = PushWords.movedOn
}
