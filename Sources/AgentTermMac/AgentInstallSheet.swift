import AgentTermProtocol
import AppKit
import SwiftUI

/// How to install an agent that is not installed on the Mac, from its
/// button in the header (#50): its maker's command, to copy, or to have
/// typed into a new shell and run there by the user; where its maker says
/// more; and a look for it again once it is installed.
struct AgentInstallSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let guide: AgentInstallGuide

    private var agent: AgentInfo? { model.agents.first { $0.id == guide.agent } }
    private var found: Bool { agent?.isInstalled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: Theme.symbol(for: guide.agent))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent(for: guide.agent))
                Text(guide.title).font(.system(size: 16, weight: .semibold))
            }
            Text(guide.message(on: model.macName))
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: guide.command, id: "install-command")
            if let alternative = guide.alternative {
                Text("Or with Homebrew:").font(.callout).foregroundStyle(.secondary)
                CommandBox(command: alternative, id: "install-alternative")
            }
            if let needs = guide.needs {
                Text(needs).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Link("How its maker says to install it", destination: guide.docs)
                .font(.callout)
                .accessibilityIdentifier("install-docs")
            status
            HStack(spacing: 8) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if found, let agent {
                    Button("Start \(guide.name)") {
                        dismiss()
                        model.launch(agent)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Look Again") { model.lookForAgentsAgain() }
                        .disabled(model.lookedForAgentsAgain && !model.agentsLoaded)
                        .help("Look for \(guide.name) on \(model.macName) again, once it is installed")
                    Button("Install in a New Shell") { model.installInNewShell(guide) }
                        .keyboardShortcut(.defaultAction)
                        .help("Open a shell on \(model.macName) with the command typed in, not run: press Return there to run it")
                        .disabled(model.status != .connected)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    /// What became of a look for it again.
    @ViewBuilder private var status: some View {
        if found {
            Label(guide.installed, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("install-found")
        } else if model.lookedForAgentsAgain && !model.agentsLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for \(guide.name)…").foregroundStyle(.secondary)
            }
        } else if model.lookedForAgentsAgain {
            Text(guide.stillMissing)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("install-still-missing")
        }
    }
}

/// A command to run, as it is to be typed, with a button that copies it.
private struct CommandBox: View {
    let command: String
    let id: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .accessibilityLabel("Copy \(command)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
    }
}
