import AgentTermProtocol
import AppKit
import SwiftUI

/// Settings > Hooks & MCP (#129): what each agent has of AgentTerm's in its
/// own configuration, asked of the agent itself, with Install and Remove,
/// and the command that does the same in a terminal.
struct HooksAndMCPSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(
                symbol: "puzzlepiece.extension.fill", tint: .indigo, title: AgentLinkWords.title,
                subtitle: "What \(AppChannel.current.appName) needs of each agent, in the agent's own configuration.")
            Text(AgentSetupWords.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AgentSetupList()
            HStack {
                Button("Show the Onboarding Again") { model.showOnboarding = true }
                    .accessibilityIdentifier("show-onboarding")
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: 680, alignment: .top)
        .frame(maxWidth: .infinity)
        .onAppear { model.refreshAgentSetup() }
    }
}

/// The agents and what each has, with Install for All: in the pane, and in
/// the onboarding's last step.
struct AgentSetupList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = model.agentSetup {
                ForEach(report.agents) { state in
                    AgentSetupRow(state: state, busy: report.busy.contains(state.agent))
                }
                if model.isRemote {
                    Label("These are \(model.remote?.name ?? "the other Mac")'s agents: set them up in AgentTerm on that Mac.", systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if report.needsSetup {
                    HStack {
                        Spacer()
                        Button(AgentSetupWords.installAll) { model.runAgentSetup(agent: nil) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!report.busy.isEmpty)
                            .accessibilityIdentifier("setup-all")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the agents…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("setup-loading")
            }
        }
    }
}

/// One agent: what it has, Install and Remove, and the command.
private struct AgentSetupRow: View {
    @EnvironmentObject private var model: AppModel
    let state: AgentSetupState
    let busy: Bool
    @State private var copied: String?

    /// Its session running now, with what the host heard of it.
    private var running: SessionInfo? {
        model.sessions.last { ($0.agent ?? $0.typedAgent) == state.agent && $0.link != nil }
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: Theme.symbol(for: state.agent))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent(for: state.agent))
                        .frame(width: 20)
                    Text(state.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                        Text(AgentSetupWords.working).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else if state.installed && !model.isRemote {
                        if state.hooks == true || state.mcp == true || state.statusLine == true {
                            Button(AgentSetupWords.remove) { model.runAgentSetup(agent: state.agent, remove: true) }
                                .accessibilityIdentifier("setup-remove-\(state.agent)")
                        }
                        Button(state.isSetUp ? "Install Again" : AgentSetupWords.install) { model.runAgentSetup(agent: state.agent) }
                            .buttonStyle(.borderedProminent)
                            .tint(state.isSetUp ? .gray : .accentColor)
                            .accessibilityIdentifier("setup-install-\(state.agent)")
                    }
                }
                if state.installed {
                    HStack(spacing: 14) {
                        part(AgentSetupWords.hooks, state.hooks)
                        part(AgentSetupWords.mcp, state.mcp)
                        if let statusLine = state.statusLine { part(AgentSetupWords.statusLine, statusLine) }
                        // Not something added: its words say how it is.
                        if let off = state.sharedServerOff {
                            Label(AgentSetupWords.sharedServer(off: off), systemImage: off ? "checkmark.circle.fill" : "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(off ? Color.green : Color.orange)
                                .accessibilityIdentifier("setup-\(state.agent)-shared-server")
                        }
                    }
                    if let session = running, let link = session.link {
                        Text("In use now, \(session.displayName): \(AgentLinkWords.summary(link)).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(link.isMissing ? .orange : .secondary)
                            .accessibilityIdentifier("setup-in-use-\(state.agent)")
                    }
                    if let problem = state.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("setup-problem-\(state.agent)")
                    }
                    if let note = state.note {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.isRemote {
                        // Each part with its own command: the agent's own
                        // where it has one, AgentTerm's for the rest.
                        commands(AgentSetupWords.commandHeading, state.steps, id: "install")
                        commands(AgentSetupWords.removeHeading, state.removeSteps, id: "remove")
                    }
                } else {
                    Text(AgentSetupWords.notInstalled).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-\(state.agent)")
    }

    private func part(_ title: String, _ value: Bool?) -> some View {
        let (symbol, color, said): (String, Color, String) = {
            switch value {
            case true?: return ("checkmark.circle.fill", .green, "added")
            case false?: return ("xmark.circle", .secondary, "not added")
            case nil: return ("questionmark.circle", .secondary, "not known")
            }
        }()
        return Label(title, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .accessibilityLabel("\(title), \(said)")
            .accessibilityIdentifier("setup-\(state.agent)-\(title)")
    }

    /// The commands of one heading, in the order they are run, each with
    /// what it is for and whose it is.
    private func commands(_ heading: String, _ steps: [AgentSetupStep], id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let key = "\(id)-\(index + 1)"
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        Text(step.command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("setup-command-\(key)-\(state.agent)")
                        Button(copied == key ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(step.command, forType: .string)
                            copied = key
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("setup-copy-\(key)-\(state.agent)")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25)))
                }
            }
        }
    }
}
