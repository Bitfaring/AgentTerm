import AgentTermProtocol
import AppKit
import UserNotifications

/// macOS notifications of what the host tells (#66, decided 2026-11-19),
/// while the app is not in front: the same words, Reply and choices as on
/// the iPhone. Handled on one device, taken away here; dismissed here,
/// handled on all.
///
/// Only in an app bundle: `swift run` and the tests have none to notify as.
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var asked = false
    private static let replyCategory = "agent-reply"
    private static let openCategory = "agent-open"

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : UNUserNotificationCenter.current()
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

    private static func identifier(_ id: UInt64) -> String { "notice-\(id)" }

    func post(_ notice: Notice, host: String) {
        guard let center else { return }
        askOnce()
        let content = UNMutableNotificationContent()
        content.title = notice.title(on: host)
        content.subtitle = notice.place(macName: host)
        content.body = notice.body
        content.sound = .default
        var info: [String: Any] = ["notice": String(notice.id)]
        let identifier = Self.identifier(notice.id)
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
        let identifiers = ids.map(Self.identifier)
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
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let model = self?.model, let id else { return }
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

    /// In front, the app shows its own banner instead.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
