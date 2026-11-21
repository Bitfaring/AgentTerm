import AgentTermProtocol
import AgentTermTelemetry
import SwiftUI

/// The onboarding (#129): what AgentTerm needs to be set up, a step at a
/// time, each of which can be skipped and done later in Settings. Shown
/// over the window each time the app opens while an agent installed on
/// this Mac misses its hooks or AgentTerm's MCP server, until the user asks
/// not to be shown it again; and from Settings > Hooks & MCP.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    @State private var hideAgain = false
    /// What may be sent to the developer, while it is not answered (#48):
    /// a step of its own, answered by its Next. Not answered, nothing is
    /// sent, and it is asked again at the next launch.
    @StateObject private var reporting = TelemetryPreferences()
    @State private var asksReporting = Telemetry.shared.shouldAskAboutCrashReports

    enum Step: Int, CaseIterable {
        case welcome, reports, folders, permissions, agents, iPhone

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .reports: return "Reports"
            case .folders: return "Folders"
            case .permissions: return "Permissions"
            case .agents: return AgentLinkWords.title
            case .iPhone: return "iPhone"
            }
        }
    }

    /// Its steps: Reports only while it is to be answered.
    private var steps: [Step] { Step.allCases.filter { $0 != .reports || asksReporting } }
    private var current: Step { steps.indices.contains(step) ? steps[step] : .welcome }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.rawValue) { each in
                    Button {
                        step = steps.firstIndex(of: each) ?? 0
                    } label: {
                        Text(each.title)
                            .font(.system(size: 12, weight: each == current ? .semibold : .regular))
                            .foregroundStyle(each == current ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(each == current ? Color.white.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(each == current ? .isSelected : [])
                    .accessibilityIdentifier("onboarding-step-\(each.rawValue)")
                    if each != steps.last {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 460)
            Divider()
            HStack(spacing: 10) {
                Toggle("Don't show this again", isOn: $hideAgain)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("onboarding-hide")
                Spacer()
                Button("Skip") { finish() }
                    .accessibilityIdentifier("onboarding-skip")
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .accessibilityIdentifier("onboarding-back")
                }
                Button(current == .iPhone ? "Done" : "Next") {
                    // Its Next is the answer: what its switches say is kept.
                    if current == .reports { reporting.answer() }
                    if current == .iPhone { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-next")
            }
            .padding(14)
        }
        .frame(width: 720)
        .background(Theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Welcome to \(AppChannel.current.appName)").font(.system(size: 22, weight: .semibold))
                Text(
                    "A terminal for coding agents. Start Claude Code, Codex, Copilot CLI and Antigravity in your projects, see what each is doing, answer them when they wait for you, and carry on from your iPhone."
                )
                .fixedSize(horizontal: false, vertical: true)
                Text("The next steps set it up. Each can be skipped, and done later in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .reports:
            ReportingChoices(preferences: reporting)
        case .folders:
            VStack(alignment: .leading, spacing: 14) {
                Text("Your projects").font(.system(size: 17, weight: .semibold))
                Text("Add the folders of your projects: their agents, changes and history are kept together, and your iPhone lists them too.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.folders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.folders) { folder in
                            Label((folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder.fill")
                                .font(.system(size: 12.5))
                        }
                    }
                }
                Button("Add Folder…") { model.addFolder() }
                    .accessibilityIdentifier("onboarding-add-folder")
            }
        case .permissions:
            PermissionsView()
                // Asked here, up front, rather than at the first one (#180).
                .onAppear {
                    MacNotifications.readPermission {
                        if MacNotifications.permission == .notDetermined { MacNotifications.askPermission {} }
                    }
                }
        case .agents:
            VStack(alignment: .leading, spacing: 14) {
                Text(AgentLinkWords.title).font(.system(size: 17, weight: .semibold))
                Text(AgentSetupWords.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AgentSetupList()
            }
        case .iPhone:
            VStack(alignment: .leading, spacing: 14) {
                Text("Your iPhone").font(.system(size: 17, weight: .semibold))
                Text(
                    "AgentTerm on your iPhone shows your sessions, lets you answer your agents and start new ones, and shows the Mac's pages. It reaches this Mac over Tailscale, wherever you are: install Tailscale on both, signed in to the same account, then pair the iPhone."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Pair Device…") {
                    finish()
                    // Once the onboarding has gone: one sheet at a time.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showPairing = true }
                }
                .accessibilityIdentifier("onboarding-pair")
            }
        }
    }

    private func finish() {
        if hideAgain { model.onboardingHidden = true }
        model.showOnboarding = false
    }
}
