import XCTest

/// The iPhone app's half of the test that runs it together with the Mac
/// app on one host. `scripts/test-both.sh` starts the host and both apps:
/// the Mac app has already done its part when this runs, and looks at what
/// this did afterwards.
final class CrossTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["AGENTTERM_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("phone-\(name).png"))
        }
    }

    func testWithTheMacApp() throws {
        // Only with the Mac app running beside it: on its own, as part of
        // the iPhone app's test, there is nothing of the Mac's to find.
        try XCTSkipUnless(environment["AGENTTERM_WITH_MAC"] != nil, "run this test through scripts/test-both.sh")
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"])
        let app = XCUIApplication()
        app.launch()
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: link)))

        // SES-6, NAME-3: the session the Mac app started is listed, under the same name.
        let macSession = app.staticTexts["zsh"].firstMatch
        XCTAssertTrue(macSession.waitForExistence(timeout: 20), "the session started on the Mac is not listed")
        _ = app.descendants(matching: .any)["system-cpu"].firstMatch.waitForExistence(timeout: 10)
        capture("1-sessions")

        // AWAKE-2: switched on on the Mac, it is on here; an option switched on here is for the Mac to show.
        app.tab("Settings").tap()
        let keepAwake = app.switches["keep-awake"]
        XCTAssertTrue(keepAwake.waitForExistence(timeout: 10))
        XCTAssertEqual(keepAwake.value as? String, "1", "Keep Mac Awake was switched on on the Mac and is off here")
        let display = app.switches["Keep the display on too"]
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.switches.firstMatch.exists ? display.switches.firstMatch.tap() : display.tap()
        capture("2-settings")
        app.tab("Sessions").tap()

        // GIT-6: the Mac grouped the changes by folder, so they are grouped here.
        app.buttons["folder-details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
        app.buttons["Git"].tap()
        XCTAssertTrue(app.buttons["Show as a flat list"].waitForExistence(timeout: 10), "the Mac's choice of a tree did not reach the phone")
        capture("3-changes")
        // Back to a flat list, for the Mac to follow.
        app.buttons["Show as a flat list"].tap()
        XCTAssertTrue(app.buttons["Group by folder"].waitForExistence(timeout: 5))

        // GIT-12: everything staged and committed here, for the Mac's list to lose.
        app.buttons["Stage All"].tap()
        XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10))
        let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
        message.tap()
        message.typeText("test: from the phone")
        app.buttons["commit"].tap()
        XCTAssertTrue(app.staticTexts["No uncommitted changes."].waitForExistence(timeout: 15), "the commit was not made")
        capture("4-committed")
        app.navigationBars.buttons.firstMatch.tap()

        // A session of the phone's own, for the Mac to list.
        let start = app.buttons[environment["AGENTTERM_LAUNCH"] ?? "Start Shell"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let compose = app.descendants(matching: .any)["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()

        // SES-6: the Mac's session opens here and takes what is typed.
        XCTAssertTrue(macSession.waitForExistence(timeout: 10))
        macSession.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        compose.tap()
        compose.typeText("echo typed-on-the-phone")
        app.buttons["Send"].tap()
        sleep(2)
        capture("5-in-the-macs-session")
        app.navigationBars.buttons.firstMatch.tap()

        try browser(app)
    }

    /// BROWSER-12: the agent's shell and page, under it; its page used from
    /// here, and given back; a page of the phone's own, shown as a device
    /// and closed.
    private func browser(_ app: XCUIApplication) throws {
        let pageURL = try XCTUnwrap(environment["AGENTTERM_PAGE_URL"])
        XCTAssertTrue(app.staticTexts["SHELLS"].waitForExistence(timeout: 15), "the agent's shell is not under it")
        XCTAssertTrue(app.staticTexts["BROWSER"].exists, "the agent's page is not under it")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'browser-tab-'"))
        let agentsPage = rows.firstMatch
        XCTAssertTrue(agentsPage.waitForExistence(timeout: 10))
        XCTAssertTrue(agentsPage.label.contains("Cross page"), agentsPage.label)
        capture("6-agents-own")
        agentsPage.tap()

        // Its screen opens on the page, live, the agent's still.
        XCTAssertTrue(app.segmentedControls["agent-parts"].waitForExistence(timeout: 10))
        let live = app.descendants(matching: .any)["browser-live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 20), "no picture of the page came")
        let control = app.buttons["browser-control"]
        XCTAssertEqual(control.label, "Take Over")
        // The iPad on its side has the page beside the agent's terminal.
        let onAnIPad = UIDevice.current.userInterfaceIdiom == .pad
        if onAnIPad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.descendants(matching: .any)["terminal"].firstMatch.waitForExistence(timeout: 10), "the terminal is not beside the page")
            XCTAssertTrue(live.exists)
            capture("7-ipad-side-by-side")
        }
        // A touch on its field: the keyboard comes up for it, and what is
        // typed goes into the page, which is the user's from then on.
        // On the picture, which is at the top of its room.
        live.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let up = app.buttons["Hide Keyboard"].waitForExistence(timeout: 10)
        if !up { capture("8-no-keyboard") }
        let problem = app.staticTexts["browser-problem"]
        XCTAssertTrue(
            up,
            "the keyboard did not come up for the page's field; the page says: \(problem.exists ? problem.label : "nothing"); its control: \(app.buttons["browser-control"].label); live: \(live.frame), \(String(describing: live.value))"
        )
        app.typeText("hi")
        let giveBack = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Go On'")).firstMatch
        XCTAssertTrue(giveBack.waitForExistence(timeout: 10), "the page did not become the user's at the first touch")
        capture("8-typed-in-the-page")
        // Given back to its agent.
        giveBack.tap()
        XCTAssertTrue(app.buttons["Take Over"].waitForExistence(timeout: 10))
        if onAnIPad { XCUIDevice.shared.orientation = .portrait }
        app.navigationBars.buttons.firstMatch.tap()
        let typed = rows.matching(NSPredicate(format: "label CONTAINS 'typed hi'")).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 10), "what was typed did not reach the page")

        // A page of the phone's own, in the folder.
        let open = app.buttons["Open a Page"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let address = app.textFields["browser-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "no page was opened")
        address.tap()
        address.typeText(pageURL + "\n")
        XCTAssertTrue(live.waitForExistence(timeout: 20), "no picture of the new page came")
        XCTAssertTrue(app.navigationBars["Cross page"].waitForExistence(timeout: 15), "the page typed in the address bar did not load")
        // Shown as a phone, which its row says.
        app.buttons["browser-menu"].tap()
        app.buttons["Show As"].firstMatch.tap()
        app.buttons["iPhone SE"].firstMatch.tap()
        app.buttons["Done"].tap()
        let asPhone = rows.matching(NSPredicate(format: "label CONTAINS 'Cross page' AND label CONTAINS 'as iPhone SE'")).firstMatch
        XCTAssertTrue(asPhone.waitForExistence(timeout: 10), "the page is not shown as iPhone SE")
        capture("9-own-page")
        // And closed.
        asPhone.tap()
        XCTAssertTrue(app.buttons["browser-menu"].waitForExistence(timeout: 10))
        app.buttons["browser-menu"].tap()
        app.buttons["Close Tab"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertFalse(asPhone.exists, "the closed page is still listed")
    }
}
