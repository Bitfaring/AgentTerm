import AgentTermProtocol
import UserNotifications
import XCTest

final class NoticeActionTests: XCTestCase {
    // IOS-26a: the system may display only the first few actions.
    func testWrittenReplyPrecedesTheChoices() throws {
        let choices = (1...9).map(String.init)
        let question = AgentQuestion(text: "Which one?", choices: choices)
        let notice = AgentNotice(session: 1, name: "agent", folder: "/tmp", state: .waitingForAnswer(question))
        let category = try XCTUnwrap(NoticeContent.choiceCategory(of: notice, request: "question"))
        XCTAssertTrue(category.actions.first is UNTextInputNotificationAction)
        XCTAssertEqual(category.actions.first?.identifier, "reply")
        XCTAssertEqual(category.actions.dropFirst().map(\.title), choices)
    }
}
