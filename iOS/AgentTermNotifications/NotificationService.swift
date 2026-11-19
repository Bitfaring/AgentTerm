import AgentTermProtocol
import UserNotifications

/// Opens a push from the Mac (#66): what it says came encrypted with the
/// key this iPhone gave that Mac, through a relay and Apple, neither of
/// which could read it. A push that cannot be opened is shown as it came:
/// "An agent needs you".
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
        fallback = request.content
        let info = request.content.userInfo
        // A notification handled on another device, taken back (#66): sent
        // this way only once the app has the filtering entitlement, which
        // lets an empty content show nothing.
        if let gone = info["g"] as? String {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [gone])
            fallback = UNNotificationContent()
            return finish(UNNotificationContent())
        }
        // The relay puts the identifier in the payload too: iOS gives the
        // request APNs' collapse identifier, which is the same.
        let identifier = info["i"] as? String ?? request.identifier
        guard let sealed = info["e"] as? String, let (mac, id) = PushNotice.parse(identifier: identifier), let saved = PushKeys.load(mac: mac),
            let pushed = try? PushSeal.open(sealed, identifier: identifier, key: saved.key)
        else { return finish(request.content) }
        let notice = pushed.agentNotice
        let content = NoticeContent.content(
            of: notice, id: id, mac: mac, macName: saved.macName, digest: pushed.stateDigest, title: pushed.title, body: pushed.body)
        guard let notice, let choices = NoticeContent.choiceCategory(of: notice, request: identifier) else { return finish(content) }
        // A question's choices are buttons of a category of its own, which
        // has to be known before the notification is shown (#55).
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { known in
            center.setNotificationCategories(known.filter { $0.identifier != choices.identifier }.union([choices]).union(NoticeContent.fixedCategories))
            content.categoryIdentifier = choices.identifier
            self.finish(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { finish(fallback) }
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler else { return }
        self.handler = nil
        handler(content)
    }
}
