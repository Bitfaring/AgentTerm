import AgentTermProtocol
import XCTest

/// Using another Mac from this one: a second host stands in for it.
final class RemoteMacTests: MacUITestCase {
    private var otherState: URL!
    private var otherHome: URL!
    private var otherProject: URL!
    private var otherPort: UInt16 = 0

    private func startOtherMac(alsoWith folders: [URL] = []) throws {
        otherState = root.appendingPathComponent("other/state")
        otherHome = root.appendingPathComponent("other/home")
        otherProject = root.appendingPathComponent("other/work")
        for folder in [otherState!, otherHome!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: otherHome.appendingPathComponent("Sites/blog"), withIntermediateDirectories: true)
        try makeRepository(otherProject, remote: nil)
        try write("first line\nchanged on the other Mac\n", to: "notes.txt", in: otherProject)
        try JSONEncoder().encode([otherProject.path] + folders.map(\.path)).write(to: otherState.appendingPathComponent("folders.json"))
        otherPort = port + 200
        try startHost(state: otherState, home: otherHome, port: otherPort)
    }

    /// Pairs with the other Mac, on its host's port or on one in front of it.
    private func pair(through port: UInt16? = nil) {
        let link = pairingLink(state: otherState, port: port ?? otherPort, name: "Other Mac")
        XCTAssertFalse(link.isEmpty, "the other host gave no pairing link")
        app.press(.id("mac-switcher"))
        app.press(.button("Pair with Another Mac…"), menus: true)
        app.write(link, into: .id("pair-mac-link"), confirm: true)
        wait("the other Mac to be on screen", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == "Other Mac" }
    }

    /// REMOTE-27's app notes each answer of the other Mac's browser.
    override func beforeTheAppStarts() throws {
        if name.contains("ThisMacSwitches") { appEnvironment["AGENTTERM_BROWSER_ANSWERS"] = root.appendingPathComponent("browser-answers").path }
    }

    private func switchTo(_ name: String) {
        app.press(.id("mac-switcher"))
        app.press(.button(name), menus: true)
        wait("\(name) to be on screen", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == name }
    }

    /// REMOTE-22 (#147): the other Mac's browser is used from here, as the
    /// iPhone uses it: its pages listed, one shown from the pictures that
    /// Mac sends while it is watched, a click sent there, a new page opened
    /// there and shown here. A stand-in for its app answers as the app does.
    func testTheOtherMacsBrowserIsUsedFromHere() throws {
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        XCTAssertFalse(app.exists(.id("browser-pick")), "picking is offered for a page of the other Mac")

        func calls() -> [(id: Int, request: BrowserRequest)] {
            browser.messages.compactMap { if case .browserCall(let id, _, let request) = $0 { return (id, request) } else { return nil } }
        }
        wait("the page watched", timeout: 15) { calls().contains { if case .watch("7", true, _) = $0.request { return true } else { return false } } }
        for call in calls() { browser.send(.browserReply(id: call.id, result: .text("Watching tab 7."))) }
        // A red page, as the other Mac's would send a picture of it.
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        image.unlockFocus()
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .jpeg, properties: [:]))
        browser.send(.browserFrame(tab: "7", jpeg: jpeg, width: 400, height: 200))
        let page = try XCTUnwrap(app.frame(of: .id("remote-page")))
        var seen = "nothing"
        var drawn = false
        let deadline = Date().addingTimeInterval(15)
        while !drawn, Date() < deadline {
            if let color = app.color(at: CGPoint(x: page.minX + 20, y: page.minY + 20))?.usingColorSpace(.sRGB) {
                seen = "\(color)"
                // Red through a JPEG and the display's colours (about 0.82,
                // 0.29, 0.13), against the dark the view shows before a picture.
                drawn = color.redComponent > 0.6 && color.redComponent - color.greenComponent > 0.3
            }
            if !drawn { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        }
        XCTAssertTrue(drawn, "the picture is not drawn: at \(page) the window has \(seen)")
        shot("remote-page")

        // A click there, at the page's point.
        app.press(.id("remote-page"))
        wait("the click sent", timeout: 15) { calls().contains { if case .tap("7", _, _) = $0.request { return true } else { return false } } }
        // Answered, as that Mac's app answers it: what comes after it waits for that (#199).
        for call in calls() { if case .tap = call.request { browser.send(.browserReply(id: call.id, result: .text("Tapped."))) } }

        // ⌘C: what is selected there is asked for. Answered with nothing, so
        // that the test leaves this Mac's pasteboard as it is.
        app.menu(["Edit", "Copy"])
        wait("the selection asked for", timeout: 15) { calls().contains { if case .copy("7") = $0.request { return true } else { return false } } }
        for call in calls() where call.request == .copy(tab: "7") { browser.send(.browserReply(id: call.id, result: .text(""))) }
        // A right click: a menu of this Mac's, made from what is at that
        // point there; its link opened there.
        app.perform("AXShowMenu", on: .id("remote-page"))
        wait("what is at the point asked for", timeout: 15) { calls().contains { if case .contextAt("7", _, _) = $0.request { return true } else { return false } } }
        let context = try XCTUnwrap(calls().last { if case .contextAt = $0.request { return true } else { return false } })
        browser.send(.browserReply(id: context.id, result: .context(link: "http://localhost:3000/far", selection: "")))
        app.wait(for: .button(BrowserWords.PageMenu.openLink), timeout: 15, menus: true)
        app.wait(for: .button(BrowserWords.PageMenu.copyLink), menus: true)
        shot("remote-page-menu")
        app.press(.button(BrowserWords.PageMenu.openLink), menus: true)
        wait("the link opened there", timeout: 15) {
            calls().contains { if case .newTab(_, "http://localhost:3000/far", _, _) = $0.request { return true } else { return false } }
        }

        // A new page: opened on the other Mac, shown here once it is listed.
        app.menu(["Browser", "New Browser Tab"])
        wait("a new page asked for", timeout: 15) { calls().contains { if case .newTab(_, nil, _, _) = $0.request { return true } else { return false } } }
        let asked = try XCTUnwrap(calls().last { if case .newTab(_, nil, _, _) = $0.request { return true } else { return false } })
        browser.send(
            .browserTabs([
                BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default"),
                BrowserTabInfo(id: "8", title: "", url: "", project: "", profile: "Default"),
            ]))
        browser.send(.browserReply(id: asked.id, result: .opened(tab: "8")))
        app.wait(for: .id("browser-8"), timeout: 15)
    }

    /// REMOTE-25 (#196): what this Mac asked of the other Mac's browser,
    /// still not answered when the connection to that Mac closes, is
    /// answered at once and said, with why: it was left waiting, and
    /// nothing said so.
    func testWhatWaitsForTheOtherMacsBrowserIsAnsweredWhenTheConnectionCloses() throws {
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        func calls() -> [(id: Int, request: BrowserRequest)] {
            browser.messages.compactMap { if case .browserCall(let id, _, let request) = $0 { return (id, request) } else { return nil } }
        }
        wait("the page watched", timeout: 15) { calls().contains { if case .watch("7", true, _) = $0.request { return true } else { return false } } }
        for call in calls() { browser.send(.browserReply(id: call.id, result: .text("Watching tab 7."))) }

        // ⌘C asked there, and not answered by that Mac's browser.
        app.press(.id("remote-page"))
        app.menu(["Edit", "Copy"])
        wait("the selection asked for", timeout: 15) { calls().contains { if case .copy("7") = $0.request { return true } else { return false } } }
        XCTAssertNil(app.first(.containing(BrowserWords.otherMacClosed("Other Mac"))), "said before the connection closed")

        // The connection closes, as when that Mac's host stops.
        killHost(on: otherPort)
        app.wait(for: .containing(BrowserWords.otherMacClosed("Other Mac")), timeout: 20)
        shot("remote-browser-gone")
        app.press(.button("OK"))
    }

    /// REMOTE-27 (#196): what this Mac asked of the other Mac's browser,
    /// still not answered when the user switches to this Mac, is answered
    /// at once, refused in the words of a closed connection, and not said:
    /// the user asked for the switch. Before the fix the switch emptied the
    /// table of what waited without answering any of it. Seen through
    /// `AGENTTERM_BROWSER_ANSWERS`, the app's note of each answer.
    func testWhatWaitsForTheOtherMacsBrowserIsAnsweredWhenThisMacSwitches() throws {
        let answers = root.appendingPathComponent("browser-answers")
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        func calls() -> [(id: Int, request: BrowserRequest)] {
            browser.messages.compactMap { if case .browserCall(let id, _, let request) = $0 { return (id, request) } else { return nil } }
        }
        wait("the page watched", timeout: 15) { calls().contains { if case .watch("7", true, _) = $0.request { return true } else { return false } } }
        for call in calls() { browser.send(.browserReply(id: call.id, result: .text("Watching tab 7."))) }
        func refused() -> Int {
            ((try? String(contentsOf: answers, encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { $0 == "refused " + BrowserWords.otherMacClosed("Other Mac") }.count
        }

        // ⌘C asked there, and not answered by that Mac's browser.
        app.press(.id("remote-page"))
        app.menu(["Edit", "Copy"])
        wait("the selection asked for", timeout: 15) { calls().contains { if case .copy("7") = $0.request { return true } else { return false } } }
        XCTAssertEqual(refused(), 0, "answered before the switch")

        // The user switches to this Mac: it is answered, and nothing is said.
        switchTo("This Mac")
        wait("what waited answered", timeout: 10) { refused() > 0 }
        XCTAssertNil(app.first(.containing(BrowserWords.otherMacClosed("Other Mac"))), "a switch the user asked for was said")
        shot("switched")
    }

    /// BROWSER-54 (#199): what is done on the other Mac's page waits for
    /// what was done there before it to be answered, as the mouse's events
    /// do: a click right after ⌘C, whose answer that Mac's stand-in holds
    /// back, is sent once the copy is answered, not before. The keys, text
    /// typed and the wheel wait in the same queue (`PageInputQueueTests`),
    /// which accessibility cannot make: it presses, it cannot type into a
    /// picture nor turn a wheel. Before the fix the click, as the keys and
    /// the wheel, was sent at once, past what waited.
    func testWhatIsDoneOnTheOtherMacsPageWaitsForWhatWasDoneBeforeIt() throws {
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        func calls() -> [(id: Int, request: BrowserRequest)] {
            browser.messages.compactMap { if case .browserCall(let id, _, let request) = $0 { return (id, request) } else { return nil } }
        }
        func taps() -> [Int] { calls().compactMap { if case .tap("7", _, _) = $0.request { return $0.id } else { return nil } } }
        wait("the page watched", timeout: 15) { calls().contains { if case .watch("7", true, _) = $0.request { return true } else { return false } } }
        for call in calls() { browser.send(.browserReply(id: call.id, result: .text("Watching tab 7."))) }
        // A picture of the page, which a press clicks in the middle of.
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        image.unlockFocus()
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .jpeg, properties: [:]))
        browser.send(.browserFrame(tab: "7", jpeg: jpeg, width: 400, height: 200))

        // Drawn: white, against the dark the view shows before a picture.
        // Looked for well inside the picture, 100 points down, and where
        // the view is read each time: the page moved 24 points down within
        // a second of being shown, before the line of figures had its place
        // from the start (#206, SYS-4), and a point 20 points down was in
        // the picture at one look and above it at the next.
        wait("the picture drawn", timeout: 15) {
            guard let page = self.app.frame(of: .id("remote-page")),
                let color = self.app.color(at: CGPoint(x: page.midX, y: page.minY + 100))?.usingColorSpace(.sRGB)
            else { return false }
            return color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7
        }

        // A first click, answered: the keyboard and Edit's commands go to the page.
        app.press(.id("remote-page"))
        wait("the click sent", timeout: 15) { !taps().isEmpty }
        for id in taps() { browser.send(.browserReply(id: id, result: .text("Tapped."))) }
        let clicked = taps().count

        // ⌘C asked there, its answer held back by that Mac's stand-in.
        app.menu(["Edit", "Copy"])
        wait("the selection asked for", timeout: 15) { calls().contains { if case .copy("7") = $0.request { return true } else { return false } } }
        let copy = try XCTUnwrap(calls().last { $0.request == .copy(tab: "7") })
        // A click right after it waits for its answer.
        app.press(.id("remote-page"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(taps().count, clicked, "the click was sent before the copy before it was answered")
        // Answered with nothing, so that the test leaves this Mac's pasteboard as it is.
        browser.send(.browserReply(id: copy.id, result: .text("")))
        wait("the click sent once the copy is answered", timeout: 15) { taps().count == clicked + 1 }
    }

    /// SYS-4 (#206): the line of the Mac's figures has its place from the
    /// start, so the page under it does not move when they come. Before
    /// the fix the line was not there until the host's first figures, which
    /// came a moment after the other Mac's page was shown, and the page
    /// moved 24 points down: read at (344, 187, 821, 705), then at
    /// (344, 211, 821, 681).
    func testTheOtherMacsPageStaysWhereItIsShownWhenTheFiguresCome() throws {
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        let first = try XCTUnwrap(app.frame(of: .id("remote-page")))
        shot("first")
        // The figures, measured: a number where the line had none.
        wait("the other Mac's figures", timeout: 15) { self.app.first(.id("system-cpu"))?.label.contains { $0.isNumber } ?? false }
        // Accessibility tells of a move a moment after it is drawn.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let later = try XCTUnwrap(app.frame(of: .id("remote-page")))
        shot("later")
        XCTAssertEqual(first, later, "the page moved once it was shown")
    }

    func testPairingShowsTheOtherMacAndWorkingOnItChangesItsDisk() throws {
        try startOtherMac()
        // REMOTE-1.
        pair()
        // REMOTE-2: its folder, not this Mac's.
        app.wait(for: .text("work, folder"), timeout: 15)
        XCTAssertFalse(app.exists(.text("project, folder")), "this Mac's folder is listed under the other Mac")
        // REMOTE-7: what only this Mac can do is not offered.
        XCTAssertFalse(app.exists(.button("Pair Device")))

        // REMOTE-3: stage and commit there.
        app.press(.button("Git"))
        app.press(.button("Stage notes.txt"), timeout: 15)
        app.wait(for: .button("Unstage notes.txt"), timeout: 15)
        app.write("fix: from this Mac", into: .text("Commit message"), confirm: true)
        app.press(.containing("Commit 1 File"))
        wait("the commit on the other Mac's disk", timeout: 15) { self.git("log", "-1", "--format=%s", in: self.otherProject) == "fix: from this Mac" }
        app.wait(for: .containing("No uncommitted changes"), timeout: 15)

        // Open a file there, change it, save: the other Mac's disk has it.
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the other Mac's file in the editor", timeout: 15) { self.app.value(of: editor) == "first line\nchanged on the other Mac\n" }
        app.write("first line\nchanged on the other Mac\nand from here\n", into: editor)
        // REMOTE-9: not while a file has changes that are not saved.
        app.press(.id("mac-switcher"))
        app.press(.button("This Mac"), menus: true)
        app.wait(for: .containing("Save or discard the changes"))
        XCTAssertEqual(app.first(.id("mac-switcher"))?.value, "Other Mac")
        app.menu(["File", "Save"])
        wait("the file on the other Mac's disk", timeout: 15) { self.read("notes.txt", in: self.otherProject) == "first line\nchanged on the other Mac\nand from here\n" }

        // A change's diff, which comes after the list it was picked in.
        app.press(.button("Git"))
        app.press(.id("change-notes.txt"), timeout: 15)
        app.wait(for: .containing("+and from here"), timeout: 15)
    }

    /// REMOTE-21 (#116): on another Mac too, the fetch the app makes by
    /// itself holds no button, and what is asked for while it is under way
    /// is done when it is over. This is where a push was lost at times: the
    /// app asks the other Mac's remotes about when REMOTE-12 presses Push.
    func testWhatIsAskedWhileTheAppFetchesByItselfIsDoneAfterOnTheOtherMac() throws {
        // A second folder on the other Mac, whose remote is slow to answer
        // a fetch.
        let slow = try makeSlowRepository(named: "slow", under: root.appendingPathComponent("other"))
        try startOtherMac(alsoWith: [slow.folder])
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        // Picked now: its remotes are asked within three seconds of its
        // changes being shown.
        app.press(.id("folder-\(slow.folder.path)"), timeout: 15)
        app.press(.button("Git"))
        pushWhileTheAppFetchesByItself(slow)
    }

    func testPushingWritingTheMessageAndHandingOffOnTheOtherMac() throws {
        try startOtherMac()
        // The other Mac's project follows a remote, and an agent had a conversation in it.
        let otherRemote = root.appendingPathComponent("other/remote.git")
        git("init", "-q", "--bare", "-b", "main", otherRemote.path, in: otherProject)
        git("remote", "add", "origin", otherRemote.path, in: otherProject)
        git("push", "-q", "-u", "origin", "main", in: otherProject)
        let history = otherHome.appendingPathComponent(".claude/projects/" + otherProject.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(otherProject.path)","message":{"role":"user","content":"finish this on the other Mac"}}"#.appending("\n").write(
            to: history.appendingPathComponent("c-9.jsonl"), atomically: true, encoding: .utf8)
        let otherDevice = try device("observer", state: otherState, port: otherPort)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)

        // REMOTE-11: an agent on the other Mac writes the message for what is staged there.
        app.press(.button("Git"))
        app.press(.button("Stage notes.txt"), timeout: 15)
        app.wait(for: .button("Unstage notes.txt"), timeout: 15)
        app.press(.containing("Write the commit message with"))
        wait("the message the other Mac's stand-in wrote", timeout: 30) { self.app.value(of: .text("Commit message")) == "feat: written by the stand-in claude" }
        app.press(.containing("Commit 1 File"))
        wait("the commit on the other Mac", timeout: 15) { self.git("log", "-1", "--format=%s", in: self.otherProject) == "feat: written by the stand-in claude" }
        // REMOTE-12: pushed from here, by the other Mac's git.
        app.press(.containing("Push"), timeout: 15)
        wait("the other Mac's remote to have the commit", timeout: 20) {
            self.git("log", "-1", "--format=%s", "main", in: otherRemote) == "feat: written by the stand-in claude"
        }

        // REMOTE-13: a conversation of the other Mac, handed off there.
        app.press(.id("place-history"))
        app.perform("Hand Off", on: .id("conversation-c-9"), timeout: 15)
        app.wait(for: .text("Hand Off"), timeout: 15)
        // REMOTE-20: the other Mac's folders can be chosen, through its host.
        app.wait(for: .button("Choose…"))
        wait("the prompt, from the other Mac's host", timeout: 15) {
            self.app.all(.role(kAXTextAreaRole as String)).contains { $0.value.contains(".agentterm/handoffs/") }
        }
        app.press(.button("Hand Off"))
        wait("the receiving agent's session on the other Mac", timeout: 15) { otherDevice.sessions.contains { $0.title == "Codex" } }
        let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: otherProject.appendingPathComponent(".agentterm/handoffs").path)) ?? []
        XCTAssertEqual(handoffs.count, 1, "the handoff file was not written on the other Mac")
    }

    func testSessionsFoldersAndComingBackToTheOtherMac() throws {
        try startOtherMac()
        let otherDevice = try device("observer", state: otherState, port: otherPort)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        // A session started here runs on the other Mac.
        app.press(.button("Shell"))
        wait("a session on the other Mac") { otherDevice.sessions.count == 1 }
        XCTAssertEqual(otherDevice.sessions.first?.cwd, otherProject.path)

        // REMOTE-4: a folder of the other Mac, picked from what its host lists.
        app.press(.button("Add"))
        app.wait(for: .containing("Add a Folder on Other Mac"))
        app.press(.button("Sites"), timeout: 15)
        app.press(.button("blog"), timeout: 15)
        app.press(.id("add-remote-folder"))
        wait("the folder on the other Mac's list") { otherDevice.folders.contains { $0.hasSuffix("/Sites/blog") } }
        app.wait(for: .text("blog, folder"), timeout: 15)

        // REMOTE-5: this Mac again, with its own folder, and back: the session is still there.
        switchTo("This Mac")
        app.wait(for: .text("project, folder"), timeout: 15)
        XCTAssertFalse(app.exists(.text("work, folder")))
        switchTo("Other Mac")
        app.wait(for: .text("work, folder"), timeout: 15)
        XCTAssertEqual(otherDevice.sessions.count, 1, "leaving the other Mac ended its session")

        // REMOTE-6: the app comes back to the Mac that was on screen.
        try relaunchApp()
        wait("the other Mac after reopening", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == "Other Mac" }
        app.wait(for: .text("work, folder"), timeout: 15)

        // REMOTE-8: the other Mac removes this one: it is forgotten here, with a word why.
        let devices = otherDevice.last { message -> [DeviceInfo]? in if case .devices(let list) = message { return list } else { return nil } } ?? []
        let this = try XCTUnwrap(devices.first, "the other Mac does not list this one as paired")
        otherDevice.send(.revokeDevice(id: this.id))
        app.wait(for: .containing("removed this Mac from its paired devices"), timeout: 20)
        wait("this Mac to be on screen again", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == "This Mac" }
    }

    /// REMOTE-23 (#167): on another Mac, a session a phone uses at a grid
    /// narrower than the pane but taller is shown whole, in the middle, as
    /// on this Mac (SIZE-12): its first row is not cut off.
    func testANarrowButTallDevicesSessionOnTheOtherMacIsShownWhole() throws {
        try startOtherMac()
        let phone = try device("iPhone", state: otherState, port: otherPort)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Shell"))
        wait("a session on the other Mac") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        let tall = TermSize(cols: 45, rows: 120)
        phone.send(.attach(session: id, size: tall))
        phone.send(.takeControl(session: id, size: tall))
        wait("the phone's size") { phone.size(of: id) == tall }
        app.wait(for: .button("Use This Size"), timeout: 15)
        phone.connection.sendInput(Data("clear; printf FIRST-ROW; tput cup 119 0; printf LAST-ROW\n".utf8), to: id)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("narrow-tall-device-other-mac")
        XCTAssertEqual(app.first(.id("terminal-view"))?.help, "whole grid in sight")
    }

    /// REMOTE-24 (#167): the case as the owner saw it, on another Mac: an
    /// agent's shell in the lower part of its area, used by a phone at
    /// 45×35, is shown whole, in the middle, as on this Mac (SIZE-14).
    func testAnAgentsShellADeviceUsesOnTheOtherMacIsShownWhole() throws {
        try startOtherMac()
        let phone = try device("iPhone", state: otherState, port: otherPort)
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shell_open","arguments":{"title":"server"}}}"#
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        try """
        #!/bin/sh
        echo "stand-in claude started"
        ( printf '%s\\n' '\(initialize)' '\(call)'; sleep 3 ) | '\(hostExecutable.path)' mcp > /dev/null 2>&1 &
        exec cat
        """.write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Claude Code"))
        wait("the agent and its shell on the other Mac") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.agent == "claude" })
        let shell = try XCTUnwrap(phone.sessions.first { $0.openedBy == agent.id })
        app.wait(for: .id("agent-shells"), timeout: 15)
        let grid = TermSize(cols: 45, rows: 35)
        phone.send(.attach(session: shell.id, size: grid))
        phone.send(.takeControl(session: shell.id, size: grid))
        wait("the phone's size") { phone.size(of: shell.id) == grid }
        app.wait(for: .containing("In use on iPhone · 45×35"), timeout: 15)
        phone.connection.sendInput(Data("clear; printf FIRST-ROW; tput cup 34 0; printf LAST-ROW\n".utf8), to: shell.id)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("agent-shell-device-other-mac")
        let nodes = app.nodes()
        let part = try XCTUnwrap(nodes.firstIndex { $0.identifier == "terminal-\(shell.id)" }, "the shell is not shown")
        let terminal = try XCTUnwrap(
            nodes[(part + 1)...].prefix { $0.depth > nodes[part].depth }.first { $0.identifier == "terminal-view" }, "the shell's terminal")
        XCTAssertEqual(terminal.help, "whole grid in sight")
    }

    private var editor: MacDriver.Query { .role(kAXTextAreaRole as String) }

    private func listens(on port: UInt16) -> Bool {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        find.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        find.standardOutput = pipe
        find.standardError = FileHandle.nullDevice
        try? find.run()
        let found = pipe.fileHandleForReading.readDataToEndOfFile()
        find.waitUntilExit()
        return !found.isEmpty
    }

    /// REMOTE-37 (#303): a forced push's question asked of the other Mac,
    /// whose connection closes before it answers, holds the sync bar no
    /// more: Fetch works again on this Mac. Before the fix Fetch, Pull and
    /// Push stayed disabled in every folder until the app was opened again.
    func testAForcedPushTheOtherMacNeverAnswersDoesNotHoldTheSyncBar() throws {
        try startOtherMac()
        let otherRemote = root.appendingPathComponent("other/remote.git")
        git("init", "-q", "--bare", "-b", "main", otherRemote.path, in: otherProject)
        git("remote", "add", "origin", otherRemote.path, in: otherProject)
        git("push", "-q", "-u", "origin", "main", in: otherProject)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .id("sync-more"), timeout: 15)

        // Its host stops answering, and then is gone.
        let other = listeners(on: otherPort)
        XCTAssertFalse(other.isEmpty, "no host listens on \(otherPort)")
        for pid in other { kill(pid, SIGSTOP) }
        app.press(.id("sync-more"))
        app.press(.button("Force Push…"), menus: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        for pid in other { kill(pid, SIGKILL) }
        wait("the other host gone") { Set(self.listeners(on: self.otherPort)).isDisjoint(with: other) }

        switchTo("This Mac")
        app.wait(for: .text("project, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .button("Fetch"), timeout: 15)
        app.wait("Fetch to be enabled", timeout: 10) { self.app.first(.button("Fetch"))?.enabled ?? false }
    }

    /// REMOTE-38 (#302): a submodule's commit on the other Mac keeps its
    /// message until git took it: refused by a hook, git's reason is said
    /// and the message stays; asked while that Mac is not connected, it is
    /// said at once and the message stays. Before the fix the message was
    /// thrown away before git had answered.
    func testASubmodulesCommitOnTheOtherMacKeepsItsMessage() throws {
        try startOtherMac()
        let library = root.appendingPathComponent("other/library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: library)
        try write("one\n", to: "l.txt", in: library)
        git("config", "user.name", "Other", in: library)
        git("config", "user.email", "other@example.com", in: library)
        git("config", "commit.gpgsign", "false", in: library)
        git("add", ".", in: library)
        git("commit", "-q", "-m", "library", in: library)
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "libs/library", in: otherProject)
        let inside = otherProject.appendingPathComponent("libs/library")
        git("config", "user.name", "Other", in: inside)
        git("config", "user.email", "other@example.com", in: inside)
        git("config", "commit.gpgsign", "false", in: inside)
        git("commit", "-q", "-m", "with the library", in: otherProject)
        try write("one\ntwo\n", to: "l.txt", in: inside)
        let hooks = otherProject.appendingPathComponent(".git/modules/libs/library/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'the library hook says no' >&2\nexit 1\n".write(to: hooks.appendingPathComponent("pre-commit"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("pre-commit").path)

        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Git"))
        app.press(.button("Stage libs/library/l.txt"), timeout: 15)
        app.wait(for: .id("staged-libs/library/l.txt"), timeout: 15)
        app.write("library: two", into: .id("submodule-message-libs/library"), confirm: true)
        app.press(.id("submodule-commit-libs/library"))
        app.wait(for: .containing("the library hook says no"), timeout: 20)
        XCTAssertEqual(app.value(of: .id("submodule-message-libs/library")), "library: two", "the message of a refused commit is gone")
        if app.exists(.button("OK")) { app.press(.button("OK")) }

        // That Mac gone: said at once, the message kept.
        killHost(on: otherPort)
        app.wait(for: .containing("Other Mac cannot be reached"), timeout: 30)
        app.press(.id("submodule-commit-libs/library"))
        app.wait(for: .containing(NotConnectedWords.notCommitted("Other Mac")), timeout: 5)
        XCTAssertEqual(app.value(of: .id("submodule-message-libs/library")), "library: two", "the message was thrown away while that Mac was not connected")
    }

    /// REMOTE-14.
    func testACommitTheOtherMacRefusesLateKeepsItsMessage() throws {
        try startOtherMac()
        // A hook that takes longer than the changes are read again, then says no.
        let hook = otherProject.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 6\necho 'the hook says no' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Git"))
        app.press(.button("Stage notes.txt"), timeout: 15)
        app.wait(for: .button("Unstage notes.txt"), timeout: 15)
        app.write("fix: a message worth keeping", into: .text("Commit message"), confirm: true)
        app.press(.containing("Commit 1 File"))
        app.wait(for: .containing("the hook says no"), timeout: 30)
        XCTAssertEqual(app.value(of: .text("Commit message")), "fix: a message worth keeping", "the message of a commit that failed is gone")
    }

    /// REMOTE-15.
    /// REMOTE-39 (#305): an open file renamed on the other Mac to a name it
    /// refuses (one taken) stays where it is: saved, it is written to its
    /// own path, and the file of that name is untouched. Renamed to a free
    /// name, it moves once that Mac took it. Before the fix the open file
    /// moved at once, and its save overwrote the other file.
    func testAFileRenamedOnTheOtherMacMovesOnlyOnceItIsRenamed() throws {
        try startOtherMac()
        try write("someone else's\n", to: "taken.txt", in: otherProject)
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        wait("the other Mac's file in the editor", timeout: 15) { self.app.value(of: self.editor) == "first line\nchanged on the other Mac\n" }
        let row = MacDriver.Query.idEnding("/work/notes.txt", prefix: "file-")
        app.perform("Rename", on: row)
        app.write("taken.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Rename"))
        app.press(.button("OK"), timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        app.write("first line\nsaved after the refusal\n", into: editor)
        app.menu(["File", "Save"])
        wait("the save on the other Mac", timeout: 15) { self.read("notes.txt", in: self.otherProject) == "first line\nsaved after the refusal\n" }
        XCTAssertEqual(read("taken.txt", in: otherProject), "someone else's\n", "the save of a file whose rename was refused overwrote another file")

        app.perform("Rename", on: row)
        app.write("moved.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Rename"))
        wait("the rename on the other Mac", timeout: 15) { FileManager.default.fileExists(atPath: self.otherProject.appendingPathComponent("moved.txt").path) }
        app.write("first line\nsaved after the rename\n", into: editor)
        app.menu(["File", "Save"])
        wait("the save under the new name", timeout: 15) { self.read("moved.txt", in: self.otherProject) == "first line\nsaved after the rename\n" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherProject.appendingPathComponent("notes.txt").path), "the save went to the old name")
    }

    func testAFileTheOtherMacCannotWriteKeepsItsChanges() throws {
        try startOtherMac()
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        wait("the other Mac's file in the editor", timeout: 15) { self.app.value(of: self.editor) == "first line\nchanged on the other Mac\n" }
        // Nothing can be written in its folder from now on.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: otherProject.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: otherProject.path) }
        let edited = "first line\nchanged on the other Mac\nnot to be lost\n"
        app.write(edited, into: editor)
        app.menu(["File", "Save"])
        // It is said, and the text stays, also when the files are read again.
        app.press(.button("OK"), timeout: 15)
        app.press(.button("Refresh"))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(app.value(of: editor), edited, "the changes that could not be saved are gone")
        XCTAssertEqual(read("notes.txt", in: otherProject), "first line\nchanged on the other Mac\n")
        // And they still count as not saved.
        app.press(.id("mac-switcher"))
        app.press(.button("This Mac"), menus: true)
        app.wait(for: .containing("Save or discard the changes"))
    }

    /// REMOTE-16.
    func testThisMacsTabsAreNotArrangedOnTheOtherMac() throws {
        try startOtherMac()
        let phone = try device()
        let otherDevice = try device("observer", state: otherState, port: otherPort)
        app.menu(["File", "New Shell"])
        wait("a session here") { phone.sessions.count == 1 }
        let own = try XCTUnwrap(phone.sessions.first)
        // A shell of the user's is held in the Shells tab of its project
        // (#127): that tab is this Mac's.
        wait("this Mac's host to have its tab") { phone.tabLayout?.order.contains { $0.hasPrefix("h:shells:") } == true }
        let ownOrder = try XCTUnwrap(phone.tabLayout?.order)
        XCTAssertFalse(ownOrder.contains(own.layoutID), "a shell of the user's has a tab of its own: \(ownOrder)")
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Shell"))
        wait("a session on the other Mac") { otherDevice.sessions.count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        // Nothing the other Mac's host was ever told names a tab of this Mac.
        let told = otherDevice.messages.compactMap { message -> TabLayout? in if case .tabLayout(let layout) = message { return layout } else { return nil } }
        XCTAssertFalse(told.contains { !Set($0.order).isDisjoint(with: ownOrder) }, "the other Mac was given this Mac's tabs: \(told.map(\.order))")
        // This Mac's own are as they were.
        switchTo("This Mac")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(phone.tabLayout?.order, ownOrder)
    }

    /// REMOTE-17.
    func testTheMacOnScreenIsNotForgottenOverUnsavedChanges() throws {
        try startOtherMac()
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        wait("the other Mac's file in the editor", timeout: 15) { self.app.value(of: self.editor) == "first line\nchanged on the other Mac\n" }
        app.write("first line\nnot saved yet\n", into: editor)
        app.press(.id("mac-switcher"))
        // The one under Forget, which comes after the one that switches.
        let named = app.all(.button("Other Mac"), menus: true)
        XCTAssertEqual(AXUIElementPerformAction(try XCTUnwrap(named.last).element, kAXPressAction as CFString), .success)
        app.press(.button("Forget"), timeout: 15)
        app.wait(for: .containing("Save or discard the changes"))
        app.press(.button("OK"))
        // Still on screen, so still one of the Macs to pick.
        XCTAssertEqual(app.first(.id("mac-switcher"))?.value, "Other Mac")
        app.press(.id("mac-switcher"))
        app.wait(for: .button("Other Mac"), menus: true)
    }

    /// REMOTE-18.
    func testOpeningOnTheOtherMacStillStartsThisMacsHost() throws {
        try startOtherMac()
        pair()
        app.wait(for: .text("work, folder"), timeout: 15)
        // The Mac was restarted: the app opens on the other Mac, and
        // nothing has started this Mac's host.
        try relaunchApp {
            stopWhateverListens(on: port)
            wait("this Mac's host to be gone") { !self.listens(on: self.port) }
        }
        wait("the other Mac after reopening", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == "Other Mac" }
        wait("this Mac's host to be started", timeout: 15) { self.listens(on: self.port) }
        // REMOTE-18, #179: a host the app starts in a test listens on
        // 127.0.0.1 only, as the tests' own hosts do; one left behind by a
        // run stopped in the middle was found on the Tailscale address.
        let addresses = listeningAddresses(on: port)
        XCTAssertTrue(addresses.allSatisfy { $0.hasPrefix("127.0.0.1:") || $0.hasPrefix("[::1]:") }, "the host the app started listens on \(addresses)")
    }

    /// REMOTE-30 (#209): this Mac showing the other Mac's page when the
    /// connection to that Mac drops and comes back (a proxy in front of its
    /// host, stopped and made again on the same port). The page is shown
    /// again by itself and watched again: nothing is shown as live without
    /// being watched. Checked for #209's gap on the iPhone, which the Mac
    /// does not have: the page's view is made again with the connection.
    func testAPageOfTheOtherMacShownAcrossAReconnectIsWatchedAgain() throws {
        try startOtherMac()
        let browser = try device("Mac", state: otherState, port: otherPort)
        browser.send(.browserProvider(true))
        browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        func watches() -> Int {
            browser.messages.filter { if case .browserCall(_, _, .watch("7", true, _)) = $0 { return true } else { return false } }.count
        }
        var proxy = try SlowProxy(to: otherPort, bytesPerSecond: 50_000_000)
        let proxyPort = proxy.start()
        defer { proxy.stop() }
        pair(through: proxyPort)
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        wait("the page watched", timeout: 15) { watches() == 1 }

        // The link drops, and comes back on the same port.
        proxy.stop()
        app.waitGone(.id("remote-page"), timeout: 15)
        proxy = try SlowProxy(to: otherPort, bytesPerSecond: 50_000_000, port: proxyPort)
        XCTAssertEqual(proxy.start(), proxyPort)
        // Shown again by itself, and watched again.
        app.wait(for: .id("remote-page"), timeout: 30)
        wait("the page shown again watched again", timeout: 15) { watches() == 2 }
        shot("watched-again")
    }

    /// REMOTE-31 (#210): the other Mac's host restarts, this Mac is back on
    /// it before that Mac's app is, and that app comes back later as the
    /// browser. The page on show says why it waits, not that it loads, and
    /// is watched again once that app is back, without being opened again.
    func testAPageOfTheOtherMacIsWatchedAgainWhenItsAppIsBack() throws {
        try startOtherMac()
        func provide(_ browser: Device) {
            browser.send(.browserProvider(true))
            browser.send(.browserTabs([BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default")]))
        }
        func watched(_ browser: Device) -> Bool {
            browser.messages.contains { if case .browserCall(_, _, .watch("7", true, _)) = $0 { return true } else { return false } }
        }
        let first = try device("Mac", state: otherState, port: otherPort)
        provide(first)
        pair()
        app.wait(for: .id("sidebar-browser"), timeout: 20)
        app.press(.id("sidebar-browser"))
        app.wait(for: .id("remote-page"), timeout: 15)
        wait("the page watched", timeout: 15) { watched(first) }

        // That Mac's host restarts; this Mac is back on it first.
        killHost(on: otherPort)
        try startHost(state: otherState, home: otherHome, port: otherPort)
        app.wait(for: .containing("The host on Other Mac stopped unexpectedly"), timeout: 30)
        // Its pages go with its app: none is shown as loading meanwhile.
        app.waitGone(.id("remote-page"), timeout: 15)
        // The page's watch and unwatch, sent by the app itself as the
        // panes come back, are refused without an alert (REMOTE-32, the
        // owner's decision, 2026-11-21).
        XCTAssertNil(app.first(.containing(BrowserWords.noApp)), "a watch the app sent by itself was refused in an alert")
        shot("app-not-back")
        // That Mac's app comes back, with its page.
        let second = try device("Mac", state: otherState, port: otherPort)
        provide(second)
        wait("the page watched again once that Mac's app is back", timeout: 20) { watched(second) }
        app.wait(for: .id("remote-page"), timeout: 15)
        shot("app-back")
    }

    /// REMOTE-19: the other Mac's host dies and is started again there.
    /// This Mac says so in words, rather than showing an empty list.
    func testWhenTheOtherMacsHostDiesThisMacSaysWhatEnded() throws {
        try startOtherMac()
        let otherDevice = try device("observer", state: otherState, port: otherPort)
        otherDevice.send(.create(CreateRequest(command: "sleep 600", cwd: otherProject.path, title: "deploy")))
        pair()
        app.wait(for: .containing("deploy"), timeout: 15)

        // Killed there, and started again there, as its own app would.
        killHost(on: otherPort)
        try startHost(state: otherState, home: otherHome, port: otherPort)
        app.wait(for: .containing("The host on Other Mac stopped unexpectedly"), timeout: 30)
        app.wait(for: .containing("and was started again"))
        app.wait(for: .containing("Its session ended: deploy"))
        shot("banner")
        app.press(.button("Dismiss"))
        app.waitGone(.containing("host on Other Mac stopped unexpectedly"))
    }

    /// SET-5: what the Mac on screen said, its schedules here, is not shown
    /// once it is out of reach, nor under the Mac switched to.
    func testTheSchedulesOfAMacOutOfReachAreNotShown() throws {
        try startOtherMac()
        let otherDevice = try device("observer", state: otherState, port: otherPort)
        otherDevice.send(
            .saveSchedule(
                Schedule(
                    id: "other", name: "Other's nightly", agent: "claude", folder: otherProject.path, prompt: "test", when: .daily(hour: 2, minute: 0),
                    warningAccepted: true)))
        pair()
        app.press(.id("place-schedules"))
        app.wait(for: .id("schedule-other"), timeout: 15)
        killHost(on: otherPort)
        app.waitGone(.id("schedule-other"), timeout: 20)
        app.wait(for: .text("No schedules yet."))
    }
}
