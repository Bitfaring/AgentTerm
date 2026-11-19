import AgentTermClient
import AgentTermFirebase
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI

/// The device token APNs gives the app (#66), for the Mac it is handed to.
final class PushToken: ObservableObject {
    static let shared = PushToken()
    @Published var token: String?
    /// Why iOS gave none, when it said.
    @Published var failure: String?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushToken.shared.failure = nil
        PushToken.shared.token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// A notification handled on another device, taken back (#66).
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(AgentNotifications.takeBack(userInfo) ? .newData : .noData)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushToken.shared.token = nil
        PushToken.shared.failure = error.localizedDescription
    }
}

@main
struct AgentTermApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var privacy: TelemetryPreferences

    init() {
        // Before anything is shown: the question about crash reports
        // depends on whether this build can report at all.
        #if DEBUG
        TouchLog.startIfAsked()
        // How long the main thread is held up, for `MARKDOWN=only
        // scripts/test-ios.sh` (#126).
        MainThreadWatch.startIfAsked()
        #endif
        FingerWatch.start()
        FirebaseSink.start()
        Telemetry.shared.record(.appOpen)
        _privacy = StateObject(wrappedValue: TelemetryPreferences())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.hosts.isEmpty {
                    PairView()
                } else if model.entered {
                    RootTabs()
                } else {
                    // First the Mac, then what is on it.
                    MacsScreen()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .tint(Palette.tint)
            .environmentObject(privacy)
            // Shown once, at the first launch of a build that can send
            // anything (#48): the app's own screen, a switch for each kind
            // of report, both on. Until it is answered nothing is sent.
            .sheet(isPresented: $privacy.needsAsking) {
                ReportingChoices(preferences: privacy)
                    .interactiveDismissDisabled()
                    .preferredColorScheme(.dark)
            }
            .onOpenURL { url in if !model.openFromLink(url) { model.pair(with: url) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.resume() }
                if phase == .background { model.enteredBackground() }
            }
        }
    }
}

enum Palette {
    static let canvas = Color(uiColor: TerminalStyle.background)
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.125)
    static let raised = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.09)
    static let tint = Color(red: 0.45, green: 0.62, blue: 0.98)
    static let danger = Color(red: 0.96, green: 0.45, blue: 0.47)
    static let added = Color(red: 0.36, green: 0.80, blue: 0.52)
}

/// What may be sent to the developer, a switch for each kind, and
/// Continue: the same words as on the Mac.
private struct ReportingChoices: View {
    @ObservedObject var preferences: TelemetryPreferences

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(TelemetryPreferences.Wording.screenIntro).font(.callout)
                }
                Section {
                    Toggle(TelemetryPreferences.Wording.crashTitle, isOn: $preferences.offersCrashReports)
                        .accessibilityIdentifier("reporting-crash")
                } footer: {
                    Text(TelemetryPreferences.Wording.questionDetail)
                }
                Section {
                    Toggle(TelemetryPreferences.Wording.usageTitle, isOn: $preferences.offersUsageStatistics)
                        .accessibilityIdentifier("reporting-usage")
                } footer: {
                    Text(TelemetryPreferences.Wording.usageDetail + "\n\n" + TelemetryPreferences.Wording.screenFooter)
                }
                Section {
                    Button(TelemetryPreferences.Wording.screenButton) { preferences.answer() }
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                        .accessibilityIdentifier("reporting-continue")
                }
            }
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
