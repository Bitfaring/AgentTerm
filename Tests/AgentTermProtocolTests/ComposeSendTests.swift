import AgentTermProtocol
import XCTest

final class ComposeSendTests: XCTestCase {
    private let question = AgentState.waitingForAnswer(AgentQuestion(text: "Which parser?", choices: ["CSV", "JSON"]))
    private let permission = AgentState.waitingForPermission(AgentQuestion(text: "Run swift test?"))
    private let done = AgentState.done(said: "Finished.")
    private let working = AgentState.working(since: Date(timeIntervalSince1970: 0))

    /// IOS-12 (#232): a prompt written while the agent asks something is
    /// not sent, or the agent would take it as the answer. Before the fix
    /// Send typed it into the session whatever the agent was doing.
    func testAPromptIsHeldWhileTheAgentAsks() {
        XCTAssertEqual(ComposeSend.send(state: question, side: .prompt), .held(ComposeWords.held(question)))
        XCTAssertEqual(ComposeSend.send(state: permission, side: .prompt), .held(ComposeWords.held(permission)))
        XCTAssertTrue(ComposeWords.held(question).contains("waiting for an answer"), ComposeWords.held(question))
        XCTAssertTrue(ComposeWords.held(permission).contains("waiting for permission"), ComposeWords.held(permission))
    }

    /// IOS-12: an agent that asks nothing takes the prompt, as before; so
    /// does a session whose state is not known, a shell above all.
    func testAPromptIsSentWhenTheAgentAsksNothing() {
        XCTAssertEqual(ComposeSend.send(state: done, side: .prompt), .prompt)
        XCTAssertEqual(ComposeSend.send(state: working, side: .prompt), .prompt)
        XCTAssertEqual(ComposeSend.send(state: nil, side: .prompt), .prompt)
    }

    /// IOS-12: the answer goes with the state it answers, for the host to
    /// type only while the agent still asks that.
    func testAnAnswerNamesWhatItAnswers() {
        XCTAssertEqual(ComposeSend.send(state: question, side: .answer), .answer(to: question))
        XCTAssertEqual(ComposeSend.send(state: permission, side: .answer), .answer(to: permission))
    }

    /// IOS-12: an answer to an agent that has moved on is not sent; were
    /// it typed, it would go into whatever comes next.
    func testAnAnswerToAnAgentThatNoLongerAsksIsNotSent() {
        XCTAssertEqual(ComposeSend.send(state: done, side: .answer), .held(ComposeWords.movedOn))
        XCTAssertEqual(ComposeSend.send(state: nil, side: .answer), .held(ComposeWords.movedOn))
    }

    /// IOS-12: once answered, the prompt waits for the agent to go on, and
    /// says so rather than that the agent waits for an answer. Answering
    /// again is the user's to do.
    func testAfterAnAnswerThePromptWaitsForTheAgentToGoOn() {
        XCTAssertEqual(ComposeSend.send(state: question, side: .prompt, answered: question), .held(ComposeWords.heldAfterAnswer))
        XCTAssertEqual(ComposeSend.send(state: question, side: .answer, answered: question), .answer(to: question))
        // Asked something else since: it waits for that answer.
        let next = AgentState.waitingForAnswer(AgentQuestion(text: "And the tests?"))
        XCTAssertEqual(ComposeSend.send(state: next, side: .prompt, answered: question), .held(ComposeWords.held(next)))
        // Gone on: the prompt is sent.
        XCTAssertEqual(ComposeSend.send(state: done, side: .prompt, answered: question), .prompt)
    }

    /// IOS-12: the place to answer is shown only while the agent asks; when
    /// it no longer does, the prompt is shown again.
    func testTheAnswerIsShownOnlyWhileTheAgentAsks() {
        XCTAssertEqual(ComposeSend.side(.answer, state: question), .answer)
        XCTAssertEqual(ComposeSend.side(.answer, state: permission), .answer)
        XCTAssertEqual(ComposeSend.side(.prompt, state: question), .prompt)
        XCTAssertEqual(ComposeSend.side(.answer, state: done), .prompt)
        XCTAssertEqual(ComposeSend.side(.answer, state: working), .prompt)
        XCTAssertEqual(ComposeSend.side(.answer, state: nil), .prompt)
    }

    /// IOS-12: what the agent asks, with its choices, for the answer's place.
    func testTheQuestionIsWhatTheAgentAsks() {
        XCTAssertEqual(ComposeSend.question(of: question), AgentQuestion(text: "Which parser?", choices: ["CSV", "JSON"]))
        XCTAssertEqual(ComposeSend.question(of: permission)?.text, "Run swift test?")
        XCTAssertNil(ComposeSend.question(of: done))
        XCTAssertNil(ComposeSend.question(of: nil))
    }
}
