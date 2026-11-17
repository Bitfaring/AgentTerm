import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What a turn came to (#71), read from each agent's own record as the four
/// were found writing it on 2026-11-17 (Claude Code 2.1.326, Codex 0.169.0,
/// Copilot CLI 1.0.112, Antigravity 1.5.9), each asked to run `echo hello`
/// and `sh -c 'echo oops >&2; exit 3'`. The lines are those, cut down to
/// what is read, with a turn before the last one that must be left out.
final class TurnTranscriptTests: XCTestCase {
    private func lines(_ objects: [String]) -> Data { Data(objects.joined(separator: "\n").utf8) }
    private let expected = [
        TurnResult.Command(command: "echo hello", exitCode: 0), TurnResult.Command(command: "sh -c 'echo oops >&2; exit 3'", exitCode: 3),
    ]

    /// TURN-2: Claude Code: `Bash` tool uses after the last prompt; a result
    /// that is an error says "Exit code N".
    func testClaudeCodesTurn() throws {
        let data = lines([
            #"{"type":"user","message":{"role":"user","content":"an earlier prompt"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t0","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t0","is_error":false,"content":"a"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"Run these two shell commands"},"promptId":"p1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo hello","description":"Print hello"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"hello"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sh -c 'echo oops >&2; exit 3'"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 3\noops"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The second failed with code 3."}]}}"#,
        ])
        let turn = try XCTUnwrap(TurnTranscript.parse(agent: "claude", data: data))
        XCTAssertEqual(turn.request, "Run these two shell commands")
        XCTAssertEqual(turn.reply, "The second failed with code 3.")
        XCTAssertEqual(turn.commands, expected)
    }

    /// TURN-2: Codex: the turn's `CommandExecution` items, by its `turn_id`.
    func testCodexsTurn() throws {
        let data = lines([
            #"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","ls"],"status":"completed","exit_code":0}}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Run these two shell commands"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-2","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","echo hello"],"status":"completed","exit_code":0}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-2","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","sh -c 'echo oops >&2; exit 3'"],"status":"failed","exit_code":3}}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The second exited with code 3."}]}}"#,
        ])
        let turn = try XCTUnwrap(TurnTranscript.parse(agent: "codex", data: data, turnID: "turn-2"))
        XCTAssertEqual(turn.request, "Run these two shell commands")
        XCTAssertEqual(turn.reply, "The second exited with code 3.")
        XCTAssertEqual(turn.commands, expected)
        // Without the turn's id, the commands after the last prompt.
        XCTAssertEqual(TurnTranscript.parse(agent: "codex", data: data)?.commands, expected)
    }

    /// TURN-2: Copilot CLI: `tool.execution_start` of `bash`, and the
    /// `shellExecution.exitCode` of its `tool.execution_complete`.
    func testCopilotsTurn() throws {
        let data = lines([
            #"{"type":"user.message","data":{"content":"an earlier prompt"}}"#,
            #"{"type":"tool.execution_start","data":{"toolCallId":"c0","toolName":"bash","arguments":{"command":"ls"}}}"#,
            #"{"type":"user.message","data":{"content":"Run these two shell commands"}}"#,
            #"{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"c1","name":"bash"}]}}"#,
            #"{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"bash","arguments":{"command":"echo hello"}}}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"c1","shellExecution":{"exitCode":0},"success":true}}"#,
            #"{"type":"tool.execution_start","data":{"toolCallId":"c2","toolName":"bash","arguments":{"command":"sh -c 'echo oops >&2; exit 3'"}}}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"c2","shellExecution":{"exitCode":3},"success":true}}"#,
            #"{"type":"assistant.message","data":{"content":"Commands completed; the second exited with code 3.","toolRequests":[]}}"#,
        ])
        let turn = try XCTUnwrap(TurnTranscript.parse(agent: "copilot", data: data))
        XCTAssertEqual(turn.request, "Run these two shell commands")
        XCTAssertEqual(turn.reply, "Commands completed; the second exited with code 3.")
        XCTAssertEqual(turn.commands, expected)
    }

    /// TURN-2: Antigravity: `run_command` calls, each followed by a step
    /// that says "Command exited with code N".
    func testAntigravitysTurn() throws {
        let data = lines([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nRun these two shell commands\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"echo hello"}}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"GENERIC","content":"Created At: x\nCommand exited with code 0.\n\nCommand output:\nhello"}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"sh -c 'echo oops >&2; exit 3'"}}]}"#,
            #"{"step_index":4,"source":"MODEL","type":"GENERIC","content":"Command exited with code 3.\n\nThere were sandbox errors"}"#,
            #"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","content":"Ran both commands: the second exited 3."}"#,
        ])
        let turn = try XCTUnwrap(TurnTranscript.parse(agent: "agy", data: data))
        XCTAssertEqual(turn.request, "Run these two shell commands")
        XCTAssertEqual(turn.reply, "Ran both commands: the second exited 3.")
        XCTAssertEqual(turn.commands, expected)
    }

    /// TURN-3: what changed between two looks at a folder: a file changed
    /// again, one that came, one put back as it was; one changed before and
    /// not touched is not of the turn.
    func testWhatChangedBetweenTwoLooks() {
        let then = Date(timeIntervalSince1970: 1000), later = Date(timeIntervalSince1970: 2000)
        let before = GitSnapshot(
            top: "/r",
            files: [
                "a.txt": .init(status: "M", added: 1, removed: 0, size: 10, modified: then),
                "b.txt": .init(status: "M", added: 2, removed: 1, size: 20, modified: then),
                "c.txt": .init(status: "M", added: 1, removed: 0, size: 5, modified: then),
            ])
        let after = GitSnapshot(
            top: "/r",
            files: [
                "a.txt": .init(status: "M", added: 1, removed: 0, size: 12, modified: later),
                "b.txt": .init(status: "M", added: 2, removed: 1, size: 20, modified: then),
                "new.txt": .init(status: "??", size: 3, modified: later),
            ])
        XCTAssertEqual(
            GitSnapshot.changes(from: before, to: after),
            [
                TurnResult.File(path: "a.txt", status: "M", added: 1, removed: 0, changedBefore: true),
                TurnResult.File(path: "c.txt", status: nil, changedBefore: true),
                TurnResult.File(path: "new.txt", status: "??"),
            ])
    }
}
