import AgentTermProtocol
import XCTest

/// NOTIFY-4 (#211): a switch that depends on another shows off while that
/// one is off, and keeps what the user chose for it.
final class DependentSwitchTests: XCTestCase {
    func testItShowsOffWhileTheSwitchItDependsOnIsOff() {
        let held = DependentSwitch(stored: true, dependsOn: false)
        XCTAssertFalse(held.shown, "a switch shows on while what it stands for does not work")
        XCTAssertFalse(held.isEnabled)
        XCTAssertTrue(held.stored, "the user's choice was not kept")
        XCTAssertFalse(DependentSwitch(stored: false, dependsOn: false).shown)
    }

    func testItShowsItsOwnValueOnceThatSwitchIsOn() {
        XCTAssertTrue(DependentSwitch(stored: true, dependsOn: true).shown)
        XCTAssertFalse(DependentSwitch(stored: false, dependsOn: true).shown)
        XCTAssertTrue(DependentSwitch(stored: false, dependsOn: true).isEnabled)
    }
}
