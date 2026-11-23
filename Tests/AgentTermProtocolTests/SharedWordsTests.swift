import AgentTermProtocol
import XCTest

/// The words both apps show, written once (principle 9): a Mac that is not
/// connected (#280, #281, #286), and the questions before what cannot be
/// undone (#308).
final class SharedWordsTests: XCTestCase {
    func testWhatIsSaidWhenTheMacIsNotConnected() {
        XCTAssertEqual(NotConnectedWords.notCommitted("Studio"), "Studio is not connected, so nothing was committed.")
        XCTAssertEqual(NotConnectedWords.notDone("Studio"), "Studio is not connected, so nothing was done. Do it again once it is back.")
        XCTAssertTrue(NotConnectedWords.notSaved("Studio").contains("Its changes are kept"))
        XCTAssertTrue(NotConnectedWords.notAnswered("Studio").hasPrefix("The connection to Studio closed before it answered"))
        XCTAssertTrue(ComposeWords.notConnected("Studio").contains("Your message is kept"))
    }

    func testTheQuestionsBeforeDeleting() {
        XCTAssertEqual(DeleteWords.scheduleTitle("Nightly"), "Delete the schedule “Nightly”?")
        XCTAssertEqual(DeleteWords.deviceTitle("iPhone"), "Remove “iPhone”?")
        XCTAssertEqual(DeleteWords.deleteSchedule, "Delete Schedule")
    }
}
