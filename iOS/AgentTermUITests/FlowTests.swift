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

    /// IOS-18 (#280): with the Mac gone, Send keeps the message and says
    /// why, and a key of the key bar is dropped and said once, not kept to
    /// be sent later. Before the fix the field emptied, and the keys went
    /// nowhere without a word.
    private func typeWhileTheMacGoes(_ app: XCUIApplication, compose: XCUIElement, mark: String) {
        compose.tap()
        // The script stops the host once this file is there.
        compose.typeText("touch '\(mark)'")
        app.buttons["Send"].tap()
        let lost = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Reconnecting")).firstMatch
        XCTAssertTrue(lost.waitForExistence(timeout: 20), "the phone does not say the Mac went")
        compose.tap()
        compose.typeText("echo kept")
        app.buttons["Send"].tap()
        let held = app.staticTexts["compose-held"]
        XCTAssertTrue(held.waitForExistence(timeout: 5), "Send with the Mac gone said nothing")
        XCTAssertTrue(held.label.contains("is not connected"), held.label)
        XCTAssertEqual(compose.value as? String, "echo kept", "Send with the Mac gone threw the message away")
        capture("send-not-connected")
        if app.buttons["hide-keyboard"].firstMatch.exists { app.buttons["hide-keyboard"].firstMatch.tap() }
        app.buttons["key-Escape"].tap()
        let dropped = app.alerts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "keys typed in its terminals are dropped")).firstMatch
        XCTAssertTrue(dropped.waitForExistence(timeout: 5), "a key typed with the Mac gone was dropped without a word")
        capture("keys-not-connected")
        app.alerts.buttons["OK"].tap()
        // Said once, not for every key.
        app.buttons["key-Tab"].tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "the dropped keys were said again")
        XCTAssertEqual(compose.value as? String, "echo kept")
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
        // Two agents' sessions in the list: an agent's menu has Pin, a
        // shell's only End Session (#127).
        app.navigationBars.buttons.firstMatch.tap()
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        for _ in 0..<2 {
            XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
            claude.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
        }
        // The rows' names: the buttons that start one say "Claude".
        let rows = app.staticTexts.matching(identifier: "Claude Code")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
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
        passNotificationAsk(app)
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

    /// NOTIFY-2 (#195): Not Now on the first screen turns the app's
    /// notifications off: iOS is not asked when the phone pairs, and the
    /// switch in Settings is off; iOS is asked once it is turned on again.
    /// The script installs the app afresh for it, so that iOS was not asked.
    /// A notice that comes after pairing, and is a notification while it is
    /// unread, does not ask iOS either: the stand-in Claude Code says it is
    /// done (`NOTNOW=only` has it do so, as `INBOX=only` does), and the host
    /// says to show it at once (`noticeAlert`, nothing waits since #234).
    private func notNow(_ app: XCUIApplication, link: String, launchButton: String) throws {
        app.buttons["notifications-not-now"].tap()
        XCTAssertTrue(app.buttons["notifications-not-now"].waitForNonExistence(timeout: 10), "the screen stays")
        app.launchEnvironment.removeValue(forKey: "AGENTTERM_ASK_NOTIFICATIONS")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.openPairingLink(try XCTUnwrap(URL(string: link)))
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 15), "not connected to the host")
        let asked = springboard.alerts.firstMatch
        XCTAssertFalse(asked.waitForExistence(timeout: 5), "iOS asked whether the app may notify after Not Now: \(asked.label)")
        // A notice after Not Now: in the Inbox, and no question of iOS when
        // its time to be a notification comes.
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
        claude.tap()
        XCTAssertTrue(app.descendants(matching: .any)["compose"].firstMatch.waitForExistence(timeout: 10), "the Claude Code session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "inbox-[0-9]+")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "the agent that is done is not in the Inbox")
        XCTAssertTrue(item.label.contains("is done"), item.label)
        // Unread on the list when it is a notification, at once (#234), and
        // some seconds on.
        XCTAssertFalse(asked.waitForExistence(timeout: 10), "iOS asked whether the app may notify when a notice came after Not Now: \(asked.label)")
        XCTAssertTrue(item.exists, "the notice was read or went, so its notification was not due")
        capture("NN-0-notice-after-not-now")
        app.tab("Settings").tap()
        let notify = app.switches["notify-agents"].firstMatch
        for _ in 0..<5 where !(notify.exists && notify.isHittable) { app.swipeUp() }
        XCTAssertTrue(notify.waitForExistence(timeout: 5), "Settings has no switch for the app's notifications")
        XCTAssertEqual(notify.value as? String, "0", "Not Now left the app's notifications on")
        // NOTIFY-4 (#211): the switch under it says off too, not only dimmed
        // (principle 3). That it shows what it was set to once they are on
        // again is DependentSwitchTests': this build has no push, by which
        // it stays off (NOTIFY-5, #212).
        let pushAlso = app.switches["push-also"].firstMatch
        XCTAssertTrue(pushAlso.waitForExistence(timeout: 5), "Settings has no switch for notifications while the app is closed")
        XCTAssertEqual(pushAlso.value as? String, "0", "Also While the App Is Closed shows on while the app's notifications are off")
        capture("NN-1-notifications-off")
        notify.switches.firstMatch.exists ? notify.switches.firstMatch.tap() : notify.tap()
        XCTAssertTrue(springboard.alerts.buttons["Allow"].firstMatch.waitForExistence(timeout: 10), "iOS was not asked once they were turned on")
        allowNotifications(timeout: 1)
        XCTAssertEqual(notify.value as? String, "1")
        XCTAssertEqual(pushAlso.value as? String, "0", "Also While the App Is Closed shows on in a build with no push")
        let noPush = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "This build has no push")).firstMatch
        XCTAssertTrue(noPush.waitForExistence(timeout: 5), "Settings does not say why Also While the App Is Closed is off")
    }

    func testPairStartSessionAndType() throws {
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"], "run this test through scripts/test-ios.sh")
        let launchButton = environment["AGENTTERM_LAUNCH"] ?? "Start Shell"
        let app = XCUIApplication()
        // #83: the app writes down the touches it receives.
        if let log = environment["AGENTTERM_TOUCH_LOG"] { app.launchEnvironment["AGENTTERM_TOUCH_LOG"] = log }
        // PERF-16 (#126): the app notes how long its main thread is held up.
        if let notes = environment["AGENTTERM_MEASURE_MAIN"] { app.launchEnvironment["AGENTTERM_MEASURE_MAIN"] = notes }
        // NOTIFY-1 (#180): the first screen asks only whether the app may
        // notify, whatever iOS was told before on this simulator.
        app.launchEnvironment["AGENTTERM_ASK_NOTIFICATIONS"] = "1"
        app.launch()
        XCTAssertTrue(app.otherElements["notifications-ask"].firstMatch.waitForExistence(timeout: 10) || app.buttons["notifications-allow"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Know When an Agent Needs You"].exists)
        XCTAssertTrue(app.buttons["notifications-not-now"].exists)
        capture("0-notifications")
        if environment["AGENTTERM_ONLY_NOT_NOW"] != nil { return try notNow(app, link: link, launchButton: launchButton) }
        passNotificationAsk(app)
        XCTAssertTrue(app.buttons["notifications-allow"].waitForNonExistence(timeout: 10), "the screen stays")
        // Opening a link launches the app again with this environment: from
        // here it is the answer kept by the app that says not to ask again.
        app.launchEnvironment.removeValue(forKey: "AGENTTERM_ASK_NOTIFICATIONS")

        // Pair by opening the link, as tapping an agentterm:// link would: the
        // simulator has no camera to scan with.
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        capture("1-pair")
        app.openPairingLink(try XCTUnwrap(URL(string: link)))
        allowNotifications()

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
            app.openPairingLink(try XCTUnwrap(URL(string: second)))
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
        if let gone = environment["AGENTTERM_GONE_MARK"], environment["AGENTTERM_ONLY_OFFLINE"] != nil {
            typeWhileTheMacGoes(app, compose: compose, mark: gone)
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
        if environment["AGENTTERM_ONLY_INBOXASK"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            answerFromTheInbox(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_ASK"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            answerWhileWritingAPrompt(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_MARKDOWN"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            try measureMarkdown(app)
            return
        }
        if environment["AGENTTERM_ONLY_CUT"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            listAnAnswerWhoseCutsComeToTheSameText(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_WORKTREE"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            watchAWorktreeBeingMade(app, compose: compose)
            return
        }
        if environment["AGENTTERM_ONLY_UNANSWERED"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            commitWhileTheMacGoes(app)
            return
        }
        if environment["AGENTTERM_ONLY_BADLINK"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            try pairWithACodeThatIsRefused(app, launchButton: launchButton)
            return
        }
        if environment["AGENTTERM_ONLY_BADSTATE"] != nil {
            // HOST-16 (#273): the host started on a schedules file it could
            // not read, and the phone's banner says so.
            app.navigationBars.buttons.firstMatch.tap()
            let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "could not read its schedules")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 15), "the phone does not say the host could not read its schedules")
            capture("unreadable-state")
            // REMOTE-36 (#274): the stand-in Tailscale address it cannot
            // listen on, said in a banner of its own.
            let listener = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "could not listen on its Tailscale address")).firstMatch
            XCTAssertTrue(listener.waitForExistence(timeout: 15), "the phone does not say the host cannot listen on its Tailscale address")
            capture("listener-failed")
            // IOS-24 (#328): the banners take room of their own: the list
            // starts under the last of them, not under the screen's top.
            let cards = app.descendants(matching: .any).matching(identifier: "failure-card").allElementsBoundByIndex
            let bottom = cards.map(\.frame.maxY).max() ?? 0
            let list = app.scrollViews.firstMatch
            XCTAssertTrue(list.exists, "no list")
            XCTAssertGreaterThanOrEqual(list.frame.minY, bottom, "the list starts at \(list.frame.minY), under the banners, which go down to \(bottom)")
            return
        }
        if environment["AGENTTERM_ONLY_COMMITWAIT"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            commitWhileTheFolderChanges(app)
            return
        }
        if environment["AGENTTERM_ONLY_DELETE"] != nil {
            app.navigationBars.buttons.firstMatch.tap()
            deleteASchedule(app)
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
            let fit = app.buttons["Use This Size"]
            XCTAssertTrue(fit.waitForExistence(timeout: 30), "the Mac did not take the session")
            // SIZE-10 (#120): the Mac is named, by its own name.
            let named = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "In use on ")).firstMatch
            XCTAssertTrue(named.waitForExistence(timeout: 5), "the banner does not say who uses the session")
            XCTAssertFalse(named.label.hasPrefix("In use on another device"), named.label)
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
        passNotificationAsk(app)
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
            // SET-6 (#155): the Mac's Hooks & MCP, Shell, Browser and Agents,
            // as its own Settings has them; Install runs on the Mac.
            let hooks = app.buttons["settings-hooks"].firstMatch
            for _ in 0..<4 where !hooks.isHittable { app.swipeUp() }
            XCTAssertTrue(hooks.waitForExistence(timeout: 5), "Settings has no Hooks & MCP")
            hooks.tap()
            let install = app.buttons["setup-install-claude"].firstMatch
            XCTAssertTrue(install.waitForExistence(timeout: 20), "Claude Code's Install is not offered")
            capture("7-settings-hooks")
            install.tap()
            // Run on the Mac, whose stand-in agent has no such command: what
            // came of it reaches the phone, said.
            let outcome = app.descendants(matching: .any)["setup-problem-claude"].firstMatch
            XCTAssertTrue(outcome.waitForExistence(timeout: 30) || app.buttons["setup-remove-claude"].exists, "what Install came to did not reach the phone")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            // Settings is longer than a screen: scrolled to it first.
            let settingsShell = app.buttons["settings-shell"].firstMatch
            for _ in 0..<4 where !settingsShell.isHittable { app.swipeUp() }
            settingsShell.tap()
            XCTAssertTrue(app.descendants(matching: .any)["shell-program"].firstMatch.waitForExistence(timeout: 10), "the Shell screen has no program")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            // Settings is longer than a screen: scrolled to it first.
            let settingsAgents = app.buttons["settings-agents"].firstMatch
            for _ in 0..<4 where !settingsAgents.isHittable { app.swipeUp() }
            settingsAgents.tap()
            XCTAssertTrue(app.textViews["prompt-text"].firstMatch.waitForExistence(timeout: 10), "the Agents screen has no words")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            // Settings is longer than a screen: scrolled to it first.
            let settingsBrowser = app.buttons["settings-browser"].firstMatch
            for _ in 0..<4 where !settingsBrowser.isHittable { app.swipeUp() }
            settingsBrowser.tap()
            XCTAssertTrue(app.buttons["profile-new"].firstMatch.waitForExistence(timeout: 10), "the Browser screen cannot add a profile")
            app.navigationBars.buttons.element(boundBy: 0).tap()
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
            // GIT-79 (#166): its words on one line, as Fetch's: not broken
            // in the middle of a word to fit the count beside them.
            let fetch = app.buttons["git-fetch"]
            capture("7b4-push-count")
            XCTAssertLessThanOrEqual(push.frame.height, fetch.frame.height + 1, "Push's words are broken over lines: \(push.frame) beside \(fetch.frame)")
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
            // LINK-7 (#129): the mark of whether its hooks and AgentTerm's
            // MCP server are heard, at the end of its usage band. The
            // stand-in runs them as one `agenttermd setup` set up does
            // (scripts/demo-agent.py): both heard.
            let mark = app.buttons["agent-link"].firstMatch
            XCTAssertTrue(mark.waitForExistence(timeout: 10), "no mark of the agent's hooks and MCP server")
            let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Hooks and MCP connected"), object: mark)
            XCTAssertEqual(XCTWaiter().wait(for: [connected], timeout: 15), .completed, mark.label)
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
        XCTAssertTrue(versionCard.label.contains("AgentTerm on Second Mac is from an older release"), versionCard.label)
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

        // The user's shells are listed under one Shells heading in their
        // folder (#127), as the Mac holds them in one Shells tab: three in
        // the project now, and one in another folder under a heading of its own.
        guard environment["AGENTTERM_TEST_PROJECT"] != nil else { return }
        for _ in 0..<2 {
            app.buttons[launchButton].firstMatch.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        }
        let rows = app.staticTexts.matching(identifier: "zsh")
        XCTAssertEqual(rows.count, 4)
        let headings = app.descendants(matching: .any).matching(identifier: "heading-Shells")
        XCTAssertEqual(headings.count, 2, "the shells are not under one heading in each folder")
        let three = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'heading-Shells' AND label == %@", "Shells, 3 shells")).firstMatch
        XCTAssertTrue(three.exists, "the project's heading does not say it holds three: \((0..<headings.count).map { headings.element(boundBy: $0).label })")
        XCTAssertFalse(app.buttons["session-group"].exists, "a group of sessions is still listed")
        capture("11-shells")

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
    /// PERF-16 (#126): the iPhone's Markdown preview, the Mac's web page,
    /// measured as the Mac's is (PERF-15): a long document, `TESTING.md`
    /// of this repository, opened and scrolled through, holds the app's
    /// main thread up no longer than a small one does, give or take a
    /// frame. The app notes its stalls (`MainThreadWatch`); while a step is
    /// measured the test asks it nothing. Starts in the sessions list.
    private func measureMarkdown(_ app: XCUIApplication) throws {
        let notes = try XCTUnwrap(environment["AGENTTERM_MEASURE_MAIN"])
        func stalls(since start: Date) -> [Double] {
            let text = (try? String(contentsOfFile: notes, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line -> Double? in
                let parts = line.split(separator: " ")
                guard parts.count == 2, let at = Double(parts[0]), let took = Double(parts[1]) else { return nil }
                return at >= start.timeIntervalSince1970 ? took : nil
            }
        }
        /// Does a step, leaves the app alone, and returns the longest stall.
        func longestStall(_ what: String, for seconds: UInt32 = 3, _ step: () -> Void) -> Double {
            sleep(1)
            let start = Date()
            step()
            sleep(seconds)
            let found = stalls(since: start)
            let longest = found.max() ?? 0
            print(
                "MEASURE markdown, \(what): "
                    + (found.isEmpty
                        ? "never held up over 16 ms"
                        : String(format: "held up %d times, the longest %.0f ms, %.0f ms in all", found.count, longest, found.reduce(0, +))))
            return longest
        }
        app.buttons["folder-details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 10))
        app.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["small.md"].waitForExistence(timeout: 15), "the documents are not listed")
        /// Opens a document of the list, found before the time starts.
        func open(_ name: String, showing words: String) -> Double {
            let row = app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) is not listed")
            let point = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let longest = longestStall("\(name) opened") { point.tap() }
            XCTAssertTrue(app.webViews.staticTexts[words].firstMatch.waitForExistence(timeout: 20), "\(name) is not shown")
            return longest
        }
        let atRest = longestStall("at rest, the list open") {}
        // The first preview starts WebKit's process: not compared.
        _ = open("first.md", showing: "First")
        app.navigationBars.buttons.firstMatch.tap()
        // A text file, in the editor: what any file opened costs.
        _ = longestStall("notes.txt opened") { app.staticTexts["notes.txt"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.textViews["code-editor"].waitForExistence(timeout: 10), "notes.txt did not open")
        app.navigationBars.buttons.firstMatch.tap()
        // The small one twice, the longer of the two kept: what opening any
        // document varies by.
        var small = 0.0
        for _ in 0..<2 {
            small = max(small, open("small.md", showing: "Small"))
            app.navigationBars.buttons.firstMatch.tap()
        }
        var opened: [String: Double] = [:]
        for (name, heading) in [("RELEASE.md", "Releasing AgentTerm"), ("SPEC.md", "AgentTerm product spec"), ("DESIGN.md", "AgentTerm design"), ("TESTING.md", "Testing AgentTerm")] {
            opened[name] = open(name, showing: heading)
            if name != "TESTING.md" { app.navigationBars.buttons.firstMatch.tap() }
        }
        capture("M1-testing-md")
        // TESTING.md on show: six fast swipes up, as a thumb goes through it.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let scrolled = longestStall("TESTING.md swiped through, six times") {
            for _ in 0..<6 { middle.press(forDuration: 0.01, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0) }
        }
        capture("M2-testing-md-scrolled")
        app.navigationBars.buttons.firstMatch.tap()
        let allowed = max(small, atRest) + 16
        let testing = try XCTUnwrap(opened["TESTING.md"])
        XCTAssertLessThanOrEqual(testing, allowed, "TESTING.md held the app up \(Int(testing)) ms as it opened; a small document \(Int(small)) ms")
        XCTAssertLessThanOrEqual(scrolled, allowed, "swiping through TESTING.md held the app up \(Int(scrolled)) ms")
    }

    /// IOS-19 (#281): a commit waiting for the Mac when its connection
    /// closes (the script stops the host while git runs the commit's hook)
    /// ends, says so, and keeps its message; pressed again while the Mac is
    /// not connected, it is refused at once. Before the fix it spun until
    /// another commit was made.
    private func commitWhileTheMacGoes(_ app: XCUIApplication) {
        // A schedule, to be changed once the Mac is gone (IOS-21, #286).
        app.tab("Schedules").tap()
        let add = app.buttons["new-schedule"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no New Schedule")
        add.tap()
        let prompt = app.textFields["Prompt"].exists ? app.textFields["Prompt"] : app.textViews["Prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("say hello")
        app.navigationBars.buttons["Save"].tap()
        let withoutAsking = app.buttons["Run Without Asking"]
        if withoutAsking.waitForExistence(timeout: 3) { withoutAsking.tap() }
        let scheduleRow = app.staticTexts["Every morning"]
        XCTAssertTrue(scheduleRow.waitForExistence(timeout: 10), "the schedule is not listed")
        app.tab("Sessions").tap()

        app.buttons["folder-details"].firstMatch.tap()
        // The files listed while the Mac is there.
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 10))
        app.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the files are not listed")
        app.buttons["Git"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the changed file is not listed")
        app.buttons["Stage All"].tap()
        XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10), "the file was not staged")
        let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
        message.tap()
        message.typeText("test: the Mac goes away")
        let commit = app.buttons["commit"]
        XCTAssertTrue(commit.isEnabled)
        commit.tap()

        func alert(_ words: String) -> XCUIElement {
            app.alerts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        }
        let unanswered = alert("closed before it answered what was asked")
        XCTAssertTrue(unanswered.waitForExistence(timeout: 30), "nothing said that the Mac went before it answered the commit")
        capture("commit-not-answered")
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(message.value as? String, "test: the Mac goes away", "the commit's message was thrown away")

        // Pressed again with the Mac gone: refused at once, the message kept.
        let pressed = Date()
        if commit.isEnabled { commit.tap() }
        let refused = alert("is not connected, so nothing was committed")
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "a commit asked while the Mac is not connected was not refused at once")
        XCTAssertLessThan(Date().timeIntervalSince(pressed), 5)
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(message.value as? String, "test: the Mac goes away", "the commit's message was thrown away when it was refused")

        // IOS-21 (#286): what changes the Mac is said at once, not sent
        // nowhere. A file renamed:
        let notDone = alert("is not connected, so nothing was done")
        app.buttons["Files"].firstMatch.tap()
        let file = app.staticTexts["notes.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the files are not listed")
        file.press(forDuration: 1.0)
        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename in the file's menu")
        rename.tap()
        app.alerts.textFields.firstMatch.typeText("-moved")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(notDone.waitForExistence(timeout: 5), "a rename while the Mac is not connected was not said")
        capture("rename-not-connected")
        app.alerts.buttons["OK"].tap()
        // A schedule saved: not taken for saved, its form still open.
        for _ in 0..<3 where !app.tab("Schedules").exists {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        // The Mac's screens, not the list of Macs, out of reach as it is.
        if !app.tab("Schedules").exists, app.buttons["First Mac"].exists { app.buttons["First Mac"].tap() }
        XCTAssertTrue(app.tab("Schedules").waitForExistence(timeout: 10), "the Mac's tabs are not shown")
        app.tab("Schedules").tap()
        XCTAssertTrue(scheduleRow.waitForExistence(timeout: 10))
        scheduleRow.tap()
        let form = app.navigationBars["Every morning"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        form.buttons["Save"].tap()
        XCTAssertTrue(notDone.waitForExistence(timeout: 5), "a schedule saved while the Mac is not connected was not said")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(form.exists, "the schedule's form closed as if it were saved")

        // IOS-25 (#283): the Mac forgotten while it cannot be reached is
        // tried, to stop its notifications, and that it could not be is said.
        form.buttons.firstMatch.tap()
        app.tab("Sessions").tap()
        let macs = app.buttons["mac-menu"].firstMatch
        if macs.waitForExistence(timeout: 5) { macs.tap() }
        let row = app.buttons.matching(identifier: "mac-row").matching(NSPredicate(format: "label == %@", "First Mac")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Macs are not listed")
        row.press(forDuration: 1.0)
        let forget = app.buttons["Forget This Mac"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "no Forget in the Mac's menu")
        forget.tap()
        app.buttons["Forget"].firstMatch.tap()
        let notTold = alert("could not be reached to stop its notifications")
        XCTAssertTrue(notTold.waitForExistence(timeout: 15), "a forgotten Mac that could not be told was not said")
        capture("forgotten-not-told")
        app.alerts.buttons["OK"].tap()
    }

    /// PAIR-12 (#279): a pairing link whose code the host refuses, opened
    /// while a Mac is on screen, pairs nothing and forgets nothing: it is
    /// said, and the Mac on screen stays, connected.
    private func pairWithACodeThatIsRefused(_ app: XCUIApplication, launchButton: String) throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTTERM_PAIR_URL"].flatMap { URLComponents(string: $0) })
        var refused = link
        refused.queryItems = link.queryItems?.map { $0.name == "code" ? URLQueryItem(name: "code", value: "000000") : $0.name == "name" ? URLQueryItem(name: "name", value: "Stale Mac") : $0 }
        app.openPairingLink(try XCTUnwrap(refused.url))
        let said = app.alerts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "pairing code has expired or was already used")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 15), "the refused code was not said")
        capture("pairing-refused")
        app.alerts.buttons["OK"].tap()
        // The list of Macs, where pairing is: the first still there and
        // connected, the refused one not kept.
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "First Mac")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the paired Mac is gone")
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connected")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 5), "the paired Mac's connection was dropped")
        XCTAssertFalse(app.staticTexts["Stale Mac"].exists, "the refused Mac was kept")
        first.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 15), "the paired Mac does not open")
    }

    /// IOS-23 (#285): while git runs a commit (its hook takes a while, and
    /// changes another file of the folder meanwhile), the folder's changes
    /// that come of a pull to refresh are not taken for its end: the message stays until the
    /// commit is over, and goes then. Before the fix the first changes of
    /// the folder ended the commit and threw its message away.
    private func commitWhileTheFolderChanges(_ app: XCUIApplication) {
        app.buttons["folder-details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
        app.buttons["Git"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the changed file is not listed")
        app.buttons["Stage All"].tap()
        XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10), "the file was not staged")
        let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
        message.tap()
        message.typeText("test: while the folder changes")
        app.buttons["commit"].tap()
        sleep(2)
        // Pulled to refresh while git still runs: the hook's change is listed.
        let top = app.staticTexts["Follows origin/main"].firstMatch
        let start = (top.exists ? top : app.buttons["Git"]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertTrue(app.staticTexts["during-commit.txt"].waitForExistence(timeout: 8), "the change made during the commit did not come")
        capture("commit-while-changing")
        XCTAssertEqual(message.value as? String, "test: while the folder changes", "the changes that came were taken for the commit's end")
        // Over: the message goes.
        let empty = NSPredicate(format: "value != %@", "test: while the folder changes")
        wait(for: [expectation(for: empty, evaluatedWith: message)], timeout: 30)
    }

    /// SCHED-39 (#308) on the iPhone: a schedule made here is deleted only
    /// once that is confirmed. Cancel keeps it, with its editor open;
    /// Delete Schedule takes it away.
    private func deleteASchedule(_ app: XCUIApplication) {
        app.tab("Schedules").tap()
        let add = app.buttons["new-schedule"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no New Schedule")
        add.tap()
        let prompt = app.textFields["Prompt"].exists ? app.textFields["Prompt"] : app.textViews["Prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "the editor has no prompt")
        prompt.tap()
        prompt.typeText("say hello")
        app.navigationBars.buttons["Save"].tap()
        let withoutAsking = app.buttons["Run Without Asking"]
        if withoutAsking.waitForExistence(timeout: 3) { withoutAsking.tap() }
        let row = app.staticTexts["Every morning"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the schedule is not listed")
        row.tap()

        let delete = app.buttons["Delete Schedule…"]
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let title = app.staticTexts["Delete the schedule “Every morning”?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "deleting was not asked first")
        capture("schedule-delete-asked")
        // Cancel is a tap outside the question: iOS shows no button for it.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Every morning"].exists, "Cancel closed the editor")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the schedule was deleted without being confirmed")

        row.tap()
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["Delete Schedule"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the schedule was not deleted once confirmed")
    }

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
    /// INBOX-10 (#66, #71): an agent done while its terminal is not on
    /// screen is at the top of the Sessions list, under Inbox, with what it
    /// said; touched, it shows what its turn came to; Open shows its
    /// terminal. Read, it leaves the top of the list and stays in the whole
    /// Inbox, kept after it is read.
    /// IOS-26 (#320): what an agent asks, opened from the Inbox, is
    /// answered there in words of one's own, as Claude Code's list offers
    /// after its choices ("Type something."). Where the answer went is what
    /// the stand-in received, which scripts/test-ios.sh checks. Before the
    /// fix the Inbox listed the choices as text, with no way to answer.
    private func answerFromTheInbox(_ app: XCUIApplication, compose: XCUIElement) {
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
        claude.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Claude Code session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "inbox-[0-9]+"))
        let item = items.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 40), "the agent's question is not in the Inbox")
        item.tap()
        let answer = app.descendants(matching: .any)["notice-answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "no field to answer the agent in words of one's own")
        XCTAssertTrue(app.buttons["notice-choice-1"].exists, "the question's choices are not offered")
        answer.tap()
        answer.typeText("a parser of my own")
        capture("25-inbox-answer")
        app.buttons["notice-answer-send"].tap()
        XCTAssertTrue(answer.waitForNonExistence(timeout: 15), "the answered question still offers to answer")
        capture("26-inbox-answered")
    }

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
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "inbox-[0-9]+"))
        let item = items.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the agent that is done is not in the Inbox")
        XCTAssertTrue(item.label.contains("is done"), item.label)
        XCTAssertTrue(item.label.contains("Decide what you want there"), item.label)
        let id = item.identifier
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
        let read = app.descendants(matching: .any)[id]
        XCTAssertTrue(read.waitForNonExistence(timeout: 10), "read, it stayed at the top of the list")
        capture("20-inbox-seen")
        app.descendants(matching: .any)["inbox-all"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 10), "read, it is no longer in the Inbox")
        capture("20a-inbox-all")
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// IOS-12 (#232): a prompt is being written when the agent asks
    /// something. Send in the prompt does not send it, and says why; the
    /// question is answered from its own place, the prompt kept the while;
    /// once the agent no longer asks, the prompt is sent. Where each went
    /// is what the stand-in received, which scripts/test-ios.sh checks.
    /// Before the fix the prompt went in as the answer.
    private func answerWhileWritingAPrompt(_ app: XCUIApplication, compose: XCUIElement) {
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
        claude.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Claude Code session did not open")
        let prompt = "add tests for the JSON parser first"
        compose.tap()
        compose.typeText(prompt)
        // The stand-in asks a few seconds after it starts (scripts/test-ios.sh).
        let answerButton = app.buttons["compose-answer-button"]
        XCTAssertTrue(answerButton.waitForExistence(timeout: 30), "no button to answer the agent with")
        capture("21-asks-while-writing")
        app.buttons["Send"].tap()
        let held = app.staticTexts["compose-held"]
        XCTAssertTrue(held.waitForExistence(timeout: 5), "Send in the prompt did not say why it was not sent")
        XCTAssertTrue(held.label.contains("waiting for an answer"), held.label)
        XCTAssertEqual(compose.value as? String, prompt, "the prompt was not kept")
        capture("22-prompt-held")

        // The place to answer: the question, its choices, a field of its own.
        answerButton.tap()
        let question = app.staticTexts["compose-question"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "the place to answer does not show the question")
        XCTAssertTrue(question.label.contains("Which parser"), question.label)
        XCTAssertFalse(compose.exists, "the prompt's field is shown with the answer's")
        let answer = app.descendants(matching: .any)["compose-answer"].firstMatch
        XCTAssertTrue(answer.exists, "no field to answer in")
        answer.tap()
        answer.typeText("not this one")
        // Back and forth: each keeps its own text.
        app.buttons["compose-prompt-button"].tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the prompt did not come back")
        XCTAssertEqual(compose.value as? String, prompt, "the prompt was lost while answering")
        answerButton.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "the answer did not come back")
        XCTAssertEqual(answer.value as? String, "not this one", "the answer was lost while the prompt was shown")
        capture("23-answer")
        let choice = app.buttons["compose-choice-1"]
        XCTAssertTrue(choice.exists, "the question's choices are not offered")
        XCTAssertEqual(choice.label, "The JSON parser")
        choice.tap()

        // Answered, the stand-in is done: the prompt is back, as it was.
        XCTAssertTrue(answerButton.waitForNonExistence(timeout: 15), "the agent no longer asks, and the button stayed")
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertEqual(compose.value as? String, prompt, "the prompt was lost")
        XCTAssertFalse(held.exists, "the held line stayed once the agent no longer asks")
        capture("24-prompt-back")
        app.buttons["Send"].tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        let sent = NSPredicate(format: "value == nil OR value == '' OR value == 'Message'")
        wait(for: [expectation(for: sent, evaluatedWith: compose)], timeout: 5)
    }

    private func readANote(_ app: XCUIApplication, compose: XCUIElement) {
        let antigravity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Antigravity")).firstMatch
        XCTAssertTrue(antigravity.waitForExistence(timeout: 10), "no Antigravity to start")
        antigravity.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Antigravity session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let mark = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "state-note-")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "no note on the Antigravity session's row")
        // TAB-6 (#127): an agent's session pinned from here, from the menu
        // of its row; it runs on, for scripts/test-ios.sh to find the pin
        // kept by the host. Its name, on the row of its note's mark: the
        // folder's buttons to start one say it too.
        let names = app.staticTexts.matching(identifier: "Antigravity")
        let name = (0..<names.count).map { names.element(boundBy: $0) }.first { abs($0.frame.midY - mark.frame.midY) < 20 }
        XCTAssertNotNil(name, "the Antigravity session's row has no name")
        if let name { pick("Pin", fromMenuOf: name, in: app) }
        XCTAssertTrue(app.images["Pinned"].waitForExistence(timeout: 10), "the session's row does not say it is pinned")
        capture("17a-before-note")
        mark.tap()
        let note = app.staticTexts["state-note-text"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "touching the mark did not show the note")
        XCTAssertTrue(note.label.contains("does not say when it waits for permission"), note.label)
        XCTAssertFalse(compose.exists, "touching the mark opened the session")
        capture("17-note")
    }

    /// WT-25 (#244): a worktree being made is shown in the list, under its
    /// folder, with what is being done, in the Mac's words, until its
    /// session takes its place. The test project's checkout is made slow by
    /// a hook `test-ios.sh` gives it in this mode.
    private func watchAWorktreeBeingMade(_ app: XCUIApplication, compose: XCUIElement) {
        let shell = app.buttons["Start Shell"].firstMatch
        XCTAssertTrue(shell.waitForExistence(timeout: 15), "no Shell button in the list")
        shell.press(forDuration: 1.0)
        let item = app.buttons["Start a Shell in a New Worktree…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Shell button has no New Worktree item")
        item.tap()
        let branch = app.textFields["worktree-branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 10), "the New Worktree sheet did not open")
        branch.tap()
        branch.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        branch.typeText("feature/slow")
        app.buttons["worktree-create"].tap()

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "worktree-in-progress-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "nothing is shown while the worktree is made")
        XCTAssertEqual(row.label, "feature/slow, Making the worktree…")
        capture("worktree-in-progress")
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: row)], timeout: 30)
        // Its session takes its place, and is opened, as one started is.
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "the session in the new worktree did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let listed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "feature/slow")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10), "the session in its worktree is not listed with its branch")
    }

    /// INBOX-13 (#240): an Inbox row of an answer whose end, cut at two
    /// lengths and begun at a word, comes to the same text is shown, and the
    /// app is still there: given twice to SwiftUI, it stopped the app, also
    /// when a notification was touched, which shows that list.
    private func listAnAnswerWhoseCutsComeToTheSameText(_ app: XCUIApplication, compose: XCUIElement) {
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Claude Code")).firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no Claude Code to start")
        claude.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the Claude Code session did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "inbox-[0-9]+")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "the agent that is done is not in the Inbox")
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app is gone")
        XCTAssertTrue(item.exists, "the row went")
        capture("inbox-cut")
    }
}
