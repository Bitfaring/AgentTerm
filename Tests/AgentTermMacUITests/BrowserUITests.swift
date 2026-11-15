import AgentTermProtocol
import XCTest

/// The browser (#76), in the app as it is shipped: Chromium runs in the app
/// bundle only, which `scripts/test-mac.sh` builds for these tests, under an
/// identifier of its own. BROWSER-6 to BROWSER-9 in docs/TESTING.md.
///
/// The test plays the agent: it starts a stand-in agent, takes the key of
/// its session, and talks to AgentTerm's MCP server as that agent would.
final class BrowserUITests: MacUITestCase {
    private static var bundle: URL? {
        ProcessInfo.processInfo.environment["AGENTTERM_TEST_BUNDLE"].map { URL(fileURLWithPath: $0) }
    }

    private var site: URL!
    /// The app was started once in this test: what it kept is kept when
    /// it is started again.
    private var launched = false

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bundle != nil, "the app bundle is built by scripts/test-mac.sh")
        try super.setUpWithError()
    }

    /// The app bundle, with the test's home, state and port, as the
    /// unbundled app is started otherwise.
    override func launchApp() throws -> MacDriver {
        let bundle = try XCTUnwrap(Self.bundle)
        if !launched { forgetBundlePreferences(bundle) }
        launched = true
        var environment = Self.ownHome(home)
        environment.merge(appEnvironment) { _, own in own }
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["AGENTTERM_PORT"] = String(appPort)
        environment["CFFIXED_USER_HOME"] = home.path
        let driver = try MacDriver(executable: bundle.appendingPathComponent("Contents/MacOS/AgentTerm"), environment: environment)
        driver.wait(for: .id("mac-switcher"), timeout: 30)
        return driver
    }

    override func tearDown() {
        super.tearDown()
        if let bundle = Self.bundle { forgetBundlePreferences(bundle) }
    }

    private func forgetBundlePreferences(_ bundle: URL) {
        guard let identifier = Bundle(url: bundle)?.bundleIdentifier, identifier.contains("uitest") else { return }
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", identifier]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        try? defaults.run()
        defaults.waitUntilExit()
    }

    private typealias Server = MCPServerProcess

    /// A stand-in agent that writes down its session's variable, and the
    /// MCP server it would start.
    private func startAgent() throws -> (Server, SessionInfo) {
        let told = root.appendingPathComponent("agent-variable")
        try """
        #!/bin/sh
        printf '%s' "$AGENTTERM_MCP" > '\(told.path)'
        echo "stand-in claude started"
        exec cat
        """.write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        let phone = try device()
        app.press(.button("Claude Code"))
        wait("the agent's session") { phone.sessions.contains { $0.agent == "claude" } }
        wait("its variable") { FileManager.default.fileExists(atPath: told.path) }
        let variable = try String(contentsOf: told, encoding: .utf8)
        let agent = try XCTUnwrap(phone.sessions.first { $0.agent == "claude" })
        return (try Server(tool: hostExecutable, variable: variable, state: state), agent)
    }

    /// A page with a form, written to the test's folder.
    private func makeSite() throws -> URL {
        let folder = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        <!doctype html>
        <html><head><title>Test page</title></head>
        <body>
          <h1>Greetings</h1>
          <label>Name <input id="name" aria-label="Name"></label>
          <select id="tone" aria-label="Tone"><option value="warm">Warm</option><option value="cold">Cold</option></select>
          <button id="greet" onclick="greet()">Greet</button>
          <p id="out"></p>
          <a href="second.html">Next page</a>
          <script>
            function greet() {
              const name = document.getElementById('name').value;
              const tone = document.getElementById('tone').value;
              document.getElementById('out').textContent = (tone === 'cold' ? 'Hello, ' : 'Hi there, ') + name;
              console.log('greeted ' + name);
              console.error('a test error');
            }
          </script>
        </body></html>
        """.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Second</title><p>The second page</p>".write(to: folder.appendingPathComponent("second.html"), atomically: true, encoding: .utf8)
        return folder.appendingPathComponent("index.html")
    }

    /// The ref the snapshot gives to the line that holds `words`.
    private func ref(in snapshot: String, _ words: String) -> String? {
        guard let line = snapshot.split(separator: "\n").first(where: { $0.contains(words) }),
            let range = line.range(of: #"ref=e\d+"#, options: .regularExpression)
        else { return nil }
        return String(line[range].dropFirst(4))
    }

    /// BROWSER-6: an agent opens a tab of its own beside it, reads the page,
    /// types, picks, clicks, waits, and reads the console, a picture and the
    /// page's script; the page shows what it did.
    func testAnAgentUsesAPage() throws {
        let page = try makeSite()
        let (server, agent) = try startAgent()
        defer { server.stop() }

        let opened = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(opened.failed, opened.text)
        XCTAssertTrue(opened.text.contains("“Test page”"), opened.text)
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) })
        // Beside the agent, where the user sees it, without a tab of its own.
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait(for: .id("browser-agent-bar"))
        XCTAssertTrue(app.exists(.id("tab-\(agent.id)")))
        XCTAssertFalse(app.exists(.id("tab-b\(tab)")), "the agent's page is a tab of the strip")
        // In the list at the left, under its project, as its agent's.
        app.wait(for: .id("browser-row-\(tab)"))
        XCTAssertTrue(app.first(.id("browser-row-\(tab)"))?.label.contains("opened by") ?? false)

        let snapshot = server.text("browser_snapshot", ["tab": tab])
        XCTAssertFalse(snapshot.failed, snapshot.text)
        XCTAssertTrue(snapshot.text.contains("heading \"Greetings\""), snapshot.text)
        let name = try XCTUnwrap(ref(in: snapshot.text, "textbox \"Name\""), snapshot.text)
        let tone = try XCTUnwrap(ref(in: snapshot.text, "combobox \"Tone\""), snapshot.text)
        let greet = try XCTUnwrap(ref(in: snapshot.text, "button \"Greet\""), snapshot.text)

        let typed = server.text("browser_type", ["tab": tab, "ref": name, "text": "Ana"])
        XCTAssertFalse(typed.failed, typed.text)
        XCTAssertTrue(typed.text.contains("“Ana”"), typed.text)
        XCTAssertFalse(server.text("browser_select", ["tab": tab, "ref": tone, "values": ["Cold"]]).failed)
        let clicked = server.text("browser_click", ["tab": tab, "ref": greet])
        XCTAssertFalse(clicked.failed, clicked.text)
        XCTAssertTrue(clicked.text.contains("The page stayed"), clicked.text)
        XCTAssertTrue(clicked.text.contains("error"), "the console's error is not mentioned: \(clicked.text)")
        let waited = server.text("browser_wait", ["tab": tab, "text": "Hello, Ana", "seconds": 5])
        XCTAssertTrue(waited.text.hasPrefix("“Hello, Ana” is on the page"), waited.text)
        let console = server.text("browser_console", ["tab": tab])
        XCTAssertTrue(console.text.contains("[log] greeted Ana"), console.text)
        XCTAssertTrue(console.text.contains("[error] a test error"), console.text)
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "document.getElementById('out').textContent"]).text, "\"Hello, Ana\"")

        let picture = server.tool("browser_screenshot", ["tab": tab])
        XCTAssertFalse(picture.failed)
        let data = try XCTUnwrap((picture.content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) })
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG")
        XCTAssertNotNil(NSImage(data: data))
        shot("agent-page")

        // An old ref after the page changed is refused with what to do.
        let next = try XCTUnwrap(ref(in: snapshot.text, "link \"Next page\""))
        let moved = server.text("browser_click", ["tab": tab, "ref": next])
        XCTAssertTrue(moved.text.contains("The page changed"), moved.text)
        XCTAssertTrue(moved.text.contains("“Second”"), moved.text)
        let stale = server.text("browser_click", ["tab": tab, "ref": greet])
        XCTAssertTrue(stale.failed)
        XCTAssertEqual(stale.text, BrowserWords.staleRef(greet))
        XCTAssertFalse(server.text("browser_back", ["tab": tab]).failed)
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "document.title"]).text, "\"Test page\"")
    }

    /// BROWSER-15: an agent reads, types into, clicks and takes pictures of
    /// its page while the page is not shown, and while the window is
    /// minimized: Chromium goes on drawing it.
    func testAnAgentUsesAPageNobodySees() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        continueAfterFailure = true

        func use(_ when: String) {
            let started = Date()
            let snapshot = server.text("browser_snapshot", ["tab": tab], timeout: 20)
            guard !snapshot.failed, let name = ref(in: snapshot.text, "textbox \"Name\""), let greet = ref(in: snapshot.text, "button \"Greet\"") else {
                return XCTFail("\(when): no snapshot: \(snapshot.text)")
            }
            let typed = server.text("browser_type", ["tab": tab, "ref": name, "text": " " + when], timeout: 20)
            XCTAssertFalse(typed.failed, "\(when): \(typed.text)")
            let clicked = server.text("browser_click", ["tab": tab, "ref": greet], timeout: 20)
            XCTAssertFalse(clicked.failed, "\(when): \(clicked.text)")
            let out = server.text("browser_evaluate", ["tab": tab, "script": "document.getElementById('out').textContent"], timeout: 20)
            XCTAssertTrue(out.text.contains(when), "\(when): the click or the typing did not reach the page: \(out.text)")
            let picture = server.tool("browser_screenshot", ["tab": tab], timeout: 20)
            let data = (picture.content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }
            XCTAssertNotNil(data.flatMap(NSImage.init(data:)), "\(when): no picture: \(picture.content.first?["text"] ?? "")")
            if let data { try? data.write(to: root.appendingPathComponent("page-\(when).png")) }
            print("BROWSER-15 \(when): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            XCTAssertLessThan(Date().timeIntervalSince(started), 15, "\(when): slow")
        }
        use("shown")
        app.press(.button("Hide Browser"))
        app.waitGone(.id("agent-browser"))
        use("hidden")
        app.minimize(true)
        use("minimized")
        app.minimize(false)
        app.wait(for: .id("mac-switcher"))
        use("back")
        if let folder = ProcessInfo.processInfo.environment["AGENTTERM_SHOT_DIR"] {
            for when in ["shown", "hidden", "minimized", "back"] {
                try? FileManager.default.copyItem(
                    at: root.appendingPathComponent("page-\(when).png"), to: URL(fileURLWithPath: folder).appendingPathComponent("BROWSER-15-\(when).png"))
            }
        }
    }

    /// PANE-17: an agent with its page beside it. Picking the page in the
    /// list selects it alone, and its page has the keyboard; picking the
    /// agent gives it back to the agent's terminal; and pages the agent
    /// loads, one with a field that asks for the keyboard, take neither the
    /// keyboard nor the agent's place in front.
    func testAPageDoesNotTakeTheKeyboard() throws {
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let page = root.appendingPathComponent("page.html")
        try "<!doctype html><title>One</title><input autofocus aria-label=Name><a href=page.html?2>Again</a>".write(to: page, atomically: true, encoding: .utf8)
        let opened = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(opened.failed, opened.text)
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        // Each of what follows is seen to fail on its own.
        continueAfterFailure = true

        app.press(.id("browser-row-\(tab)"))
        app.wait("the page picked, alone") { self.app.selectedRows() == ["browser-row-\(tab)"] }
        app.waitForKeyboard(in: "browser-\(tab)", page: true, "the page picked")
        app.press(.id("session-\(agent.id)"))
        app.wait("the agent picked, alone") { self.app.selectedRows() == ["session-\(agent.id)"] }
        app.waitForKeyboard(in: "terminal-\(agent.id)", "the agent picked")

        for url in [page.absoluteString + "?1", page.absoluteString + "?2"] {
            let moved = server.text("browser_navigate", ["tab": tab, "url": url])
            XCTAssertFalse(moved.failed, moved.text)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(app.selectedRows(), ["session-\(agent.id)"], "a page the agent loaded took its place in front")
        app.waitForKeyboard(in: "terminal-\(agent.id)", "the agent, after its pages loaded", timeout: 1)
        shot("agent-has-the-keyboard")
    }

    /// BROWSER-7: the user takes a page over and gives it back; the agent
    /// is refused meanwhile, with why, and reads it still.
    func testTheUserTakesAPageOver() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("browser-control"), timeout: 20)
        app.press(.id("browser-control"))
        app.wait(for: .containing("You have this tab"))
        let refused = server.text("browser_navigate", ["tab": tab, "url": page.absoluteString])
        XCTAssertTrue(refused.failed)
        XCTAssertEqual(refused.text, BrowserWords.userHasIt(tab))
        XCTAssertFalse(server.text("browser_snapshot", ["tab": tab]).failed, "looking is not acting")
        shot("taken-over")
        app.press(.id("browser-control"))
        app.wait(for: .containing("is using this tab"))
        XCTAssertFalse(server.text("browser_navigate", ["tab": tab, "url": page.absoluteString]).failed)
    }

    /// BROWSER-8: a server of the project that is not running is said so;
    /// a tab the agent did not open, the user's, it neither sees nor
    /// reaches; the device size is pretended; and the switch in Settings
    /// turns it all off.
    func testWhatIsRefusedAndWhy() throws {
        let page = try makeSite()
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        // A port nothing listens on.
        let closed = "http://127.0.0.1:\(port + 400)/"
        let nothing = server.text("browser_navigate", ["tab": tab, "url": closed])
        XCTAssertTrue(nothing.failed)
        XCTAssertTrue(nothing.text.contains(BrowserWords.nothingAnswers(closed)), nothing.text)
        XCTAssertEqual(server.text("browser_click", ["tab": "999", "ref": "e1"]).text, BrowserWords.notYours("999"))
        // The user's own tab: not listed to the agent, and not reached.
        app.menu(["Browser", "New Browser Tab"])
        app.wait("the user's tab") { self.app.nodes().contains { $0.identifier.hasPrefix("tab-b") } }
        let users = try XCTUnwrap(app.nodes().first { $0.identifier.hasPrefix("tab-b") }.map { String($0.identifier.dropFirst(5)) })
        XCTAssertNotEqual(users, tab)
        let listed = server.text("browser_tabs").text.split(separator: "\n").map { String($0.prefix { $0 != ":" }) }
        XCTAssertEqual(listed, [tab], "the agent is listed other tabs than its own")
        for (name, arguments) in [("browser_snapshot", [:]), ("browser_navigate", ["url": page.absoluteString]), ("browser_close", [:])] as [(String, [String: Any])] {
            let refused = server.text(name, arguments.merging(["tab": users]) { a, _ in a })
            XCTAssertTrue(refused.failed, "\(name): \(refused.text)")
            XCTAssertEqual(refused.text, BrowserWords.notYours(users))
        }
        app.press(.id("session-\(agent.id)"))

        XCTAssertFalse(server.text("browser_navigate", ["tab": tab, "url": page.absoluteString]).failed)
        XCTAssertFalse(server.text("browser_emulate", ["tab": tab, "device": "iPhone 16"]).failed)
        // The screen's: a page with no viewport of its own is laid out
        // 980 wide on a phone, as on a real one.
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "screen.width"]).text, "393")
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "window.devicePixelRatio"]).text, "3")
        XCTAssertTrue(server.text("browser_evaluate", ["tab": tab, "script": "navigator.userAgent"]).text.contains("iPhone"))
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "navigator.platform"]).text, "\"iPhone\"")
        app.wait(for: .button("iPhone 16"))
        // The page as wide as the phone's screen, and the agent the rest.
        app.wait("the page as wide as the phone, not \(app.frame(of: .id("browser-page"))?.width ?? 0)") {
            abs((self.app.frame(of: .id("browser-page"))?.width ?? 0) - 393) < 1.5
        }
        app.wait("the agent's page part as wide as the phone") { abs((self.app.frame(of: .id("agent-browser"))?.width ?? 0) - 393) < 2 }
        // An Android phone: its user agent with this Chromium's version,
        // its platform, and its client hints.
        XCTAssertFalse(server.text("browser_emulate", ["tab": tab, "device": "Pixel 9"]).failed)
        let pixel = server.text("browser_evaluate", ["tab": tab, "script": "navigator.userAgent"]).text.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(pixel.contains("Android 14; Pixel 9") && pixel.range(of: #"Chrome/\d+\.0\.0\.0 Mobile"#, options: .regularExpression) != nil, pixel)
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "navigator.platform"]).text, "\"Linux armv81\"")
        // #95: a promise is waited for; a function's body is run as one, and
        // a return inside a function of the script is not taken for one.
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "Promise.resolve(5)"]).text, "5", "a promise is waited for")
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "const x = 2;\nreturn x * 3"]).text, "6")
        let hints = server.text(
            "browser_evaluate",
            [
                "tab": tab,
                "script":
                    "(async () => { const d = navigator.userAgentData; if (!d) return 'none'; const h = await d.getHighEntropyValues(['model', 'platformVersion']); return [d.mobile, d.platform, d.brands.length > 0, h.model, h.platformVersion].join(','); })()",
            ]
        ).text
        XCTAssertEqual(hints, "\"true,Android,true,Pixel 9,14\"")
        XCTAssertFalse(server.text("browser_emulate", ["tab": tab, "off": true]).failed)
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "navigator.platform"]).text, "\"MacIntel\"")

        app.press(.id("place-settings"))
        app.press(.id("settings-browser"))
        app.press(.id("agents-use-browser"))
        XCTAssertEqual(server.text("browser_snapshot", ["tab": tab]).text, BrowserWords.turnedOff)
        app.press(.id("agents-use-browser"))
        XCTAssertFalse(server.text("browser_snapshot", ["tab": tab]).failed)
        app.press(.id("place-sessions"))
        app.wait(for: .id("agent-browser"))
        // Closing a tab closes the tab, not the window it is in.
        XCTAssertFalse(server.text("browser_close", ["tab": tab]).failed)
        app.waitGone(.id("agent-browser"))
        XCTAssertTrue(app.exists(.id("mac-switcher")), "the window closed with the tab")
    }

    /// BROWSER-10: with two profiles, an agent's first tab asks which one,
    /// the default picked already; its next tab uses the same without
    /// asking; with one profile, nothing is asked.
    func testAnAgentIsAskedWhichProfile() throws {
        let page = try makeSite()
        app.press(.id("place-settings"))
        app.press(.id("settings-browser"))
        app.press(.id("profile-new"))
        app.wait(for: .id("profile-name-Profile 2"))
        app.press(.id("place-sessions"))
        let (server, _) = try startAgent()
        defer { server.stop() }

        // Asked in a sheet; the agent waits for the answer.
        var opened: (text: String, failed: Bool)?
        DispatchQueue.global().async {
            let answer = server.text("browser_open", ["url": page.absoluteString])
            DispatchQueue.main.async { opened = answer }
        }
        app.wait(for: .id("profile-choice"), timeout: 20)
        shot("profile-question")
        app.press(.text("Profile 2"))
        app.press(.id("profile-use"))
        wait("the tab opened", timeout: 30) { opened != nil }
        XCTAssertFalse(opened?.failed ?? true, opened?.text ?? "")
        app.wait(for: .id("browser-profile"))
        XCTAssertEqual(app.first(.id("browser-profile"))?.value.isEmpty == false ? app.first(.id("browser-profile"))?.value : app.first(.id("browser-profile"))?.label, "Profile 2")

        // The next tab is the same profile's, without a question.
        let again = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(again.failed, again.text)
        XCTAssertFalse(app.exists(.id("profile-choice")), "asked again")

        // Chromium made the profile where it is kept: a profile it refuses
        // falls back to one of its own, shared by every profile.
        let browser = state.appendingPathComponent("browser")
        let log = (try? String(contentsOf: browser.appendingPathComponent("chromium.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("Cannot create profile"), "Chromium refused a profile:\n\(log)")
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: browser.path)) ?? []).filter { $0.hasPrefix("profile-") && $0 != "profile-default" }
        XCTAssertEqual(made.count, 1, "Profile 2's folder: \(made)")
    }

    /// BROWSER-13: a page asks for a permission; the bar asks the user, not
    /// the agent; answering it, either way, is answered, and nothing else
    /// happens to the app (it crashed on Allow, 2026-11-15).
    func testAPageAsksForAPermission() throws {
        let folder = root.appendingPathComponent("served")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        <!doctype html><title>Asks</title>
        <button id="ask" onclick="navigator.geolocation.getCurrentPosition(() => document.title = 'Allowed', () => document.title = 'Refused')">Where am I</button>
        """.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        // A server of the Mac's own: a page from a file asks nothing.
        let serverPort = port + 500
        // /usr/bin/python3 starts the real one as a child, which outlives
        // it: whatever listens on the port is stopped, before and after.
        stopWhateverListens(on: serverPort)
        defer { stopWhateverListens(on: serverPort) }
        let web = Process()
        web.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        web.arguments = ["-I", "-m", "http.server", String(serverPort), "--bind", "127.0.0.1", "--directory", folder.path]
        web.standardOutput = FileHandle.nullDevice
        web.standardError = FileHandle.nullDevice
        try web.run()
        defer { web.terminate() }
        Thread.sleep(forTimeInterval: 1)

        let (server, _) = try startAgent()
        defer { server.stop() }
        // Two origins: a page that was allowed is not asked again.
        for (answer, host) in [("Allow", "127.0.0.1"), ("Don't Allow", "localhost")] {
            let address = "http://\(host):\(serverPort)/"
            let opened = server.text("browser_open", ["url": address])
            let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
            let snapshot = server.text("browser_snapshot", ["tab": tab]).text
            let button = try XCTUnwrap(ref(in: snapshot, "button \"Where am I\""), snapshot)
            XCTAssertFalse(server.text("browser_click", ["tab": tab, "ref": button]).failed)
            app.wait(for: .id("browser-permission"), timeout: 15)
            shot("asks-\(answer)")
            app.press(.button(answer))
            app.waitGone(.id("browser-permission"))
            // The app is there, and the page was answered.
            XCTAssertTrue(app.exists(.id("mac-switcher")))
            let waited = server.text("browser_evaluate", ["tab": tab, "script": "document.title"])
            XCTAssertFalse(waited.failed, waited.text)
            XCTAssertFalse(server.text("browser_close", ["tab": tab]).failed)
        }
    }

    /// BROWSER-9: the user's own tab, in the project's panes, kept when the
    /// app opens again.
    /// BROWSER-17 (#94): an agent with its page beside it opens a shell,
    /// which shows under both: the page stays shown, and so does the
    /// agent's terminal.
    func testThePageStaysWhenTheAgentOpensAShell() throws {
        let page = try makeSite()
        let (server, agent) = try startAgent()
        /// Whether the agent's terminal is in the view it is shown in.
        func agentTerminal() -> String? {
            let nodes = app.nodes()
            guard let index = nodes.firstIndex(where: { $0.identifier == "terminal-\(agent.id)" }) else { return nil }
            return nodes[(index + 1)...].prefix { $0.depth > nodes[index].depth }.first { $0.identifier == "terminal-view" }?.value
        }
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(opened.failed, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        let shell = server.text("shell_open", ["title": "server"])
        XCTAssertFalse(shell.failed, shell.text)
        app.wait(for: .id("agent-shells"), timeout: 20)
        continueAfterFailure = true
        // At once, and a moment later.
        for _ in 0..<2 {
            app.wait("the page still shown, not \(app.value(of: .id("browser-page")) ?? "nothing")", timeout: 3) {
                self.app.value(of: .id("browser-page")) == "Test page"
            }
            app.wait("the agent's terminal still shown, not \(agentTerminal() ?? "nothing")", timeout: 3) { agentTerminal() == "shown" }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        shot("page-and-shell")
    }

    /// BROWSER-16 (#92): two tabs shown in turn each show their own page,
    /// back and forth.
    func testEachTabShowsItsOwnPage() throws {
        func page(_ name: String, _ color: String) throws -> URL {
            let file = root.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><body style=\"margin:0;background:\(color)\"></body>".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        let red = try page("Red", "#ff0000"), blue = try page("Blue", "#0000ff")
        var tabs: [String] = []
        for url in [red, blue] {
            app.menu(["Browser", "New Browser Tab"])
            app.wait("a new tab") { self.app.nodes().filter { $0.identifier.hasPrefix("tab-b") }.count == tabs.count + 1 }
            let id = try XCTUnwrap(app.nodes().map(\.identifier).first { $0.hasPrefix("tab-b") && !tabs.contains($0) })
            tabs.append(id)
            app.wait(for: .id("browser-address"), timeout: 20)
            app.write(url.absoluteString, into: .id("browser-address"), confirm: true)
            app.wait(for: .text(url.deletingPathExtension().lastPathComponent), timeout: 20)
        }
        // Which page is on top in the pane: the one drawn. A picture of the
        // window cannot tell, while the window is behind another one and
        // Chromium draws nothing.
        continueAfterFailure = true
        for (tab, title) in [(tabs[0], "Red"), (tabs[1], "Blue"), (tabs[0], "Red"), (tabs[1], "Blue")] {
            app.press(.id(tab))
            app.wait("\(tab) to show its page, \(title), not \(app.value(of: .id("browser-page")) ?? "none")") {
                self.app.value(of: .id("browser-page")) == title
            }
        }
    }

    /// BROWSER-9: the tabs are not kept: the app opens again with none.
    func testNoTabComesBack() throws {
        let page = try makeSite()
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
        app.wait(for: .text("Test page"), timeout: 20)
        shot("users-tab")
        app.wait(for: .id("browser-row-1"))
        try relaunchApp()
        app.wait(for: .id("mac-switcher"), timeout: 30)
        // Long enough for the host to have listed its sessions, which tabs
        // once came back after.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.nodes().contains { $0.identifier.hasPrefix("browser-row-") || $0.identifier.hasPrefix("tab-b") }, "a tab came back")
    }
}
