import AgentTermProtocol
import SwiftUI

/// The Mac's settings that its own app has and the iPhone did not (#155):
/// Hooks & MCP, Shell, Browser and Agents, each a screen of its own, in the
/// words the Mac uses (principle 9).
struct MacSettingsSection: View {
    @EnvironmentObject private var model: PhoneModel
    let macName: String

    var body: some View {
        Section {
            NavigationLink {
                HooksAndMCPScreen()
            } label: {
                Label(AgentLinkWords.title, systemImage: "puzzlepiece.extension")
            }
            .accessibilityIdentifier("settings-hooks")
            NavigationLink {
                ShellSettingsScreen()
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            .accessibilityIdentifier("settings-shell")
            NavigationLink {
                BrowserProfilesScreen()
            } label: {
                Label("Browser", systemImage: "globe")
            }
            .accessibilityIdentifier("settings-browser")
            NavigationLink {
                AgentPromptsScreen()
            } label: {
                Label("Agents", systemImage: "sparkles")
            }
            .accessibilityIdentifier("settings-agents")
        } header: {
            Text("Set Up \(macName)")
        } footer: {
            Text("What \(macName) does with its agents, its shells and its browser: changed there, for every device.")
        }
        .disabled(model.status != .connected)
    }
}

/// What each agent has of AgentTerm's in its own configuration on the Mac,
/// with Install, Remove and Install for All, run by the host there.
private struct HooksAndMCPScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Form {
            if let report = model.agentSetup {
                Section {
                    Text(AgentSetupWords.explanation).font(.footnote).foregroundStyle(.secondary)
                    // Above the agents, as on the Mac (#153).
                    if report.needsSetup {
                        Button(AgentSetupWords.installAll) { model.runAgentSetup(agent: nil) }
                            .disabled(!report.busy.isEmpty)
                            .accessibilityIdentifier("setup-all")
                    }
                }
                ForEach(report.agents) { state in
                    AgentSetupSection(state: state, busy: report.busy.contains(state.agent))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the agents…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(AgentLinkWords.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.askAgentSetup() }
    }
}

private struct AgentSetupSection: View {
    @EnvironmentObject private var model: PhoneModel
    let state: AgentSetupState
    let busy: Bool

    private func part(_ title: String, _ has: Bool?) -> some View {
        Label(title, systemImage: has == true ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(has == true ? Palette.added : .secondary)
            .accessibilityLabel("\(title), \(has == true ? "added" : "not added")")
    }

    var body: some View {
        Section {
            if state.installed {
                part(AgentSetupWords.hooks, state.hooks)
                part(AgentSetupWords.mcp, state.mcp)
                if state.statusLine != nil { part(AgentSetupWords.statusLine, state.statusLine) }
                if state.sharedServerOff != nil { part(AgentSetupWords.sharedServer(off: state.sharedServerOff), state.sharedServerOff) }
                if let problem = state.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                        .accessibilityIdentifier("setup-problem-\(state.agent)")
                }
                if busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(AgentSetupWords.working).foregroundStyle(.secondary)
                    }
                } else {
                    Button(state.isSetUp ? "Install Again" : AgentSetupWords.install) { model.runAgentSetup(agent: state.agent) }
                        .accessibilityIdentifier("setup-install-\(state.agent)")
                    if state.hooks == true || state.mcp == true || state.statusLine == true {
                        Button(AgentSetupWords.remove, role: .destructive) { model.runAgentSetup(agent: state.agent, remove: true) }
                            .accessibilityIdentifier("setup-remove-\(state.agent)")
                    }
                }
            } else {
                Text(AgentSetupWords.notInstalled).foregroundStyle(.secondary)
            }
        } header: {
            Text(state.name)
        } footer: {
            if let note = state.note { Text(note) }
        }
        // No identifier of its own: a section's would be its buttons'.
    }
}

/// How the Mac's shells start: the program, and what is run in the user's
/// shells and in the agents' first. The terminal's looks are each device's.
private struct ShellSettingsScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var program = ""
    @State private var startup = ""
    @State private var agentStartup = ""

    private var settings: ShellSettings { ShellSettings(program: program.isEmpty ? nil : program, startup: startup, agentStartup: agentStartup) }
    private var changed: Bool { model.shellSettings.map { $0.settings != settings } ?? false }

    var body: some View {
        Form {
            if let shell = model.shellSettings {
                Section {
                    Picker("Program", selection: $program) {
                        Text("Login shell (\((shell.loginShell as NSString).lastPathComponent))").tag("")
                        ForEach(shell.shells.filter { $0 != shell.loginShell }, id: \.self) { path in Text(path).tag(path) }
                        if !program.isEmpty, !shell.shells.contains(program) { Text(program).tag(program) }
                    }
                    .accessibilityIdentifier("shell-program")
                } footer: {
                    Text("The program of each new shell, from the Mac and from this \(ThisDevice.name). A session that runs a command, an agent's, starts through the login shell all the same.")
                }
                Section {
                    TextField("None", text: $startup, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("shell-startup")
                } header: {
                    Text("Run in Your Shells")
                } footer: {
                    Text("Typed into each shell you open, with Return, once it shows its prompt.")
                }
                Section {
                    TextField("None", text: $agentStartup, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("shell-agent-startup")
                } header: {
                    Text("Run in the Agents' Shells")
                } footer: {
                    Text("Run in each shell an agent opens, before its first prompt.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Shell")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Save") { model.setShellSettings(settings) }
                .disabled(!changed)
                .accessibilityIdentifier("shell-save")
        }
        .onAppear(perform: read)
        .onChange(of: model.shellSettings) { _, _ in read() }
    }

    private func read() {
        guard let shell = model.shellSettings else { return }
        program = shell.settings.program ?? ""
        startup = shell.settings.startup
        agentStartup = shell.settings.agentStartup
    }
}

/// The browser's profiles on the Mac: the default one, a new one, renaming,
/// clearing one's data and deleting one, both asked first.
private struct BrowserProfilesScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var clearing: BrowserProfileInfo?
    @State private var deleting: BrowserProfileInfo?
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.browserProfiles) { profile in
                    Button {
                        model.changeProfiles(.makeDefault(id: profile.id))
                    } label: {
                        HStack {
                            Text(profile.name).foregroundStyle(.primary)
                            Spacer()
                            if profile.isDefault { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityIdentifier("profile-\(profile.name)")
                    .accessibilityAddTraits(profile.isDefault ? .isSelected : [])
                    .swipeActions {
                        if model.browserProfiles.count > 1 {
                            Button("Delete…", role: .destructive) { deleting = profile }
                        }
                        Button("Clear Data…") { clearing = profile }
                    }
                    .contextMenu {
                        Button("Make Default") { model.changeProfiles(.makeDefault(id: profile.id)) }
                        Button("Clear Data…") { clearing = profile }
                        if model.browserProfiles.count > 1 { Button("Delete…", role: .destructive) { deleting = profile } }
                    }
                }
                Button("New Profile") {
                    name = ""
                    adding = true
                }
                .accessibilityIdentifier("profile-new")
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each with its own sign-ins and cookies. The one checked is where your pages open. A profile's menu clears its data or deletes it.")
            }
            if let problem = model.profileProblem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.profileProblem = nil
            model.loadBrowserProfiles()
        }
        .alert("New Profile", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Add") { model.changeProfiles(.add(name: name.trimmingCharacters(in: .whitespaces))) }
        }
        .confirmationDialog(
            BrowserWords.clearQuestion(clearing?.name ?? ""), isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            titleVisibility: .visible, presenting: clearing
        ) { profile in
            Button(BrowserWords.clearButton, role: .destructive) { model.changeProfiles(.clearData(id: profile.id)) }
        } message: { _ in
            Text(BrowserWords.clearMessage)
        }
        .confirmationDialog(
            BrowserWords.deleteQuestion(deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { profile in
            Button(BrowserWords.deleteButton, role: .destructive) { model.changeProfiles(.delete(id: profile.id)) }
        } message: { _ in
            Text(BrowserWords.deleteMessage)
        }
    }
}

/// What each agent's new sessions are told: the user's own words, or
/// AgentTerm's, which they go back to.
private struct AgentPromptsScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var agent = "claude"
    @State private var text = ""

    private var saved: String? { model.agentPrompts.map { $0.custom[agent] ?? $0.defaults[agent] ?? "" } }
    private var isDefault: Bool { model.agentPrompts?.custom[agent] == nil }

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $agent) {
                    ForEach(model.agents) { agent in Text(agent.name).tag(agent.id) }
                }
                .accessibilityIdentifier("prompt-agent")
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("prompt-text")
            } header: {
                Text(isDefault ? "AgentTerm's Words" : "Your Words")
            } footer: {
                Text("Told to each new session of the agent, from the Mac, this \(ThisDevice.name) and the schedules alike. Emptied, it is told nothing.")
            }
            Section {
                Button("Save") { model.setAgentPrompt(agent, text) }
                    .disabled(saved == text)
                    .accessibilityIdentifier("prompt-save")
                Button("Use AgentTerm's Words") { model.setAgentPrompt(agent, nil) }
                    .disabled(isDefault)
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = saved ?? "" }
        .onChange(of: agent) { _, _ in text = saved ?? "" }
        .onChange(of: model.agentPrompts) { _, _ in text = saved ?? "" }
    }
}
