import AgentTermProtocol
import SwiftUI

/// Settings > Agents: what AgentTerm tells each agent when it starts a
/// session of it, the user's own words or the default, edited on the Mac
/// (principle 1). The host keeps them, so a schedule's run and an agent
/// started from the iPhone are told the same.
struct AgentPromptsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var agent = "claude"
    @State private var text = ""
    /// The text as it was when it was shown, to know what was changed.
    @State private var shown = ""

    private static let agents: [(id: String, name: String, how: String)] = [
        ("claude", "Claude Code", "Given as part of its system prompt (--append-system-prompt), and as the MCP server's instructions."),
        ("codex", "Codex", "Given as the instructions of AgentTerm's MCP server, which Codex reads."),
        ("copilot", "Copilot CLI", "Given in a file of instructions it is told of, next to any of yours, and as the MCP server's instructions."),
        ("agy", "Antigravity", "Given as a rule that is always on, in a folder of AgentTerm's it is given, and as the MCP server's instructions."),
    ]

    private var isCustom: Bool { model.agentPromptsCustom[agent] != nil }
    private var defaultText: String { model.agentPromptsDefaults[agent] ?? "" }
    private var changed: Bool { text != shown }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(symbol: "sparkles", tint: .purple, title: "Agents", subtitle: "What \(AppChannel.current.appName) tells each agent when it starts a session of it.")
            Picker("Agent", selection: $agent) {
                ForEach(Self.agents, id: \.id) { agent in Text(agent.name).tag(agent.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("prompt-agent")
            Text(Self.agents.first { $0.id == agent }?.how ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                .frame(minHeight: 260)
                .accessibilityIdentifier("prompt-text")
            HStack(spacing: 10) {
                Text(isCustom ? (changed ? "Edited, not saved" : "Your words") : (changed ? "Edited, not saved" : "AgentTerm's default"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("prompt-state")
                Spacer()
                Button("Reset to Default") {
                    model.setAgentPrompt(agent, nil)
                    text = defaultText
                    shown = defaultText
                }
                .disabled(!isCustom && !changed)
                .accessibilityIdentifier("prompt-reset")
                Button("Save") {
                    // The default, unchanged, stays the default: it follows
                    // the switches, and the app's next versions.
                    model.setAgentPrompt(agent, text == defaultText && !isCustom ? nil : text)
                    shown = text
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!changed)
                .accessibilityIdentifier("prompt-save")
            }
            Text("Sessions started after it is saved are told it; those running keep what they were told. Empty, the agent is told nothing by \(AppChannel.current.appName).")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: agent) { _, _ in load() }
        // What the host says, once it has said it, unless the user is
        // writing.
        .onChange(of: model.agentPromptsCustom) { _, _ in if !changed { load() } }
        .onChange(of: model.agentPromptsDefaults) { _, _ in if !changed { load() } }
    }

    private func load() {
        let current = model.agentPromptsCustom[agent] ?? defaultText
        text = current
        shown = current
    }
}
