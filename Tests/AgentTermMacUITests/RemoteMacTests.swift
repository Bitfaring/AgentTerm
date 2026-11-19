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

    private func pair() {
        let link = pairingLink(state: otherState, port: otherPort, name: "Other Mac")
        XCTAssertFalse(link.isEmpty, "the other host gave no pairing link")
        app.press(.id("mac-switcher"))
        app.press(.button("Pair with Another Mac…"), menus: true)
        app.write(link, into: .id("pair-mac-link"), confirm: true)
        wait("the other Mac to be on screen", timeout: 20) { self.app.first(.id("mac-switcher"))?.value == "Other Mac" }
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

        // A new page: opened on the other Mac, shown here once it is listed.
        app.menu(["Browser", "New Browser Tab"])
        wait("a new page asked for", timeout: 15) { calls().contains { if case .newTab = $0.request { return true } else { return false } } }
        let asked = try XCTUnwrap(calls().last { if case .newTab = $0.request { return true } else { return false } })
        browser.send(
            .browserTabs([
                BrowserTabInfo(id: "7", title: "Shop", url: "http://localhost:3000/", project: "", profile: "Default"),
                BrowserTabInfo(id: "8", title: "", url: "", project: "", profile: "Default"),
            ]))
        browser.send(.browserReply(id: asked.id, result: .opened(tab: "8")))
        app.wait(for: .id("browser-8"), timeout: 15)
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
    /// on this Mac (SIZE-10): its first row is not cut off.
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
