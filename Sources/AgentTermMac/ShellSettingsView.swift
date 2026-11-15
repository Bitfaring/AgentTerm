import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// Settings > Shell: which shell a new session starts and what is run in it
/// first, the shells agents open, and how the terminals look. The first two
/// the host keeps, for every device; the looks are this Mac's.
struct ShellSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var startup = ""
    @State private var agentStartup = ""
    @State private var otherProgram = ""
    @State private var choosingOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(symbol: "terminal.fill", tint: .green, title: "Shell", subtitle: "How \(AppChannel.current.appName) starts a shell, and how terminals look.")
            if let settings = model.shellSettings {
                SettingsCard { program(settings) }
                SettingsCard { startupCommands(settings) }
            }
            SettingsCard { agents }
            SettingsCard { looks }
        }
        .padding(24)
        .frame(maxWidth: 820, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: model.shellSettings) { _, _ in load() }
    }

    private func load() {
        guard let settings = model.shellSettings else { return }
        startup = settings.startup
        agentStartup = settings.agentStartup
    }

    private func save(_ change: (inout ShellSettings) -> Void) {
        guard var settings = model.shellSettings else { return }
        change(&settings)
        model.setShellSettings(settings)
    }

    // MARK: The program

    private func program(_ settings: ShellSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shell").font(.headline)
            Text("The program of each new shell, here and from the iPhone. A session that runs a command, an agent's, starts through your login shell all the same.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let login = "Login shell (\((model.loginShell as NSString).lastPathComponent))"
            Picker(
                "Shell",
                selection: Binding(
                    get: { choosingOther ? "other" : (settings.program ?? "") },
                    set: { picked in
                        if picked == "other" {
                            choosingOther = true
                            otherProgram = settings.program ?? ""
                        } else {
                            choosingOther = false
                            save { $0.program = picked.isEmpty ? nil : picked }
                        }
                    })
            ) {
                Text(login).tag("")
                ForEach(model.availableShells.filter { $0 != model.loginShell }, id: \.self) { Text($0).tag($0) }
                if let program = settings.program, !model.availableShells.contains(program) { Text(program).tag(program) }
                Text("Other…").tag("other")
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("shell-program")
            if choosingOther {
                HStack {
                    TextField("/path/to/shell", text: $otherProgram)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("shell-program-path")
                    Button("Use") {
                        save { $0.program = otherProgram.trimmingCharacters(in: .whitespaces) }
                        choosingOther = false
                    }
                    .disabled(otherProgram.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: What is run first

    private func startupCommands(_ settings: ShellSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run when a shell opens").font(.headline)
            command(
                "In your shells", "Typed at the prompt with Return, as you would: a line a command. Shells that run a command are left alone.", text: $startup,
                id: "shell-startup", saved: settings.startup
            ) { value in save { $0.startup = value } }
            Divider()
            command(
                "In the shells agents open", "Run before the shell's first prompt, so that it is not taken for one of the agent's commands.",
                text: $agentStartup, id: "agent-shell-startup", saved: settings.agentStartup
            ) { value in save { $0.agentStartup = value } }
        }
    }

    private func command(_ title: String, _ detail: String, text: Binding<String>, id: String, saved: String, save: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                .frame(height: 64)
                .accessibilityIdentifier(id)
            HStack {
                Spacer()
                Button("Save") { save(text.wrappedValue) }
                    .disabled(text.wrappedValue == saved)
                    .accessibilityIdentifier(id + "-save")
            }
        }
    }

    // MARK: Agents' shells

    @ViewBuilder
    private var agents: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let agentShells = model.agentShells {
                SettingSwitch(
                    "Agents can open shells you see", id: "agent-shells",
                    detail: "An agent can open a shell beside it here, and reaches only the shells it opened.",
                    help:
                        "Through AgentTerm's MCP server, put in the settings of Claude Code, Codex, Copilot CLI and Antigravity; turning this off takes it out. An agent opens shells only, never another agent.",
                    isOn: Binding(get: { agentShells }, set: { model.setAgentShells($0) }))
                if let useShells = model.agentsUseShells {
                    Divider()
                    SettingSwitch(
                        "Agents run their commands in shells you see", id: "agents-use-shells",
                        detail: "They are asked to use those shells rather than their own.",
                        help:
                            "Claude Code is told in its system prompt, Copilot CLI and Antigravity in instructions files of AgentTerm's, Codex through the MCP server's instructions. An agent still decides for itself.",
                        isOn: Binding(get: { useShells }, set: { model.setAgentsUseShells($0) })
                    )
                    .disabled(!agentShells)
                }
                Divider()
            }
            if let settings = model.shellSettings {
                SettingSwitch(
                    "Agents' shells say when a command ends", id: "shell-marks",
                    detail: settings.marks
                        ? "An agent runs a command and is told its exit code and its output, in one step."
                        : "An agent types a command and waits for the screen to be still; its exit code is not known.",
                    help:
                        "A zsh an agent opens reads your startup files, then writes a mark when each command starts and ends (OSC 133), which you do not see. Your own shells are left as they are.",
                    isOn: Binding(get: { settings.marks }, set: { on in save { $0.marks = on } })
                )
                .disabled(model.agentShells == false)
            }
        }
    }

    // MARK: Looks

    private var looks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminal").font(.headline)
            Text("How the terminals look on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            LabeledContent("Font") {
                Picker("Font", selection: Binding(get: { model.terminalFontName ?? "" }, set: { model.setTerminalFont($0.isEmpty ? nil : $0) })) {
                    Text("System monospaced").tag("")
                    ForEach(AppModel.monospacedFonts, id: \.name) { font in Text(font.shown).tag(font.name) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("terminal-font")
            }
            LabeledContent("Size") {
                HStack {
                    Button("Smaller") { model.changeFontSize(by: -1) }
                        .disabled(model.terminalFontSize <= AppModel.fontSizes.lowerBound)
                    Text("\(Int(model.terminalFontSize)) pt").monospacedDigit().frame(minWidth: 44)
                        .accessibilityIdentifier("terminal-font-size")
                    Button("Larger") { model.changeFontSize(by: 1) }
                        .disabled(model.terminalFontSize >= AppModel.fontSizes.upperBound)
                }
            }
            LabeledContent("Cursor") {
                HStack {
                    Picker("Cursor", selection: Binding(get: { model.terminalCursor }, set: { model.setTerminalLooks(cursor: $0) })) {
                        Text("Block").tag(TerminalCursor.block)
                        Text("Underline").tag(TerminalCursor.underline)
                        Text("Bar").tag(TerminalCursor.bar)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("terminal-cursor")
                    Toggle("Blinks", isOn: Binding(get: { model.cursorBlinks }, set: { model.setTerminalLooks(blinks: $0) }))
                        .accessibilityIdentifier("terminal-cursor-blinks")
                }
            }
            LabeledContent("Scrolls back") {
                Picker("Scrolls back", selection: Binding(get: { model.scrollbackLines }, set: { model.setTerminalLooks(scrollback: $0) })) {
                    ForEach(AppModel.scrollbackChoices, id: \.self) { lines in Text("\(lines.formatted()) lines").tag(lines) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("terminal-scrollback")
            }
        }
    }
}
