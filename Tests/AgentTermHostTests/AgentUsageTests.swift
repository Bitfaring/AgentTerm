import AgentTermProtocol
import XCTest

@testable import AgentTermHost

final class AgentUsageTests: XCTestCase {
    private func parse(_ agent: String, _ lines: [String]) -> SessionUsage? {
        AgentUsage.parse(agent: agent, data: Data(lines.joined(separator: "\n").utf8))
    }

    func testClaudeTakesTheNewestReplyOfTheMainConversation() {
        let usage = parse(
            "claude",
            [
                #"cut off line","usage":{"input_tokens":999}}"#,
                #"{"type":"assistant","message":{"model":"claude-a","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":5,"output_tokens":7}}}"#,
                #"{"type":"assistant","message":{"model":"claude-b","usage":{"input_tokens":4,"cache_read_input_tokens":236021,"cache_creation_input_tokens":39,"output_tokens":1953}}}"#,
                #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-sub","usage":{"input_tokens":50,"output_tokens":1}}}"#,
                #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
                #"{"type":"user","message":{"role":"user","content":"what is my usage"}}"#,
            ])
        XCTAssertEqual(usage, SessionUsage(model: "claude-b", contextTokens: 236_064))
        XCTAssertNil(usage?.contextFraction, "Claude Code does not record the window")
    }

    func testCodexReadsContextAndLimits() {
        let usage = parse(
            "codex",
            [
                #"{"type":"turn_context","payload":{"model":"gpt-x"}}"#,
                #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":51762},"last_token_usage":{"total_tokens":17639},"model_context_window":475000},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1794396857},"secondary":{"used_percent":97.0,"window_minutes":10080,"resets_at":1794388909}}}}"#,
                #"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":13.0,"window_minutes":300,"resets_at":1794396857},"secondary":{"used_percent":97.5,"window_minutes":10080,"resets_at":1794388909}}}}"#,
            ])
        XCTAssertEqual(usage?.model, "gpt-x")
        XCTAssertEqual(usage?.contextTokens, 17639, "the last request, not the running total")
        XCTAssertEqual(usage?.contextWindow, 475_000)
        XCTAssertEqual(
            usage?.limits,
            [
                UsageLimit(windowMinutes: 300, usedPercent: 13, resetsAt: Date(timeIntervalSince1970: 1_794_396_857)),
                UsageLimit(windowMinutes: 10080, usedPercent: 97.5, resetsAt: Date(timeIntervalSince1970: 1_794_388_909)),
            ], "the newest limits, also from an event without token counts")
        XCTAssertEqual(usage?.limits.map(\.label), ["5h", "Week"])
    }

    func testCopilotReadsTheLastRequestAndPremiumRequests() {
        let usage = parse(
            "copilot",
            [
                #"{"type":"session.usage_record","data":{"usage":{"model":"gpt-a","modelDisplayName":"GPT A","inputTokens":100,"maxPromptTokens":272000}}}"#,
                #"{"type":"session.usage_record","data":{"usage":{"model":"gpt-b","modelDisplayName":"GPT B","inputTokens":20196,"maxPromptTokens":272000}}}"#,
                #"{"type":"session.usage_checkpoint","data":{"totalPremiumRequests":3}}"#,
            ])
        XCTAssertEqual(usage, SessionUsage(model: "GPT B", contextTokens: 20196, contextWindow: 272_000, premiumRequests: 3))
        XCTAssertEqual(usage?.contextFraction ?? 0, 20196.0 / 272_000, accuracy: 0.0001)
    }

    func testAntigravityReadsTheLastStep() {
        let usage = parse(
            "agy",
            [
                #"{"step_index":1,"input_tokens":9336,"cache_read_tokens":0,"output_tokens":13}"#,
                #"{"step_index":2,"input_tokens":12000,"cache_read_tokens":500,"output_tokens":20}"#,
            ])
        XCTAssertEqual(usage, SessionUsage(contextTokens: 12500))
    }

    /// USAGE-12 (#130): each agent's thinking level, where each records it,
    /// as the four were found writing it on 2026-11-17.
    func testEachAgentSaysHowHardItThinks() {
        XCTAssertEqual(parse("codex", [#"{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"medium","summary":"none"}}"#])?.effort, "medium")
        XCTAssertEqual(
            parse(
                "copilot",
                [#"{"type":"session.usage_record","data":{"usage":{"model":"gpt-5.6-luna","inputTokens":100,"maxPromptTokens":272000,"reasoningEffort":"high"}}}"#]
            )?.effort, "high")
        XCTAssertEqual(
            parse("copilot", [#"{"type":"session.model_change","data":{"newModel":"gpt-5.6-luna","reasoningEffort":"medium"}}"#])?.effort, "medium")
        XCTAssertEqual(
            parse("agy", [#"{"step_index":1,"model":"gemini-4-hydrogen-medium","input_tokens":11408,"cache_read_tokens":0}"#]),
            SessionUsage(contextTokens: 11408, effort: "medium"))
        XCTAssertNil(AgentUsage.antigravityEffort(of: "gemini-4-hydrogen"), "a name without a level says none")
        let status = Data(#"{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"xhigh"},"thinking":{"enabled":true}}"#.utf8)
        XCTAssertEqual(StatusLineRelay.usage(from: status)?.effort, "xhigh")
        XCTAssertEqual(SessionUsage(model: "Opus 5.5", effort: "xhigh").modelLine(or: "Claude Code"), "Opus 5.5 · xhigh")
        XCTAssertEqual(SessionUsage().modelLine(or: "Claude Code"), "Claude Code", "nothing is shown of a level not known")
    }

    func testNothingRecordedIsNil() {
        XCTAssertNil(parse("claude", [#"{"type":"user","message":{"content":"hi"}}"#]))
        XCTAssertNil(parse("codex", []))
        XCTAssertNil(parse("zsh", [#"{"input_tokens":5}"#]))
        XCTAssertNil(parse("copilot", ["not json at all"]))
    }

    func testShortTokenCounts() {
        XCTAssertEqual([850, 1500, 17639, 236_064, 1_250_000].map(SessionUsage.short), ["850", "1.5K", "18K", "236K", "1.2M"])
    }
}

final class StatusLineRelayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.claude"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var home: String { root.appendingPathComponent("home").path }
    private var project: String { root.appendingPathComponent("project").path }
    private var file: String { root.appendingPathComponent("usage/session-1.json").path }

    private func input(_ extra: String = "") -> Data {
        Data(
            #"{"model":{"id":"claude-x","display_name":"Claude X"},"workspace":{"project_dir":"\#(project)"},"context_window":{"context_window_size":200000,"used_percentage":8,"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}}\#(extra)}"#
                .utf8)
    }

    func testReadsContextAndLimits() {
        let limits = #","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}"#
        XCTAssertEqual(
            StatusLineRelay.usage(from: input(limits)),
            SessionUsage(
                model: "Claude X", contextTokens: 15500, contextWindow: 200_000,
                limits: [
                    UsageLimit(windowMinutes: 300, usedPercent: 23.5, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
                    UsageLimit(windowMinutes: 10080, usedPercent: 41.2, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)),
                ]
            ))
        // No subscription, or before the first reply: no limits, and that is fine.
        XCTAssertEqual(StatusLineRelay.usage(from: input())?.limits, [])
        XCTAssertNil(StatusLineRelay.usage(from: Data("not json".utf8)))
    }

    func testSavesTheInputAndPrintsNothingWithoutAUserStatusLine() throws {
        let output = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        XCTAssertEqual(output, Data())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), input())
    }

    /// USE-5: what the relay could not save is said, for the host to report.
    func testWhatCannotBeSavedIsSaidAndForgottenOnceItIsSaved() throws {
        // A folder where the file should be: it cannot be written.
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: true)
        _ = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        let problem = StatusLineRelay.failureFile(for: file)
        XCTAssertFalse(try String(contentsOfFile: problem, encoding: .utf8).isEmpty, "why it could not be saved")

        try FileManager.default.removeItem(atPath: file)
        _ = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), input())
        XCTAssertFalse(FileManager.default.fileExists(atPath: problem), "saved again, so nothing to report")
    }

    func testRunsTheUsersOwnStatusLineWithTheSameInput() throws {
        try #"{"statusLine":{"type":"command","command":"/usr/bin/sed -n 's/.*display_name\":\"\\([^\"]*\\)\".*/[\\1] mine/p'"}}"#
            .write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let output = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "[Claude X] mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    func testTheProjectsStatusLineComesFirstAndOursIsNeverRunAgain() throws {
        try #"{"statusLine":{"type":"command","command":"echo user"}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo user")
        try #"{"statusLine":{"type":"command","command":"echo project"}}"#.write(toFile: project + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo project")
        try #"{"statusLine":{"type":"command","command":"'/Apps/agenttermd' statusline '/tmp/x.json'"}}"#.write(toFile: project + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo user")
        // A configuration folder of the user's choosing is honored.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"echo other"}}"#.write(toFile: other.path + "/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: nil, home: home, environment: ["CLAUDE_CONFIG_DIR": other.path]), "echo other")
    }

    /// USAGE-13 (#129): Claude Code's status line, which
    /// `agenttermd setup claude` put in its settings, keeps the one the user
    /// had and runs it after AgentTerm's, puts it back when taken out, and
    /// saves nothing outside a session of AgentTerm's.
    func testTheStatusLineKeepsTheUsersOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus","statusLine":{"type":"command","command":"printf mine"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let setup = AgentSetup(
            directory: root.appendingPathComponent("setup"), tool: "/Apps/My App's/agenttermd", home: home.path, environment: [:], locate: { [] },
            run: { _ in nil })
        try setup.setClaudeStatusLine()
        let set = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((set["statusLine"] as? [String: String])?["command"], "'/Apps/My App'\\''s/agenttermd' statusline")
        XCTAssertEqual(set["model"] as? String, "opus", "the user's own settings changed")
        // The command runs as the shell unquotes it.
        let words = Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' " + setup.statusLineCommand])
        XCTAssertEqual(String(decoding: words?.output ?? Data(), as: UTF8.self), "/Apps/My App's/agenttermd\nstatusline\n")

        // Run: it saves what it is given in its session's file, then shows
        // what the user's own line printed.
        let previous = AgentSetup.previousStatusLine(in: root.appendingPathComponent("setup"))
        let file = root.appendingPathComponent("usage/session-1.json").path
        let shown = StatusLineRelay.run(input: Data(#"{"model":{"id":"opus"}}"#.utf8), file: file, previous: previous, home: home.path, environment: [:])
        XCTAssertEqual(String(decoding: shown, as: UTF8.self), "mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        // Outside a session of AgentTerm's: nothing saved, theirs shown.
        let outside = StatusLineRelay.run(input: Data(#"{"model":{"id":"opus"}}"#.utf8), file: nil, previous: previous, home: home.path, environment: [:])
        XCTAssertEqual(String(decoding: outside, as: UTF8.self), "mine")

        // Taken out: the user's own again.
        try setup.restoreClaudeStatusLine()
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((back["statusLine"] as? [String: String])?["command"], "printf mine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }
}

final class ConfiguredModelTests: XCTestCase {
    func testReadsTheModelEachAgentsSettingsName() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        try "# comment\nmodel_reasoning_effort = \"low\"\nmodel = \"gpt-x\"  \n\n[profiles.other]\nmodel = \"not-this-one\"\n"
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"model":"Gemini 4 Argon (Medium)","permissions":{}}"#
            .write(to: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentUsage.configuredModel(agent: "codex", home: home.path, environment: [:]), "gpt-x")
        XCTAssertEqual(AgentUsage.configuredModel(agent: "agy", home: home.path, environment: [:]), "Gemini 4 Argon (Medium)")
        XCTAssertNil(AgentUsage.configuredModel(agent: "claude", home: home.path, environment: [:]), "Claude Code reports its own")
        XCTAssertNil(AgentUsage.configuredModel(agent: "codex", home: "/nonexistent", environment: [:]))
    }

    func testCodexAndCopilotSayWhatTheyKnowBeforeTheFirstReply() {
        let codex = AgentUsage.parse(agent: "codex", data: Data(#"{"type":"session_meta","payload":{"id":"s","cwd":"/x","context_window":475000}}"#.utf8))
        XCTAssertEqual(codex, SessionUsage(contextTokens: 0, contextWindow: 475_000))
        let copilot = AgentUsage.parse(agent: "copilot", data: Data(#"{"type":"session.model_change","data":{"newModel":"gpt-5.6-terra","cause":"initial_resolution"}}"#.utf8))
        XCTAssertEqual(copilot, SessionUsage(model: "gpt-5.6-terra"))
    }
}
