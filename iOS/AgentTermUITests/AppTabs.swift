import XCTest

extension XCUIApplication {
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
