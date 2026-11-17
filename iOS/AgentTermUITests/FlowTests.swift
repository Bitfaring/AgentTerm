import XCTest

/// Walks through the app against a real host: pair, start a session, type in
/// it, go back. Run it with scripts/test-ios.sh, which starts the host and
/// passes its pairing link in.
final class FlowTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    /// Saves a screenshot next to the test results when a folder was given.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["AGENTTERM_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// The main screens with the phone on its side, from a session's terminal.
    /// PERF-6: how smoothly a terminal of 5,000 lines scrolls, as the time
    /// frames were late while it coasted after a fast swipe.
    /// Makes a gesture until what it is for has happened, three times at
    /// most. A touch or a drag was now and then lost in the grouping steps:
    /// the picture taken after "Orange" was touched showed the menu still
    /// open, with nothing chosen. That was seen while each step around a
    /// menu waited a minute for the app to settle (#65); whether it still
    /// happens now that they do not is not known, so this stays. What the
    /// gesture is for is still asserted by the caller.
    /// Opens an element's menu with a long press and picks an entry of it,
    /// without the minute the test would wait before and after each of the
    /// two while the menu is open (#65, `IdleWaits`). The entry is waited
    /// for by itself; what picking it is for is the caller's to check.
    /// - Parameter open: Looked at while the menu is open, before the pick.
    /// - Parameter hold: How long the finger stays on the entry; a tap without it.
    private func pick(
        _ entry: String, fromMenuOf element: XCUIElement, in app: XCUIApplication, hold: TimeInterval? = nil, open: () -> Void = {}, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        IdleWaits.skipped {
            element.press(forDuration: 1.2)
            let item = app.buttons[entry].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu has no “\(entry)”", file: file, line: line)
            open()
            if let hold { item.press(forDuration: hold) } else { item.tap() }
        }
    }

    private func gesture(until done: () -> Bool, _ make: () -> Void, line: UInt = #line) {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        for attempt in 1...3 {
            let made = clock.string(from: Date())
            make()
            if done() { return }
            // #83: when, to set beside the app's own log of touches.
            print("MEASURE gesture at line \(line) lost, attempt \(attempt), made at \(made), given up at \(clock.string(from: Date()))")
        }
    }

    private func measureScrolling(_ app: XCUIApplication, compose: XCUIElement) {
        compose.tap()
        compose.typeText("seq 1 5000")
        app.buttons["Send"].tap()
        if app.buttons["hide-keyboard"].firstMatch.waitForExistence(timeout: 3) { app.buttons["hide-keyboard"].firstMatch.tap() }
        sleep(4)
        let terminal = app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        // On a simulator only the length of the coast comes from the scroll
        // metric; the processor time the app spends drawing it says how
        // costly each frame is, which is what drawing on the GPU changes.
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
            terminal.swipeDown(velocity: .fast)
            stopMeasuring()
            terminal.swipeUp(velocity: .fast)
            terminal.swipeUp(velocity: .fast)
        }
    }

    /// HIST-6: a long session opened again comes with the screen and 500
    /// lines above it; scrolled to their top, a strip says earlier lines
    /// load, and they come, a page at a time.
    /// PERF-13 (#83): how often a touch on an entry of a listed folder's
    /// menu is lost. "Move Down" is chosen again and again, as the main
    /// test chooses it once, and each time the order is looked at. Printed
    /// as `MEASURE`, with a picture of each loss; nothing fails on it.
    private func measureMenuTouches(_ app: XCUIApplication, launchButton: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        // A second listed folder, so the first can move down.
        app.buttons["Open Another Folder…"].tap()
        let add = app.buttons["Add to Folders"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the folder being looked at cannot be added to the list")
        add.tap()
        app.buttons["Cancel"].tap()
        countMenuTouches(app)
    }

    /// Chooses "Move Down" in the first listed folder's menu, again and
    /// again, and says each time whether the folder moved.
    private func countMenuTouches(_ app: XCUIApplication) {
        let names = app.staticTexts.matching(identifier: "folder-name")
        func order() -> [String] { (0..<names.count).map { names.element(boundBy: $0).label } }
        let rounds = Int(ProcessInfo.processInfo.environment["AGENTTERM_MENU_ROUNDS"] ?? "") ?? 20
        var lost = 0
        for round in 1...rounds {
            var expected = order()
            guard expected.count >= 2 else { return XCTFail("two listed folders are needed: \(expected)") }
            expected.swapAt(0, 1)
            let started = Date()
            // MENU_HOLD: the finger kept on the entry that long, for the
            // Mac's figures, which come every 3 seconds, to arrive meanwhile.
            pick("Move Down", fromMenuOf: names.element(boundBy: 0), in: app, hold: TimeInterval(ProcessInfo.processInfo.environment["AGENTTERM_MENU_HOLD"] ?? ""))
            let moved = IdleWaits.skipped { () -> Bool in
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if order() == expected { return true }
                    usleep(300_000)
                }
                return false
            }
            if !moved {
                lost += 1
                capture("menu-lost-\(round)")
                // Away from the menu, which closes it.
                IdleWaits.skipped { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap() }
                sleep(2)
            }
            print(String(format: "MEASURE menu, round %d: %@ (%.1f s)", round, moved ? "moved" : "LOST", Date().timeIntervalSince(started)))
        }
        print("MEASURE menu, lost \(lost) of \(rounds)")
    }

    /// #83, #99: how often a touch on an entry of the terminal's menu is
    /// lost, with the keyboard up or down (`AGENTTERM_MENU_KEYBOARD=down`).
    /// Printed as `MEASURE`, with the time of each touch to set beside the
    /// app's own log of touches; nothing fails on it.
    private func countTerminalMenuTouches(_ app: XCUIApplication, compose: XCUIElement) {
        let rounds = Int(environment["AGENTTERM_MENU_ROUNDS"] ?? "") ?? 20
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        if environment["AGENTTERM_MENU_KEYBOARD"] == "down" {
            if app.buttons["hide-keyboard"].firstMatch.exists { app.buttons["hide-keyboard"].firstMatch.tap() }
        } else if !app.keyboards.firstMatch.exists {
            compose.tap()
        }
        sleep(1)
        print("MEASURE menu, keyboard up: \(app.keyboards.firstMatch.exists)")
        var lost = 0
        for round in 1...rounds {
            let name = round % 2 == 1 ? "Larger Text" : "Smaller Text"
            // What the whole test does right before it opens this menu.
            if environment["AGENTTERM_MENU_KEYBOARD"] == "busy" {
                compose.typeText("stty size")
                app.buttons["Send"].tap()
                sleep(2)
                app.buttons["key-Up"].tap()
                app.buttons["Send"].tap()
                sleep(1)
            }
            app.buttons["session-menu"].tap()
            let entry = app.buttons[name]
            guard entry.waitForExistence(timeout: 10) else {
                print("MEASURE menu, round \(round): the menu did not open")
                continue
            }
            let place = entry.frame
            let touched = clock.string(from: Date())
            entry.tap()
            let taken = entry.waitForNonExistence(timeout: 5)
            if !taken {
                lost += 1
                capture("terminal-menu-lost-\(round)")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
                sleep(2)
            }
            print(
                String(
                    format: "MEASURE menu, round %d: %@ at %@, entry at (%.0f, %.0f) %@", round, taken ? "taken" : "LOST", touched, place.midX, place.midY,
                    clock.string(from: Date())))
        }
        print("MEASURE menu, lost \(lost) of \(rounds)")
    }

    /// PERF-9 (#65): how long each step waits for the app to be idle
    /// around a session's menu. XCUITest waits for that before every step,
    /// up to a minute; a step that takes about that long found the app
    /// busy all the while. Printed as `MEASURE`, and nothing fails on it.
    private func measureIdle(_ app: XCUIApplication, launchButton: String, compose: XCUIElement) {
        // Two sessions in the list.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        app.buttons[launchButton].firstMatch.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        let rows = app.staticTexts.matching(identifier: "zsh")
        XCTAssertEqual(rows.count, 2)

        func timed(_ what: String, _ step: () -> Void) {
            let started = Date()
            step()
            print(String(format: "MEASURE idle, %@: %.1f s", what, Date().timeIntervalSince(started)))
        }
        timed("a tap with no menu about (the tab bar)") { app.tab("Sessions").tap() }
        timed("the press that opens a row's menu") { rows.element(boundBy: 0).press(forDuration: 1.2) }
        timed("finding an entry of the open menu") { XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 90)) }
        timed("touching the entry") { app.buttons["Pin"].tap() }
        timed("the first look at the list afterwards") { XCTAssertEqual(rows.count, 2) }

        // The same without waiting for the app to be idle while its menu is open.
        print("MEASURE idle, the waits that can be skipped: \(IdleWaits.isAvailable ? IdleWaits.found.joined(separator: ", ") : "none found")")
        IdleWaits.skipped {
            timed("not waiting: the press that opens the menu") { rows.element(boundBy: 0).press(forDuration: 1.2) }
            timed("not waiting: finding its entry") { XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 90)) }
            timed("not waiting: touching it") { app.buttons["Unpin"].tap() }
        }
        timed("a look at the list after it") { XCTAssertEqual(rows.count, 2) }
        XCTAssertFalse(app.buttons["Unpin"].exists, "the menu is still open")
    }

    private func pagedHistory(_ app: XCUIApplication, compose: XCUIElement) {
        compose.tap()
        compose.typeText("seq 1 3000")
        app.buttons["Send"].tap()
        if app.buttons["hide-keyboard"].firstMatch.waitForExistence(timeout: 3) { app.buttons["hide-keyboard"].firstMatch.tap() }
        sleep(3)
        // Opened again by an app that has none of it: now with only the
        // lines near the screen. (Started here, it came whole, and going
        // back and in again keeps what the terminal has.)
        app.terminate()
        app.launch()
        if app.buttons["First Mac"].waitForExistence(timeout: 15) { app.buttons["First Mac"].tap() }
        let row = app.staticTexts["zsh"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let terminal = app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        sleep(2)
        let loaded = app.descendants(matching: .any)["history-loaded"].firstMatch
        func asked() -> Int { Int(loaded.value as? String ?? "") ?? 0 }
        var seen: [Int] = []
        for _ in 0..<120 where seen.count < 2 {
            terminal.swipeDown(velocity: .fast)
            sleep(1)
            let now = asked()
            if now > (seen.last ?? 500) {
                seen.append(now)
                capture("17-history-page-\(seen.count)")
            }
        }
        XCTAssertEqual(seen, [1_500, 2_500], "scrolling up did not load earlier lines a page at a time")
    }

    private func landscape(_ app: XCUIApplication, compose: XCUIElement) {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sleep(2)
        // On its side the phone has no height to spare: the navigation bar
        // is gone, and back, the keys, the message field and the menu
        // share one row under the terminal.
        XCTAssertTrue(app.buttons["terminal-back"].waitForExistence(timeout: 5), "no way back from a terminal on its side")
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "the navigation bar takes height from a terminal on its side")
        XCTAssertTrue(app.buttons["key-Escape"].exists)
        XCTAssertTrue(app.buttons["session-menu"].exists)
        capture("L1-terminal")
        compose.tap()
        compose.typeText("echo sideways")
        sleep(4)
        capture("L2-terminal-keyboard")
        // With the keyboard up there is still a terminal to look at, and a
        // button that puts the keyboard away again.
        if app.keyboards.firstMatch.exists {
            let terminal = app.descendants(matching: .any)["terminal"].firstMatch
            if terminal.exists { XCTAssertGreaterThan(terminal.frame.height, 60, "the keyboard leaves no terminal on a phone on its side") }
            let hide = app.buttons["hide-keyboard"].firstMatch
            XCTAssertTrue(hide.waitForExistence(timeout: 3), "no button to hide the keyboard")
            hide.tap()
            sleep(1)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stayed up")
            XCTAssertEqual(compose.value as? String, "echo sideways", "hiding the keyboard lost what was written")
        }
        capture("L3-terminal-keyboard-hidden")
        app.buttons["terminal-back"].firstMatch.tap()
        sleep(1)
        capture("L4-sessions")
        if environment["AGENTTERM_TEST_PROJECT"] != nil {
            app.buttons["folder-details"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
            app.buttons["Git"].tap()
            sleep(1)
            capture("L5-git")
            if app.staticTexts["notes.txt"].waitForExistence(timeout: 5) {
                app.staticTexts["notes.txt"].tap()
                sleep(2)
                capture("L6-diff")
                app.buttons["diff-layout"].tap()
                sleep(2)
                capture("L7-diff-two-panels")
                app.buttons["diff-layout"].tap()
                app.navigationBars.buttons.firstMatch.tap()
            }
            for tab in ["History", "Files"] where app.buttons[tab].firstMatch.exists {
                app.buttons[tab].firstMatch.tap()
                sleep(1)
                capture("L8-folder-\(tab)")
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.tab("Settings").tap()
        sleep(1)
        capture("L9-settings")
        app.tab("History").tap()
        sleep(1)
        capture("L10-history")
    }

    func testPairStartSessionAndType() throws {
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"], "run this test through scripts/test-ios.sh")
        let launchButton = environment["AGENTTERM_LAUNCH"] ?? "Start Shell"
        let app = XCUIApplication()
        // #83: the app writes down the touches it receives.
        if let log = environment["AGENTTERM_TOUCH_LOG"] { app.launchEnvironment["AGENTTERM_TOUCH_LOG"] = log }
        app.launch()

        // Pair by opening the link, as tapping an agentterm:// link would: the
        // simulator has no camera to scan with.
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        capture("1-pair")
        app.open(try XCTUnwrap(URL(string: link)))

        // Connected: the Mac's folders and launch buttons show up.
        let start = app.buttons[launchButton].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "not connected to the host")
        // HOST-8: the host on the Mac died before this one, and the phone
        // is told so in words rather than shown an empty list.
        if environment["AGENTTERM_EXPECT_HOST_DIED"] != nil {
            let card = app.descendants(matching: .any)["failure-card"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), "the phone did not say that the Mac's host had stopped")
            XCTAssertTrue(card.label.contains("The host on First Mac stopped unexpectedly"), card.label)
            XCTAssertTrue(card.label.contains("was started again"), card.label)
            XCTAssertTrue(card.label.contains("Its 2 sessions ended: build, tests"), card.label)
            capture("2a-host-died")
            // Seen once, it goes.
            app.buttons["failure-dismiss"].firstMatch.tap()
            XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the report stayed after it was dismissed")
        }
        // The second Mac is paired now, while its link is fresh: a link
        // lives five minutes, and its part of the test comes later. Paired,
        // it is the one on screen; the first comes back from the menu.
        if let second = environment["AGENTTERM_SECOND_PAIR_URL"] {
            app.open(try XCTUnwrap(URL(string: second)))
            XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 15), "the second Mac did not pair")
            app.buttons["mac-menu"].tap()
            app.buttons["First Mac"].tap()
            XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 10))
            XCTAssertTrue(start.waitForExistence(timeout: 15), "not connected to the first Mac again")
        }
        capture("2-sessions")
        // IPAD-2 (#88): on the iPad's screen the list keeps a column's width.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let another = app.buttons["Open Another Folder…"].firstMatch
            XCTAssertTrue(another.waitForExistence(timeout: 10))
            XCTAssertLessThanOrEqual(another.frame.width, 760, "the list is as wide as the screen")
        }
        // The Mac's figures arrive a moment after the list and push it
        // down: a tap aimed at where the button was would land beside it.
        _ = app.descendants(matching: .any)["system-cpu"].firstMatch.waitForExistence(timeout: 10)
        start.tap()

        // The terminal opens with the key bar and the compose field.
        let compose = app.descendants(matching: .any)["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["key-Escape"].exists)
        XCTAssertTrue(app.buttons["key-Shift Tab"].exists)
        sleep(2)
        capture("3-terminal")

        // A run that only looks at the app on its side.
        if environment["AGENTTERM_ONLY_LANDSCAPE"] != nil {
            landscape(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_SCROLL"] != nil {
            measureScrolling(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_HISTORY"] != nil {
            pagedHistory(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_IDLE"] != nil {
            measureIdle(app, launchButton: launchButton, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_MENU"] != nil {
            measureMenuTouches(app, launchButton: launchButton)
            return
        }
        if environment["AGENTTERM_ONLY_TERMINAL_MENU"] != nil {
            countTerminalMenuTouches(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_NOTE"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            readANote(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_INBOX"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            useTheInbox(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_NARROW"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            narrowTheWindow(app)
            return
        }

        // Text written in the compose field, Vietnamese included, is sent as typed.
        // When the Mac takes the session, the phone shows the Mac's larger
        // terminal scaled down, and can take the session back. Only checked
        // when the test is told that something will play the Mac.
        if environment["AGENTTERM_EXPECT_MAC_TAKEOVER"] != nil {
            let fit = app.buttons["Fit This Screen"]
            XCTAssertTrue(fit.waitForExistence(timeout: 30), "the Mac did not take the session")
            sleep(1)
            capture("3b-mac-in-control")
            // The Mac's terminal can be scrolled back and forth here while
            // it is shown scaled down, and stays in one piece.
            let terminal = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            terminal.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            sleep(1)
            capture("3b1-scrolled-back")
            terminal.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            sleep(1)
            capture("3b2-scrolled-back-more")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            sleep(1)
            capture("3b3-scrolled-forward")
            fit.tap()
            let gone = NSPredicate(format: "exists == false")
            wait(for: [expectation(for: gone, evaluatedWith: fit)], timeout: 10)
            sleep(1)
            capture("3c-taken-back")
            // A run that only looks at this part stops here.
            if environment["AGENTTERM_ONLY_MAC_TAKEOVER"] != nil { return }
        }

        compose.tap()
        compose.typeText("echo Xin chào tiếng Việt: ờ ữ ẩ đ")
        capture("4-composing")
        app.buttons["Send"].tap()
        sleep(1)

        compose.typeText("stty size")
        app.buttons["Send"].tap()
        sleep(2)
        print("AGENTTERM keyboard visible: \(app.keyboards.firstMatch.exists)")
        capture("5-sent")

        // Keys from the key bar reach the program: Up recalls the last
        // command, and Send with nothing written is Return.
        app.buttons["key-Up"].tap()
        app.buttons["Send"].tap()
        sleep(1)
        capture("6-key-bar")

        // The whole grid is on screen, also after the text size changes: a
        // marker written on the last row has to sit right above the key
        // bar. Full screen programs keep their status line there.
        // On the iPad, with the keyboard up, an entry of this menu touched
        // was taken by nothing, and the menu stayed open; with it down it
        // was taken (#88, 2026-11-15). Why is #83's to find: the keyboard
        // goes first here meanwhile, and #83 stays open.
        if UIDevice.current.userInterfaceIdiom == .pad, app.buttons["hide-keyboard"].firstMatch.exists {
            app.buttons["hide-keyboard"].firstMatch.tap()
            sleep(1)
        }
        for _ in 0..<3 {
            app.buttons["session-menu"].tap()
            app.buttons["Larger Text"].tap()
        }
        sleep(1)
        // A short command, so the compose field stays one line tall and the
        // terminal keeps its height while the command runs.
        compose.tap()
        compose.typeText("clear; tput cup 99 0; printf LAST-$(tput lines)")
        app.buttons["Send"].tap()
        sleep(2)
        capture("6b-bottom-row")

        // What is written and not sent is kept for the session: it is there
        // again when the terminal is opened the next time.
        compose.tap()
        compose.typeText("not sent yet")
        // The keyboard covers half of the terminal; a button at the end of
        // the key bar puts it away, and what was written stays.
        if app.keyboards.firstMatch.exists {
            XCTAssertTrue(app.buttons["hide-keyboard"].firstMatch.waitForExistence(timeout: 3), "no button to hide the keyboard")
            app.buttons["hide-keyboard"].firstMatch.tap()
            sleep(1)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stayed up")
            XCTAssertEqual(compose.value as? String, "not sent yet")
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["zsh"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["zsh"].firstMatch.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertEqual(compose.value as? String, "not sent yet", "what was written and not sent was lost")
        // Also when the app was closed in between.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["First Mac"].waitForExistence(timeout: 15))
        app.buttons["First Mac"].tap()
        XCTAssertTrue(app.staticTexts["zsh"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["zsh"].firstMatch.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertEqual(compose.value as? String, "not sent yet", "what was written and not sent was lost when the app was closed")
        // Sent, it is no longer kept.
        app.buttons["Send"].tap()
        sleep(1)
        XCTAssertNotEqual(compose.value as? String, "not sent yet")

        // Back in the list the session is there to return to.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 5))
        let session = app.staticTexts["zsh"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        // SES-25: ending it from its row's menu asks first.
        pick("End Session…", fromMenuOf: session, in: app)
        let confirm = app.buttons["End Session"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "ending the session from its row did not ask first")
        // Put away without answering: Cancel where the question has one,
        // a tap beside it where it has none.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the session ended though it was not confirmed")
        if environment["AGENTTERM_TEST_PROJECT"] != nil {
            // How the Mac itself is doing, above its sessions.
            for figure in ["system-cpu", "system-memory", "system-temperature", "system-down", "system-battery", "system-uptime"] {
                XCTAssertTrue(app.descendants(matching: .any)[figure].firstMatch.waitForExistence(timeout: 15), "\(figure) is not shown")
            }
            // The Settings tab: what the menu used to hold, in the order of
            // the Mac's Settings.
            app.tab("Settings").tap()
            XCTAssertTrue(app.switches["keep-awake"].waitForExistence(timeout: 5), "Settings has no Keep Mac Awake switch")
            // IPAD-3 (#88): what the app says names the device it runs on.
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let said = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "this \(device) can still reach them")).firstMatch
            XCTAssertTrue(said.exists, "Settings does not say this \(device)")
            capture("7-settings-tab")
            // Further down, under the agents' settings.
            let commitMessages = app.staticTexts["Commit Messages"].firstMatch
            for _ in 0..<4 where !commitMessages.isHittable { app.swipeUp() }
            XCTAssertTrue(commitMessages.exists, "Settings has no Commit Messages")
            // SCHED-14: Schedules, a tab of its own as on the Mac's bar of
            // places, in three groups, as the Mac shows them; no longer a
            // row of Settings.
            XCTAssertFalse(app.buttons["schedules"].exists, "Schedules is still in Settings")
            app.tab("Schedules").tap()
            XCTAssertTrue(app.navigationBars["Schedules"].waitForExistence(timeout: 5))
            for group in ["RUNNING", "SCHEDULED", "PAST RUNS"] {
                XCTAssertTrue(app.staticTexts[group].waitForExistence(timeout: 5) || app.staticTexts[group.capitalized].exists, "no \(group) group")
            }
            XCTAssertTrue(app.staticTexts["No run is going on."].exists)
            capture("7-schedules")
            app.tab("History").tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
            app.tab("Sessions").tap()
            // The hosts of the Mac's SSH configuration, without its patterns.
            let ssh = app.buttons["ssh-menu"].firstMatch
            XCTAssertTrue(ssh.waitForExistence(timeout: 5), "there is no SSH menu")
            ssh.tap()
            XCTAssertTrue(app.buttons["build-server"].waitForExistence(timeout: 5), "the SSH host is not listed")
            capture("7-ssh-hosts")
            // Put the menu away without connecting anywhere.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
            // The menu takes a moment to go; what is under it cannot be tapped until then.
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["build-server"])
            waitForExpectations(timeout: 10)
        }
        capture("7-session-listed")

        // The folder's git changes and its history, as in the Mac's side
        // panel. The script that runs this test sets up the project.
        if environment["AGENTTERM_TEST_PROJECT"] != nil {
            app.buttons["folder-details"].firstMatch.tap()
            // The app remembers the tab last used, so pick it rather than assume it.
            XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
            app.buttons["Git"].tap()
            XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the changed file is not listed")
            capture("7a-changes")
            // The files can be grouped by folder, and the choice sticks.
            let group = app.buttons["Group by folder"]
            if group.exists {
                group.tap()
                XCTAssertTrue(app.buttons["Show as a flat list"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["notes.txt"].exists)
                capture("7a2-changes-tree")
                app.buttons["Show as a flat list"].tap()
            }
            app.staticTexts["notes.txt"].tap()
            let firstChange = app.staticTexts["+second line"]
            XCTAssertTrue(firstChange.waitForExistence(timeout: 10), "the diff is not shown")
            capture("7b-diff")
            // The diff scrolls sideways, to the end of a long line, and down
            // to its last line.
            let left = firstChange.frame.minX
            app.swipeLeft()
            XCTAssertLessThan(firstChange.frame.minX, left, "the diff does not scroll sideways")
            app.swipeRight()
            let lastChange = app.staticTexts["+line 150"]
            for _ in 0..<14 where !lastChange.exists { app.swipeUp() }
            XCTAssertTrue(lastChange.exists, "the diff does not scroll down to its end")
            capture("7b1-diff-end")
            // The same diff as two panels, before and after, and back.
            app.buttons["diff-layout"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["split-diff-after"].firstMatch.waitForExistence(timeout: 10), "the diff is not shown as two panels")
            capture("7b1a-diff-two-panels")
            // Each panel is a text, which its panel scrolls sideways on its
            // own; the line is in the text of what it is now, without its mark.
            let after = app.descendants(matching: .any)["split-diff-after"].firstMatch
            let text = after.textViews.firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "the panel of what it is now has no text")
            let shown = text.value as? String ?? ""
            XCTAssertTrue(shown.contains("second line") && !shown.contains("+second line"), "the two panels do not show the changed line")
            let before = text.frame.minX
            after.swipeLeft()
            XCTAssertLessThan(text.frame.minX, before, "the panel of what it is now does not scroll sideways")
            after.swipeRight()
            app.buttons["diff-layout"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["patch"].firstMatch.waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()

            // Stage the file, take it back, stage it again and commit it.
            let commit = app.buttons["commit"]
            XCTAssertTrue(commit.waitForExistence(timeout: 5))
            XCTAssertFalse(commit.isEnabled, "nothing is staged yet")
            app.buttons["Stage notes.txt"].tap()
            XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10), "the file was not staged")
            XCTAssertTrue(app.staticTexts["STAGED"].exists)
            capture("7b2-staged")
            app.buttons["Unstage All"].tap()
            XCTAssertTrue(app.buttons["Stage notes.txt"].waitForExistence(timeout: 10), "the file was not unstaged")
            app.buttons["Stage All"].tap()
            XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10))
            XCTAssertFalse(commit.isEnabled, "there is no message yet")
            let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
            message.tap()
            message.typeText("test: add a second line")
            XCTAssertTrue(commit.isEnabled)
            capture("7b3-ready-to-commit")
            commit.tap()
            XCTAssertTrue(app.staticTexts["No uncommitted changes."].waitForExistence(timeout: 15), "the commit was not made")
            capture("7b4-committed")

            // The commit is what there is to push: the project follows a remote.
            let push = app.buttons["git-push"]
            XCTAssertTrue(push.waitForExistence(timeout: 10), "there is no Push button")
            XCTAssertEqual(push.label, "Push, 1 commit", "one commit is waiting to be pushed")
            XCTAssertTrue(app.buttons["git-pull"].exists)
            XCTAssertTrue(app.staticTexts["Follows origin/main"].exists)
            push.tap()
            expectation(for: NSPredicate(format: "label == %@", "Push"), evaluatedWith: push)
            waitForExpectations(timeout: 20)
            capture("7b4a-pushed")

            // GIT-73 (#35): a branch made, renamed and deleted from the
            // phone, as on the Mac; one with nothing of its own is asked
            // about once.
            app.buttons["branch-menu"].tap()
            app.buttons["new-branch"].tap()
            let newBranch = app.textFields["new-branch-name"]
            XCTAssertTrue(newBranch.waitForExistence(timeout: 5))
            newBranch.tap()
            newBranch.typeText("phone-branch")
            // Not switched to: the switch itself, at the row's end, not its label.
            let switchToIt = app.switches["new-branch-checkout"]
            switchToIt.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(switchToIt.value as? String, "0", "Switch to it is still on")
            app.buttons["new-branch-create"].tap()
            let made = app.buttons["branch-phone-branch"]
            XCTAssertTrue(made.waitForExistence(timeout: 10), "the branch was not made")
            made.press(forDuration: 1.2)
            app.buttons["Rename…"].tap()
            let newName = app.alerts.textFields.firstMatch
            XCTAssertTrue(newName.waitForExistence(timeout: 5), "not asked for the new name")
            newName.typeText("phone-renamed")
            app.alerts.buttons["Rename"].tap()
            let renamed = app.buttons["branch-phone-renamed"]
            XCTAssertTrue(renamed.waitForExistence(timeout: 10), "the branch was not renamed")
            XCTAssertFalse(app.buttons["branch-phone-branch"].exists)
            capture("7b4b-branch-renamed")
            renamed.press(forDuration: 1.2)
            app.buttons["Delete…"].tap()
            let deleteBranch = app.buttons["Delete Branch"]
            XCTAssertTrue(deleteBranch.waitForExistence(timeout: 5), "not asked before deleting")
            deleteBranch.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: renamed)
            waitForExpectations(timeout: 10)
            app.buttons["Done"].tap()

            // GIT-74 (#36): the newest commit reverted from the phone, then
            // the revert reverted, so the files are as they were; picking
            // is offered and asked about the same way.
            app.buttons["git-commits"].tap()
            func revertNewest(_ subject: String) {
                let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", subject)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 15), "the commit “\(subject)” is not listed")
                row.tap()
                let revert = app.buttons["commit-revert"]
                XCTAssertTrue(revert.waitForExistence(timeout: 10), "the commit cannot be reverted")
                XCTAssertTrue(app.buttons["commit-pick"].exists, "the commit cannot be picked")
                revert.tap()
                let confirm = app.buttons["Revert"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5), "not asked before reverting")
                confirm.tap()
                app.navigationBars.buttons.firstMatch.tap()
            }
            revertNewest("test: add a second line")
            revertNewest("Revert \"test: add a second line\"")
            // git 2.43 and later name the revert of a revert "Reapply".
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Reapply \"test: add a second line\"", "Revert \"Revert"))
                    .firstMatch.waitForExistence(timeout: 15),
                "the revert of the revert is not listed")
            capture("7b4c-reverted")
            app.navigationBars.buttons.firstMatch.tap()

            // The folder's files: open one, edit it, save it, make a new one.
            app.buttons["Files"].tap()
            XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the file is not listed")
            capture("7b5-files")
            app.staticTexts["notes.txt"].tap()
            let editor = app.textViews["code-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor did not open")
            XCTAssertTrue((editor.value as? String)?.contains("second line") == true, "the file's text is not shown")
            editor.tap()
            editor.typeText("edited ")
            XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
            capture("7b6-editing")
            app.buttons["Save"].tap()
            let saved = NSPredicate(format: "exists == false")
            expectation(for: saved, evaluatedWith: app.buttons["Save"])
            waitForExpectations(timeout: 10)
            app.navigationBars.buttons.firstMatch.tap()

            app.buttons["New File"].tap()
            let name = app.alerts.textFields.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.typeText("plan.md")
            app.alerts.buttons["Create"].tap()
            XCTAssertTrue(app.navigationBars["plan.md"].waitForExistence(timeout: 10), "the new file did not open")
            capture("7b7-new-file")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["plan.md"].waitForExistence(timeout: 10))
            // The edit is a change git sees.
            app.buttons["Git"].tap()
            XCTAssertTrue(app.buttons["Stage notes.txt"].waitForExistence(timeout: 10), "the saved edit is not a change")

            app.buttons["History"].tap()
            let conversation = app.staticTexts["write tests for the parser"]
            XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation is not listed")
            capture("7c-history")
            // HIST-24 (#50): picked to be deleted, a touch ticks a row and
            // opens nothing; Done leaves the rows as they were.
            app.buttons["history-select"].tap()
            XCTAssertTrue(app.staticTexts["Pick the ones to delete"].waitForExistence(timeout: 5))
            conversation.tap()
            XCTAssertTrue(app.staticTexts["1 picked"].waitForExistence(timeout: 5), "a touch did not pick the row")
            XCTAssertFalse(app.buttons["Resume in Claude Code"].exists, "a touch while picking opened the conversation")
            // A folder's list deletes what is picked; every one on the Mac
            // is the History tab's to offer.
            XCTAssertTrue(app.buttons["history-delete-picked"].exists)
            XCTAssertFalse(app.buttons["history-delete-all"].exists, "a folder's list offers to delete every conversation")
            capture("7c2-history-picking")
            app.buttons["history-pick-done"].tap()
            XCTAssertTrue(app.staticTexts["history-summary"].waitForExistence(timeout: 5))
            conversation.tap()
            XCTAssertTrue(app.buttons["Resume in Claude Code"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Copy Resume Command"].exists)
            // The prompt the receiving agent would start with is shown.
            let prompt = app.descendants(matching: .any)["handoff-prompt"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the handoff prompt is not shown")
            XCTAssertTrue((prompt.value as? String)?.contains("You are taking over a task from Claude Code") == true, "\(String(describing: prompt.value))")
            capture("7d-conversation")
            // The agent can be sent on in another folder: a repository
            // inside the conversation's folder is offered, and any folder
            // on the Mac can be picked.
            app.buttons["choose-folder"].tap()
            XCTAssertTrue(app.buttons["web"].waitForExistence(timeout: 10), "the folder picker does not open at the conversation's folder")
            capture("7d2-choose-folder")
            app.buttons["web"].tap()
            let pick = app.buttons["pick-folder"]
            XCTAssertTrue(pick.waitForExistence(timeout: 10))
            XCTAssertEqual(pick.label, "Continue in web")
            pick.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'project/web'")).firstMatch.waitForExistence(timeout: 5), "the picked folder is not the one chosen")
            capture("7d3-folder-chosen")
            app.buttons["Close"].tap()
            app.navigationBars.buttons.firstMatch.tap()

            // Any folder on the Mac can be picked to start in.
            app.buttons["Open Another Folder…"].tap()
            XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 10), "the home folder is not listed")
            capture("7e-browse-home")
            app.buttons["Projects"].tap()
            XCTAssertTrue(app.buttons["demo"].waitForExistence(timeout: 10))
            app.buttons["demo"].tap()
            let startHere = app.buttons["Start Shell here"]
            XCTAssertTrue(startHere.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Start in demo"].waitForExistence(timeout: 5))
            capture("7f-browse-demo")
            startHere.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10), "no terminal opened for the picked folder")
            compose.tap()
            compose.typeText("pwd")
            app.buttons["Send"].tap()
            sleep(2)
            capture("7g-started-in-picked-folder")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["demo"].waitForExistence(timeout: 5), "the session's folder is not listed")
        }

        // Something that needs the user's attention shows up over whatever
        // screen is in front. Handing off a session that has no saved
        // conversation yet says so, right there in the terminal, not only
        // after going back. Needs an agent, so it runs where one is installed.
        let startAgent = app.buttons["Start Claude Code"].firstMatch
        if startAgent.exists {
            startAgent.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 15), "no terminal opened for the agent")
            app.buttons["session-menu"].tap()
            let handOff = app.buttons["Hand Off…"]
            XCTAssertTrue(handOff.waitForExistence(timeout: 5), "an agent's session offers no handoff")
            handOff.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "nothing happened after choosing Hand Off")
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no conversation to hand off'")).firstMatch.exists)
            capture("7h-handoff-nothing-yet")
            alert.buttons["OK"].tap()
            app.buttons["session-menu"].tap()
            app.buttons["End Session"].tap()
            app.buttons["End Session"].firstMatch.tap()
            XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10), "ending the session did not return to the list")
        }

        // A second Mac can be paired. It becomes the one on screen, with
        // nothing of the first Mac's sessions.
        guard environment["AGENTTERM_SECOND_PAIR_URL"] != nil else { return }
        app.buttons["mac-menu"].tap()
        app.buttons["Second Mac"].tap()
        XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 15), "the second Mac is not on screen")
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["zsh"].exists, "the first Mac's session must not show under the second")
        // The second Mac's host says it is of an older release: the phone says so.
        let versionCard = app.descendants(matching: .any)["version-card"].firstMatch
        XCTAssertTrue(versionCard.waitForExistence(timeout: 5), "a Mac of another version is not pointed out")
        XCTAssertTrue(versionCard.label.contains("Second Mac is an older version"), versionCard.label)
        capture("8-second-mac")

        // SET-4: the second Mac kept awake, then out of reach (the script
        // stops its host): its settings stay as it last said them, and
        // cannot be changed until it is reached again.
        app.tab("Settings").tap()
        let awake = app.switches["keep-awake"].firstMatch
        XCTAssertTrue(awake.waitForExistence(timeout: 10), "the second Mac's settings are not shown")
        awake.switches.firstMatch.exists ? awake.switches.firstMatch.tap() : awake.tap()
        let gone = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Not connected to Second Mac'")).firstMatch
        XCTAssertTrue(gone.waitForExistence(timeout: 20), "nothing says the Mac is out of reach")
        XCTAssertFalse(awake.isEnabled, "the setting of a Mac out of reach can still be changed")
        XCTAssertEqual(awake.value as? String, "1", "the setting is not as the Mac last said")
        capture("8a-second-mac-gone")
        app.tab("Sessions").tap()

        // The menu lists both, and switching goes back to the first Mac and
        // its session, which kept running.
        app.buttons["mac-menu"].tap()
        XCTAssertTrue(app.buttons["Second Mac"].waitForExistence(timeout: 5))
        capture("9-mac-menu")
        app.buttons["First Mac"].tap()
        XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["zsh"].firstMatch.waitForExistence(timeout: 10), "the first Mac's session is back")
        XCTAssertFalse(versionCard.exists, "the warning about the second Mac's version is still shown on the first")
        capture("10-back-on-first")

        // Sessions can be arranged: grouped, pinned, dragged. Three in the
        // project now, under one more in another folder.
        guard environment["AGENTTERM_TEST_PROJECT"] != nil else { return }
        for _ in 0..<2 {
            app.buttons[launchButton].firstMatch.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        }
        let rows = app.staticTexts.matching(identifier: "zsh")
        XCTAssertEqual(rows.count, 4)
        // The list is longer than the screen now. Bring the project's
        // sessions to the middle, clear of the bars, before dragging them.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
        let group = app.buttons["session-group"].firstMatch
        func groupSays(_ text: String) -> Bool {
            let wanted = NSPredicate(format: "label CONTAINS %@", text)
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: wanted, object: group)], timeout: 6) == .completed
        }
        pick("Add to New Group", fromMenuOf: rows.element(boundBy: 0), in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 5), "no group was made")
        XCTAssertTrue(groupSays("1 sessions"), group.label)
        // Dropped on the group's label, a session joins it. Dropped on a
        // session of the group, it joins too.
        gesture(until: { groupSays("2 sessions") }) {
            rows.element(boundBy: 2).press(forDuration: 0.7, thenDragTo: group, withVelocity: .slow, thenHoldForDuration: 0.6)
        }
        XCTAssertTrue(groupSays("2 sessions"), "dropping on the label did not add the session: \(group.label)")
        gesture(until: { groupSays("3 sessions") }) {
            rows.element(boundBy: 2).press(forDuration: 0.7, thenDragTo: rows.element(boundBy: 0), withVelocity: .slow, thenHoldForDuration: 0.6)
        }
        XCTAssertTrue(groupSays("3 sessions"), "dropping on a grouped session did not add the session: \(group.label)")
        capture("11-grouped")
        // A pinned session leaves its group and goes first.
        pick("Pin", fromMenuOf: rows.element(boundBy: 1), in: app)
        XCTAssertTrue(groupSays("2 sessions"), "pinning did not take the session out of the group: \(group.label)")
        // The group is renamed, recolored and folded away.
        pick("Rename Group…", fromMenuOf: group, in: app)
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText(" api")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(groupSays("Group 1 api"), group.label)
        // Chosen, the menu goes. The colors are a menu inside the menu:
        // open all the while, so none of these steps waits for the app.
        let orange = app.buttons["Orange"]
        func menuIsGone() -> Bool {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: orange)
            return XCTWaiter().wait(for: [gone], timeout: 4) == .completed
        }
        pick("Color", fromMenuOf: group, in: app)
        IdleWaits.skipped {
            XCTAssertTrue(orange.waitForExistence(timeout: 5), "the colors are not offered")
            capture("12-colors")
            gesture(until: menuIsGone) { if orange.exists { orange.tap() } }
        }
        XCTAssertFalse(orange.exists, "the color was not chosen: its menu is still open")
        capture("13-arranged")
        gesture(until: { groupSays("collapsed") }) { group.tap() }
        XCTAssertTrue(groupSays("collapsed"), group.label)
        XCTAssertEqual(rows.count, 2, "a collapsed group still shows its sessions")
        capture("14-collapsed")

        // The Mac keeps the arrangement: it is there again after looking at
        // another Mac, which has none of it.
        app.buttons["mac-menu"].tap()
        app.buttons["Second Mac"].tap()
        XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(group.exists, "the first Mac's group must not show under the second")
        app.buttons["mac-menu"].tap()
        app.buttons["First Mac"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the arrangement did not come back from the Mac")
        XCTAssertTrue(groupSays("Group 1 api, 2 sessions, collapsed"), group.label)

        // Listed folders can be put in another order, from the menu of a
        // folder's name and by dragging one onto another. A second folder
        // is listed first.
        app.buttons["Open Another Folder…"].tap()
        let add = app.buttons["Add to Folders"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the folder being looked at cannot be added to the list")
        add.tap()
        app.buttons["Cancel"].tap()
        let names = app.staticTexts.matching(identifier: "folder-name")
        func order() -> [String] { (0..<names.count).map { names.element(boundBy: $0).label } }
        func orderBecomes(_ wanted: [String]) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline { if order() == wanted { return true }; usleep(300_000) }
            return false
        }
        // The project, the folder just added, then the unlisted one a session runs in.
        XCTAssertTrue(orderBecomes(["project", "home", "demo"]), "\(order())")
        // PERF-13: here, after everything before it, the menu's entry
        // chosen again and again.
        if environment["AGENTTERM_MENU_AFTER"] != nil {
            countMenuTouches(app)
            return
        }
        // IOS-10 (#83): the finger kept on the entry 4 seconds, for the
        // Mac's figures, which come every 3, to be drawn meanwhile. The menu
        // was made anew under it, and the entry not chosen.
        pick("Move Down", fromMenuOf: names.element(boundBy: 0), in: app, hold: 4) { capture("15-folder-menu") }
        XCTAssertTrue(orderBecomes(["home", "project", "demo"]), "Move Down, held, did not move the folder: \(order())")
        // Back to the top of the list, so both names are on screen and
        // clear of the bars: one is dragged onto the other.
        app.swipeDown()
        names.element(boundBy: 1).press(forDuration: 0.7, thenDragTo: names.element(boundBy: 0), withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(orderBecomes(["project", "home", "demo"]), "dragging a folder onto another did not move it: \(order())")
        capture("16-folders-reordered")
        readANote(app, compose: compose)
    }

    /// IPAD-2 (#88): the iPad's window narrowed by the handle at its bottom
    /// right corner, the list is laid out as on the iPhone, as wide as the
    /// window less its margins. Starts in the sessions list.
    private func narrowTheWindow(_ app: XCUIApplication) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        // In the screen's points: the app's own frame moves with its window.
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: .zero)
        let screenWidth = XCUIScreen.main.screenshot().image.size.width
        /// The handle at the window's bottom right corner, dragged across to `x`.
        func dragCorner(to x: CGFloat) {
            let window = app.windows.firstMatch.frame
            screen.withOffset(CGVector(dx: window.maxX - 4, dy: window.maxY - 4))
                .press(forDuration: 0.8, thenDragTo: screen.withOffset(CGVector(dx: x, dy: window.maxY - 4)))
            sleep(3)
        }
        // A window left narrow by a run before this one is made whole first.
        if app.windows.firstMatch.frame.width < screenWidth - 40 { dragCorner(to: screenWidth - 2) }
        let another = app.buttons["Open Another Folder…"].firstMatch
        XCTAssertTrue(another.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let wide = another.frame.width
        capture("N0-full")
        dragCorner(to: window.minX + 420)
        capture("N1-narrowed")
        let narrowed = app.windows.firstMatch.frame
        print("MEASURE narrow: window \(window.width) -> \(narrowed.width), list \(wide) -> \(another.frame.width)")
        XCTAssertLessThan(narrowed.width, window.width - 200, "the window was not narrowed")
        XCTAssertGreaterThan(another.frame.width, narrowed.width - 60, "narrowed, the list does not fill the window as on the iPhone")
        // Whole again, for the runs after this one.
        dragCorner(to: screenWidth - 2)
        print("MEASURE narrow: window back to \(app.windows.firstMatch.frame.width)")
    }

    /// IOS-9 (#87): why an agent's state is not known is read on the phone
    /// too. A stand-in Antigravity, whose session always has a note:
    /// touched, its mark shows the words, and the session does not open.
    /// Starts in the sessions list.
    /// INBOX-4 (#67, #71): an agent done while its terminal is not on
    /// screen is at the top of the Sessions list, under Inbox, with what it
    /// said; touched, it shows what its turn came to, without being seen;
    /// Open shows its terminal, and it is then seen: it leaves the Inbox.
    private func useTheInbox(_ app: XCUIApplication, compose: XCUIElement) {
        // The stand-in Claude Code says it is done a few seconds after it
        // starts (scripts/test-ios.sh): by then the list is on screen.
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
        claude.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Claude Code session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let title = app.descendants(matching: .any)["inbox-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "nothing came to the Inbox")
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "inbox-session-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the agent that is done is not in the Inbox")
        XCTAssertTrue(item.label.contains("is done"), item.label)
        XCTAssertTrue(item.label.contains("Decide what you want there"), item.label)
        capture("18-inbox")
        item.tap()
        let said = app.descendants(matching: .any)["result-said"].firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 10), "the item did not show what the turn came to")
        let request = app.descendants(matching: .any)["result-request"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 5), "what the agent was asked is not shown")
        XCTAssertTrue(request.label.contains("Explain in short lines"), request.label)
        capture("19-result")
        app.buttons["result-open"].tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "Open did not show the terminal")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(said.waitForExistence(timeout: 5), "back from the terminal is not the result")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "the session seen stayed in the Inbox")
        capture("20-inbox-seen")
    }

    private func readANote(_ app: XCUIApplication, compose: XCUIElement) {
        let antigravity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Antigravity")).firstMatch
        XCTAssertTrue(antigravity.waitForExistence(timeout: 10), "no Antigravity to start")
        antigravity.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Antigravity session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let mark = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "state-note-")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "no note on the Antigravity session's row")
        capture("17a-before-note")
        mark.tap()
        let note = app.staticTexts["state-note-text"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "touching the mark did not show the note")
        XCTAssertTrue(note.label.contains("does not say when it waits for permission"), note.label)
        XCTAssertFalse(compose.exists, "touching the mark opened the session")
        capture("17-note")
    }
}
