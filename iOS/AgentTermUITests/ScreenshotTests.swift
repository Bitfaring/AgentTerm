import XCTest

/// Takes the iPhone app's pictures for the App Store and the product page.
/// `scripts/screenshots.sh` starts a host with a demo project, stand-in
/// agents and sessions already arranged, and passes its pairing link in.
final class ScreenshotTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func capture(_ name: String) throws {
        let directory = try XCTUnwrap(environment["AGENTTERM_SHOT_DIR"])
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testThePictures() throws {
        try XCTSkipUnless(environment["AGENTTERM_SCREENSHOTS"] != nil, "run this test through scripts/screenshots.sh")
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"])
        let app = XCUIApplication()
        app.launch()
        passNotificationAsk(app)
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: link)))
        allowNotifications()

        // The folders and their sessions, pinned and grouped.
        let pinned = app.staticTexts["Fix the flaky parser tests"].firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 30), "the demo sessions are not listed")
        _ = app.descendants(matching: .any)["system-cpu"].firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        try capture("01-sessions")

        // An agent's session, sized to the phone, with the keyboard up.
        pinned.tap()
        let compose = app.descendants(matching: .any)["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        // The model, then its thinking level (#130).
        let band = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Fable 5.2")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 60), "the session shows no usage")
        sleep(3)
        compose.tap()
        // The keyboard leaves the terminal fewer rows, and the agent draws
        // its screen again for them.
        sleep(7)
        try capture("02-terminal")
        if app.buttons["hide-keyboard"].firstMatch.exists { app.buttons["hide-keyboard"].firstMatch.tap() }
        sleep(1)

        // What is left of the context and the limits.
        band.tap()
        XCTAssertTrue(app.staticTexts["Context"].firstMatch.waitForExistence(timeout: 10), "the usage sheet did not open")
        sleep(1)
        try capture("03-usage")
        app.swipeDown(velocity: .fast)
        sleep(1)
        if app.staticTexts["THIS SESSION"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        app.navigationBars.buttons.firstMatch.tap()

        // The folder's changes, one change's diff, and its files.
        XCTAssertTrue(app.buttons["folder-details"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["folder-details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
        app.buttons["Git"].tap()
        let change = app.staticTexts["Parser.swift"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 15), "the demo project's changes are not listed")
        sleep(1)
        try capture("04-git")
        change.tap()
        sleep(3)
        try capture("05-diff")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["README.md"].firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        try capture("06-files")
    }

    /// The agent's page, live from the Mac's browser, which
    /// `scripts/screenshots.sh` has the agent open once the pictures above
    /// are taken, with the Mac app started again to show it.
    func testTheAgentsPage() throws {
        try XCTSkipUnless(environment["AGENTTERM_SCREENSHOTS"] != nil, "run this test through scripts/screenshots.sh")
        let app = XCUIApplication()
        app.launch()
        passNotificationAsk(app)
        // Paired by the pictures above; else by the link.
        let pinned = app.staticTexts["Fix the flaky parser tests"].firstMatch
        if !pinned.waitForExistence(timeout: 15), let link = environment["AGENTTERM_PAIR_URL"].flatMap(URL.init(string:)) {
            app.open(link)
        }
        XCTAssertTrue(pinned.waitForExistence(timeout: 30), "the demo sessions are not listed")
        // Under its agent; opened, its screen shows the page live.
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'browser-tab-'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "the agent's page is not listed")
        page.tap()
        let live = app.descendants(matching: .any)["browser-live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 30), "no picture of the page came")
        sleep(4)
        try capture("07-browser")
    }
}
