import AgentTermProtocol
import ApplicationServices
import XCTest

/// The browser (#76), in the app as it is shipped: Chromium runs in the app
/// bundle only, which `scripts/test-mac.sh` builds for these tests, under an
/// identifier of its own. BROWSER-6 to BROWSER-9 in docs/TESTING.md.
///
/// The test plays the agent: it starts a stand-in agent, takes the key of
/// its session, and talks to AgentTerm's MCP server as that agent would.
final class BrowserUITests: MacUITestCase {
    private static var bundle: URL? { testBundle }

    private var site: URL!
    /// The app was started once in this test: what it kept is kept when
    /// it is started again.
    private var launched = false

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bundle != nil, "the app bundle is built by scripts/test-mac.sh")
        // What a page holds, readable as VoiceOver reads it (BROWSER-37).
        if name.contains("RightClick") || name.contains("ExtensionTrial") { appEnvironment["AGENTTERM_WEB_ACCESSIBILITY"] = "1" }
        try super.setUpWithError()
    }

    /// The app bundle, with the test's home, state and port, as the
    /// unbundled app is started otherwise.
    override func launchApp() throws -> MacDriver {
        defer { launched = true }
        return try launchBundledApp(fresh: !launched)
    }

    override func tearDown() {
        super.tearDown()
        if let bundle = Self.bundle { forgetBundlePreferences(bundle) }
    }

    private typealias Server = MCPServerProcess

    /// A stand-in agent that writes down its session's variable, and the
    /// MCP server it would start.
    private func startAgent() throws -> (Server, SessionInfo) {
        let told = root.appendingPathComponent("agent-variable")
        // A second agent's own, not the first's.
        try? FileManager.default.removeItem(at: told)
        try """
        #!/bin/sh
        printf '%s' "$AGENTTERM_MCP" > '\(told.path)'
        echo "stand-in claude started"
        exec cat
        """.write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        let phone = try device()
        wait("the sessions listed") { phone.messages.contains { if case .sessions = $0 { return true } else { return false } } }
        let before = Set(phone.sessions.filter { $0.agent == "claude" }.map(\.id))
        // From the menu: once an agent runs, its tab is a "Claude Code" button too.
        app.menu(["File", "New Claude Code"])
        wait("the agent's session") { phone.sessions.contains { $0.agent == "claude" && !before.contains($0.id) } }
        wait("its variable") { FileManager.default.fileExists(atPath: told.path) }
        let variable = try String(contentsOf: told, encoding: .utf8)
        let agent = try XCTUnwrap(phone.sessions.first { $0.agent == "claude" && !before.contains($0.id) })
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
        XCTAssertFalse(app.exists(.id("strip-browser")), "the agent's page is in the user's Browser tab")
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
        // Hidden from the agent's row (#127), where its part's own button was.
        app.press(.id("agent-part-browser"))
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

    /// BROWSER-31: the + Page of an agent's row (#127) opens one more page
    /// beside the agent: the agent's, which it lists, and the user's to use
    /// until it is given back; not a page of the user's Browser tab.
    func testTheUserOpensAPageBesideAnAgent() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let first = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.press(.id("agent-new-page"))
        app.wait(for: .containing("You have this tab"), timeout: 20)
        XCTAssertFalse(app.exists(.id("strip-browser")), "the page went to the user's Browser tab")
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
        // The agent lists both, the new one as the user's for now.
        var listed = ""
        wait("the agent to list the new page", timeout: 15) {
            listed = server.text("browser_tabs").text
            return listed.split(separator: "\n").count == 2 && listed.contains("Test page")
        }
        let second = try XCTUnwrap(listed.split(separator: "\n").compactMap { $0.split(separator: ":").first.map(String.init) }.first { $0 != first }, listed)
        XCTAssertTrue(listed.split(separator: "\n").first { $0.hasPrefix(second + ":") }?.contains("the user has it now") ?? false, listed)
        let refused = server.text("browser_navigate", ["tab": second, "url": page.absoluteString])
        XCTAssertTrue(refused.failed)
        XCTAssertEqual(refused.text, BrowserWords.userHasIt(second))
        // Given back, the agent drives it.
        app.press(.id("browser-control"))
        app.wait(for: .containing("is using this tab"))
        XCTAssertFalse(server.text("browser_navigate", ["tab": second, "url": page.absoluteString]).failed)
    }

    /// TABS-4 (#145): ending an agent from its tab says what goes with it,
    /// then ends the shell and closes the page it has beside it: neither is
    /// left to the user.
    func testEndingAnAgentEndsItsShellAndClosesItsPage() throws {
        let page = try makeSite()
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let phone = try device()
        let opened = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(opened.failed, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.press(.id("agent-new-shell"))
        wait("its shell") { phone.sessions.contains { $0.openedBy == agent.id } }
        func lastTabs() -> [BrowserTabInfo] { phone.messages.reversed().lazy.compactMap { if case .browserTabs(let tabs) = $0 { return tabs } else { return nil } }.first ?? [] }
        wait("its page listed") { lastTabs().contains { $0.openedBy == agent.id } }

        app.perform("End Session", on: .id("tab-\(agent.id)"))
        app.wait(for: .text(CloseWords.endMessage(shells: 1, pages: 1)))
        app.press(.button(CloseWords.endButton))
        wait("the agent and its shell ended") { !phone.sessions.contains { $0.id == agent.id || $0.openedBy == agent.id } }
        wait("its page closed", timeout: 20) { lastTabs().isEmpty }
        XCTAssertTrue(phone.sessions.isEmpty, "a session was left: \(phone.sessions.map(\.title))")
        XCTAssertFalse(app.exists(.id("strip-browser")), "the page went to the user's Browser tab")
        XCTAssertFalse(app.exists(.id("strip-shells")), "the shell went to the user's Shells tab")
    }

    /// PANE-20 (#127): the + Shell of an agent's row starts a shell in the
    /// agent's folder, in the agent's tab, shown with the keyboard in it;
    /// not in the user's Shells tab. The agent lists it and runs a command
    /// in it, as in a shell it opened itself.
    func testTheUserOpensAShellForAnAgent() throws {
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let phone = try device()
        app.wait(for: .id("agent-new-shell"), timeout: 20)
        app.press(.id("agent-new-shell"))
        wait("the shell for the agent") { phone.sessions.contains { $0.openedBy == agent.id } }
        let shell = try XCTUnwrap(phone.sessions.first { $0.openedBy == agent.id })
        XCTAssertEqual(shell.cwd, agent.cwd)
        XCTAssertNil(shell.agent)
        app.wait(for: .id("item-\(shell.id)"))
        app.waitForKeyboard(in: "terminal-\(shell.id)", "the new shell")
        XCTAssertFalse(app.exists(.id("strip-shells")), "the shell is in the user's Shells tab")
        XCTAssertFalse(app.exists(.id("tab-\(shell.id)")), "the shell has a tab of its own")
        // TABS-5 (#146): the agent's item in the row is "Agent", never the
        // name its tab above says, even before its conversation has one.
        let item = app.first(.id("item-\(agent.id)"))?.label
        XCTAssertEqual(item, AgentPartWords.agent)
        XCTAssertNotEqual(app.first(.id("tab-\(agent.id)"))?.label, item, "the tab and the item read the same")
        let listed = server.text("shell_list")
        XCTAssertFalse(listed.failed, listed.text)
        XCTAssertTrue(listed.text.contains("\(shell.id)"), "the agent does not list it: \(listed.text)")
        let ran = server.text("shell_run", ["session": Int(shell.id), "command": "echo from-the-$((40 + 2))-agent"])
        XCTAssertFalse(ran.failed, ran.text)
        XCTAssertTrue(ran.text.contains("from-the-42-agent"), ran.text)
    }

    /// BROWSER-32: Show As is a button of the page's bar, in sight, which
    /// names the device in use; its list shows the page as another, one
    /// after another, each time named on the bar and the page given its
    /// screen's width, and as this Mac again.
    func testShowAsOnTheBarShowsOneDeviceAfterAnother() throws {
        let page = try makeSite()
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        XCTAssertEqual(app.value(of: .id("browser-show-as")), "This Mac")
        func width() -> CGFloat { app.frame(of: .id("browser-page"))?.width ?? 0 }
        let whole = width()
        for (name, wide) in [("iPhone SE", 375), ("iPad Mini", 768), ("Pixel 7", 412), ("iPhone 12 Pro", 390), ("iPhone SE", 375)] {
            app.press(.id("browser-show-as"))
            app.press(.id("show-as-\(name)"))
            app.wait("the bar to name \(name), not \(app.value(of: .id("browser-show-as")) ?? "nothing")", timeout: 15) {
                self.app.value(of: .id("browser-show-as")) == name
            }
            app.wait("the page as wide as \(name)'s screen, \(wide), not \(width())") { abs(width() - CGFloat(wide)) < 2 }
        }
        shot("shown-as")
        app.press(.id("browser-show-as"))
        // The one in use is marked.
        XCTAssertEqual(app.first(.id("show-as-iPhone SE"))?.value, "shown")
        app.press(.id("show-as-this-mac"))
        app.wait("the bar to name this Mac") { self.app.value(of: .id("browser-show-as")) == "This Mac" }
        app.wait("the page as wide as before, \(whole), not \(width())") { abs(width() - whole) < 2 }
    }

    /// BROWSER-40 (#134): Show As is one button whatever the page is shown
    /// as. Its label was of another shape with a device's name in it, and
    /// the button was made anew when the first device was picked: a list
    /// open under it was closed with the button left as open, so that the
    /// next press did nothing, and a press on the button as it was found
    /// before was lost, though it was reported as done.
    func testShowAsIsOneButtonWhateverThePageIsShownAs() throws {
        let page = try makeSite()
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        // Pressed with no wait after, which `app.press` has.
        func press(_ node: Node) { AXUIElementPerformAction(node.element, kAXPressAction as CFString) }

        // The first device picked and the button pressed again at once: its
        // list is open when the page comes to be shown as the device.
        app.press(.id("browser-show-as"))
        let phone = try XCTUnwrap(app.wait(for: .id("show-as-iPhone SE")))
        let button = try XCTUnwrap(app.first(.id("browser-show-as")))
        press(phone)
        press(button)
        app.wait("the bar to name iPhone SE") { self.app.value(of: .id("browser-show-as")) == "iPhone SE" }
        // Longer than the list of the pick takes to go.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(app.first(.id("show-as-iPhone SE"))?.value, "shown", "the list opened again at once was closed when the page came to be shown as a device")

        // Back to this Mac, from that list.
        app.press(.id("show-as-this-mac"))
        app.wait("the bar to name this Mac") { self.app.value(of: .id("browser-show-as")) == "This Mac" }
        app.waitGone(.id("show-as-this-mac"))
        // The button as it is found now still opens its list once a device
        // is picked.
        let before = try XCTUnwrap(app.first(.id("browser-show-as")))
        app.press(.id("browser-show-as"))
        app.press(.id("show-as-iPad Mini"))
        app.wait("the bar to name iPad Mini") { self.app.value(of: .id("browser-show-as")) == "iPad Mini" }
        app.waitGone(.id("show-as-this-mac"))
        press(before)
        app.wait(for: .id("show-as-this-mac"))
        XCTAssertEqual(app.first(.id("show-as-iPad Mini"))?.value, "shown")
    }

    /// BROWSER-8: a server of the project that is not running is said so;
    /// a tab the agent did not open, the user's, it neither sees nor
    /// reaches; the device size is pretended; and Settings has no switch
    /// that takes the browser from the agents.
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
        func usersPage() -> String? {
            app.nodes().first { $0.identifier.hasPrefix("item-b") && $0.identifier != "item-b\(tab)" }.map { String($0.identifier.dropFirst(6)) }
        }
        app.wait("the user's tab") { usersPage() != nil }
        let users = try XCTUnwrap(usersPage())
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
        // The bar's Show As names it.
        app.wait("the bar to name the device, not \(app.value(of: .id("browser-show-as")) ?? "nothing")") { self.app.value(of: .id("browser-show-as")) == "iPhone 16" }
        // The page as wide as the phone's screen, and the agent the rest.
        app.wait("the page as wide as the phone, not \(app.frame(of: .id("browser-page"))?.width ?? 0)") {
            abs((self.app.frame(of: .id("browser-page"))?.width ?? 0) - 393) < 1.5
        }
        // Its part is no narrower than its bar needs, the owner's wish: the
        // page is the phone's width in it, the bar's buttons whole.
        app.wait("the agent's page part as wide as its bar needs, not \(self.app.frame(of: .id("agent-browser"))?.width ?? 0)") {
            abs((self.app.frame(of: .id("agent-browser"))?.width ?? 0) - 460) < 2
        }
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

        // No switch turns the agents' browser off: Settings has none.
        app.press(.id("place-settings"))
        app.press(.id("settings-browser"))
        app.wait(for: .id("profile-new"))
        XCTAssertFalse(app.exists(.id("agents-use-browser")), "the switch is still in Settings")
        XCTAssertFalse(server.text("browser_snapshot", ["tab": tab]).failed)
        app.press(.id("place-sessions"))
        app.wait(for: .id("agent-browser"))
        // Closing a tab closes the tab, not the window it is in.
        XCTAssertFalse(server.text("browser_close", ["tab": tab]).failed)
        app.waitGone(.id("agent-browser"))
        XCTAssertTrue(app.exists(.id("mac-switcher")), "the window closed with the tab")
    }

    /// BROWSER-10: with one profile, an agent's tab uses it without a word;
    /// with two, its first `browser_open` that names none is refused at once
    /// with the profiles' names, to ask the user in its conversation; one it
    /// names it gets, and its next tab the same without naming it; a name
    /// that is no profile's is refused. `browser_profiles` lists them. The
    /// header's Browser button opens a tab of the user's in a profile picked
    /// from its menu, or a private one.
    func testAnAgentAsksWhichProfile() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        func tabID(_ text: String) throws -> String {
            try XCTUnwrap(text.range(of: #"tab \d+"#, options: .regularExpression).map { String(text[$0].dropFirst(4)) }, text)
        }
        /// The profile the tab in front says it uses, in its bar.
        func profileShown() -> String {
            let pill = app.first(.id("browser-profile"))
            return pill.map { $0.value.isEmpty ? $0.label : $0.value } ?? "none"
        }

        // One profile: used.
        let first = server.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(first.failed, first.text)
        XCTAssertFalse(server.text("browser_close", ["tab": try tabID(first.text)]).failed)

        // Two: the agent is told to ask.
        app.press(.id("place-settings"))
        app.press(.id("settings-browser"))
        app.press(.id("profile-new"))
        app.wait(for: .id("profile-name-Profile 2"))
        app.press(.id("place-sessions"))
        let (other, _) = try startAgent()
        defer { other.stop() }
        let unnamed = other.text("browser_open", ["url": page.absoluteString])
        XCTAssertTrue(unnamed.failed, unnamed.text)
        XCTAssertEqual(unnamed.text, BrowserWords.whichProfile(["Default", "Profile 2"]))
        XCTAssertEqual(other.text("browser_profiles").text, BrowserWords.profiles(["Default", "Profile 2"], uses: nil))
        let wrong = other.text("browser_open", ["url": page.absoluteString, "profile": "Work"])
        XCTAssertEqual(wrong.text, BrowserWords.noProfile("Work", ["Default", "Profile 2"]))
        let named = other.text("browser_open", ["url": page.absoluteString, "profile": "profile 2"])
        XCTAssertFalse(named.failed, named.text)
        app.wait(for: .id("browser-profile"), timeout: 20)
        app.wait("its tab in Profile 2, not \(profileShown())") { profileShown() == "Profile 2" }
        // Its next tab: the same, without naming it.
        let again = other.text("browser_open", ["url": page.absoluteString])
        XCTAssertFalse(again.failed, again.text)
        XCTAssertEqual(other.text("browser_profiles").text, BrowserWords.profiles(["Default", "Profile 2"], uses: "Profile 2"))
        shot("agent-in-profile-2")

        // Chromium made the profile where it is kept: a profile it refuses
        // falls back to one of its own, shared by every profile.
        let browser = state.appendingPathComponent("browser")
        let log = (try? String(contentsOf: browser.appendingPathComponent("chromium.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("Cannot create profile"), "Chromium refused a profile:\n\(log)")
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: browser.path)) ?? []).filter { $0.hasPrefix("profile-") && $0 != "profile-default" }
        XCTAssertEqual(made.count, 1, "Profile 2's folder: \(made)")

        // The user's: the header's Browser button asks which.
        app.press(.id("browser-launch"))
        app.press(.button("Profile 2"))
        app.wait("the user's tab in Profile 2, not \(profileShown())") { profileShown() == "Profile 2" }
        app.press(.id("browser-launch"))
        app.press(.button("Private"))
        app.wait("the user's private tab, not \(profileShown())") { profileShown() == BrowserWords.privateProfile }
        shot("user-private-tab")
    }

    /// BROWSER-22: an agent's private tabs share a profile of their own in
    /// memory: what one keeps the other has, a tab in the default profile
    /// has none of it, another agent's private tab neither, and once its
    /// last private tab is closed it is gone.
    func testPrivateTabsKeepNothing() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        func open(_ arguments: [String: Any], on server: Server) throws -> String {
            let opened = server.text("browser_open", ["url": page.absoluteString].merging(arguments) { $1 })
            XCTAssertFalse(opened.failed, opened.text)
            return try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        }
        func kept(_ tab: String, on server: Server) -> String {
            server.text("browser_evaluate", ["tab": tab, "script": "localStorage.getItem('kept') ?? 'nothing'"]).text
        }
        let one = try open(["private": true], on: server)
        XCTAssertFalse(server.text("browser_evaluate", ["tab": one, "script": "localStorage.setItem('kept', 'yes'); 'set'"]).failed)
        let two = try open(["private": true], on: server)
        XCTAssertEqual(kept(two, on: server), "\"yes\"", "the agent's private tabs do not share")
        let plain = try open([:], on: server)
        XCTAssertEqual(kept(plain, on: server), "\"nothing\"", "the default profile has what a private tab kept")
        let (other, _) = try startAgent()
        defer { other.stop() }
        let others = try open(["private": true], on: other)
        XCTAssertEqual(kept(others, on: other), "\"nothing\"", "another agent's private tab has what this one's kept")
        app.wait("its profile said") { self.app.exists(.id("browser-profile")) }

        // Its last private tab closed: gone.
        XCTAssertFalse(server.text("browser_close", ["tab": one]).failed)
        XCTAssertFalse(server.text("browser_close", ["tab": two]).failed)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let three = try open(["private": true], on: server)
        XCTAssertEqual(kept(three, on: server), "\"nothing\"", "a private profile kept what it had after its last tab closed")
        // Nothing of it on disk.
        let browser = state.appendingPathComponent("browser")
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: browser.path)) ?? []).filter { $0.contains("private") }
        XCTAssertEqual(folders, [], "a private profile has a folder")
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
    /// BROWSER-18: a device watches an agent's page live and uses it: it is
    /// sent pictures no wider than it asked, with the page's size; a touch
    /// on a field and on a button, and text typed, reach the page, and the
    /// tab is the user's from then on; once it no longer watches, no
    /// picture comes.
    func testADeviceWatchesAndUsesAPage() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        let phone = try device()
        var asked = 1000
        func ask(_ request: BrowserRequest) -> BrowserResult? {
            asked += 1
            let id = asked
            phone.send(.browserAsk(id: id, request: request))
            var answer: BrowserResult?
            wait("the answer to \(request)") {
                answer = phone.messages.lazy.compactMap { if case .browserAnswer(id, let result) = $0 { return result } else { return nil } }.first
                return answer != nil
            }
            return answer
        }
        func frames() -> [(jpeg: Data, width: Double, height: Double)] {
            phone.messages.compactMap { if case .browserFrame(tab, let jpeg, let width, let height) = $0 { return (jpeg, width, height) } else { return nil } }
        }

        _ = ask(.watch(tab: tab, on: true, width: 300))
        wait("a picture of the page", timeout: 15) { !frames().isEmpty }
        let frame = try XCTUnwrap(frames().last)
        let picture = try XCTUnwrap(NSBitmapImageRep(data: frame.jpeg), "not a picture")
        XCTAssertLessThanOrEqual(picture.pixelsWide, 300)
        XCTAssertGreaterThan(frame.width, 100)
        XCTAssertGreaterThan(frame.height, 100)

        // Where the field and the button are, in the page's CSS pixels.
        func center(_ id: String) throws -> (Double, Double) {
            let rect = server.text("browser_evaluate", ["tab": tab, "script": "(r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById('\(id)').getBoundingClientRect())"]).text
            let numbers = rect.split { !"0123456789.".contains($0) }.compactMap { Double($0) }
            return (try XCTUnwrap(numbers.first), try XCTUnwrap(numbers.dropFirst().first))
        }
        let field = try center("name"), button = try center("greet")
        // The agent reads the page still, which is not acting on it.
        func looked() -> String { server.text("browser_snapshot", ["tab": tab]).text }
        if case .refused(let why)? = ask(.tap(tab: tab, x: field.0, y: field.1)) { XCTFail(why) }
        _ = ask(.text(tab: tab, text: "Bo"))
        wait("the text in the field") { looked().contains("textbox \"Name\"") && looked().contains("Bo") }
        _ = ask(.tap(tab: tab, x: button.0, y: button.1))
        wait("the page did it, not \(looked())") { looked().contains("Hi there, Bo") }
        // The user's now: the agent waits.
        XCTAssertEqual(server.text("browser_navigate", ["tab": tab, "url": page.absoluteString]).text, BrowserWords.userHasIt(tab))
        app.wait(for: .containing("You have this tab"))

        _ = ask(.watch(tab: tab, on: false, width: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let count = frames().count
        _ = ask(.text(tab: tab, text: " and more"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(frames().count, count, "pictures came after the device stopped watching")
    }

    /// BROWSER-19 (#100): a page shown on the Mac as a device whose pixels
    /// are not the screen's, watched by a device: what the Mac shows of it
    /// stays as it is, the page standing still.
    func testWatchingDoesNotShakeThePage() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        // A phone of three pixels to the point: not the screen's, whatever it is.
        let phone = try XCTUnwrap(BrowserDevice.presets.first { $0.kind == .phone && $0.scale == 3 })
        let emulated = server.text("browser_emulate", ["tab": tab, "device": phone.name])
        XCTAssertFalse(emulated.failed, emulated.text)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let rect = try XCTUnwrap(app.frame(of: .id("browser-page")))
        let window = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }
        let bounds = try XCTUnwrap((window?[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-shake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func shot(_ name: String) -> NSBitmapImageRep? {
            let file = folder.appendingPathComponent(name + ".png")
            app.capture(to: file)
            return NSImage(contentsOf: file)?.representations.first as? NSBitmapImageRep
        }
        // The share of the page's points that differ between two pictures of the window.
        func differs(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
            guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
            let scale = CGFloat(a.pixelsWide) / bounds.width
            let xs = max(Int((rect.minX - bounds.minX) * scale), 0)..<min(Int((rect.maxX - bounds.minX) * scale), a.pixelsWide)
            let ys = max(Int((rect.minY - bounds.minY) * scale), 0)..<min(Int((rect.maxY - bounds.minY) * scale), a.pixelsHigh)
            var changed = 0, all = 0
            for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 3) {
                for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 3) {
                    all += 1
                    guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.06 { changed += 1 }
                }
            }
            return Double(changed) / Double(max(all, 1))
        }
        let still = try XCTUnwrap(shot("before"), "no picture of the window")
        let device = try self.device()
        device.send(.browserAsk(id: 2001, request: .watch(tab: tab, on: true, width: 1290)))
        wait("a picture of the page", timeout: 15) { device.messages.contains { if case .browserFrame = $0 { return true } else { return false } } }
        var during: [Double] = []
        for index in 1...14 { if let picture = shot("during-\(index)") { during.append(differs(still, picture)) } }
        XCTAssertEqual(during.count, 14, "pictures of the window missing")
        XCTAssertTrue(during.allSatisfy { $0 < 0.002 }, "the page shown as \(phone.name) changed while watched: \(during.map { String(format: "%.3f", $0) })")
    }

    /// BROWSER-27 (#107): a page shown as a device whose screen is larger
    /// than its pane, watched by a device. While the Mac draws it, it is
    /// drawn smaller to fit, all of it in sight, and each picture a device
    /// is sent, what the Mac draws, is all of its screen in its shape, not a
    /// part squeezed into it. While the Mac does not draw it, the pictures
    /// are as sharp as the device asked for, the page drawn as the device.
    func testAPageShownAsADeviceIsSentWholeInItsShape() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        // A phone taller than the pane, of three pixels to the point.
        let phone = try XCTUnwrap(BrowserDevice.presets.filter { $0.kind == .phone && $0.scale == 3 }.max { $0.height < $1.height })
        let pane = try XCTUnwrap(app.frame(of: .id("browser-page")))
        XCTAssertGreaterThan(Double(phone.height), pane.height, "the pane is as tall as \(phone.name)")
        // A page that says its viewport, as a site made for phones does,
        // with a blue mark in the bottom right corner of what it shows: where
        // the mark is in a picture says how much of the picture the page fills.
        let mark =
            "const m = document.createElement('meta'); m.name = 'viewport'; m.content = 'width=device-width, initial-scale=1'; document.head.appendChild(m); const d = document.createElement('div'); d.style.cssText = 'position:fixed;right:0;bottom:0;width:30vw;height:15vh;background:rgb(20,40,220)'; document.body.appendChild(d); 1"
        XCTAssertFalse(server.text("browser_evaluate", ["tab": tab, "script": mark]).failed)
        let emulated = server.text("browser_emulate", ["tab": tab, "device": phone.name])
        XCTAssertFalse(emulated.failed, emulated.text)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let device = try self.device()
        let asked = 1290
        /// Whether the page's mark is in a picture's bottom right corner,
        /// and not at its middle, where it is when the page is drawn small.
        func red(_ image: NSBitmapImageRep) -> [Bool] {
            [(0.93, 0.96), (0.5, 0.5)].map { x, y in
                guard let color = image.colorAt(x: Int(Double(image.pixelsWide) * x), y: Int(Double(image.pixelsHigh) * y))?.usingColorSpace(.sRGB) else { return false }
                return color.blueComponent > 0.6 && color.redComponent < 0.35 && color.greenComponent < 0.4
            }
        }
        func frames() -> [(jpeg: Data, width: Double, height: Double)] {
            device.messages.compactMap { if case .browserFrame(tab, let jpeg, let width, let height) = $0 { return (jpeg, width, height) } else { return nil } }
        }
        /// The last picture of a while of watching, and its size in pixels.
        func watched(_ id: Int) throws -> (pixels: CGSize, width: Double, height: Double, red: [Bool]) {
            let before = frames().count
            device.send(.browserAsk(id: id, request: .watch(tab: tab, on: true, width: asked)))
            // A page that stays as it is is streamed when it is drawn, and seldom after.
            wait("a picture of the page", timeout: 15) { frames().count > before }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            device.send(.browserAsk(id: id + 1, request: .watch(tab: tab, on: false, width: 0)))
            let last = try XCTUnwrap(frames().last)
            if let folder = ProcessInfo.processInfo.environment["AGENTTERM_SHOT_DIR"] {
                try? last.jpeg.write(to: URL(fileURLWithPath: folder).appendingPathComponent("BROWSER-27-frame-\(id).jpg"))
            }
            let image = try XCTUnwrap(NSBitmapImageRep(data: last.jpeg), "not a picture")
            return (CGSize(width: image.pixelsWide, height: image.pixelsHigh), last.width, last.height, red(image))
        }
        // As wide as the phone's screen and as tall as the pane, never drawn
        // smaller: the size sent is that, the picture is in its shape, with
        // the pixels the Mac draws, and the page fills it to its corner.
        let drawn = try watched(2101)
        XCTAssertEqual(drawn.width, Double(phone.width), accuracy: 1, "the page is not as wide as the phone's screen")
        XCTAssertLessThanOrEqual(drawn.height, Double(pane.height) + 2, "the page is taller than its pane, \(pane.height)")
        XCTAssertGreaterThan(drawn.height, Double(pane.height) * 0.8, "the page does not use its pane's height, \(pane.height)")
        let shape = drawn.width / drawn.height
        XCTAssertEqual(
            Double(drawn.pixels.width / drawn.pixels.height), shape, accuracy: shape * 0.03,
            "a picture of \(Int(drawn.pixels.width)) × \(Int(drawn.pixels.height)) pixels for a page of \(drawn.width) × \(drawn.height)")
        // Chromium streams a pixel to the page's point, whatever the Mac's
        // screen has (found by trying, CEF 156): no fewer, as when the page
        // was drawn smaller.
        XCTAssertGreaterThanOrEqual(Double(drawn.pixels.width), Double(phone.width) * 0.98, "a picture \(Int(drawn.pixels.width)) pixels wide of a page \(phone.width) points wide: drawn smaller")
        XCTAssertEqual(drawn.red, [true, false], "the page does not fill the picture sent while the Mac draws it")
        // The page is still told the phone's whole screen.
        XCTAssertEqual(server.text("browser_evaluate", ["tab": tab, "script": "screen.width + 'x' + screen.height"]).text, "\"\(phone.width)x\(phone.height)\"")

        app.minimize(true)
        defer { app.minimize(false) }
        let hidden = try watched(2103)
        XCTAssertEqual(Double(hidden.pixels.width / hidden.pixels.height), shape, accuracy: shape * 0.03, "a picture of \(Int(hidden.pixels.width)) × \(Int(hidden.pixels.height)) pixels")
        XCTAssertEqual(hidden.red, [true, false], "the page does not fill the picture taken while the Mac does not draw it")
        let wanted = min(Double(asked), Double(phone.width) * phone.scale)
        XCTAssertGreaterThanOrEqual(Double(hidden.pixels.width), wanted * 0.9, "a picture \(Int(hidden.pixels.width)) pixels wide, where \(Int(wanted)) were asked for")
    }

    /// The app's page processes, by number, and their names: Chromium's
    /// renderers, children of the app.
    private func renderers() -> [Int32: String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var found: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard words.count == 3, let pid = Int32(words[0]), Int32(words[1]) == app.pid, words[2].contains("--type=renderer") else { continue }
            found[pid] = String(words[2].split(separator: "/").last { $0.contains("(Chromium)") } ?? "")
        }
        return found
    }

    /// BROWSER-28: the processes of the pages are named for the browser, as
    /// Activity Monitor lists them; and a tab closed lets its page's go, its
    /// memory with it. Three tabs of three sites, each in a process of its own.
    func testAClosedTabsPageProcessEndsAndPagesAreNamedForTheBrowser() throws {
        let page = try makeSite()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let port = Int.random(in: 20_000..<40_000)
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", page.deletingLastPathComponent().path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        let (agent, _) = try startAgent()
        defer { agent.stop() }
        let before = Set(renderers().keys)
        var tabs: [String] = []
        for url in ["http://127.0.0.1:\(port)/\(page.lastPathComponent)", "http://localhost:\(port)/\(page.lastPathComponent)", page.absoluteString] {
            var opened = agent.text("browser_open", ["url": url])
            // The little server may still be starting.
            for _ in 0..<10 where opened.failed || opened.text.contains("could not") {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                opened = agent.text("browser_open", ["url": url])
            }
            XCTAssertFalse(opened.failed, opened.text)
            tabs.append(try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text))
        }
        wait("a process for each page", timeout: 20) { Set(self.renderers().keys).subtracting(before).count >= 3 }
        let pages = renderers().filter { !before.contains($0.key) }
        for (_, name) in pages {
            XCTAssertTrue(name.contains("Browser (Chromium)"), "a page's process is named \(name)")
        }

        for tab in tabs { XCTAssertFalse(agent.text("browser_close", ["tab": tab]).failed) }
        // Chromium may keep one spare, for the next page.
        let deadline = Date().addingTimeInterval(20)
        while Set(renderers().keys).intersection(pages.keys).count > 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertLessThanOrEqual(Set(renderers().keys).intersection(pages.keys).count, 1, "processes of closed pages still running: \(renderers().filter { pages.keys.contains($0.key) })")
    }

    /// BROWSER-34: the user's own pages, closed by the user, let their
    /// processes go too: one by one with Close Tab, the rest with the
    /// Browser tab, and one closed before anything was loaded in it.
    func testTheUsersClosedPagesProcessesEnd() throws {
        let page = try makeSite()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let port = Int.random(in: 20_000..<40_000)
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", page.deletingLastPathComponent().path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        func pages() -> [String] { app.nodes().map(\.identifier).filter { $0.hasPrefix("item-b") } }
        let before = Set(renderers().keys)
        let urls = ["http://127.0.0.1:\(port)/\(page.lastPathComponent)", "http://localhost:\(port)/\(page.lastPathComponent)", page.absoluteString]
        for (index, url) in urls.enumerated() {
            if index == 0 { app.menu(["Browser", "New Browser Tab"]) } else { app.press(.id("browser-new-page")) }
            app.wait("page \(index + 1)") { pages().count == index + 1 }
            app.wait(for: .id("browser-address"), timeout: 20)
            app.write(url, into: .id("browser-address"), confirm: true)
            app.wait(for: .text("Test page"), timeout: 20)
        }
        // One more, with nothing loaded in it.
        app.press(.id("browser-new-page"))
        app.wait("a fourth page") { pages().count == 4 }
        wait("a process for each page", timeout: 20) { Set(self.renderers().keys).subtracting(before).count >= 3 }
        let opened = renderers().filter { !before.contains($0.key) }

        let all = pages()
        app.perform("Close Tab", on: .id(all[3]))
        app.wait("three pages left") { pages().count == 3 }
        app.perform("Close Tab", on: .id(all[0]))
        app.wait("two pages left") { pages().count == 2 }
        app.perform("Close Browser", on: .id("strip-browser"))
        app.press(.button("Close 2 Pages"))
        app.wait("the Browser tab gone") { pages().isEmpty && !self.app.exists(.id("strip-browser")) }
        // Chromium may keep one spare, for the next page.
        let deadline = Date().addingTimeInterval(20)
        while Set(renderers().keys).subtracting(before).count > 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        let left = renderers().filter { !before.contains($0.key) }
        XCTAssertLessThanOrEqual(left.count, 1, "\(left.count) processes of \(opened.count) closed pages still running: \(left.keys.sorted())")
    }

    /// BROWSER-35 (#117): with the last page closed, no page process is
    /// left, not one kept in reserve either; a page opened later loads.
    func testNoPageProcessIsLeftWithTheLastPageClosed() throws {
        let page = try makeSite()
        for round in 1...2 {
            app.menu(["Browser", "New Browser Tab"])
            app.wait(for: .id("browser-address"), timeout: 30)
            app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
            app.wait(for: .text("Test page"), timeout: 30)
            XCTAssertFalse(renderers().isEmpty, "round \(round): a page is shown by no process")
            app.perform("Close Browser", on: .id("strip-browser"))
            app.wait("the Browser tab gone") { !self.app.exists(.id("strip-browser")) }
            let deadline = Date().addingTimeInterval(20)
            while !renderers().isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            XCTAssertEqual(renderers().keys.sorted(), [], "round \(round): page processes still running with no page open")
        }
    }

    /// BROWSER-29: a page's two modes, in sight on its bar. Picking on, an
    /// element clicked opens the sheet that sends it to an agent, the
    /// project's agent picked already; sent, the agent is told what to do
    /// with it; picking stays on, and the next click opens the sheet again,
    /// until it is turned off and the page is browsed again.
    func testPickingSendsElementsToAnAgentUntilTurnedOff() throws {
        let page = try makeSite()
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        // Where the button is, in the page's CSS pixels.
        let middle = "(() => { const r = document.getElementById('greet').getBoundingClientRect(); return (r.x + r.width / 2) + ',' + (r.y + r.height / 2); })()"
        let place = server.text("browser_evaluate", ["tab": tab, "script": middle])
        let point = place.text.split(whereSeparator: { !"0123456789.,".contains($0) }).joined().split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(point.count, 2, place.text)
        let device = try self.device()
        func click() { device.send(.browserAsk(id: Int.random(in: 3000..<9000), request: .tap(tab: tab, x: point[0], y: point[1]))) }

        XCTAssertTrue(app.exists(.button("Pick an Element for an Agent")), "the mode's button is not on the bar")
        app.press(.id("browser-pick"))
        app.wait(for: .button("Stop Picking"))
        click()
        app.wait(for: .text("Send to an Agent"), timeout: 15)
        XCTAssertTrue(app.exists(.containing("#greet")), "the element sent is not the button")
        // What the agent's session is typed, a stand-in that echoes it,
        // read as a device reads it.
        device.send(.attach(session: agent.id, size: .default))
        app.write("Make this button blue", into: .id("pick-note"))
        app.press(.button("Send"))
        wait("the note typed into the agent's session", timeout: 15) { device.text(agent.id).contains("Make this button blue") }
        XCTAssertTrue(device.text(agent.id).contains("button#greet"), "the element is not told: \(device.text(agent.id).suffix(400))")

        // Still picking: the next click opens it again.
        app.wait(for: .button("Stop Picking"))
        click()
        app.wait(for: .text("Send to an Agent"), timeout: 15)
        app.press(.button("Cancel"))
        app.press(.id("browser-pick"))
        app.wait(for: .button("Pick an Element for an Agent"))
    }

    /// BROWSER-44 (#148): a page the user opens belongs to no folder: one
    /// Browser, its row above the folders in the list, its tab in the strip
    /// of every folder, the same page shown from each.
    func testTheUsersPagesBelongToNoFolder() throws {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let phone = try device()
        phone.send(.addFolder(path: other.path))
        app.wait(for: .id("folder-\(other.path)"), timeout: 15)
        app.press(.id("folder-\(project.path)"))
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("strip-browser"), timeout: 15)
        func lastTabs() -> [BrowserTabInfo] { phone.messages.reversed().lazy.compactMap { if case .browserTabs(let tabs) = $0 { return tabs } else { return nil } }.first ?? [] }
        wait("the page told", timeout: 15) { lastTabs().count == 1 }
        XCTAssertEqual(lastTabs().first?.project, "", "the page is of the folder on show")
        let row = try XCTUnwrap(app.frame(of: .id("sidebar-browser")))
        let folder = try XCTUnwrap(app.frame(of: .id("folder-\(project.path)")))
        XCTAssertLessThan(row.minY, folder.minY, "the Browser row is not above the folders")
        shot("one-browser")

        // In the other folder's strip too, showing the same page.
        app.press(.id("folder-\(other.path)"))
        app.wait(for: .id("strip-browser"), timeout: 15)
        XCTAssertEqual(app.all(.id("strip-browser")).count, 1)
        app.press(.id("strip-browser"))
        app.wait(for: .id("browser-address"), timeout: 15)
        XCTAssertEqual(lastTabs().count, 1, "another page was opened for the other folder")
    }

    /// BROWSER-42 (#149): an element picked in an agent's page goes to that
    /// agent, though another agent of the project was started before it:
    /// the sheet names it and offers no other.
    func testAnElementPickedInAnAgentsPageGoesToThatAgent() throws {
        let page = try makeSite()
        let (firstServer, first) = try startAgent()
        defer { firstServer.stop() }
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait("the page shown") { self.app.value(of: .id("browser-page")) == "Test page" }
        let middle = "(() => { const r = document.getElementById('greet').getBoundingClientRect(); return (r.x + r.width / 2) + ',' + (r.y + r.height / 2); })()"
        let place = server.text("browser_evaluate", ["tab": tab, "script": middle])
        let point = place.text.split(whereSeparator: { !"0123456789.,".contains($0) }).joined().split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(point.count, 2, place.text)
        let device = try self.device()
        device.send(.attach(session: first.id, size: .default))
        device.send(.attach(session: agent.id, size: .default))

        app.press(.id("browser-pick"))
        app.wait(for: .button("Stop Picking"))
        device.send(.browserAsk(id: 4100, request: .tap(tab: tab, x: point[0], y: point[1])))
        app.wait(for: .text("Send to an Agent"), timeout: 15)
        XCTAssertFalse(app.exists(.id("pick-agent")), "an agent's page offers a choice of agent")
        XCTAssertTrue(app.exists(.text(BrowserWords.sendsTo(agent.displayName))), "the sheet does not say which agent it goes to")
        app.write("Make this button blue", into: .id("pick-note"))
        app.press(.button("Send"))
        wait("the note typed into the page's agent", timeout: 15) { device.text(agent.id).contains("Make this button blue") }
        XCTAssertFalse(device.text(first.id).contains("Make this button blue"), "the element went to the other agent")
    }

    /// BROWSER-20: a device watches and uses an agent's page while the Mac's
    /// window is minimized, as when the user is away from it: pictures come,
    /// and a touch on a field, text typed and a touch on a button reach the
    /// page.
    func testADeviceUsesAPageTheMacDoesNotShow() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        let phone = try device()
        var asked = 1000
        func ask(_ request: BrowserRequest) -> BrowserResult? {
            asked += 1
            let id = asked
            phone.send(.browserAsk(id: id, request: request))
            var answer: BrowserResult?
            wait("the answer to \(request)") {
                answer = phone.messages.lazy.compactMap { if case .browserAnswer(id, let result) = $0 { return result } else { return nil } }.first
                return answer != nil
            }
            return answer
        }
        func center(_ id: String) throws -> (Double, Double) {
            let rect = server.text("browser_evaluate", ["tab": tab, "script": "(r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById('\(id)').getBoundingClientRect())"]).text
            let numbers = rect.split { !"0123456789.".contains($0) }.compactMap { Double($0) }
            return (try XCTUnwrap(numbers.first), try XCTUnwrap(numbers.dropFirst().first))
        }
        let field = try center("name"), button = try center("greet")
        app.minimize(true)
        defer { app.minimize(false) }
        _ = ask(.watch(tab: tab, on: true, width: 300))
        wait("a picture of the page", timeout: 15) { phone.messages.contains { if case .browserFrame(tab, _, _, _) = $0 { return true } else { return false } } }
        func looked() -> String { server.text("browser_snapshot", ["tab": tab]).text }
        if case .refused(let why)? = ask(.tap(tab: tab, x: field.0, y: field.1)) { XCTFail(why) }
        _ = ask(.text(tab: tab, text: "Bo"))
        if case .refused(let why)? = ask(.tap(tab: tab, x: button.0, y: button.1)) { XCTFail(why) }
        wait("the page did it, not \(looked())") { looked().contains("Hi there, Bo") }
        _ = ask(.watch(tab: tab, on: false, width: 0))
    }

    /// BROWSER-21: what a device does to pages, as the Mac's user does: a
    /// touch says whether a field took the keyboard; text and keys sent one
    /// after the other reach the page in that order; it shows the page as a
    /// device; it opens a tab of the user's in a project, which the Mac does
    /// not bring to the front, stops it and closes it, and an agent's too.
    func testADeviceOpensShowsAsAndClosesPages() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        let phone = try device()
        var asked = 2000
        func send(_ request: BrowserRequest) -> Int {
            asked += 1
            phone.send(.browserAsk(id: asked, request: request))
            return asked
        }
        func answer(_ id: Int) -> BrowserResult? {
            var answer: BrowserResult?
            wait("the answer to \(id)") {
                answer = phone.messages.lazy.compactMap { if case .browserAnswer(id, let result) = $0 { return result } else { return nil } }.first
                return answer != nil
            }
            return answer
        }
        func ask(_ request: BrowserRequest) -> BrowserResult? { answer(send(request)) }
        func center(_ id: String) throws -> (Double, Double) {
            let rect = server.text("browser_evaluate", ["tab": tab, "script": "(r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById('\(id)').getBoundingClientRect())"]).text
            let numbers = rect.split { !"0123456789.".contains($0) }.compactMap { Double($0) }
            return (try XCTUnwrap(numbers.first), try XCTUnwrap(numbers.dropFirst().first))
        }
        // The tab is the user's after the first touch: the agent can look, not run scripts.
        func looked() -> String { server.text("browser_snapshot", ["tab": tab]).text }
        continueAfterFailure = true

        // A touch on the field, and one on the heading.
        let field = try center("name"), heading = try center("out")
        XCTAssertEqual(ask(.tap(tab: tab, x: field.0, y: field.1)), .touched(field: true))
        // Sent without waiting: in this order they reach the page.
        let sent = [send(.text(tab: tab, text: "ab")), send(.press(tab: tab, key: "Backspace")), send(.text(tab: tab, text: "c"))]
        sent.forEach { _ = answer($0) }
        wait("the field to say ac, not \(looked())") {
            let now = looked()
            return now.contains("textbox \"Name\"") && now.contains("ac") && !now.contains("abc")
        }
        XCTAssertEqual(ask(.tap(tab: tab, x: heading.0, y: heading.1)), .touched(field: false))

        // Shown as a phone, from the device.
        let phoneDevice = try XCTUnwrap(BrowserDevice.preset(named: "iPhone SE"))
        if case .tabs(let tabs)? = ask(.emulate(tab: tab, device: phoneDevice)) {
            XCTAssertEqual(tabs.first { $0.id == tab }?.emulating, "iPhone SE")
        } else {
            XCTFail("no tabs after Show As")
        }

        // A tab of the user's, of no folder whatever the device names (#148),
        // not in front on the Mac.
        let project = try XCTUnwrap(phone.messages.lazy.compactMap { if case .browserTabs(let tabs) = $0 { return tabs.first { $0.id == tab }?.project } else { return nil } }.first)
        // Empty, then the page typed into its address bar, as the iPhone does.
        guard case .opened(let own)? = ask(.newTab(project: project, url: nil, profile: nil, private: false)) else { return XCTFail("no tab opened") }
        func lastTabs() -> [BrowserTabInfo] { phone.messages.reversed().lazy.compactMap { if case .browserTabs(let tabs) = $0 { return tabs } else { return nil } }.first ?? [] }
        wait("the device's tab listed as the user's") { lastTabs().contains { $0.id == own && $0.openedBy == nil && $0.project == "" } }
        if case .refused(let why)? = ask(.navigate(tab: own, url: page.absoluteString)) { XCTFail(why) }
        wait("the page loaded in the device's tab, not \(lastTabs().first { $0.id == own }?.url ?? "")") {
            lastTabs().contains { $0.id == own && $0.url == page.absoluteString && $0.title == "Test page" }
        }
        shot("device-tab-opened")
        XCTAssertTrue(app.exists(.id("agent-browser")), "the device's tab was brought to the front on the Mac")
        if case .refused(let why)? = ask(.stop(tab: own)) { XCTFail(why) }

        // Both closed from the device: the agent has no tab left.
        for closing in [own, tab] {
            if case .refused(let why)? = ask(.close(tab: closing)) { XCTFail(why) }
        }
        XCTAssertEqual(server.text("browser_tabs").text, "You have no tab. Open one with browser_open.")
    }

    /// PANE-19 (#69, #127): an agent with its page beside it and a shell
    /// under both, each in its row, in that order. The View menu's commands
    /// (⌥⌘ and ←, → or ↓) put the keyboard in its page, its shells and the
    /// agent again, and the row says which has it; the part it is in is
    /// shown alone, filling the area, and all of them again (⇧⌘Return); the
    /// button at the end of the row hides its page, and shows it again.
    func testTheKeyboardMovesAboutAnAgentsArea() throws {
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let page = root.appendingPathComponent("page.html")
        try "<!doctype html><title>One</title><p>A page</p>".write(to: page, atomically: true, encoding: .utf8)
        let opened = server.text("browser_open", ["url": page.absoluteString])
        let tab = try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
        let shellOpened = server.text("shell_open")
        XCTAssertFalse(shellOpened.failed, shellOpened.text)
        let phone = try device()
        wait("the agent's shell") { phone.sessions.contains { $0.openedBy == agent.id } }
        let shell = try XCTUnwrap(phone.sessions.first { $0.openedBy == agent.id })
        app.wait(for: .id("agent-browser"), timeout: 20)
        app.wait(for: .id("agent-shells"), timeout: 20)
        XCTAssertEqual(app.nodes().map(\.identifier).filter { $0.hasPrefix("item-") }, ["item-\(agent.id)", "item-b\(tab)", "item-\(shell.id)"])
        XCTAssertFalse(app.exists(.id("tab-\(shell.id)")), "the agent's shell has a tab of its own")
        /// The item of the row that says it has the keyboard.
        func keyboardItem() -> [String] { app.nodes().filter { $0.identifier.hasPrefix("item-") && $0.value == "has the keyboard" }.map(\.identifier) }

        app.press(.id("session-\(agent.id)"))
        app.waitForKeyboard(in: "terminal-\(agent.id)", "the agent")
        app.wait("the row says the agent has the keyboard") { keyboardItem() == ["item-\(agent.id)"] }
        app.menu(["View", "Keyboard to Its Page"])
        app.waitForKeyboard(in: "browser-\(tab)", page: true, "its page")
        app.wait("the row says its page has the keyboard") { keyboardItem() == ["item-b\(tab)"] }
        XCTAssertTrue(app.exists(.id("terminal-\(agent.id)")), "the agent is not shown beside its page")
        app.menu(["View", "Keyboard to Its Shells"])
        app.waitForKeyboard(in: "terminal-\(shell.id)", "its shell")
        shot("keyboard-in-its-shell")
        app.menu(["View", "Keyboard to the Agent"])
        app.waitForKeyboard(in: "terminal-\(agent.id)", "the agent again")

        // Its page alone, then all of them.
        app.menu(["View", "Keyboard to Its Page"])
        app.waitForKeyboard(in: "browser-\(tab)", page: true, "its page")
        app.menu(["View", "Show This Part Alone"])
        app.wait(for: .id("agent-alone"))
        app.wait("the shells and the agent hidden") { !self.app.exists(.id("agent-shells")) && !self.app.exists(.id("terminal-\(agent.id)")) }
        app.waitForKeyboard(in: "browser-\(tab)", page: true, "its page, alone")
        shot("page-alone")
        app.menu(["View", "Show This Part Alone"])
        app.wait("all of them again") { self.app.exists(.id("agent-shells")) && self.app.exists(.id("terminal-\(agent.id)")) && !self.app.exists(.id("agent-alone")) }

        // Its page hidden from the row: the keyboard goes to the agent, the
        // page stays open and in the row; shown again from the row.
        app.press(.id("agent-part-browser"))
        app.waitGone(.id("agent-browser"))
        app.waitForKeyboard(in: "terminal-\(agent.id)", "the agent, its page hidden")
        XCTAssertTrue(app.exists(.id("item-b\(tab)")), "a hidden page left the agent's row")
        let listed = server.text("browser_tabs").text
        XCTAssertTrue(listed.split(separator: "\n").contains { $0.hasPrefix("\(tab):") }, "hiding the page closed it: \(listed)")
        app.press(.id("item-b\(tab)"))
        app.wait(for: .id("agent-browser"))
        app.waitForKeyboard(in: "browser-\(tab)", page: true, "its page, picked in the row")
    }

    /// The id `browser_open` said it opened.
    private func tabID(_ opened: (text: String, failed: Bool)) throws -> String {
        XCTAssertFalse(opened.failed, opened.text)
        return try XCTUnwrap(opened.text.range(of: #"tab \d+"#, options: .regularExpression).map { String(opened.text[$0].dropFirst(4)) }, opened.text)
    }

    /// BROWSER-23: an agent chooses a file of its project for a file field,
    /// by a path from its folder, and the page has it. A file outside its
    /// project, one that is not there, and an element that is no file field
    /// are refused, with why.
    func testAnAgentUploadsAFileOfItsProject() throws {
        let (server, agent) = try startAgent()
        defer { server.stop() }
        let page = root.appendingPathComponent("upload.html")
        try """
        <!doctype html><title>Upload</title>
        <input type="file" id="file" aria-label="Report" onchange="document.title = 'got ' + [...this.files].map(f => f.name).join(',')">
        <button>Send</button>
        """.write(to: page, atomically: true, encoding: .utf8)
        try "hello".write(to: URL(fileURLWithPath: agent.cwd).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let tab = try tabID(server.text("browser_open", ["url": page.absoluteString]))
        let snapshot = server.text("browser_snapshot", ["tab": tab]).text
        let field = try XCTUnwrap(ref(in: snapshot, "\"Report\""), snapshot)
        let button = try XCTUnwrap(ref(in: snapshot, "button \"Send\""), snapshot)
        continueAfterFailure = true

        let chosen = server.text("browser_upload", ["tab": tab, "ref": field, "paths": ["report.txt"]])
        XCTAssertFalse(chosen.failed, chosen.text)
        wait("the page has the file") { server.text("browser_evaluate", ["tab": tab, "script": "document.title"]).text == "\"got report.txt\"" }
        let outside = server.text("browser_upload", ["tab": tab, "ref": field, "paths": ["/etc/hosts"]])
        XCTAssertTrue(outside.failed && outside.text.contains("is not a file of your project"), outside.text)
        let missing = server.text("browser_upload", ["tab": tab, "ref": field, "paths": ["not-there.txt"]])
        XCTAssertTrue(missing.failed && missing.text.contains("There is no file at"), missing.text)
        let notAField = server.text("browser_upload", ["tab": tab, "ref": button, "paths": ["report.txt"]])
        XCTAssertTrue(notAField.failed && notAField.text.contains("not a file field"), notAField.text)
    }

    /// BROWSER-24: a sign-in kept by a profile, on a server of the Mac's
    /// own: the agent signs in in one tab, and its second tab is signed in;
    /// its private tab is not, nor a tab of another profile.
    func testASignInIsTheProfilesOnly() throws {
        let folder = root.appendingPathComponent("signs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<!doctype html><title>Sign in</title><button onclick=\"document.cookie = 'who=bo; path=/'; document.title = 'In'\">Sign in</button>"
            .write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Who</title><script>document.title = document.cookie.includes('who=bo') ? 'Signed in' : 'Signed out'</script>"
            .write(to: folder.appendingPathComponent("who.html"), atomically: true, encoding: .utf8)
        let serverPort = port + 501
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
        let site = "http://127.0.0.1:\(serverPort)/"

        let (server, _) = try startAgent()
        defer { server.stop() }
        func title(_ tab: String) -> String { server.text("browser_evaluate", ["tab": tab, "script": "document.title"]).text }
        let signing = try tabID(server.text("browser_open", ["url": site]))
        let button = try XCTUnwrap(ref(in: server.text("browser_snapshot", ["tab": signing]).text, "button \"Sign in\""))
        XCTAssertFalse(server.text("browser_click", ["tab": signing, "ref": button]).failed)
        wait("signed in") { title(signing) == "\"In\"" }
        continueAfterFailure = true
        XCTAssertEqual(title(try tabID(server.text("browser_open", ["url": site + "who.html"]))), "\"Signed in\"", "the profile's second tab")
        XCTAssertEqual(title(try tabID(server.text("browser_open", ["url": site + "who.html", "private": true]))), "\"Signed out\"", "a private tab")

        // Another profile, which another agent names.
        app.press(.id("place-settings"))
        app.press(.id("settings-browser"))
        app.press(.id("profile-new"))
        app.wait(for: .id("profile-name-Profile 2"))
        app.press(.id("place-sessions"))
        let (other, _) = try startAgent()
        defer { other.stop() }
        let elsewhere = try tabID(other.text("browser_open", ["url": site + "who.html", "profile": "Profile 2"]))
        XCTAssertEqual(other.text("browser_evaluate", ["tab": elsewhere, "script": "document.title"]).text, "\"Signed out\"", "another profile's tab")
    }

    /// BROWSER-25: a page's frames are named in its snapshot, with their
    /// addresses, their insides not read; a frame's page opened in the tab
    /// is read.
    func testASnapshotNamesThePagesFrames() throws {
        let folder = root.appendingPathComponent("framed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<!doctype html><title>Inner</title><button>Inside</button>".write(to: folder.appendingPathComponent("inner.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Framed</title><p>Outside</p><iframe src=\"inner.html\"></iframe><iframe src=\"inner.html?2\"></iframe>"
            .write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let (server, _) = try startAgent()
        defer { server.stop() }
        let tab = try tabID(server.text("browser_open", ["url": folder.appendingPathComponent("index.html").absoluteString]))
        let inner = folder.appendingPathComponent("inner.html").absoluteString
        let snapshot = server.text("browser_snapshot", ["tab": tab]).text
        XCTAssertTrue(snapshot.contains(BrowserWords.frames([inner, inner + "?2"])), snapshot)
        XCTAssertNil(ref(in: snapshot, "button \"Inside\""), "a frame's insides were read")
        XCTAssertFalse(server.text("browser_navigate", ["tab": tab, "url": inner]).failed)
        XCTAssertNotNil(ref(in: server.text("browser_snapshot", ["tab": tab]).text, "button \"Inside\""), "the frame's page opened in the tab is not read")
    }

    /// BROWSER-26: what changes under an agent while it acts: a link it
    /// clicked took the page elsewhere, which it is told, and a ref of the
    /// page before is refused as such; the tab closed by a device is no
    /// longer its, and it is told so.
    func testWhatChangesUnderAnAgent() throws {
        let page = try makeSite()
        let (server, _) = try startAgent()
        defer { server.stop() }
        let tab = try tabID(server.text("browser_open", ["url": page.absoluteString]))
        let snapshot = server.text("browser_snapshot", ["tab": tab]).text
        let link = try XCTUnwrap(ref(in: snapshot, "link \"Next page\""), snapshot)
        let field = try XCTUnwrap(ref(in: snapshot, "textbox \"Name\""), snapshot)
        let clicked = server.text("browser_click", ["tab": tab, "ref": link])
        XCTAssertFalse(clicked.failed, clicked.text)
        XCTAssertTrue(clicked.text.contains("second.html"), "not told where the page went: \(clicked.text)")
        let stale = server.text("browser_type", ["tab": tab, "ref": field, "text": "Bo"])
        XCTAssertTrue(stale.failed, stale.text)
        XCTAssertEqual(stale.text, BrowserWords.staleRef(field))

        let phone = try device()
        phone.send(.browserAsk(id: 3001, request: .close(tab: tab)))
        wait("closed") { phone.messages.contains { if case .browserAnswer(3001, _) = $0 { return true } else { return false } } }
        let gone = server.text("browser_snapshot", ["tab": tab])
        XCTAssertTrue(gone.failed, gone.text)
        XCTAssertEqual(gone.text, BrowserWords.notYours(tab))
    }

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
            app.wait("a new tab") { self.app.nodes().filter { $0.identifier.hasPrefix("item-b") }.count == tabs.count + 1 }
            let id = try XCTUnwrap(app.nodes().map(\.identifier).first { $0.hasPrefix("item-b") && !tabs.contains($0) })
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

    /// BROWSER-38 (#125), by hand only (`AGENTTERM_EXTENSION_TRIAL=1
    /// scripts/test-mac.sh ExtensionTrial`): an extension from the Chrome
    /// Web Store is installed in the test's own profile; the window of
    /// Chrome's own it opens is held back and said in the Browser tab, and
    /// shown when asked for. It reaches Google's site.
    func testExtensionTrial() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_EXTENSION_TRIAL"] != nil, "reaches the Web Store: run by hand")
        func windows() -> [String] {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            return list.compactMap { info -> String? in
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                guard owner.contains("AgentTerm") else { return nil }
                let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
                return
                    "\(owner) pid=\(info[kCGWindowOwnerPID as String] ?? 0) layer=\(info[kCGWindowLayer as String] ?? 0) title=\(info[kCGWindowName as String] ?? "") \(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)"
            }
        }
        print("MEASURE windows before: \(windows())")
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write("https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh", into: .id("browser-address"), confirm: true)
        app.wait(for: .containing("Add to Chrome"), timeout: 60)
        shot("store")
        app.press(.containing("Add to Chrome"))
        Thread.sleep(forTimeInterval: 6)
        shot("after-add")
        print("MEASURE windows after Add: \(windows())")
        let texts = app.nodes().map(\.text).filter { $0.contains("extension") || $0.contains("Extension") || $0.contains("Add") }
        print("MEASURE texts after Add: \(texts.prefix(20))")
        app.press(.containing("Add extension"), timeout: 20)
        Thread.sleep(forTimeInterval: 10)
        print("MEASURE windows after install: \(windows())")
        shot("after-install")
        // Installed, the extension opens a page of its own: in a window of
        // Chrome's, which is held back and said in the Browser tab.
        app.wait(for: .id("browser-held-window"), timeout: 30)
        XCTAssertFalse(windows().contains { $0.contains("title=Help") }, "Chrome's window opened by itself")
        app.press(.id("browser-open-held"))
        wait("Chrome's window, asked for", timeout: 20) { self.windowsNamed("Dark Reader") }
        print("MEASURE windows after Open in Chrome Window: \(windows())")
        Thread.sleep(forTimeInterval: 2)
        print("MEASURE held after: \(app.nodes().filter { $0.text.contains("of its own") }.map(\.text))")
    }

    private func windowsNamed(_ text: String) -> Bool {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String ?? "").contains("AgentTerm") && ($0[kCGWindowName as String] as? String ?? "").contains(text) }
    }

    /// BROWSER-37 (#131): a right click in a page opens a menu as Chrome's:
    /// on a link, Open Link in New Tab and Copy Link Address; on the page,
    /// Back, Forward, Reload; Inspect always. Reload reads the page again,
    /// as it is on disk by then. Open Link in New Tab opens the link as
    /// another page of the Browser tab. Copy is not pressed: it would write
    /// to the user's pasteboard.
    ///
    /// A menu that is open closes when another app comes to the front
    /// (#135): the Mac is left alone while this runs.
    func testARightClickOpensAMenuAsChromes() throws {
        let two = root.appendingPathComponent("two.html")
        try "<!doctype html><title>Two</title><body>Two</body>".write(to: two, atomically: true, encoding: .utf8)
        let one = root.appendingPathComponent("one.html")
        try #"<!doctype html><title>One</title><body><p>The first page</p><p><a href="two.html">Go to two</a></p></body>"#.write(to: one, atomically: true, encoding: .utf8)
        func pages() -> [String] { app.nodes().map(\.identifier).filter { $0.hasPrefix("item-b") } }
        app.menu(["Browser", "New Browser Tab"])
        app.wait("the first page") { pages().count == 1 }
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(one.absoluteString, into: .id("browser-address"), confirm: true)
        app.wait("One shown") { self.app.value(of: .id("browser-page")) == "One" }

        // The items of the menu that is open, and not the window's.
        func item(_ title: String) -> Node? {
            app.nodes(menus: true).first { $0.role == kAXMenuItemRole && ($0.title == title || $0.label == title) }
        }
        func choose(_ title: String) {
            guard let node = item(title) else { return XCTFail("no item \(title)") }
            AXUIElementPerformAction(node.element, kAXPressAction as CFString)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        // On the page.
        app.perform("AXShowMenu", on: .containing("The first page"), timeout: 20)
        wait("the page's menu") { item("Reload") != nil }
        shot("page-menu")
        XCTAssertNotNil(item("Back"))
        XCTAssertNotNil(item("Forward"))
        XCTAssertNotNil(item("Inspect"))
        XCTAssertNil(item("Open Link in New Tab"), "a link's items on the page")
        // The file is another by now: Reload reads it again, and the test
        // goes on once it has.
        try #"<!doctype html><title>One</title><body><p>The page, read again</p><p><a href="two.html">Go to two</a></p></body>"#.write(to: one, atomically: true, encoding: .utf8)
        choose("Reload")
        wait("the menu closed") { item("Reload") == nil }
        app.wait(for: .containing("The page, read again"), timeout: 20)
        XCTAssertEqual(app.value(of: .id("browser-page")), "One")

        // On the link.
        app.perform("AXShowMenu", on: .containing("Go to two"), timeout: 20)
        wait("the link's menu") { item("Open Link in New Tab") != nil }
        shot("link-menu")
        XCTAssertNotNil(item("Copy Link Address"))
        XCTAssertNotNil(item("Inspect"))
        XCTAssertNil(item("Reload"), "the page's items on a link")
        choose("Open Link in New Tab")
        app.wait("the link opened as another page") { pages().count == 2 }
        app.wait("Two shown") { self.app.value(of: .id("browser-page")) == "Two" }
    }

    /// BROWSER-41 (#139): Chromium's work goes on while a right-click menu
    /// is open in a page. A page that changes its own title several times a
    /// second goes on being shown with the title it has, the menu open and
    /// left open: what the page tells the app (its title, that it was read
    /// again, an agent's answer) does not wait for the menu to close.
    ///
    /// The Mac is left alone while this runs: a menu that is open closes
    /// when another app comes to the front.
    func testChromiumsWorkGoesOnWhileARightClickMenuIsOpen() throws {
        let page = root.appendingPathComponent("ticks.html")
        try #"<!doctype html><title>Tick 0</title><body><p>The page that ticks</p><script>let n = 0; setInterval(() => { document.title = "Tick " + (++n) }, 200)</script></body>"#
            .write(to: page, atomically: true, encoding: .utf8)
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(page.absoluteString, into: .id("browser-address"), confirm: true)
        func tick() -> Int { Int((app.value(of: .id("browser-page")) ?? "").replacingOccurrences(of: "Tick ", with: "")) ?? -1 }
        app.wait("the page ticking") { tick() > 2 }

        func item(_ title: String) -> Node? {
            app.nodes(menus: true).first { $0.role == kAXMenuItemRole && ($0.title == title || $0.label == title) }
        }
        app.perform("AXShowMenu", on: .containing("The page that ticks"), timeout: 20)
        wait("the page's menu") { item("Reload") != nil }
        // Open, and left open: the title goes on.
        let opened = tick()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertNotNil(item("Reload"), "the menu closed by itself: is another app in front? \(app.screen().prefix(200))")
        let later = tick()
        XCTAssertGreaterThan(later, opened + 3, "the page's title stood still while the menu was open: \(opened), then \(later) two seconds later")
        shot("menu-open-page-ticking")
        // Closed without a choice.
        if let menu = app.nodes(menus: true).first(where: { $0.role == kAXMenuRole }) { AXUIElementPerformAction(menu.element, kAXCancelAction as CFString) }
        wait("the menu closed") { item("Reload") == nil }
        let closed = tick()
        app.wait("the page ticking after") { tick() > closed + 2 }
    }

    /// BROWSER-30: the user's pages are one Browser tab of the strip, as a
    /// window of Chrome holds its tabs: a row of them under the strip, a
    /// button for one more, each shown when picked; a page closed shows the
    /// one beside it, and closing the tab, of several pages, is asked first.
    func testTheUsersPagesAreOneBrowserTab() throws {
        func page(_ name: String) throws -> URL {
            let file = root.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><body>\(name)</body>".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func pages() -> [String] { app.nodes().map(\.identifier).filter { $0.hasPrefix("item-b") } }
        func load(_ name: String) throws {
            app.wait(for: .id("browser-address"), timeout: 20)
            app.write(try page(name).absoluteString, into: .id("browser-address"), confirm: true)
            app.wait("\(name) shown") { self.app.value(of: .id("browser-page")) == name }
        }
        app.menu(["Browser", "New Browser Tab"])
        app.wait("the first page") { pages().count == 1 }
        try load("One")
        XCTAssertEqual(app.first(.id("strip-browser"))?.label, "Browser")
        // One more, from the button in the tab.
        app.press(.id("browser-new-page"))
        app.wait("a second page") { pages().count == 2 }
        try load("Two")
        app.press(.id("browser-new-page"))
        app.wait("a third page") { pages().count == 3 }
        try load("Three")
        // Still one tab of the strip, which says how many it holds.
        XCTAssertEqual(app.nodes().filter { $0.identifier == "strip-browser" }.count, 1)
        XCTAssertEqual(app.first(.id("strip-browser"))?.label, "Browser, 3 pages")
        let all = pages()
        app.press(.id(all[0]))
        app.wait("the first page shown again") { self.app.value(of: .id("browser-page")) == "One" }
        // Closed, the page beside it is shown.
        app.perform("Close Tab", on: .id(all[0]))
        app.wait("two pages left") { pages().count == 2 }
        app.wait("the page beside it shown") { self.app.value(of: .id("browser-page")) == "Two" }
        shot("browser-tab")
        // The tab closed with several pages: asked first.
        app.perform("Close Browser", on: .id("strip-browser"))
        app.wait(for: .text("Close 2 pages?"))
        app.press(.button("Cancel"))
        XCTAssertEqual(pages().count, 2)
        app.perform("Close Browser", on: .id("strip-browser"))
        app.press(.button("Close 2 Pages"))
        app.wait("the Browser tab gone") { pages().isEmpty && !self.app.exists(.id("strip-browser")) }
        // With one page, it closes without a question.
        app.menu(["Browser", "New Browser Tab"])
        app.wait("a page again") { pages().count == 1 }
        app.perform("Close Browser", on: .id("strip-browser"))
        app.wait("gone again") { pages().isEmpty && !self.app.exists(.id("strip-browser")) }
    }

    /// BROWSER-36 (#122): the sidebar holds the user's pages as the strip
    /// does: one Browser row in the project, the pages under it. A page's
    /// row shows that page; the Browser row shows the page the Browser tab
    /// shows; closed from its menu, it asks first when there are several.
    func testTheSidebarHoldsTheUsersPagesInOneBrowserRow() throws {
        func page(_ name: String) throws -> URL {
            let file = root.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><body>\(name)</body>".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func pages() -> [String] { app.nodes().map(\.identifier).filter { $0.hasPrefix("item-b") } }
        func load(_ name: String) throws {
            app.wait(for: .id("browser-address"), timeout: 20)
            app.write(try page(name).absoluteString, into: .id("browser-address"), confirm: true)
            app.wait("\(name) shown") { self.app.value(of: .id("browser-page")) == name }
        }
        /// The sidebar's row of a page, by its title.
        func row(_ name: String) -> String? { app.nodes().first { $0.identifier.hasPrefix("browser-row-") && $0.label == "\(name), page" }?.identifier }
        app.press(.id("folder-\(project.path)"))
        app.menu(["Browser", "New Browser Tab"])
        app.wait("the first page") { pages().count == 1 }
        try load("One")
        for (count, name) in [(2, "Two"), (3, "Three")] {
            app.press(.id("browser-new-page"))
            app.wait("page \(count)") { pages().count == count }
            try load(name)
        }
        // One Browser row, its three pages under it.
        app.wait(for: .id("sidebar-browser"), timeout: 10)
        XCTAssertEqual(app.nodes().filter { $0.identifier == "sidebar-browser" }.count, 1)
        XCTAssertEqual(app.first(.id("sidebar-browser"))?.label, "Browser, 3 pages")
        let all = app.nodes()
        let group = try XCTUnwrap(all.firstIndex { $0.identifier == "sidebar-browser" })
        let rows = all.indices.filter { all[$0].identifier.hasPrefix("browser-row-") }
        XCTAssertEqual(rows.count, 3, "the pages' rows")
        XCTAssertTrue(rows.allSatisfy { $0 > group }, "a page's row is not under the Browser row")
        shot("sidebar-browser")
        // A page's row shows that page.
        app.press(.id(try XCTUnwrap(row("Two"))))
        app.wait("Two shown from its row") { self.app.value(of: .id("browser-page")) == "Two" }
        // With a shell in front, the Browser row shows the page its tab shows.
        app.press(.button("Shell"))
        app.wait("the page gone behind the shell") { self.app.value(of: .id("browser-page")) == nil }
        app.press(.id("sidebar-browser"))
        app.wait("Two shown from the Browser row") { self.app.value(of: .id("browser-page")) == "Two" }
        // Closed from its row: asked first, then all three go.
        app.perform("Close Browser", on: .id("sidebar-browser"))
        app.wait(for: .text("Close 3 pages?"))
        app.press(.button("Close 3 Pages"))
        app.wait("the Browser row gone") { !self.app.exists(.id("sidebar-browser")) && row("One") == nil && pages().isEmpty }
    }

    /// BROWSER-33 (#111): the user's pages and an agent's are never mixed,
    /// whichever is opened first, though both use one profile: the user's
    /// are in the Browser tab and the agent does not list them; the agent's
    /// are in its tab and not in the Browser tab.
    func testTheUsersPagesAndAnAgentsAreNotMixed() throws {
        func page(_ name: String) throws -> URL {
            let file = root.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><body>\(name)</body>".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        /// The pages of the row of the tab in front, by their names.
        func pages(in part: String = "group-row") -> [String] {
            let all = app.nodes()
            guard let start = all.firstIndex(where: { $0.identifier == part }) else { return [] }
            let depth = all[start].depth
            return all[(start + 1)...].prefix { $0.depth > depth }.filter { $0.role == "AXButton" && ["Mine", "Mine too", "Agents", "Agents too"].contains($0.label) }.map(\.label)
        }
        // The user's first, in the project the agent will be started in:
        // each project has a Browser tab of its own.
        app.press(.id("folder-\(project.path)"))
        app.menu(["Browser", "New Browser Tab"])
        app.wait(for: .id("browser-address"), timeout: 20)
        app.write(try page("Mine").absoluteString, into: .id("browser-address"), confirm: true)
        app.wait("the user's page") { self.app.value(of: .id("browser-page")) == "Mine" }
        // Then an agent's.
        let (server, _) = try startAgent()
        defer { server.stop() }
        // The agent is in front, started just now.
        app.wait(for: .id("tab-1"), timeout: 10)
        let opened = server.text("browser_open", ["url": try page("Agents").absoluteString])
        XCTAssertFalse(opened.failed, opened.text)
        app.wait("the agent's page in its row, not \(pages())", timeout: 20) { pages() == ["Agents"] }
        XCTAssertEqual(server.text("browser_tabs").text.split(separator: "\n").count, 1, "the agent lists a page that is not its own")
        XCTAssertTrue(server.text("browser_tabs").text.contains("Agents"))
        // One more of the user's, from the header, while the agent's tab is in front.
        app.menu(["Browser", "New Browser Tab"])
        app.wait("a second page of the user's") { self.app.nodes().filter { $0.identifier.hasPrefix("item-b") }.count == 2 }
        app.write(try page("Mine too").absoluteString, into: .id("browser-address"), confirm: true)
        app.wait("the user's second page") { self.app.value(of: .id("browser-page")) == "Mine too" }
        XCTAssertEqual(pages(), ["Mine", "Mine too"], "the user's Browser tab")
        // And one more of the agent's.
        XCTAssertFalse(server.text("browser_open", ["url": try page("Agents too").absoluteString]).failed)
        wait("the agent to list its two") { server.text("browser_tabs").text.split(separator: "\n").count == 2 }
        let listed = server.text("browser_tabs").text
        XCTAssertFalse(listed.contains("Mine"), "the agent lists the user's page: \(listed)")
        // Back to the agent: its two in its row, none of the user's.
        app.press(.id("tab-1"))
        app.wait("the agent's two pages in its row, not \(pages())") { Set(pages()) == ["Agents", "Agents too"] }
        app.press(.id("strip-browser"))
        app.wait("the user's two pages in the Browser tab, not \(pages())") { pages() == ["Mine", "Mine too"] }
        XCTAssertEqual(app.first(.id("strip-browser"))?.label, "Browser, 2 pages")
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
        XCTAssertFalse(app.nodes().contains { $0.identifier.hasPrefix("browser-row-") || $0.identifier.hasPrefix("item-b") }, "a tab came back")
    }
}
