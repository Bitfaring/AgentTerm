import XCTest

extension XCUIApplication {
    /// Opens a pairing link as one from elsewhere is opened, and says yes to
    /// the question the app asks before pairing from it (#279, PAIR-10).
    func openPairingLink(_ url: URL) {
        open(url)
        let pair = alerts.buttons["Pair"].firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "a pairing link was not asked about before pairing")
        pair.tap()
    }

    /// A tab of the app: in the tab bar at the bottom on the iPhone; on the
    /// iPad (#88), in the bar that floats at the top, whose items are
    /// buttons and no tab bar's.
    func tab(_ name: String) -> XCUIElement {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        return tabBars.buttons[name]
    }
}
