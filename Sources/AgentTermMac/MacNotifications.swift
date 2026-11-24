import AgentTermProtocol
import AppKit
import UserNotifications

/// macOS notifications of what the host tells (#66, decided 2026-11-19),
/// in front or not (2026-11-20): the same words, Reply and choices as on
/// the iPhone. Handled on one device, taken away here; dismissed here,
/// handled on all.
///
/// Only in an app bundle: `swift run` and the tests have none to notify as.
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var asked = false
    private static let replyCategory = "agent-reply"
    private static let openCategory = "agent-open"

    /// None outside an app bundle, and none for the tests, which leave the
    /// user's Notification Center alone (`AGENTTERM_NO_SYSTEM_NOTIFICATIONS`).
    private var center: UNUserNotificationCenter? { Self.systemCenter }

    static var systemCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app",
            ProcessInfo.processInfo.environment["AGENTTERM_NO_SYSTEM_NOTIFICATIONS"] == nil
        else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Whether macOS lets the app notify, as last read (`readPermission`);
    /// nil while not known, or where there is no Notification Center.
    static private(set) var permission: UNAuthorizationStatus?

    /// Reads it again, then `done` on the main thread.
    static func readPermission(then done: @escaping () -> Void = {}) {
        guard let center = systemCenter else { return done() }
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                permission = settings.authorizationStatus
                done()
            }
        }
    }

    /// Asked of macOS once, in the onboarding's Permissions step (#180),
    /// rather than at the first notification.
    static func askPermission(then done: @escaping () -> Void) {
        guard let center = systemCenter else { return done() }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in readPermission(then: done) }
    }

    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(Self.fixedCategories)
    }

    private static var reply: UNNotificationAction {
        UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
    }

    private static var fixedCategories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: replyCategory, actions: [reply], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: openCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
        ]
    }

    private var choiceCategories: [String: UNNotificationCategory] = [:]

    func askOnce() {
        guard !asked, let center else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The Mac whose host posted it: another Mac's id, `thisMac` for this
    /// one's own. Its notices are numbered by its host, from one (#301).
    static let thisMac = "this-mac"

    /// The Mac on screen now, whose notices are posted and taken back.
    /// Asked on the main thread, where it is posted and answered.
    private var mac: String { MainActor.assumeIsolated { model?.remote?.id } ?? Self.thisMac }

    private static func identifier(_ id: UInt64, mac: String) -> String { "notice-\(mac)-\(id)" }

    func post(_ notice: Notice, host: String) {
        guard let center else { return }
        askOnce()
        let content = UNMutableNotificationContent()
        content.title = notice.title(on: host)
        content.subtitle = notice.place(macName: host)
        content.body = notice.body
        content.sound = .default
        var info: [String: Any] = ["notice": String(notice.id), "mac": mac]
        let identifier = Self.identifier(notice.id, mac: mac)
        if let agent = notice.agentNotice {
            info["session"] = Int(agent.session)
            info["state"] = String(decoding: MessageCoding.encode(agent.state), as: UTF8.self)
            let buttons = agent.buttons
            if buttons.isEmpty {
                choiceCategories[identifier] = nil
                content.categoryIdentifier = agent.takesAReply ? Self.replyCategory : Self.openCategory
            } else {
                let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) }
                let category = UNNotificationCategory(
                    identifier: "agent-choices-\(identifier)", actions: actions + [Self.reply], intentIdentifiers: [], options: [.customDismissAction])
                choiceCategories[identifier] = category
                content.categoryIdentifier = category.identifier
            }
            center.setNotificationCategories(Self.fixedCategories.union(choiceCategories.values))
        } else {
            content.categoryIdentifier = Self.openCategory
        }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func remove(_ ids: [UInt64]) {
        guard let center, !ids.isEmpty else { return }
        let mac = mac
        let identifiers = ids.map { Self.identifier($0, mac: mac) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for identifier in identifiers { choiceCategories[identifier] = nil }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = (info["notice"] as? String).flatMap(UInt64.init)
        let session = (info["session"] as? Int).map { SessionID(truncatingIfNeeded: $0) }
        let state = (info["state"] as? String).flatMap { MessageCoding.decode(AgentState.self, from: Data($0.utf8)) }
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let from = info["mac"] as? String
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self, let model = self.model, let id else { return }
            // Of a Mac that is not on screen now: its number is another
            // notice's here, and its host is not the one connected (#301).
            guard from == self.mac else {
                if action != UNNotificationDismissActionIdentifier { model.notice = MacNotifications.ofAnotherMac(from, among: model.remoteMacs) }
                return
            }
            if action == UNNotificationDismissActionIdentifier { return model.dismissNotice(id) }
            if let session, let state {
                let notice = AgentNotice(session: session, name: "", folder: "", state: state)
                if let text = typed ?? notice.choice(ofButton: action) {
                    model.answerNotice(session: session, state: state, text: text)
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                model.open(notice)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                model.dismissNotice(id)
            }
        }
    }

    /// What is said when a notification of a Mac that is not on screen is
    /// answered or opened.
    static func ofAnotherMac(_ id: String?, among macs: [RemoteMac]) -> String {
        let name = id == thisMac ? "this Mac" : macs.first { $0.id == id }?.name ?? "a Mac that is not on screen"
        return "That notification is of \(name), which is not the Mac on screen: switch to it to answer or open it."
    }

    /// Takes away what was posted of the Mac on screen, when another is
    /// switched to: its notifications can no longer be answered (#301).
    func removeAll(of mac: String) {
        guard let center else { return }
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter { ($0.request.content.userInfo["mac"] as? String) == mac }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// In front too (the owner's decision, 2026-11-20): shown as it is on
    /// the iPhone at the same moment.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
