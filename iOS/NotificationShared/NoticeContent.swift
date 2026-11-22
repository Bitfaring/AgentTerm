import AgentTermProtocol
import Foundation
import UserNotifications

/// What a notification of an agent says and offers (#22, #55), the same
/// whether the app makes it or its extension makes it from a push (#66).
enum NoticeContent {
    static let replyCategory = "agent-reply"
    static let openCategory = "agent-open"

    static var reply: UNNotificationAction {
        // A reply runs something on the Mac: the phone is unlocked first.
        UNTextInputNotificationAction(
            identifier: "reply", title: "Reply", options: [.authenticationRequired], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
    }

    /// Dismissed from Notification Center is told too (`customDismissAction`):
    /// handled on one device, handled on all (#66).
    static var fixedCategories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(
                identifier: replyCategory, actions: [reply], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle, .customDismissAction]),
            UNNotificationCategory(identifier: openCategory, actions: [], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle, .customDismissAction]),
        ]
    }

    /// The category of a question with choices: a button for each, then
    /// the text reply. Nil for anything else.
    static func choiceCategory(of notice: AgentNotice, request: String) -> UNNotificationCategory? {
        let buttons = notice.buttons
        guard !buttons.isEmpty else { return nil }
        // A choice runs something on the Mac, as a reply does: the phone
        // is unlocked first.
        let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.authenticationRequired]) }
        return UNNotificationCategory(
            identifier: "agent-choices-\(request)", actions: actions + [reply], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle, .customDismissAction])
    }

    /// The content of a notice, with its category for a notice that has
    /// none of its own. `digest` names the whole state when `notice` holds a
    /// shortened one (from a push): a reply then waits until the Mac says
    /// the agent is still in it. `title` and `body` stand for a failure's.
    static func content(
        of notice: AgentNotice?, id: UInt64, mac: String, macName: String, digest: String? = nil, title: String? = nil, body: String? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        // Every notice that is a notification needs the user (#233): shown
        // during a Focus too, as the push says to iOS before the extension
        // makes this from it.
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = mac
        var info: [String: Any] = ["mac": mac, "notice": String(id)]
        if let notice {
            content.title = "\(notice.name) \(notice.why)"
            content.subtitle = "\((notice.folder as NSString).lastPathComponent) on \(macName)"
            // What the agent said shows only where iOS shows previews: by
            // default not on the lock screen. A question's choices are its
            // buttons, not its last line, which iOS cuts off after a long
            // question (#55).
            content.body = notice.words ?? ""
            content.categoryIdentifier = notice.takesAReply ? replyCategory : openCategory
            info["session"] = Int(notice.session)
            info["stateDigest"] = digest ?? PushNotice.digest(notice.state)
            if digest == nil { info["state"] = String(decoding: MessageCoding.encode(notice.state), as: UTF8.self) }
        } else {
            content.title = title ?? ""
            content.subtitle = macName
            content.body = body ?? ""
            content.categoryIdentifier = openCategory
        }
        content.userInfo = info
        return content
    }

    /// The notice a notification is of, from its identifier.
    static func notice(of request: UNNotificationRequest) -> (mac: String, notice: UInt64)? { PushNotice.parse(identifier: request.identifier) }
}
