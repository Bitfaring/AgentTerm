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

    /// NOTIFY-5 (#212): a switch the system or the build stops shows off,
    /// cannot be changed and says why, and keeps what the user chose.
    func testItShowsOffWithItsReasonWhileTheSystemOrTheBuildStopsIt() {
        let stopped = DependentSwitch(stored: true, stoppedBy: "This build cannot")
        XCTAssertFalse(stopped.shown, "a switch shows on while what it stands for does not work")
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertTrue(stopped.stored, "the user's choice was not kept")
        XCTAssertTrue(DependentSwitch(stored: true).shown)
    }

    /// NOTIFY-5 (#212): "Also While the App Is Closed" in a build with no push.
    func testAlsoWhileTheAppIsClosedShowsOffInABuildWithoutPush() {
        let dev = DependentSwitch.pushAlso(stored: true, notifications: true, channel: .dev)
        XCTAssertFalse(dev.shown, "Also While the App Is Closed shows on in a build with no push")
        XCTAssertFalse(dev.isEnabled)
        XCTAssertEqual(dev.stoppedBy, PushWords.notInThisBuild)
        XCTAssertTrue(dev.stored)
        let released = DependentSwitch.pushAlso(stored: true, notifications: true, channel: .release)
        XCTAssertTrue(released.shown)
        XCTAssertNil(released.stoppedBy)
        XCTAssertFalse(DependentSwitch.pushAlso(stored: true, notifications: false, channel: .release).shown)
    }

    /// NOTIFY-6 (#213): "Also While the App Is Closed" while iOS has
    /// notifications turned off for the app.
    func testAlsoWhileTheAppIsClosedShowsOffWhileIOSHasNotificationsOff() {
        let refused = DependentSwitch.pushAlso(stored: true, notifications: true, channel: .release, allowed: false)
        XCTAssertFalse(refused.shown, "Also While the App Is Closed shows on while iOS has notifications off")
        XCTAssertFalse(refused.isEnabled)
        XCTAssertEqual(refused.stoppedBy, PushWords.notAllowed)
        XCTAssertTrue(refused.stored, "the user's choice was not kept")
        // A build with no push says that first: allowing them would not help.
        XCTAssertEqual(DependentSwitch.pushAlso(stored: true, notifications: true, channel: .dev, allowed: false).stoppedBy, PushWords.notInThisBuild)
        XCTAssertTrue(DependentSwitch.pushAlso(stored: true, notifications: true, channel: .release, allowed: true).shown)
    }

    /// LIVE-7 (#212): the Live Activity switch while iOS has Live
    /// Activities turned off for the app.
    func testTheLiveActivitySwitchShowsOffWhileIOSTurnsThemOff() {
        let off = DependentSwitch.liveActivity(stored: true, allowed: false)
        XCTAssertFalse(off.shown, "the Live Activity switch shows on while iOS turns Live Activities off")
        XCTAssertFalse(off.isEnabled)
        XCTAssertEqual(off.stoppedBy, AgentsStatus.notAllowed)
        XCTAssertTrue(off.stored)
        let allowed = DependentSwitch.liveActivity(stored: true, allowed: true)
        XCTAssertTrue(allowed.shown)
        XCTAssertNil(allowed.stoppedBy)
        XCTAssertFalse(DependentSwitch.liveActivity(stored: false, allowed: true).shown)
    }
}
