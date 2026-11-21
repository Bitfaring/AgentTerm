# Testing AgentTerm

What AgentTerm does, case by case, and what checks each case. The list
follows `SPEC.md`. Each case says three things:

- **Input**: what there is before anything is done: the data, and the state
  the apps and the host are in.
- **Action or event**: what the user does, or what happens.
- **Expected response**: what has to be true afterwards.

The last column says what checks the case. A case marked "hand" is checked
by nothing automatic, which is where a bug can sit unnoticed.

## The layers

| Mark | Layer | Run with | Runs in CI |
|---|---|---|---|
| H | Host and protocol: a real host over a loopback WebSocket | `swift test` | yes |
| P | iPhone app in the simulator, against two throwaway hosts | `scripts/test-ios.sh` | no |
| L | iPhone app on its side | `LANDSCAPE=only scripts/test-ios.sh` | no |
| M | Mac app, driven through accessibility, against a throwaway host | `scripts/test-mac.sh` | no |
| X | Mac app and iPhone app together on one host | `scripts/test-both.sh` | no |
| hand | Only by hand so far | | |

In M a second device, a phone say, is played by a client that speaks the
protocol: the Mac app is real, the other device is not. In X both apps are
real.

M and X need the terminal they run in to be allowed under System Settings >
Privacy & Security > Accessibility. They press and read the app's own
elements, as VoiceOver does: no pointer is moved and no key is sent. The
Mac is left alone while they run: the app under test is in front, and when
another app comes to the front a menu it has open closes (#135), and what
it does only while in front stops. What was on screen when a test failed
names the app in front first, and says so when it is not the one under
test. A run of `scripts/test-mac.sh` stopped in the middle, by Control-C or by
`kill`, ends every app, host and helper its tests started (#179): left
behind, they kept a test's port, and a later run of that test met them.
When the tests are over, the script looks for anything of theirs still
running: the app under test, the bundle's processes (a host the bundled app
started by itself, Chromium's), a test's host or web server. It names and
ends what it finds, and the run fails (#185). Such leftovers came from an
app whose window never came, for example with the screen locked: the test's
set-up stopped before the app was its `app`, so it was never quit, and once
the test's host was stopped it started a host of its own. Every app a test
starts is now kept from the moment it starts (`startDriver`). Two web
servers of `BrowserUITests` were left too: `/usr/bin/python3` runs the real
one as a child that outlives it, and whatever listens on its port is now
stopped after the test. A test that puts something between the app and its
host (`SlowProxy`, `PortBlocker`) quits the app first and stops that thing
after (#203): `WaitingTests` stopped its proxy first, and the app, finding
its host gone, started one of its own on the proxy's port, which no one
stopped. Every test now checks, as it ends, that no program of the build
with its state folder is still running (TEST-9): one that is, is named and
ended, and the test fails. While a `SlowProxy` stands on the app's port,
the program the app finds listening there is the test runner itself
(`xctest`), not the app's own host. The app took any such program for
another copy's host and showed that banner, naming `xctest`, in every
picture of those tests, with a button that would have stopped the test
runner (#204); no other host, left behind or the installed app's, was
involved. Another copy's host is now an `agenttermd` only: for anything
else the app says the port is in use by that program, by its name, and
offers nothing that stops it (HOST-13). Run from a session of the installed app, the tests have that
session's own variables (`AGENTTERM_EVENTS`, `AGENTTERM_USAGE`,
`AGENTTERM_MCP`), which reached every host, app and session they started
(#207). The test scripts now take every `AGENTTERM_` variable out of their
environment first, but the settings they document
(`scripts/lib-own-environment.sh`); what a test starts is given none of
the test runner's `AGENTTERM_` variables, only those the test sets
(`withoutAgentTerms`); and a host gives its sessions none of the session
it was started from (TEST-10, TEST-11). All
layers use state folders, ports, a home folder and preferences of their own,
and stand-in agents (small scripts) instead of the installed ones: the
installed app, its sessions, its paired devices and the user's accounts are
never touched.

## Running them

Everything is run from the root of the repository. Each script builds what
it needs first, prints one line per test, and on a failure says where the
full log is.

| To check | Run | Takes about |
|---|---|---|
| The host, the protocol and the shared code | `swift test` | 2 minutes |
| The Mac app | `scripts/test-mac.sh` | 5 minutes |
| The iPhone app | `scripts/test-ios.sh "iPhone Air"` | 5 minutes |
| The iPhone app on an iPad (#88) | `scripts/test-ios.sh "iPad Pro 13-inch (M5)"` | 7 minutes |
| The iPhone app on its side | `LANDSCAPE=only scripts/test-ios.sh "iPhone Air"` | a few minutes |
| Both apps on one host | `scripts/test-both.sh "iPhone Air"` | 5 minutes |

**Chromium is fetched before the Mac app is built** (#181).
`scripts/test-mac.sh` runs `scripts/fetch-cef.sh` before its first build.
`CAgentTermCEF` finds CEF's headers with `__has_include`, and SwiftPM does
not watch a header that was missing. So a `.build` that compiled it before
`.build/cef/current` existed kept a browser that says "made without
Chromium", and 39 tests of `BrowserUITests` failed. When `fetch-cef.sh`
sets or changes that link, it marks `Sources/CAgentTermCEF/AgentTermCEF.m`
changed, and the next build has Chromium, whatever was built before.

**A menu held the iPhone's test up for a minute at each step** (#65). A
row of the sessions' list can be dragged and has a menu, and for as long as
such a menu is open iOS keeps the app busy: XCUITest, which waits for the
app to be idle before and after every step for up to 60 seconds, waited
them out at the press that opens the menu and at the touch that picks from
it. With the row not draggable the same steps take two seconds; where the
drag is put (on the row or inside it, `onDrag` or `draggable`) makes no
difference. It is how iOS pairs a drag with a menu, not something the app
does, so the app is as it was and the test does not wait: its steps
around a menu run inside `IdleWaits.skipped` (`iOS/AgentTermUITests`),
which replaces the test runner's own wait while they run. The test went
from 13 minutes to 5. Should a later Xcode name that wait otherwise,
nothing is replaced and the steps wait as before; `IDLE=only
scripts/test-ios.sh` says which waits it found. Made once, a drag onto a
session of a group was lost in 2 of 10 runs on 2026-11-15; the groups,
and the steps that made their gestures again (`gesture`), were taken away
with them (#127). On the iPad, with the keyboard up, a
touch on an entry of the terminal's menu was lost too, now and then, and
the menu stayed open: the test puts the keyboard down before that menu
there. Why either touch is lost is #83's, still open.

Before a release all of them are run, in that order: the first is the
quickest to say that something is broken, the last needs everything else
to work.

What they need, once:

- For M and X: the terminal they are run from, or the app a coding agent
  runs in, allowed under System Settings > Privacy & Security >
  Accessibility. Without it the Mac tests are skipped, not failed: a run
  that says "Executed 0 tests" or lists them as skipped checked nothing.
- For P, L and X: Xcode with an iPhone simulator (an iPad one too, for the
  iPad), and `brew install xcodegen`. Name the simulator: the test resets its keychain, so it should
  not be the one an app you use is paired in. `scripts/test-ios.sh --list`
  shows the simulators.

One test, or a few:

```sh
swift test --filter OutputTrackerTests                    # a class
swift test --filter "ScreenMirrorTests|LoginItemTests"    # several
swift test --filter testAStringEndsWhereAnotherSequenceBegins
scripts/test-mac.sh RemoteMacTests                        # a class of the Mac app's
scripts/test-mac.sh "RemoteMacTests/testACommit"          # tests whose name starts so
scripts/test-mac.sh "RemoteMacTests/test(ACommit|AFile)"  # a pattern, as --filter takes
```

When a Mac test fails, its message ends with everything that was on screen
at that moment, element by element: most often that says what went wrong.
For a picture of the window as well:

```sh
SHOTS=/tmp/shots scripts/test-mac.sh RemoteMacTests               # of each test that fails
SHOTS=/tmp/shots ALL_SHOTS=1 scripts/test-mac.sh RemoteMacTests   # of every test, at its end
```

`ALL_SHOTS=1` is also the way to look at a change to the window without
opening the app: run a test that ends where the change shows, and look at
its picture. The iPhone scripts take `SHOTS` the same way.

### The figures

`scripts/measure.sh` (`CONFIGURATION=release` for the build users run)
takes the figures of `docs/PERFORMANCE.md` again: heavy cases made in a
folder of its own, each timed or weighed. Nothing fails on a figure;
compare with the table there after a change that may make AgentTerm
slower or larger.

### The pictures

The pictures of both apps, in the README, on the product page and in the
App Store, are taken the same way the apps are tested, by
`scripts/screenshots.sh`:

```sh
KEEP=/tmp/pictures scripts/screenshots.sh   # take them there, to look at first
scripts/screenshots.sh                      # put them where the pages take them from
ONLY=mac scripts/screenshots.sh             # only the Mac's three
ONLY=ios scripts/screenshots.sh             # only the iPhone app's six, on the iPhone and on the iPad
ONLY=iphone scripts/screenshots.sh          # or ONLY=ipad: on one of them
```

It builds the app into a folder of its own, starts a host with a demo
project, a second folder and stand-in agents (`scripts/demo-agent.py`,
which draws an agent's screen and reports usage without any account),
then runs `ScreenshotTests` of the Mac app and of the iPhone app, the
latter on the iPhone Air and on the iPad Pro 13-inch (`IPAD=` names
another), each paired by a link of its own. The iPad's go beside the
iPhone's in `fastlane/screenshots/en-US`, named `ipad-*.png` (#88). What a
picture shows is decided there: the demo project in the script, what the
agent says in `demo-agent.py`, where each picture is taken in the two
`ScreenshotTests`. They are taken again whenever a release changes what
they show, and looked at before they are committed. The iPhone's are
taken on the iPhone Air, whose screen is the size the App Store asks for.

The Simulator copies the Mac's pasteboard to the simulator's, and the
keyboard of iOS offers to paste what is there: a picture with the keyboard
up showed the text last copied on the Mac (#143). The script empties the
simulator's own pasteboard before the pictures are taken, and touches
neither the Mac's nor the Simulator's setting. What is copied on the Mac
while they are taken may still show: one more reason to look at each. They
are taken after the version was set (`make bump`), as the list of sessions
says the version and the protocol at its foot.

### Where a new test goes

| What is tested | Where | Start from |
|---|---|---|
| What the host answers, what a client is sent | `Tests/AgentTermHostTests/EndToEndTests.swift` | a test there that connects a client |
| What a client is sent on attach | `Tests/AgentTermHostTests/ScreenMirrorTests.swift` | `session(_:)` and `attach(to:)`, which give the session's own terminal and a client's to compare |
| The connection itself | `Tests/AgentTermHostTests/SlowLinkTests.swift` | a host on a port of its own and a real `AgentTermConnection` |
| What one host leaves for the next: a host that died | `Tests/AgentTermHostTests/HostDeathTests.swift` | `startHost()`, which runs the real `agenttermd` on the test's own state folder and port, and `kill` |
| The host as launchd runs it | `Tests/AgentTermHostTests/LaunchdHostTests.swift` | a launch agent of the test's own: a label no app uses (`com.example.agentterm-test.…`), its property list in the test's folder, never `~/Library/LaunchAgents`, loaded into the user's launchd and unloaded after |
| The Mac app | a class under `Tests/AgentTermMacUITests` | `MacUITestCase`: `app.press`, `app.write`, `app.menu`, `app.wait(for:)`, and `device()` for a second device |
| The Mac app on another Mac | `RemoteMacTests` | `startOtherMac()` and `pair()` |
| The iPhone app | `iOS/AgentTermUITests` | the test `scripts/test-ios.sh` runs |

A Mac test finds an element by what VoiceOver would say of it:
`.button("Stage notes.txt")`, `.text("Commit message")`,
`.containing("the hook says no")`, `.id("mac-switcher")`. An element that
cannot be found that way has no name for VoiceOver either, which is worth
fixing in the app rather than working around in the test.

### A bug, before it is fixed

A bug that can be shown is shown first: a test that fails because of it,
run and seen to fail, then the fix, then the same test passing. The test
stays. What makes each kind of bug show:

- Something that depends on timing: make the slow thing slow. A git hook
  that sleeps (REMOTE-14), a link that carries little (`SlowProxy`,
  SES-9), output cut where the bug needs it cut (SES-16, SES-19).
- Something that fails on the other side: make it fail there. A folder
  nothing can be written in (REMOTE-15), a host that is stopped
  (REMOTE-18) or killed (`killHost(on:)`, HOST-5, REMOTE-19), a port held
  by something else (HOST-7), a device that is removed (REMOTE-8).
- Something one device does to another: a second client on the same host
  (`device()`), which also remembers everything the host told it
  (REMOTE-16).
- Something slow: time it in the test and compare with itself, not with
  a number of seconds that holds on one machine only (SES-21).

## Cases

"The fixture project" is a git repository with a remote, one commit, and
changes not yet committed: `notes.txt` with a second line, `docs/guide.md`
new, `new.txt` new. "A second device" is another client on the same host.

### Sessions

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SES-1 | A host with no session | A client creates a session with the command `echo hello-$((40+2)); exit 3` | The output `hello-42` arrives, then the exit status 3, then a session list without it | H |
| SES-2 | The app connected, the fixture project selected | Press the Shell launch button | A session starts in the project's folder and its terminal is shown | P, M |
| SES-3 | Stand-in agents `claude` and `codex` installed | Press the Claude Code launch button | A session titled "Claude Code" starts, runs the agent's program, and has a tab | M |
| SES-4 | Two sessions running, one with a line typed and not sent | Quit the Mac app and open it again | Both sessions are listed again, under the same ids, with what was typed still at the prompt | M |
| SES-5 | A session open on the iPhone | The connection drops and comes back | The app reconnects by itself and is back in that session | H (the host side), hand (the app) |
| SES-6 | A session started on one device | A second device attaches to it | The second device gets the same output; a session started on the Mac is listed on the iPhone, and one started on the iPhone on the Mac | H, M, X |
| SES-7 | A session that wrote 20,000 lines | A client attaches | The screen and the 10,000 newest lines above it arrive whole, in pieces, with no line lost or torn, ending where the session is now | H |
| SES-8 | A client that was attached and got N bytes | It attaches again naming how far it is | Only what the session wrote since is sent; a place that is not this session's gets all of it again, and is told so | H |
| SES-9 | A link that carries 100 KB a second; a link that carries nothing | A replay of 300 KB is sent; nothing is sent | The slow connection stays open and gets all of it; the silent one is closed as lost | H |
| SES-10 | A session in front on the Mac; a session open on the iPhone | Choose End Session | The app asks first, nothing ends before the answer, and after it the session is gone from every device | P, M |
| SES-25 | A session on the Mac and on the iPhone | End it from the × of its row or its tab on the Mac, from its row's menu on the iPhone | Each asks first, as End Session does | P (the row's menu); hand for the Mac's ×, which shows under the pointer only, and the Mac's UI tests never move it |
| SES-26 | A host given a home folder of its own, as a test's | A session is started in a folder that is not there; another with no folder | Both start in the host's home folder, not in the home folder of the person running the tests | H |
| SES-27 | A shell started with a command to type (`create`'s `typed`) | It starts; a second passes; Return is typed | The command is at its prompt and has not run; it runs once Return is typed | H |
| SES-28 (#160) | The Mac's terminal; a pasteboard of the test's own with two files | Quote paths; read the files; the terminal's view | A plain path as it is, one with spaces or a quote quoted for the shell; both files read; the view registered for files dropped | U |
| SES-29 (#189) | The Mac and the iPhone connected | The Mac creates a shell with a request number while the iPhone creates one without; the Mac attaches to the iPhone's; the Mac asks a shell for a session that is no running agent, and a worktree of a folder that is not a repository, each with its number | The Mac's `attached` carries its number, the iPhone's none, the attach none, and the iPhone is never given the Mac's; each refusal is an `error` with the number of the launch it refuses, to the Mac alone. Before the host gave it back: seen failing, then passing | H |
| SES-11 | A client that is not attached to a session | It sends input for that session | The input does not reach the program | H |
| SES-12 | Text written for a session and not sent | Leave the terminal, or close the app, and come back | iPhone: the text is in the message field again. Mac: it is still at the program's prompt | P; M as far as the host goes: the session is there and replays what was typed. What the Mac's terminal draws cannot be read through accessibility |
| SES-13 | A replay holding a question the program once asked its terminal | The replay is fed slowly, longer than five seconds in all | The emulator's answer does not reach the program; a question asked after the replay is answered | H |
| SES-14 | A full screen program on the other screen, with the cursor hidden, the mouse and pastes reported | A client attaches | Its emulator shows the same screen, cursor and modes without the program drawing again; when the program ends both are back at the shell's screen | H |
| SES-15 | Output drawn for 80 columns, then a session resized to 40 | A client attaches | The lines are laid out for 40 columns, as in the session's own terminal | H |
| SES-16 | Output that stops in the middle of a color sequence, a character of three bytes, or a title | A client attaches at that moment, and the rest is written | The client shows what the session's own terminal shows: nothing of the sequence appears as text | H |
| SES-17 | A program that asked where the cursor is and which terminal this is | A client attaches | Nothing in what it is sent makes its emulator answer | H |
| SES-18 | An emulator that already holds other text and is on the other screen | It is sent a session's screen | It is left as the session is, with nothing of before | H |
| SES-19 | A title that never ends: its program was killed, or the output is binary; then colored text | A client attaches, also right after the escape that cut the title short | The client shows what the session's own terminal shows, once, in its colors | H |
| SES-20 | An image of 1.5 MB being written, more than is kept of one sequence | A client attaches in the middle of it, and the rest is written | The client is sent a few kilobytes, misses the image and draws none of it as text; what follows the image shows | H |
| SES-21 | A session with 10,000 lines that says nothing meanwhile | Ten clients attach one after the other | The screen is written out once: the ten take less time together than the first did. After more output it is written out anew. Writing out 10,040 lines takes less than eight times as long as writing out 2,640: in proportion to the lines, not more | H |
| SES-22 | A client that is still connecting | It is asked to send something | That waits and follows the greeting; the host answers it instead of closing a client whose first word was not its hello | H |
| SES-23 | A session whose program waits | Its program is killed (SIGKILL) | Every client is told that the program of that session stopped unexpectedly, that it was killed, and that its session ended; it is not started again | H |
| SES-24 | A session whose program ignores the hang-up; another that waits | The first is closed from a device (SIGHUP, then SIGKILL); the second is stopped by Control C (SIGINT) | Nothing is reported | H |

### Session names and usage

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| NAME-1 | An agent's session whose agent saved a conversation | The host looks at the sessions | The session is named after the conversation's title | H |
| NAME-2 | Two sessions of one agent in one folder | Each has its own conversation | Each session gets its own conversation, not the other's | H |
| NAME-3 | A session started on the Mac | Look at the folder list, the tabs, and the iPhone | The same name and icon in all three | M (Mac), X (name on the iPhone) |
| USE-1 | What each agent's service answers about limits | The host reads it | The limits are listed as the agent's own usage screen lists them | H |
| USE-2 | A sign-in for one service; one that has run out | The host asks for usage | The sign-in goes only to the service that issued it; one that ran out is not sent and never renewed | H |
| USE-3 | An agent's session in front | Look under the terminal, press the band | The band shows model, context and limits; pressing it opens the details | hand (the band is there in M; its figures need a real account) |
| USE-4 | A user with a status line of their own | Claude Code runs AgentTerm's status line | The user's own still runs, with the same input | H |
| USE-5 | A Claude Code session whose usage the status line relay cannot save | The relay runs; it saves again; then it cannot again | The relay leaves why next to the file and removes it once it saves. The host reports it once for the session, with the relay's words, and again after it was saved in between | H |

### The Mac at a glance

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SYS-1 | A host with a client connected | Three seconds pass | The six figures are measured and sent | H |
| SYS-2 | The app connected | Look under the launch buttons in Sessions (Mac), above the sessions (iPhone) | Processor, memory, network down and up, temperature, battery, uptime, and the memory in gigabytes ("Memory 12.4/32 GB", #154) are shown | P, M |
| SYS-3 | Temperature in Celsius | A second device chooses Fahrenheit | The Mac's line shows °F | H, M |
| SYS-4 (#206) | Another Mac's page shown, the host's figures not come yet | The figures come | The page stays where it was shown: the line of figures has its place from the start, its figures "—" until then. Before the fix the line came with the figures and the page moved 24 points down, from (344, 187, 821, 705) to (344, 211, 821, 681) | M |

### Terminal size

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SIZE-1 | Two clients attached with different sizes | One takes control; the other only watches | The PTY has the size of the one that took control; watching changes nothing | H |
| SIZE-2 | A client attached that is not the driver | Its emulator answers a question by itself | The session is not taken away from the driver | H |
| SIZE-3 | A session open on the iPhone | The Mac takes the session at a larger size | The iPhone shows the Mac's terminal scaled down with "Fit This Screen", which takes it back | P (`TAKEOVER=1`) |
| SIZE-4 | A session started on the Mac | A second device takes control at 40 × 20 | The Mac says another device is using it, names 40 × 20, and offers "Use This Window's Size"; pressing it gives the Mac's size back | M |
| SIZE-5 | A session at the size that fits | Make the text four steps larger, then back to the actual size | Fewer columns while it is larger; the same number again afterwards | P, M |
| SIZE-6 | A session open on the iPhone | Turn the phone on its side, bring up the keyboard | The terminal keeps a usable height; one row holds back, the keys, the message field and the menu | L |
| SIZE-7 | The Mac's launch screen, its line of figures shown | Start a shell | It starts at the size its pane shows it at, not one it is made smaller to afterwards | M |
| SIZE-8 | A session the Mac and the iPhone show, the iPhone using it | The iPhone goes; the Mac's window is resized; the Mac app is used; the Mac types in it | The session stays at the iPhone's size and nobody drives until the Mac types, then it takes the Mac's; an iPhone coming back takes its own at once, without a button | H |
| SIZE-9 | A session started on the Mac, in a pane smaller than an iPad's grid | A second device takes control at 300 × 100 | The Mac shows the whole grid, scaled down to fit its pane, as the iPhone shows the Mac's: the last rows, where the prompt is, are not cut off; taken back, it fills the pane again | M |
| SIZE-12 (#167) | A phone takes a shell at 45×120: narrower than the pane, taller | The Mac shows it | In the middle, scaled down to fit, the first row and the last in sight | M |
| SIZE-13 (#167) | A phone takes a shell at 45×20, then grows it to 45×120 | The Mac shows it | Laid out again for the new grid, whole | M |
| REMOTE-23 (#167) | Another Mac on show; a phone takes one of its shells at 45×120 | This Mac shows it | As SIZE-12 | M |
| SIZE-14 (#167) | An agent's shell in the lower part of its area, lower than 35 rows; a phone takes it at 45×35, as the owner saw it | The Mac shows it | In the middle of its part, whole: none of it cut off | M |
| REMOTE-24 (#167) | Another Mac on show; a phone takes one of its agent's shells at 45×35 | This Mac shows it | As SIZE-14 | M |
| SIZE-10 (#120) | A session of the Mac's own app, then used on a device named "Manh's iPad"; on the Mac, a phone named iPhone using one | The device watches; then takes it | The device is told the Mac has it, by the Mac's name; then the Mac is told the device has it, by the device's name; the one that has it is not named to itself. The Mac's banner reads "In use on iPhone · 40×20"; the iPhone's names the Mac by its name, not "another device" | H, M, X |
| SIZE-11 (#157) | The Mac's app and an iPad that says it is one, attached to a session | The iPad takes it, then the Mac | Each is told the other with what it is (`kind`); an iPad's icon for the iPad, none for the Mac | H |

### Quick launch and SSH

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LAUNCH-1 | Two of the four agents installed | Open the app | In the header, launch buttons for those two and for Shell, and the other two dimmed, said to be not installed (#50); the host tells which are installed | H, M |
| LAUNCH-2 | `~/.ssh/config` with `Host build-server`, `Host *.internal` | Open the SSH menu | `build-server` is listed; the pattern is not | H, P, M |
| LAUNCH-3 | The same configuration | A client asks to open a host the configuration does not name | The host refuses | H |
| LAUNCH-4 | No SSH configuration | Open the app | There is no SSH menu | M |
| LAUNCH-5 | A `Host` line with a comment after it | The host reads the configuration | The words of the comment are not hosts | H |
| LAUNCH-6 | The Mac app, Antigravity not installed | Its button in the header; Look Again; Install in a New Shell | A sheet with its maker's command and page; still not found, and why that may be; a shell with the command typed at its prompt, not run (the test ends it without pressing Return) | M |
| LAUNCH-8 (#202) | The Mac app not connected to its host: the app's port held by something that is not a host, as HOST-7 | File > New Shell | Nothing is started; the window's notice says at once `StateWords.notStarted` (why, and to start it again once connected), and OK closes it. Before the fix nothing happened and nothing was said beyond the window's "could not be started". The same check stands before every way of starting a session (New <agent>, the menu bar's, a worktree, SSH, resuming, a handoff, a Shells tab's part turned on with no shell free); the part cannot be pressed while not connected, since the window then shows why in place of the tabs, so no test turns it on | M |
| LAUNCH-7 | Each of the four agents, and one AgentTerm does not know | Its guide | Its maker's macOS command as read on the maker's page on 2026-11-15, another way where there is one, an https page; none for the unknown one; the words of the title, the message and the help | U |

### Handoff

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| HAND-1 | A conversation of each agent, with tool traffic in it | Prepare a handoff | The file holds what the user and the agent said, without the tool traffic | H |
| HAND-2 | A git repository | Prepare a handoff | The file is in `.agentterm/handoffs/`, and git does not list it as a change | H, M |
| HAND-3 | A past conversation of Claude Code, Codex installed too | Choose Hand Off on the conversation | A sheet names Codex and shows the prompt it will start with, naming the handoff file | P, M |
| HAND-4 | The sheet from HAND-3 | Press Hand Off | A Codex session starts, told to read the handoff file, and the file exists in the project | P, M |
| HAND-5 | The same, with another folder picked under Continue in | Press Hand Off | The agent starts in that folder, which is added to the list | M |
| HAND-6 | A running session of an agent | Choose Hand Off from the session's menu | The sheet opens for that session's conversation | P, M |
| HAND-7 (#150) | A conversation of a repository | Hand it off into a new worktree, on a branch named; again with the same branch | The worktree on that branch, the file written in it, saying it is a worktree and to work there only; the second refused | U |
| HAND-8 (#150) | A conversation of the folder | New Worktree in the worktrees' popup (#217), Begin: Continue a Conversation, Create | The conversation picked already, and what is done said; the agent started in the new worktree on its branch, the handoff file there with the conversation | M |
| HAND-9 (#165) | Conversations of the folder, of one of its worktrees, of another project, of a subfolder | What a new worktree offers to carry on, on the Mac and the iPhone | The folder's and the worktree's, newest first, each once; not the other project's nor the subfolder's | U |

### The Mac window and its tabs

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| WIN-1 | A host with one folder | A second device adds a folder, then removes it | The Mac's list gains the folder, then loses it | H, P, M |
| WIN-2 | A session started in a folder that is not listed | Look at the list | The session is under "Other" | P, M |
| WIN-3 | The window with all three panes | Press Sessions in the bar of places twice, the Side Panel button twice | Each pane goes and comes back | M |
| WIN-4 | The window on Sessions, with a session, conversations in two folders | Press History, then Settings, then Sessions | History lists every conversation at the left; the side panel is in Sessions only; Settings lists its panes at the left and shows General in the middle, the terminal hidden; the line of figures is in neither; back on Sessions the folders, the line of figures and the session's terminal are there again | M |
| WIN-5 | The window on Settings, History or Schedules | Start a shell or an agent from the header | It is shown in Sessions | M |
| WIN-6 | The app staying in the menu bar (on by default), its window closed (#182) | Open the app again, from the Dock, Launchpad or the Finder | Its window is shown, in front | M |
| TAB-1 | A shell and two agents | Pick the shell in the sidebar | Each agent has a tab; the shell is in the Shells tab, in its row, not a tab of its own (#127), and its terminal is shown | M |
| TAB-2 | The same | Pin an agent's tab | The host has the pin | H, M |
| TAB-3 | The arrangement from TAB-2 | Quit the Mac app and open it again; look on a second device | The same arrangement on both, also after the restart | H, M |
| TAB-4 | Several tabs, the Shells tab pinned, one file with unsaved changes | Close Others, Close All | The app asks before ending sessions; the pinned tab, with the shells it holds, and the unsaved file stay | M (Close Others: it asks, and the pinned tab stays) |
| TAB-5 | A file open and a diff picked | Look at the strip of tabs | The Files and Diffs tabs next to the sessions, the file and the diff in their rows | M (as part of FILE-3 and GIT-4) |
| TAB-6 (#127) | An agent's session on the iPhone | Pin it from its row's menu | Its row says it is pinned; the host has the pin | P |
| TAB-7 (#169) | A tab, a page, a group or a session with its × | The pointer is over it; a click beside the glyph, within the control | An 18-point control with a background closes it; a click outside it selects | hand: the tests press elements through accessibility, which does not show where a click lands |
| TABS-1 (#127) | An agent, its shell, a shell of the user's, a shell whose agent ended | Which have tabs of their own | The agent only: the Mac and the phones keep the same ones in the arrangement | U |
| TABS-2 (#145) | Closing a tab of the strip, ending an agent with 0, 1 or several shells and pages | What is asked, in `CloseWords` | "End 3 shells?", "Close 2 Pages", "Its 2 shells and 1 page are closed with it."; one shell asked, one page, diff or file not; the Files tab's item is not the pane's "Close All Files" | U |
| TABS-3 (#145) | Two shells of the user's | End Shells on the Shells tab; Cancel; again, End 2 Shells | "End 2 shells?"; both still run; both end and the tab goes | M |
| TABS-6 (#152) | A shell of the user's, picked | Pick the folder in the list; the Shells row; the shell | The folder's row alone is marked, the shell still shown; then the Shells row alone, with End Shells in its menu; then the shell alone | M |
| TABS-5 (#146) | A new agent, its conversation not named yet, with a shell beside it | Read the agent's item in its row, and its tab | The item says "Agent"; the tab says "Claude Code": never the same | M (PANE-20's test) |
| TABS-4 (#145) | An agent with a page it opened and a shell from + Shell | End Session on the agent's tab | The question names its shell and its page; the agent and its shell end, the page closes; no Shells or Browser tab of the user's is left with them | M |

### Panes (#69)

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| PANE-1 | Three tabs in one pane | Move one to a new pane on the right, then show it in the first pane again | It is in one pane at a time; the pane it left closes, its tab gone | U |
| PANE-2 | Two panes | A new tab comes; a tab is shown | The new one goes into the pane the keyboard is in; showing a tab moves the keyboard to its pane | U |
| PANE-3 | Three panes, the middle one with tabs | Close it; close panes until one is left | Its tabs join the pane nearest to it, which takes the keyboard; the last pane stays; nothing ends | U, M |
| PANE-4 | A pane whose front tab ends | The tab goes | The tab before it comes to the front | U |
| PANE-5 | [ a \| [ b / c ] ] | Move the keyboard left, right, up and down | To the pane on that side, none past the window's edge | U |
| PANE-6 | Two panes | Show one alone; another takes the keyboard; close the one shown alone | Only it is shown, then all of them again | U |
| PANE-7 | A layout of two panes | It is kept as JSON and read back; a pane is split after | The same layout; the new pane has a name of its own | U |
| PANE-8 | Four tabs, two of them in a pane, moved | Look at the pane's strip | Its own two, in the arrangement's order | U |
| PANE-9 | Two shells | Look at the strip, the pane's and a tab's actions, the menu bar | Both in the one pane, in its Shells tab, which says it holds two; no button, action or menu item splits it, starts a tab from the strip, or moves a tab to another pane | M |
| PANE-11 | Two projects, a shell in each | Pick each folder in turn; pick a session of the other project in the list | Each shows its own panes and none of the other's tabs; the session shows its project | M |
| PANE-12 | An agent that opens a shell through the MCP server | Look at it; hide its shells from its row; show them; hide them and pick the shell in the row; look in Settings | The shell shows under the agent, in its area (#69), and is in the agent's row (#127), not a tab, nor in the Shells tab; in the list at the left, right under the agent and set in; hidden, it keeps running and stays in the row, whose button, or the shell picked there, brings it back; no switch makes it a tab | M |
| PANE-14 | An agent the user types to | It opens a shell, and a page | The keyboard stays where it was | hand |
| PANE-15 | An agent and its shell below it, Vietnamese input (Telex) | Type in one, click into the other, type | Each composes in its own terminal | hand |
| PANE-16 | Two shells | Pick each in the row of the Shells tab; pick each session in the list; View > Next Item in Group twice, then Previous Item in Group | The keyboard goes to the terminal picked, each time; the menu goes round the shells the tab holds, one shown at a time | M |
| PANE-17 | An agent with its page beside it | Pick the page in the list; pick the agent; the agent loads two pages, one with a field that asks for the keyboard | The page's row alone is selected, the page has the keyboard; then the agent's row alone, its terminal has it; the pages the agent loads take neither | M |
| PANE-19 | An agent with its page and a shell | Look at its row; View > Keyboard to Its Page, to Its Shells, to the Agent; to Its Page and Show This Part Alone; again; hide its page from the row; pick the page in the row | The row holds the agent, its page and its shell in that order, and says which has the keyboard; the keyboard in each; the page alone, the agent and its shells hidden, a bar that says so, the keyboard in the page; all of them again; hidden, the page stays open and in the row, the keyboard in the agent; picked, it is shown again with the keyboard | M |
| PANE-20 (#127) | An agent | + Shell in its row; `shell_list` and `shell_run` as the agent | A shell in the agent's folder, in its row and shown under it with the keyboard, not in the Shells tab nor a tab of its own; the agent lists it and runs a command in it | M |
| PANE-21 (#69, #127) | An agent's area: a shell and a page picked, then gone | Which shell and which page it shows | The one picked while it is there, the last of them otherwise; none when there are none | U |
| PANE-22 (#171) | Three shells in the Shells tab | View > Item 1, 3, 2 in Group (⌥⌘1, ⌥⌘3, ⌥⌘2) | That shell shown each time, with the keyboard | M |
| PANE-23 (#171) | A tab whose row holds several items | Look at it, then point at an item | Each of the first nine says its keys (⌥⌘1 and on) at its end, always, as the strip's tabs say ⌘1 to ⌘9; under the pointer its × takes their place. The numbers shown only while ⌥⌘ was held were taken away (the owner's decision, 2026-11-21) | hand: the tests do not move the pointer |
| PANE-24 (#171) | The user's Browser tab with two pages; an agent's tab with its page and its shell | ⌥⌘1, ⌥⌘2, then View > Previous Item in Group; in the agent's tab ⌥⌘2, ⌥⌘3, ⌥⌘1, then Keyboard to Its Page | That page or part shown, with the keyboard; the shortcuts that move by one as before | M |
| SHELL-SPLIT-1 | Two shells of the user's in the Shells tab | The right turned on; below turned on; the first picked in the row; its menu's Show on the Right; the right turned off | The right shows the second, with the keyboard; below a new shell, with the keyboard, all three on show; the keyboard back on the left, nothing moved; the first on the right with the keyboard, the second on the left; the first gone from view, still running and in the row. A shell dragged from the row onto a part: by hand, the tests do not move the pointer | M |
| SHELL-SPLIT-2 (#188) | Two shells, the first on the left, the right off; the same with nothing picked; three with the left's on the right and below on; one below moved to a right that is off; the left's shell ended, the other two on the right and below | Its menu's Show on the Right (or Show Below); the shell ends | The first on the right alone, with the keyboard, the second on the left: no shell in two parts; parts already on change places as before; the part a shell left from the right or below is turned off; the right's shell moves to the left. Before the fix the shell was in both parts, one blank, and the keyboard went back to the left: seen failing, then passing | U (`ShellSplitTests`), M (the first, and below's moved to a right that is off; a picture after each) |
| SHELL-SPLIT-3 (#188) | One shell, on the left; or two, the other on the right | Show on the Right (or Show Below) on the left's | Refused, nothing moved, no shell started; the window's notice says `ShellSplitWords.leftKeepsIt` at once | U, M (the first; a picture of the notice) |
| SHELL-SPLIT-4 (#189) | One shell, the host's answers held back (`SlowProxy.hold`) | The right turned on, then below, then the answers let through | The right shows the first new shell, below the second, all three on show. Before the fix below took the right's wait and the right stayed off | U, M |
| SHELL-SPLIT-5 (#189) | Two shells, the second on the right; the host's answers held back | Below turned on; the right turned off; the second picked in the row; the answers let through; or the part turned off, or the host's error | The second on the left, below still off; then below shows the new shell. Turned off, or after an error or a lost connection, the part waits no more. Before the fix below took the second. The hold first let one answer through: a receive the proxy had asked for while the link was idle, before the hold, ended with the new shell's answer, so the app had the third below with the keyboard, and the second, picked, went there, as SPEC says it should. The answer now waits too, and both tests check that the app has not heard of the new shell while held: seen failing, then passing | U, M |
| SHELL-SPLIT-6 (#189) | A part waiting for the shell launched for it | A shell new to the tab, launched for no part, is put in front and is in the row; then the host names the part's own (`attached`'s `request`) | The other is not taken, the part still waits; then it shows its own. Before the fix, which knew only "new to the tab", it took the other: seen failing, then passing | U (`ShellSplitTests`) |
| SHELL-SPLIT-7 (#189) | The right and below both waiting, each for its own launch | The host refuses below's launch (`error`'s `request`); an error for a request no part made | Below waits no more; the right still waits and takes its own shell. Before the fix any error ended every wait: seen failing, then passing | U (`ShellSplitTests`) |
| SHELL-SPLIT-8 (#188) | Three shells, the first on the left, another on the right | The keys that pick an item of the row (⌥⌘ and its number, ⌥⌘→, ⌥⌘←): the left's, the right's, the one not shown | They move no shell between parts: one shown in a part takes the keyboard there; one not shown takes the place of the shell in the part with the keyboard, which goes back to the row; no shell is in two parts, and none is started. The context menu of the row and a drop are the only ways to move a shell between parts, and both go through `showShell` | M |
| PANE-28 | An agent's tab with its page and its shell; the app told to write down the places a click looks in (`AGENTTERM_PANE_PLACES`) | Its page hidden from the row and shown again | The agent, its page and its shells are all found by a click. Before the fix the agent's part, made again, had its place taken away by the one made before it, which went after it appeared: a click in the agent left the keyboard and the frame where they were (the owner's report, 2026-11-21). Seen failing, then passing | M |
| PANE-27 | An agent's tab with its page and its shell | The keyboard put in its shell (BrowserUITests `testTheKeyboardMovesAboutAnAgentsArea`, picture `keyboard-in-its-shell` with `ALL_SHOTS`) | Looked at: the parts parted by lighter gutters with a grip, the shell framed in the accent colour, the others not; alone, no frame | M, picture |
| PANE-26 (#171) | Two files open in the Files tab | Look at the row | "⌥⌘1" and "⌥⌘2" within their chips, always. Before the fix a number alone, while ⌥⌘ was held, set 3 points above its chip, where the row's scroll view cut it off under the strip: seen failing (122 against 125), then passing | M |
| PANE-25 (#171) | Two files open in the Files tab; two diffs in the Diffs tab | ⌥⌘1, ⌥⌘2, then the shortcut that moves by one | That file or diff shown, its text with the keyboard. Before the fix the keyboard stayed with the window: only a terminal or a page was given it. Asked for while the new editor was made but not yet in the window, it was lost now and then (#184, 3 failures in 10 runs): the editor and the diff's text now take it as they move into the window | M |
| PANE-18 | Tabs, the browser beside an agent | Click a tab, its close button, a session in the list, the agent's terminal while the page has the keyboard | Each click does what it says at once, and the keyboard goes where it was clicked | hand: the mouse's own events cannot be given to the app without moving the user's pointer |

### Git

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| GIT-1 | The fixture project | Open the Git tab | `notes.txt`, `guide.md` and `new.txt` are listed under Changes, each with a button to stage it | H, P, M |
| GIT-2 | The same | Stage `notes.txt`; Stage all; unstage `new.txt` | After each step git's index holds exactly what the lists show as staged | H, P, M |
| GIT-3a | Two files staged, a message in the field | Press Commit | git has a commit with that message; the committed files leave the list, the others stay, the field is empty | H, P, M |
| GIT-3b | A pre-commit hook that prints a message and fails | Press Commit | git's own words are shown; no commit is made; the message stays in the field | H, M |
| GIT-3c | A pre-commit hook that records the environment it is given | Press Commit | The hook sees `GIT_TERMINAL_PROMPT=0`, no `GIT_ASKPASS` and `SSH_ASKPASS_REQUIRE=never`, as push and pull do; the commit has the message as written | H |
| GIT-4 | `notes.txt` changed | Pick it in the list; switch to two panels and back | Its diff opens as a tab with `+second line`; in two panels the line is in the text of the right panel, without its mark or its number, and not in the left's | P, M |
| GIT-5 | Changes in several folders | Press Group by folder | The list becomes a tree; folders fold and show totals | H, P, X |
| GIT-6 | One panel and a flat list on both devices | Choose two panels, or the tree, on one device | The other device shows the same choice | H, M, X |
| GIT-7 | One commit that the remote does not have | Press Push | The remote has the commit | H, P, M |
| GIT-8 | A pull that would conflict; a remote that asks for a password | Pull; push | The pull stops on the conflict and says so, to be resolved or aborted (GIT-57); git fails with its own message instead of waiting | H |
| GIT-9 | A push under way on the iPhone | The changes are asked for again meanwhile | That answer is not taken for the end of the push | H |
| GIT-10 | Files staged, a stand-in agent that answers with a message | Press Write | The agent's message is in the field; nothing is committed | H, M |
| GIT-11 | Default commit message settings | A second device sets agent Codex, a model and a prompt | Settings > Git shows that agent, model and prompt, and the Write button names Codex | H, M |
| GIT-12 | Changes listed on the Mac | Another device stages everything and commits | The Mac's list is empty and git has that device's commit | M, X |
| GIT-13 | A diff scrolled part of the way down | The file changes under it | The diff stays where it was scrolled to | M |
| GIT-14 | A remote that wants a sign-in; a credential helper (`!name`) in a folder only the login shell's `PATH` names | Push; pull | git finds and runs the helper | H |
| GIT-15 | A pre-commit hook that calls a tool in a folder only the login shell's `PATH` names | Press Commit | The hook finds the tool; the commit is made | H |
| GIT-16 | A credential helper that is nowhere, written as `!name args` or as a name git knows (`credential.helper = name`) | Push | The first line says "git could not sign in to <host>: its credential helper `name` was not found."; git's own words follow. A helper that answers with a sign-in the remote refuses is not called missing | H |
| GIT-17 | The login shell asked once, before a tool the hook calls was installed | The shell's `PATH` now names the tool's folder; press Commit | The shell is asked again and the commit made on the second try; when the shell's `PATH` is the same, the action is not tried again | H |
| GIT-18 | A login shell that prints its `PATH` after other lines, or prints nothing | The host asks it | Only the `PATH` behind the marker is taken, once; with nothing, git keeps the host's `PATH` and `GIT_TERMINAL_PROMPT=0` is still set | H |
| GIT-19 | The host tests, which stand in no shell of their own | A git action asks for the login shell's `PATH` | The user's own shell is not started and none of their startup files is read; the `PATH` stays the host's | H |
| GIT-20 | A repository with a file changed after it was staged, a changed file, a deleted one, a new file and a new folder; a file named like a pattern; a device | One file is discarded, a new one, then every change; again with nothing left; the same through the host | The file goes back to what is staged of it and what is staged stays; the new file is in the Trash; all of them: changed and deleted files are back, the new folder is in the Trash whole and none is left empty; nothing left is said; a name is taken as it is; the device is sent the list each time | H |
| GIT-21 | One change to a tracked file; one new file; several of both | What is asked before discarding | "Discard the changes to …?", that it cannot be undone; "Move … to the Trash?", that it can be put back; "Discard all N changes?" with how many of each | U |
| GIT-22 | The Mac app, a changed file and two new ones | Discard on a row, Cancel; again, Discard Changes; Discard all, Discard All | Asked each time; cancelled, nothing changes; the file is as committed and the others are left; then nothing is uncommitted and the new files are in the Trash of the test | M |
| GIT-23 | The iPhone, a folder with changes | A file's menu, Discard Changes…; Discard All… | Asked as on the Mac; the Mac's files change and the list follows | hand, until the iPhone tests cover it |
| GIT-24 | A repository with a remote, a branch ahead of the one it follows, a merged branch, a commit whose subject has a tab; a folder that is no repository | Its branches are read | Its own first, the checked out one before the rest, then the remote's; each with what it follows, how far ahead, its last commit, whether it is merged; none for a folder that is no repository | H |
| GIT-25 | A repository; a change that is not committed; a remote with a branch the repository has not | A branch is made, with and without checking it out, with no name, a name git refuses, a name that is taken; switched to; switched to with a change in the way; renamed; deleted merged, not merged, forced, checked out; a remote's is switched to twice | Made from the checked out commit or the one named; the switch that would lose a change is refused in words and nothing is lost; a branch with commits of its own is kept unless forced and the checked out one always; the remote's becomes a branch of its own that follows it, used again the second time | H |
| GIT-26 | A device and a repository | It asks for the branches, makes one, switches, is refused a switch, renames, deletes | Each change is answered with the branches and the folder's changes, a refusal with git's words first | H |
| GIT-27 | A branch ahead and behind; one whose remote branch is gone; a remote's; a merged one and one with commits of its own | Its words; what is asked before it is deleted | "2 ahead, 1 behind", "its remote branch is gone", the name it has here; asked once when nothing is lost, and a second time, saying its commits would be lost, when it has its own | U |
| GIT-28 | The Mac app | The branch in the header; New Branch…, a name, Create Branch; the first branch is chosen; Delete on the new one, Delete Branch | The branches are listed; the new one is checked out, with the changes that were not committed still there; the first is checked out again; the new one is asked about once and deleted | M |
| GIT-29 | The iPhone, a folder | The branch's name; a branch is touched; New Branch | The branches as on the Mac; the Mac's folder is on that branch; a branch is made and checked out | hand, until the iPhone tests cover it; making one is in GIT-73 |
| GIT-30 | Two clones of a remote; a commit pushed from the other; a change that is not committed; a branch made and deleted on the remote; a repository with no remote | Fetch | What the remote has is known; the branch and the files are as they were; a branch gone from the remote is forgotten; without a remote it says so | H |
| GIT-31 | A branch that diverged from its upstream, set up to merge, then to rebase | Pull by rebase; pull by merge | Rebased with no merge commit; merged with one: as asked, whatever the repository is set up to | H |
| GIT-32 | A remote with two commits the branch has not, and a commit of the branch's own | Push; what a forced push would overwrite; push forced; again; a branch that follows none | Refused, saying the remote has commits the branch has not and what to do, and nothing is overwritten; the two commits, newest first; the remote then has the branch's commits only; nothing left to overwrite; nothing to be told | H |
| GIT-33 | One commit to overwrite; eleven; none; settings saved before there was the choice | What is asked before a forced push; the setting | The commit named; eight named and the rest counted; that a plain push does the same; fetching by itself is on unless turned off | U |
| GIT-34 | The Mac app, a commit pushed to the remote by someone else | Fetch; a commit of this side's, then Force Push… from the menu, Force Push | Pull says one commit, and the files are as they were; the question names the other's commit; the remote then has this side's and not theirs | M |
| GIT-35 | The Mac app and the iPhone, a folder with a remote that cannot be reached | Five minutes with the changes shown; Fetch; "Fetch automatically" off | A warning beside the buttons, and no alert; Fetch says why in an alert; off, nothing is asked by itself, on either app | hand |
| GIT-36 | The iPhone, a folder with a remote | Fetch; Pull by Rebase; Force Push… | As on the Mac | hand, until the iPhone tests cover it |
| GIT-37 | A repository with eight commits, a branch merged in, a tag, a commit with a body | Its history, whole and a page at a time; another branch's; one that is not there; what a commit and what the merge changed | Newest first, each with its parents, its author and what points at it; the pages are the same commits in the same order, and say whether there are more; the commit's body and its file with its diff; the merge shows what it brought in | H |
| GIT-38 | A repository with two branches | A commit is reverted; one of the other branch is picked; one that conflicts is picked, and one reverted; a merge is reverted; a hash that is not there | A new commit takes the change back, or makes it here; the ones that conflict stop, say so, and are aborted, or resolved and continued (#42); the merge is said to be for a terminal; no such commit is said | H |
| GIT-39 | A straight line of commits; a branch merged into it | Where each is drawn in the graph | One lane for the line; the side in a second lane from the merge until the commit they parted from, where both end; the words asked before a revert and a pick | U |
| GIT-40 | A device and a repository of three commits | It asks for two commits, then two more; for what the newest changed; for a commit that is not there; reverts the newest | The pages, and whether there are more; the file with its diff; none; the file is as before that commit | H |
| GIT-41 | The Mac app, a commit with a body | Commits; the commit; its file; Revert from its actions, Revert | Listed with the commit before it; its body and its file; the diff under the commit's hash, with nothing to stage; asked, then a new commit that reverts it leads the list and the file is as it was | M |
| GIT-42 | The Mac app | Copy Hash; Cherry-Pick from another branch's commits; scrolling past fifty commits; a history with a merge | The hash is on the clipboard; the commit is on the checked out branch; older commits are read as they come into view; the graph shows the side beside the line | hand: the clipboard is the user's |
| GIT-43 | The iPhone, a folder | Commits; a commit; a file; another branch picked above the list | The list with the graph as on the Mac; its message, hash and files; the file's diff; that branch's commits | hand, until the iPhone tests cover it; reverting is in GIT-74 |
| GIT-44 | A repository with nothing changed; with a new file only; with a changed file; with a staged change and a new file | Stash: with nothing; without new files; under a name; with new files and no name | Said there is nothing; said only new files changed; the change is aside and the new file stays; everything is aside and the folder as committed; listed newest first with their names, branch and files, the new file among them | H |
| GIT-45 | Two stashes | The older is applied; applied onto a change to the same line, as a pop; the newer is dropped; dropped again; the older is popped where it fits | Back and still stashed; said to conflict and kept; the older is the same stash at another place; said to be gone; back and out of the stash | H |
| GIT-46 | What git notes of a stash with a name, without one, and words of its own | Its words; what is asked before it is dropped | The name and the branch; "Changes on" the commit it was made on; that nothing else holds what is in it | U |
| GIT-47 | The Mac app, a changed file and two new ones | Stashes; Stash Changes…, a name, Stash; the stash; a file; Pop; stash again; Drop, Drop Stash | Nothing is stashed; the folder is as committed and the stash is listed by its name; its files, the new ones too; the diff under STASH; the changes are back and nothing is stashed; asked, then gone | M |
| GIT-48 | The iPhone, a folder with changes | Stashes; Stash Changes; a stash; Apply; Drop… | As on the Mac | hand, until the iPhone tests cover it |
| GIT-49 | A repository with no commit; with two; with a file staged since; with a remote | Amend and undo with no commit; the last commit's message is amended; amended with no message and a file staged; undone; the first commit is undone; a commit that is pushed and one that is not | Said there is none; the message is another and the commits as many; the file is in the commit and its message kept; the branch is at the commit before, its changes staged, and what was not committed as it was; the branch has no commit again and the file is staged; said to be pushed, or not | H |
| GIT-50 | The last commit, pushed or not | What is asked before it is undone, and amended | Once, saying its changes stay staged; when it is pushed, that it is asked once more, then what follows from changing a pushed commit, for undoing and for amending | U |
| GIT-51 | The Mac app, a commit with a wrong message, a file staged since | Amend Last Commit… from the menu beside Commit; the message is put right, Amend with 1 File; Undo Last Commit…, Undo Commit | The commit's message is in the field under "Amending"; the commit has the new message and the file, and is still one commit; asked, then the branch is at the commit before and both files are staged | M |
| GIT-52 | The Mac app and the iPhone | Amend with nothing staged and no changes; Cancel; a commit that is pushed is undone; Amend and Undo from the newest commit in Commits; the same on the iPhone from the menu beside the branch | The commit box shows for the message alone; cancelled, the message goes; asked twice; as from the menu; as on the Mac | hand |
| GIT-53 | A file with a line changed, one put in and one taken out; a new file; a file without a final newline | The change to one line is staged; of the rest, the line put in is discarded; the staged hunk is unstaged; a part of a diff the file has moved on from is discarded; the first line of the new file is staged; the last line of the other | Only that is staged, the rest is as it was; the line is gone from the file and what is staged untouched; it is among the changes again; refused in words and the file left alone; the index has the first line and the file both; staged | H |
| GIT-54 | A diff of two hunks | It is taken apart; a hunk as a patch; one line of it, for staging and for discarding; nothing picked | The hunks with where they start, their section and their lines; the patch with the names git needs; the line left out stays as a line both sides have, or goes, by which way the patch is applied; no patch | U |
| GIT-55 | The Mac app, a file with two hunks | Stage Parts…; Stage Hunk on the second; a line of the first is ticked, Stage 1 Line; Discard Hunk…, Discard; Done | Both hunks with their lines; only the second is staged and it leaves the list; the line is staged; asked, then nothing is left that is not staged | M |
| GIT-56 | The Mac app | Unstage Parts… on a staged change; the same with the diff in two panels; on another Mac | A hunk and lines are unstaged; the same sheet; the same, through that Mac's host | hand |
| GIT-57 | Two clones that changed the same line; one where a side deleted a file and both added two; a pull set to rebase | Pull; continue with a file still conflicting; mark one with markers resolved; abort; pull again, take theirs, continue; take theirs where it deleted, ours, and edit by hand; the rebasing pull is aborted, then resolved and continued | Left stopped, saying so, with the file listed as conflicting and how; refused in words; as before the pull; a merge commit with their line; the file is deleted, ours kept, the edited one as written; the rebase is given up, then finished with this branch's commit on top | H |
| GIT-58 | The Mac app, a merge stopped on one file | The Git tab; Abort…, Cancel; Take Theirs; Continue | "Merging: 1 file conflicts" and the file; asked, and nothing changes; every conflict is resolved and the file leaves the list; the merge is committed and the banner goes | M |
| GIT-59 | The Mac app and the iPhone | Edit, the markers taken out, Mark Resolved; Stage all while a file conflicts; a rebase that stops twice; on the iPhone, the card, a file, Abort… | The file opens in the editor and is then resolved; refused in words; said to have stopped again; the files as they are, and everything put back | hand |
| GIT-60 | A project with a submodule; two files changed inside it | The folder's changes; one discarded and one staged in the submodule; discard all in the folder; commit in the submodule; stage and commit the submodule in the folder | None of the folder's own, the two under the submodule with their diffs; as asked, there; nothing to discard; nothing is changed inside it and its commit is a change of the folder, saying from which commit to which; the folder records the new commit | H |
| GIT-61 | A submodule with a new commit and an untracked file inside, and a changed file of the folder | The folder's changes; discard all in the folder | The file and the submodule's commit as the folder's, the untracked file under the submodule; the file is restored and the recorded commit checked out, the untracked file stays, and the submodule says it has no branch checked out | H |
| GIT-62 | A submodule inside a submodule with a change; the project seen from a folder inside it | The changes | Listed under the inner one, under the outer one; the submodule named from that folder | H |
| GIT-63 | A host, a device that asked for a folder's changes | A file is staged, then committed, inside its submodule; the folder is asked for again each time | Answered with the submodule's changes; the folder says what is so now, at once: staged there, then the commit moved | H |
| GIT-64 | The Mac app, a project with a submodule and a file changed in it | The Git tab; the file; Stage; Commit… with a message; Stage the submodule | Listed under the submodule and not as the folder's; its diff, said to be in the submodule; staged there; committed there, the list gone and the submodule's row in the folder's changes with its two commits; staged | M |
| GIT-65 | The Mac app and the iPhone | Discard inside a submodule and of its commit; Commit… with no branch checked out; hunks of a file in a submodule; on the iPhone the submodule's lists and its commit box | Asked first, in the submodule's words for its commit; warned; applied in the submodule; the same as the Mac, committed from the box under the submodule | hand |
| GIT-66 | A repository whose index is out of date: a file's time changed and its text did not; another file really changed | The host reads the changes, makes the diff, lists the branches and the files, notes how the folder is for a run and what changed since | Nothing is written into the repository: its index is byte for byte as it was, and no `index.lock` is left. Before the fix each of the first, the diff and the last two rewrote it | H |
| GIT-67 | A repository with a worktree of its own in `.claude/worktrees`, work in it, a file beside it, a changed file and a new one; then a new folder of two files | Every change discarded; one file of the folder; both, by name | The worktree and its work stay, and are not listed; the rest goes; the other file and the folder stay; the folder goes to the Trash whole. Before the fix `.claude/` went to the Trash, the worktree in it | H |
| GIT-68 | The Mac app, the fixture project with a worktree of its own inside it and 53 more new files | Discard all, Discard All | "Discard all 51 changes?"; the fifty listed go, the five not listed and the worktree stay. Before the fix every new file went, listed or not | M |
| GIT-69 | A diff cut off in its second hunk | Taken apart; each hunk as a patch | Both shown, the second as far as it goes and marked cut; a patch of the first, none of the second; the Mac says why where its buttons would be | U |
| GIT-70 | A folder inside its repository, a changed file and a new one in it | A hunk staged, unstaged and discarded from that folder; the new file's staged | Each done. Before the fix git skipped the file and said nothing went wrong | H |
| GIT-71 | A remote someone pushes to after a forced push was looked at, and a fetch in between | The forced push; one without a lease; looked at again and pushed | Refused, in words, the commit pushed since still there; refused; pushed over what was said this time. Before the fix the commit was overwritten | H |
| GIT-72 | A repository; `--output=<file>` named as a branch and as a commit | Log, show, revert, pick, a branch made from it, switched to, renamed, deleted | None of them writes the file or makes a branch; names that are names still work | H |
| GIT-73 | The iPhone, the fixture project | A branch made without switching to it; renamed from its menu; deleted from its menu | Made; listed under its new name and not the old; asked once (nothing of its own), then gone, as on the Mac (#35) | P |
| GIT-79 (#166) | The iPhone's Git tab, one commit to push, Fetch, Pull, Push and the menu side by side | It is shown | Push says its count on one line, as tall as Fetch: "Push 1 commit" where there is room, else "Push 1"; read out as "Push, 1 commit" | P |
| GIT-74 | The iPhone, the fixture project after its commit | Commits; the newest, Revert…, Revert; the revert, the same | Picking is offered too; asked first, in the Mac's words; each revert is the newest commit after it, and the files are as they were (#36) | P |
| GIT-75 (#82) | A diff with hunks, removed and added lines; one of 20,000 changed lines | Laid out as two panels | Each side is one text with a line for every row, facing the other's, the header on the left; the numbers and the marks are drawn, not in the text, so what is copied is the file's; no row left out, where 2,500 were the most; every row one line of one height; laying out ten times the rows takes less than fifteen times as long, in the best of three rounds: a runner of CI that is slow for a few seconds made one round say 16.1 times where it says 11 (#136) | U |
| GIT-76 (#116) | A folder whose remotes the app is asking by itself; one with nothing under way; one with something of the user's under way | A push asked for in each; the app's own fetch asked for again | Kept, the folder busy with it from then, and handed back once to be begun when the fetch is over; begun at once; refused, and the app's own fetch not begun beside it, nor twice. Nothing kept is begun once the connection is another. The Mac and the iPhone both go by `RemoteWork` | U |
| GIT-77 (#116) | A second folder whose remote takes five seconds to answer a fetch and lacks the folder's last commit; the app in front | The folder picked; while the app asks its remotes by itself, Fetch, Pull and Push looked at, and Push pressed | None is held; the push is made once the fetch is over, not beside it, and the remote has the commit. Before, they were held meanwhile, Fetch turning, and a press that got through as the fetch began was thrown away without a word | M |
| GIT-78 (#151) | A submodule with a change staged in it | Write in its own box, then a message of the user's, Commit | The stand-in's message in the submodule's field, nothing committed; then the commit in the submodule, and its new commit a change of the folder | M |

### History

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| HIST-1 | Conversations of each agent in a folder, a subfolder and a look-alike sibling | The host lists the folder's conversations | Only that folder's, newest first | H |
| HIST-2 | One conversation of Claude Code in the fixture project | Open History | The conversation is listed, with "1 conversation"; on the Mac every conversation is, with no switch to one folder's | P, M |
| HIST-3 | The same | Choose Resume | A new session of that agent starts with the conversation's id on its command line | H, P, M |
| HIST-4 | History on the Mac, one conversation | Look in the middle; pick the conversation | "Choose a conversation", not a folder's launch screen; then the conversation: its agent, title and folder, Resume, Copy Resume Command, its transcript, and under Hand Off the handoff form with the agents to hand it to | M |
| HIST-5 | The Mac's Sessions, a conversation in the folder and one in another folder | Open the side panel's History; pick the conversation | Only the folder's is listed; picked, it is shown in a sheet over Sessions, which stays, with Resume and the handoff; Close puts it away | M |
| HIST-6 | A session of 3,000 lines opened again on the iPhone | Scroll to the top, twice | It came with 500 lines above the screen; each time earlier lines load, 1,000 more, a strip saying so, and the line in view stays in view; the host writes out only as many as asked and says how many it keeps | H, P |
| HIST-10 | A Claude Code conversation with tools, a subagent's lines and the app's own | Read | What was asked and answered, each tool with what it ran on; not the subagent's or the app's lines; the model, tokens counted once for each message, the last branch, each file once, how long it ran | H |
| HIST-11 | A conversation of 650 entries, one of them very long | Read | The last 600, saying 52 are left out; the long one cut; what the file does not say is not known | H |
| HIST-12 | A Codex and a Copilot conversation | Read; the Copilot one again after its session ended | Each as its own record tells; Codex's files are not recorded, Copilot's cost is not shown and its files are told once it ended | H |
| HIST-13 | Two conversations | Searched for a word in a title and in what was said, in another case, with a quote in it, for a field's name, for blanks; stopped | Found with a piece of the text and how often; found all the same; nothing; nothing | H |
| HIST-14 | A Claude Code and a Copilot conversation; a file named by a client outside the agents' folders | Deleted; deleted again; the forged one; Antigravity's | Moved to the test's own trash and no longer listed; said to be gone; refused, the file untouched; refused with what to do instead | H |
| HIST-15 | Conversations of two agents in two folders, one in a worktree, over three weeks | Filtered by agent, by folder, by today, this week, a day | Each only what passes; the worktree's is its folder's | U |
| HIST-16 | The same | Grouped by day; by agent, in another order of the agents; one agent's by day | Today, Yesterday, then dates; the agents' groups in the order given, and no other group, none of pinned ones (#219); the filter holds in either grouping | U |
| HIST-17 | A conversation's figures | Its length, tokens and facts in words; its Markdown; the two questions before deleting | "2 h 5 min", "34k"; what is not recorded is said; the tool line and what is left out; the first question does not offer to hide it (#219); the second question names the agent | U |
| HIST-18 | A host, two devices, two conversations | Read; one that is not there; searched; written out as a file; older ones; deleted; deleted again | Read with what the file tells; said to be gone; found by what was said; a file in the host's folder; none; in the trash, both told; said to be gone, and no longer listed. Nothing pins or hides one (#219) | H |
| HIST-19 | The Mac app, two conversations in the folder | Search a word one of them said; clear; pick it; look at its header; Close; look at what its row offers; Delete the other, twice | "1 found" with the text around it; both back; the transcript with its tool, length and model; no Pin and no Hide from the List in the header, neither offered by the row (#219); asked twice, the row gone and its file in the trash | M |
| HIST-21 | The Mac app, a conversation whose agent answered in Markdown (a heading, a list, code, a table) | Its transcript; Preview Markdown; Close and open it again; Show as Text | As written; rendered; still rendered; as written again (#50). The iPhone's switch is checked by hand | M |
| HIST-22 | The Mac app, a conversation's transcript | Look at its header | Delete… is a button in view, with no menu (#50); there is no Pin and no Hide from the List (#219). The iPhone keeps Delete… in its menu | M |
| HIST-23 | A host, two devices, four conversations, one whose agent named a word its title does not, and one of Antigravity; a `history.json` an earlier build left, naming one as pinned | Searched for it; by the titles only; two deleted together, one of them Antigravity's; every one deleted | Both found; only the one whose title holds it; the other deleted, Antigravity's kept, every device told of each and the sender "deleted 1, kept 1"; all but Antigravity's in the trash, the one an earlier build had pinned too (#50, #219) | H |
| HIST-24 | The Mac app, two conversations in the folder, one in another and one of Antigravity; then the iPhone | Search a word only said; Titles Only; a word of a title; Select, tick two, untick one; Delete 1…, twice; Delete All…, twice. On the iPhone: Select, tick one, Done | History's list wider than the others'; "1 found"; none; "1 found"; "1 picked", nothing opened; the row gone, nothing said; no row offers Pin, every one gone but Antigravity's, "1 was kept: having a session, or of Antigravity." said (#219); the questions' words checked by themselves, which do not speak of pinned ones. On the iPhone "1 picked", nothing opened, the list back after Done; its Titles Only and its deleting are checked by hand (#50) | U, M, P, hand |
| HIST-25 | The Mac app, a conversation's transcript | Look at what was asked, what was answered and a tool's line | Each thing asked and answered offers Copy, a tool's line does not; Copy is not pressed, the pasteboard being the user's. The iPhone's is checked by hand (#50) | M, hand |
| HIST-20 | The Mac app and the iPhone | Group by day; filter by agent, folder, a day; no Pin, Hide or Show Hidden in any menu, on the iPhone too (#219); Copy Transcript and Open as a File; Show Older with more than 300; on the iPhone all of it, and Read the Transcript | As HIST-15 to HIST-18 say; the file opens as a tab; the next 200; the same as the Mac | hand |
| PERF-1 (#201) | A message of 1,000 bytes; one larger than a frame may be | Sent | The small one in one frame; the large one in pieces of no more than 256 KB, joined whole | H |
| PERF-2 (#201) | A folder of 25,000 entries with long names, whose list is larger than a message could hold | Listed by a client | It arrives whole, in pieces | H |
| PERF-6 | A terminal of 5,000 lines on the iPhone | A fast swipe, five times (`SCROLL=only scripts/test-ios.sh`) | The app's processor work while it coasts is measured; the figures are in PERFORMANCE.md | P |
| PERF-7 | A session of 10,000 lines | A client attaches; another asks something meanwhile; the session writes meanwhile | The other is answered at once (measured: `scripts/measure.sh`); what was written follows the screen | H |
| PERF-8 | The real host, on a state folder of its own | Twenty sessions opened and ended, then 180 more (`scripts/measure.sh`) | `leaks` finds nothing; what it has allocated (`heap`) after 200 is within 15% of what it was after the first 20 | H |
| PERF-9 | The iPhone app, two agents' sessions listed (a shell's menu has no Pin since #127) | A session's menu opened and an entry picked, each step timed, as XCUITest does them and with its wait for the app to be idle left out (`IDLE=only scripts/test-ios.sh`) | The figures: 61 s for the press and 61 s for the pick while the menu is open, 1.5 s and 0.4 s without the wait; a tap with no menu about takes 2 s either way (measured 2026-11-14, #65) | P |
| PERF-13 | The iPhone app, two listed folders; then the same at the end of the whole test, after the second Mac | "Move Down" chosen in the first folder's menu again and again, the order looked at each time (`MENU=only` or `MENU=after scripts/test-ios.sh`, `MENU_ROUNDS` times) | How many touches were lost. 0 of 30 alone and 0 of 20 at the end of the whole test, each round 3.1 to 3.3 s (measured 2026-11-15, #83). The two losses of ten runs made with the repeated gestures taken out were not seen again | P |
| PERF-10 | The Mac app, told to note when its main thread is held up; a file with 20,000 changed lines, a text file of 5 MB, a session writing 12,000 lines | Each heavy thing done once and the app left alone meanwhile (`MEASURE=1 scripts/test-mac.sh MainThreadMeasurements`) | The figures: how often its main thread took longer than 16 ms to answer, and the longest; in PERFORMANCE.md. Skipped unless asked for | M |
| PERF-11 | A Swift file of 20 KB, one over 512 KB, plain text | Which is colored, and the text storage made for each | The small one in a known language; the others get a plain storage | U |
| PERF-12 | The editor made with no text, then given one over 512 KB in a known language; then a small Swift file in it | Whether each is colored | Not the large one, the small one. Before the fix the large one was colored, as on the iPhone, where the file comes after the editor is made | U |
| PERF-14 (#104) | A text of over 1 MB with lines of every kind and every line break the layout knows; the editor's view of it | Given; a break typed; a carriage return and a line feed parted and brought together; lines pasted and taken away; a long text pasted; undone; a change it was not asked about; a line of tabs on show; a line typed longer | It sizes itself, AppKit does not: as tall as AppKit's own layout of the whole text at once after each (a second after the one it was not asked about), as wide as the widest line shown or typed in; a small text's view is AppKit's again | U |
| PERF-15 (#126) | The Mac app, told to note when its main thread is held up; a small Markdown document and `RELEASE.md`, `SPEC.md`, `DESIGN.md` and `TESTING.md` of this repository | Each opened in its preview, after a first preview that starts WebKit's process; `TESTING.md` scrolled from top to bottom in a second (`scripts/test-mac.sh MarkdownPreviewTimingTests`) | Opening `TESTING.md` and scrolling it hold the main thread up no longer than opening the small one, give or take a frame (16 ms): the work compared with itself. Before the fix, 1,738 ms against 40 ms; the figures in PERFORMANCE.md | M |
| PERF-16 (#126) | The iPhone app, told to note when its main thread is held up; the documents of PERF-15 in the Mac's project | Each opened in its preview from the folder's Files, after a first preview; `TESTING.md` swiped through six times (`MARKDOWN=only scripts/test-ios.sh`) | Opening `TESTING.md` and swiping through it hold the main thread up no longer than opening the small one, give or take a frame; the figures in PERFORMANCE.md | P |
| FIND-12 | A text of four lines, one empty; one with Windows line ends | Where line 1, 3, 4, 40 and 0 are | Each without its line break; the empty one at its place; the last line for a number past the end | U |

### Keeping the Mac awake, starting at login

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| AWAKE-1 | Keep awake on | A session starts; the last session ends | The hold on sleep is taken, then let go | H |
| AWAKE-2 | Keep awake off on both devices | Switch it on on the Mac; switch it off, or an option on, on a second device | Each device shows what the other set | H, P, M, X |
| AWAKE-3 | Keep awake on with "after 1 hour" | The hour passes | The switch goes off on both devices | H |
| AWAKE-4 | Keep awake on, a session running, macOS refusing the hold | Refreshes go by; then macOS gives the hold | It is reported once, that the Mac could not be kept awake; once held, the report says it is kept awake again | H |
| AWAKE-5 | Keep awake on with "only while an agent is working", a shell and an agent | The agent works, waits for permission, works, is done; then the option is turned off | Held while it works, let go while it waits and when it is done; the shell holds nothing. Off, the sessions hold the Mac awake as before. Options saved before the option existed read with it off | H |
| LOGIN-1 | A host that can be started at login | A client switches Start at Login on, then off | A launch agent naming this host's program is written, then removed; every client is told | H |
| LOGIN-2 | A host with a state folder of its own | Connect | No client shows the switch | H |
| LOGIN-3 | Start at Login on | Log out and in again | The host is running without the app having been opened | hand |
| LOGIN-4 | Start at Login on, and the app moved since: the launch agent names its host where it was | The app's host starts from where the app is now | The launch agent names this host's program | H |
| LOGIN-5 | Start at Login on for the installed app | A build that is not part of an app starts its host, or the installed host is started by hand with other arguments | The launch agent is left as it was | H |
| LOGIN-6 | A host launchd started from its launch agent, the app closed | The host is killed (SIGKILL); then it is stopped as asked (SIGTERM) | launchd starts it again after the kill, and says it was killed; after the stop it does not | H |
| LOGIN-7 | Start at Login on | The app starts its host; again while it runs; the host is killed within ten seconds of its start and the app starts it; Start at Login is turned off, the host stopped, and the app starts it | launchd starts it, once; started again at once, not after launchd's ten seconds, and the app is told it was killed; with the switch off the app starts its own and launchd has no job left | H |
| LOGIN-8 | A launch agent written by 0.5.0, without `KeepAlive` | The host it names starts; the same host started by hand with other arguments | It is written again as this version writes it; by the other, it is left as it was | H |
| LOGIN-9 | A host that can be started at login, run for the first time | It starts; the user turns Start at Login off; the next host starts | It is on by default; then it stays off: the user's choice is kept | H |
| LOGIN-10 | A host that can be started at login, where its launch agent cannot be written | It starts; then the next host starts, with the launch agent's folder writable | Start at Login stays off; then it is turned on: the failure was not taken for the user's choice | H |

### Menu bar, permissions, the host

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| MENU-1 | The window open | Close it | The menu bar icon stays, and its menu opens the window again | hand |
| MENU-2 | The app running | Choose File > New Shell, New Claude Code | A session of each kind starts | M |
| PERM-1 | The app running | Open Settings > Permissions | Each permission is listed with whether it is allowed, Notifications among them (#180) | M |
| HOST-1 | A host from another copy of the app on the app's port | Open the app | A banner names the other host's path and offers this app's own | M |
| HOST-13 (#204) | A program that is not an AgentTerm host (the test runner, through a `SlowProxy` in front of the host) on the app's port | Open the app | The banner says the port is in use by that program, by its name (`PortWords.inUse`); it is not called another copy's host, and neither Use This App's Host… nor Restart Host… is offered. Before the fix the banner of another copy's host named `xctest` | M |
| HOST-2 | A host of another protocol version | Connect | Both apps say the versions differ | H, P |
| HOST-14 (#214) | A host of protocol 32 (`protocolVersion`), which refuses what came after it as the real one does; then one of this release | A client connects and sends `readNotices` and `deviceInBackground`, then asks for the agents | The earlier host is not sent them and answers no "malformed message"; the host of this release is sent both. Before the fix the earlier host answered "malformed message", which the Mac app showed as a notice on its first opening after an update. `EarlierHostTests`. On the Mac, `HostReleaseTests.testAHostOfAnEarlierProtocolIsSaidInTheBannerOnly`: the banner says the host is from an older version, the app is connected, no notice says it a second time, and Restart Host… takes the banner away. That a notice already there goes once a host of the app's own release answers is not reached by a test | H, M |
| HOST-12 (#121) | The app as shipped, its own host left running from an earlier release (`--app-version 0.0.1`): built from other sources (`--host-revision`), then from the same ones | Open the app | Other sources: a banner says the host is from AgentTerm 0.0.1, older than the app, and Restart Host… asks, then starts the app's own, and the banner goes. The same sources: nothing is said, a release that changes nothing of the host asks for no restart | M, P |
| HOST-3 | A host with two sessions, `build` and `tests` | The host is killed (SIGKILL), and another is started on its state folder and port | Every client is told that the host stopped, about when, that `build` and `tests` ended with it, and that it was started again; so is a client that connects later, also after the host is restarted on purpose. Dismissed on one client, it is gone from all and not sent again | H |
| HOST-4 | A host with two sessions | It is stopped as asked for (SIGTERM: Restart Host, replacing another copy's host, logging out), and started again | Nothing is reported | H |
| HOST-5 | The Mac app on its host, a session `build` running | The host is killed | The app starts its host again by itself and shows a banner: the host stopped unexpectedly, was started again, and `build` ended with it. Dismiss takes it away here and on the host | M |
| HOST-6 | The Mac app on its host | The host is killed three times within sixty seconds | After the third the app does not start it again: it says the host keeps stopping, how often, why the last one stopped (it was killed), and offers Try Again, which starts it; the new host then reports the three | M |
| HOST-7 | The app's port held by something that is not a host | Open the app | The host it starts cannot listen there; the app says it could not be started, with the host's own words why, and offers Try Again | M |
| HOST-9 | A host started again each time it died, by launchd with the app closed | It dies three times within sixty seconds; then the user asks for it (Try Again) | The host after the third does not run: it exits with status 0, so launchd leaves it, and the third report says it keeps stopping. After Try Again it runs, and one more death does not break it | H |
| HOST-8 | The host on the Mac died with two sessions before this one started | The iPhone connects | A card says "The host on <Mac> stopped unexpectedly … and was started again", names the two sessions that ended, and goes once dismissed | P |

### Files

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| FILE-1 | The fixture project | Open the Files tab; press the `docs` folder | Folders come first, `.git` is not listed, and `docs` opens in place showing `guide.md` | H, P, M |
| FILE-2 | The same | New file, new folder, rename, move to the Trash; a name that is taken | Each is done on disk; the taken name is refused and nothing is overwritten | H, P, M |
| FILE-3 | `notes.txt` with two lines | Open it, add a third line, choose Save | The editor shows the two lines; the disk is unchanged until Save, and has three lines after | H, P, M |
| FILE-4 | A Markdown file with a table, a task list, struck-through text, a link, a Swift code block, a Mermaid block and a picture of 40 by 30 beside it | Open it | A rendered preview with a switch to the source: the table's cells each on their own, the link a link, the diagram drawn (its boxes' words on their own, its code not shown), the picture read from beside the document at its size; looked at in its picture (`markdown`) | H (Markdown), M |
| FILE-5 | An image, a binary file, a file over 2 MB | Open each | The image shows; the others say why they do not | H, M |
| FILE-6 | A file open without edits | Something else rewrites it on disk; press Refresh | The editor shows the new text | M |
| FILE-7 | A file open as a tab | Quit the app and open it again | The file is a tab again | M |
| FILE-8 | The Files tab open on the Mac | A second device creates a file and writes into it | The file appears in the Mac's tree and opens with that text | M |
| FILE-9 | A text file of 3 MB, and one over 20 MB | Open it | It says it is too large to open by itself and offers Open Anyway, which opens it; over 20 MB it is not offered | H, M |
| FILE-10 (#132) | A line of thirty tabs, in a plain text and in one that is colored | Given; typed at the text's start; typed at its end | One line each time: AppKit's own paragraph style breaks a line at its thirteenth tab | U |
| FILE-11 (#104) | `notes.txt` open on the Mac | Typed into; typed back to the disk's text; a text of the same length; Revert; typed twice and saved; edited, and the disk's changed | Save and Revert show only while it differs from the disk's; Revert gives the disk's text back; the last of what was typed is saved; its own edits are kept | M |
| FILE-12 (#126) | A Markdown document with a heading, a table, a link, a code block and a `<script>` | Made into the preview's page | The heading, table with its heading cells and cells, link and code block are in it; the script is not, and only the page's own scripts may run (by nonce); Mermaid is in the page only for a diagram. Struck-through text, a task done and a link found in the text are made as GitHub makes them. Before the fix the table's cells were left out (MarkdownUI's `renderHTML()`) | U |
| FILE-13 (#126) | A temporary folder with the preview folders of an ended app of the same build, of another build, and of launchd | The preview's folder asked for | A folder of the build's and the process's own; only the ended app's folder of the same build is taken away | U |
| FIND-1 | A repository with tracked, new, ignored and deleted files, and `.agentterm/` | Its files, and from a folder inside it | What git tracks and what is new; not what is ignored, deleted or AgentTerm's own; named from that folder | H |
| FIND-2 | A folder that is no repository | Its files | Every file, hidden ones too, without `.git` and `.agentterm` | H |
| FIND-3 | A list of files | Ranked for part of a name, for letters apart, with a slash, with blanks, for nothing | The name that starts with it, then names that hold it, then folders that do; in their order; against the path; blanks are not letters; nothing | H |
| FIND-4 | A repository with a word in tracked, new, ignored, binary and very large files | Searched without and with its case, with a dot and a parenthesis, for nothing | Each line with its file and number, new files too, not the ignored, binary or large ones; only the line with that case; as written; nothing; where the word is in the line is given | H |
| FIND-5 | 300 lines that hold a word | Searched with a limit of 25; stopped at once | 25 lines and said to be cut short; nothing, and no problem | H |
| FIND-6 | A line of 10,000 characters with the word in its middle | Searched | Cut to 300 characters around the word, marked as cut at both ends | H |
| FIND-7 | A folder that is no repository | Searched for a word | As FIND-4 | H |
| FIND-8 | A repository with a submodule | Its files; a word that is in both | The submodule's files named from the folder; found in both | H |
| FIND-9 | The Mac app | File > Go to File…, part of a name, the file; Find in Files…, a word, Aa, a word of a Markdown file, its line; Close | The search in place of the tree, the file found and opened; the line with its file and number; nothing with the wrong case; the Markdown file opens in its source; the tree is back | M |
| FIND-10 | A host and a device | A file by name; an empty query after a file was made; text without and with its case; a search stopped; a search stopped that nobody has | Answered with the search's number; the folder read again; the lines, then said to be over; still said to be over; nothing | H |
| FIND-11 | The Mac app and the iPhone | ⌘P and ⌘⇧F with the side panel hidden; the arrow keys and Return; a search of a worktree; Stop on a long search; on the iPhone the field above the tree, Name and Text, a line | The panel shows on Files with the keyboard in the field; the row opens; the worktree's files; it stops and says how far it got; the same as the Mac, the file opening at the line | hand |
| FIND-13 | A host, a device, 400 conversations | A search of the history, then a stop and a search for text of the same number; then one search of everywhere and one of a folder | The first finds its conversation; so does each of the two. Before the fix the search for text and its stop ended the search of the history, and either list's search the other's | H |
| FIND-14 | A command that prints nothing for 20 seconds, its output streamed | Not wanted any more after 0.3 s | Ended within three seconds, said to have been stopped. Before the fix it ran its 20 seconds, as a search for text that finds nothing went through the whole repository after it was stopped | H |

### Pairing and devices

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| PAIR-1 | A pairing code on show | It is used once; used again; five minutes pass; the window closes | It pairs one device; every later use is refused | H |
| PAIR-2 | A pairing link | Open it on the iPhone | The iPhone is paired with a token of its own and shows the Mac | H, P, X |
| PAIR-3 | A paired device's client | It asks for a pairing code, or to remove a device | The host refuses: only the Mac's own client may | H |
| PAIR-4 | Tailscale connected, or not | Open the pairing window | A code, or what Tailscale is missing with the steps to fix it | M (one or the other, whichever this Mac is in) |
| PAIR-5 | A paired device connected | The Mac removes it | It is disconnected at once and has to pair again | H, M (a paired Mac) |
| PAIR-6 | The iPhone paired with one Mac | Pair a second; switch between them | Both are listed; each shows its own folders and sessions | P |
| PAIR-7 (#157) | A device that paired as an iPhone | The host restarts; it signs in saying it is an iPad | The list of paired devices has it as an iPhone, then as an iPad | U |
| SET-6 (#155) | The iPhone connected to a host with stand-in agents | Settings: Hooks & MCP, Install Claude Code; Shell; Agents; Browser | Install offered and run, then Remove; the shell's program, the agent's words and a new profile there | P |

### Another Mac

A second host stands in for the other Mac, with a project of its own.

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| REMOTE-1 | The other Mac's pairing link | Choose Pair with Another Mac, paste the link | The other Mac is on screen and named in the menu | M |
| REMOTE-2 | Paired | Look at the folders | The other Mac's folder is listed and this Mac's is not | M |
| REMOTE-3 | A changed file on the other Mac | Stage it, commit with a message; open a file, change it, save | The other Mac's git has the commit and its disk has the saved text | M |
| REMOTE-4 | The other Mac's home with `Sites/blog` | Press Add; go into Sites, into blog; press Add This Folder | The other Mac's list has the folder and it shows here | M |
| REMOTE-5 | A session started on the other Mac from here | Switch to This Mac, then back | This Mac shows its own folder; back on the other Mac the session is still running | M |
| REMOTE-6 | The other Mac on screen | Quit the app and open it again | It comes back to the other Mac | M |
| REMOTE-7 | The other Mac on screen | Look for Pair Device | It is not offered | M (Pair Device), hand (Show in Finder, Restart Host) |
| REMOTE-8 | Paired | The other Mac removes this one from its devices | A message says so, the other Mac is forgotten, and this Mac is on screen | M |
| REMOTE-9 | A file of the other Mac open with unsaved changes | Switch to This Mac | Refused, with a message to save or discard first; the other Mac stays on screen | M |
| REMOTE-10 | A changed file on the other Mac | Pick it in the Git tab | Its diff, which comes after the list, is shown | M |
| REMOTE-11 | A file staged on the other Mac, a stand-in agent there | Press Write, then Commit | The other Mac's agent writes the message into the field, and its git has the commit | M |
| REMOTE-12 | That commit, which the other Mac's remote does not have | Press Push | The other Mac's remote has the commit | M |
| REMOTE-21 (#116) | Another Mac on screen, with a second folder whose remote is slow in the same way | The same as GIT-77 | The same, the other Mac's git doing the work. This is where a push was lost at times: the app asks the other Mac's remotes about when REMOTE-12 presses Push | M |
| REMOTE-13 | A conversation an agent had on the other Mac | Choose Hand Off on it, press Hand Off | The prompt comes from the other Mac's host; the receiving agent starts there and the handoff file is on its disk | M |
| REMOTE-20 | Another Mac on screen | Choose Hand Off on a conversation, or make a schedule, and press Choose… | The other Mac's folders are browsed through its host and the one chosen is used; the repositories inside the conversation's folder are offered | M |
| REMOTE-14 | A file staged on the other Mac, whose git has a hook that takes six seconds and then refuses | Write a message, press Commit | What the hook said is shown, and the message is still in the field | M |
| REMOTE-15 | A file of the other Mac open, in a folder nothing can be written in | Change it, save, press Refresh in the Files tab | It is said that the file could not be saved; the changes are still in the editor, still count as not saved, and the other Mac's disk is as it was | M |
| REMOTE-16 | A session on this Mac, so its host has a tab to arrange | Pair with the other Mac, start a session there, come back | The other Mac's host was never told of this Mac's tab, and this Mac's arrangement is as it was | M |
| REMOTE-17 | A file of the other Mac open with unsaved changes | Choose Forget for the Mac on screen, confirm | Refused, with a message to save or discard first; the other Mac stays on screen and in the menu | M |
| REMOTE-18 | The app last on the other Mac, and this Mac's host not running, as after a restart | Open the app | It comes back to the other Mac, and this Mac's host is started all the same; in a test, that host listens on 127.0.0.1 only (`AGENTTERM_LOCAL_ONLY`, #179): before the fix it listened on the Tailscale address too | M |
| REMOTE-19 | The other Mac on screen, a session `deploy` running there | The other Mac's host is killed and started again there | A banner says that the host on the other Mac stopped unexpectedly and was started again, and that `deploy` ended with it, rather than an empty list | M |
| REMOTE-22 (#147) | This Mac showing another, a stand-in for that Mac's app showing a page | Pick the Browser row; a picture of the page sent; press the page; New Browser Tab | The page shown, without Pick; watched, its picture drawn; the click sent as a tap; Edit > Copy asks that Mac for the selection; the page's menu (`AXShowMenu`) asks what is at its point and shows this Mac's menu, whose Open Link in New Tab opens the link there; a new page asked of that Mac, and shown once listed | M |
| REMOTE-25 (#196) | This Mac showing another's page, a stand-in for that Mac's app that does not answer a copy | Edit > Copy; that Mac's host killed | Nothing said before; once the connection closes, what waited is answered at once, refused, and said in words that name that Mac and say it may not have been done (`BrowserWords.otherMacClosed`). A switch to another Mac answers it the same way without saying it (REMOTE-27), and what the page's queue still holds is not sent to the Mac switched to (not tested) | M |
| REMOTE-26 (#198) | The iPhone waiting for the Mac's browser: a picture, a tap | The connection to the Mac closes; or the iPhone switches to another Mac, pairs, or forgets the Mac | Each is answered at once, the first asked first, refused in the Mac's words that name the Mac and say it may not have been done (`BrowserWords.otherMacClosed`, as REMOTE-25), and said where its own refusal is said (the page's problem line, the sheet that opens a page); nothing is kept, and an answer come late answers nothing. Asked with no connection, refused at once. Before the fix nothing was answered and every ask was kept. `BrowserAsksTests`, which `PhoneModel` goes by; that `PhoneModel` hands it the close and the switch is not reached by a test: the iPhone's tests have no Mac app to hold an answer | H |
| REMOTE-27 (#196) | This Mac showing another's page, a stand-in for that Mac's app that does not answer a copy; the app told to write down each answer an ask of that Mac's browser is given (`AGENTTERM_BROWSER_ANSWERS`) | Edit > Copy; the user switches to This Mac | The copy is answered at once, refused in the words of a closed connection (`BrowserWords.otherMacClosed`), and nothing is said: the user asked for the switch. Before the fix the switch emptied the table of what waited without answering it: seen failing, then passing | M |
| REMOTE-28 (#198) | The iPhone and the Mac app on one host, the Mac's browser the provider, the iPhone reaching the host through a proxy that holds what the host sends (`scripts/hold-proxy.py`) | The agent's page opened on the iPhone, its watch held; the connection closed; then let through | The page's problem line says `BrowserWords.otherMacClosed` with the Mac's name at once; once the Mac is back and the page is opened again, it is watched again and the line goes. Before the fix (the wiring of 72992ae in `PhoneModel` reverted) nothing was said: seen failing, then passing | X |
| REMOTE-29 (#209) | As REMOTE-28, the page left open | The connection closed; then back | While closed the page does not say "Asking the Mac for the page…"; once back it is watched again by itself, live, and the refusal's line goes. Before the fix it stayed on "Asking…" under the line until it was left and opened again: seen failing, then passing | X |
| REMOTE-30 (#209) | This Mac showing another Mac's page, a stand-in for that Mac's app, the link through a proxy | The proxy stopped, then made again on the same port | The page goes with the connection, comes back by itself with it, and is watched again. The Mac has no gap of #209's: passed with no change | M |
| REMOTE-31 (#210) | This Mac showing another Mac's page, a stand-in for that Mac's app | That Mac's host killed and started again; this Mac back on it first; that Mac's app back after | While that app is away its pages go (none is shown loading), and once it is back the page is shown again and watched again, without being opened again. #210's page left on "Loading…" was not seen in 5 runs: what was seen is the refusal of the app's own watch at the reconnect, said in an alert, before the pages go, which no alert says now (REMOTE-32) | M |
| REMOTE-32 (#210) | This Mac showing another Mac's page, that Mac's app not connected to its host | A watch or an unwatch the app sends by itself (the page shown again as the connection comes back, before that host lists its pages again; a new width; the page going), and one the user asks for by opening a page, refused with `BrowserWords.noApp`; another refusal | The first kind is not said in an alert (the owner's decision, 2026-11-21); the user's watch and every other refusal are. `BrowserRefusalTests`, which `AppModel.remoteBrowserAnswered` goes by; REMOTE-31 sees no alert at the reconnect (not run yet) | H; M |

### iPhone only

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| IOS-1 | A shell with a command in its history | Press Up, then Return, in the key bar | The command runs again | P |
| IOS-2 | A shell open | Write `echo Xin chào tiếng Việt: ờ ữ ẩ đ` in the message field, press Send | The terminal shows the text as written | P, H |
| IOS-3 | Text in the message field, the keyboard up | Press the hide keyboard button | The keyboard goes; the text stays | P, L |
| IOS-4 | A session open, the phone on its side | Bring up the keyboard | There is still terminal to see, and a way back without the navigation bar | L |
| IOS-5 | The Mac's home with folders | Open Another Folder, pick one, start a shell | The shell starts in that folder | H, P |
| IOS-6 | The History or Settings tab in front | The Mac answers with an error | The message shows over whichever tab is in front | P |
| IOS-7 | Paired | Look at the three tabs | Sessions, History, Settings, with the settings the Mac's Settings has | P |
| IPAD-1 | The app on an iPad Pro 13-inch simulator (#88) | The whole of the iPhone's test, `scripts/test-ios.sh "iPad Pro 13-inch (M5)"` | Everything the iPhone does, done the same; the tabs in the bar that floats at the top | P on the iPad |
| IPAD-2 | The sessions' list on the iPad's screen; then the app narrowed by Split View | Look at it | The list, History, Schedules and Settings keep a column of 760 points in the middle, their background and scroll bar at the edges; narrowed, they fill it as on the iPhone. A terminal and a folder's Git, History and Files take the whole width. Narrowed by the window's handle from 1,032 points to 375, the list went from 728 to 343 (2026-11-15) | P on the iPad (the list's width); `NARROW=only scripts/test-ios.sh "iPad Pro 13-inch (M5)"` narrows the window by its handle, and makes it whole again |
| IPAD-3 | The app on an iPad | Read Settings, the pairing screen and the messages that name the device | "this iPad", not "this iPhone" | P on the iPad (Settings) |
| IOS-9 | A stand-in Antigravity's session in the list, its state not known | Touch the mark on its row | A popover with the note in the Mac's words; the session does not open. Before the fix the words were only the mark's accessibility label (#87) | P |
| IOS-10 (#83) | An entry of an open menu, the Mac's figures arriving every 3 seconds | Keep the finger on the entry 4 seconds, then lift it (`MENU=only MENU_HOLD=4` counts it again and again) | The entry is chosen and the menu goes. Before the fix the menu was made anew under the finger whenever the list was drawn meanwhile, and the entry was not chosen, the menu staying open | P |
| IOS-11 (#127) | Three shells of the user's in the project, one in another folder | Look at the list | Each folder's shells under one Shells heading that says how many ("Shells, 3 shells"); no group of sessions | P |
| IOS-8 | A program that asked for bracketed paste, and one that did not; an agent asking a question | Send a message of more than 64 characters, one of several lines, one of a few characters | The long and the multi-line one go inside bracketed paste, then Return 80 ms later, to the program that asked; everything else typed as it is, lines ended with Return. Before the fix Codex 0.169 kept a single line of 437 characters in its input, the Return a new line in it | H (`SentTextTests`); with the real agents, the same bytes through a throwaway host, on 2026-11-15: 4,000 characters submitted in Claude Code 2.1.325, Codex 0.169.0, Copilot CLI 1.0.112 and Antigravity 1.5.8 |

### Waiting

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LOAD-1 | A slow link to the Mac | Open the History tab; open a session with megabytes behind it | A spinner with what is loading: "Loading the history…", "Loading the session…" | M (the session); the iPhone by hand |
| LOAD-2 | The same, slower still | Ten seconds pass | It says that it is taking longer than usual, and offers Try Again where that can be done | M; the iPhone by hand |

### What the agent is doing

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| AGENT-1 | What Claude Code tells its hooks, as recorded | A prompt; a question (`AskUserQuestion`); a command that runs; one that asks permission; the end of the turn | Working; waiting for an answer, with the question and its choices; working; waiting for permission, with the command; done, with the end of what it said | H |
| AGENT-2 | What Copilot CLI tells its hooks, as recorded | The same | The same, done without what it said; a question's choices from its form | H |
| AGENT-3 | What Antigravity tells its hooks, as recorded | A model call; a question; a command; the end with nothing running | Working; waiting for an answer; not known while the command runs; done. Its `PreToolUse` hook answers "allow" | H |
| AGENT-4 | What Codex's documentation says its hooks are told | A prompt; a permission; the end; an interrupt | Working; waiting for permission, in its own words; done; not known | H |
| AGENT-5 (#129) | Each agent | `agenttermd setup` writes its plugin | Its hooks, the start's among them, each running `agenttermd hook <agent> <event>`, the same for every session; no server in it, which the agent's own command adds; none for Codex; nothing of a session in it (AGENT-13) | U |
| AGENT-6 | A stand-in agent telling its hooks through `agenttermd hook`, two devices, and a shell | It works, asks permission, works, ends | Each state is told when it begins, once, to both devices; a device that connects later is told the state as it is; the shell has none | H |
| AGENT-7 | A working agent | Escape alone, or Control C, is typed | Its state is not known until it says more. An arrow key changes nothing | H |
| AGENT-8 | A session of Codex and one of Antigravity | They start; then Codex's hooks report | Codex's says its state shows once AgentTerm's hooks run, and to choose "Trust all and continue" if Codex asks; the note goes when its hooks first report. Antigravity's says it cannot tell when it waits for permission. Before the fix Codex's said nothing, though Codex 0.169 asks to review hooks that are new or changed (tried 2026-11-15) | H |
| AGENT-9 | A stand-in agent that waits for permission | The Mac app shows it | A mark next to its name in the folder list and on its tab, read as "waiting for permission"; its folder's row says a session waits | M |
| AGENT-10 | The same | The iPhone shows it | A mark in the sessions list, and the state in the terminal's title | hand, until the iPhone tests cover it |
| AGENT-11 | A host that does not refresh during the test, a stand-in Claude Code | It saves that it works, then that it is done | Each state is told within two seconds, through the watch of the hooks' folder | H |
| AGENT-14 (#124, #129, #142) | Codex's config.toml with the user's own; the hooks of a released build and of a development build | Added, added again; one build's taken out, then the other's | Each build's hooks its own, each under a comment that names the build, after the user's, once each; taking one out leaves the other's and the user's as they were | U |
| AGENT-16 (#141) | Antigravity's `PreToolUse`, as Antigravity 1.5.10 gives it: a call of AgentTerm's own server's tool, of the other build's, of another server's, of one of its own; `PostToolUse`; Claude Code's | Told apart | A call of the build's own server's tool is named `<server>/<tool>`; none of the others is | U |
| AGENT-17 (#141) | A stand-in Antigravity, a session working, `leaveGrace` 0.6 s | A `PreToolUse` of AgentTerm's `shell_open` with no call after it; the call; another one held, then `Stop`. Then: the hook and the call 0.15 s after; the call, then a hook dated before it; a `PreToolUse` of another server's tool and of one of Antigravity's own | The session waits for permission, its question `<server>/shell_open`, and works once the call comes; the next held waits, and is done at `Stop`. A call that comes, before or after its hook is read, is never said to wait; another tool's state is not known, as before, and never waiting | H |
| AGENT-15 (#129) | A setup with a program whose path has a space and a quote | The words of each agent's command for the server, to add and to take out; as typed; Codex's table with and without the variable, a comment over the next table under it | `claude mcp add --scope user <name> -- <program> mcp`, `codex` and `copilot` with `--`, `agy` without; quoted only where a shell would take a word apart; the agent's own first, AgentTerm's last; the variable under the lines Codex wrote, once, never under the comment that is over the next table | U |

### Worktrees

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| WT-1 | A project with a change not committed and an ignored `.env` | A worktree is made for Claude Code; another; one with a name taken | `agentterm/claude-1` in `.agentterm/worktrees`, at the project's commit, without the change or `.env`, not seen by git as a change; then `agentterm/claude-2`; the taken name refused | H |
| WT-2 | Two worktrees | Each changes the same file; the first is merged before and after committing; the second thrown away without its branch | Neither sees the other's change; listed with what is changed and ahead; not merged with changes not committed; merged, removed with its branch; the second removed, its branch kept | H |
| WT-3 | A worktree made by hand outside the project, one whose folder is gone | Listed, a session in a folder inside the first | The project's first; the others with their paths, the first in use, the second missing; nothing removed | H |
| WT-4 | A folder with an ignored `.env` | A session is started in a new worktree | It runs in the worktree, with its branch and its agent known; the `.env` did not come along, nothing being run in it but the session; the worktree is listed in use | H |
| WT-5 | A worktree a session runs in | It is thrown away; the session ends; it is thrown away | Refused; then removed | H |
| WT-6 | `.agentterm/` in a project | The Files tab lists the project | It is not listed | H |
| WT-7 | The Mac app, a session in a new worktree with a change of its own | The session is selected | Listed under its project with its branch; the side panel's worktrees' button names the branch (#217) and the Git tab shows the worktree's change, not the project's | M |
| WT-8 | The Mac app | Merge, open a pull request, throw away from the ⋯ menu of a worktree's row in the popup (#217); a folder with uncommitted changes started in a new worktree | Each as WT-2 says; the question before starting | hand, until the UI tests cover it |
| WT-9 | A worktree whose changes are watched | Its branch is pushed in a terminal (its remote branch written in the repository's own git folder) | The watch sees it, so ahead and behind are read again | H |
| WT-10 | A folder inside a worktree AgentTerm made | A worktree is made from it; one from the top of the first | Next to the first, the session in the same folder inside it; then at the top of the new one | H |
| WT-12 | Worktrees: the folder's own, one AgentTerm made, one made elsewhere at a long path, one whose folder is named as its branch, one that is missing | What the menu's row says of each | The branch, how far ahead, how many changed, in use; for one made elsewhere the name of its folder and never its path, which the tooltip says; a folder named as the branch is not said twice | U; the tooltip by hand |
| WT-13 | A repository with another branch and a branch of a remote | A worktree cut from each; from nothing named; from a branch that is not there | At that branch's commit; following nothing; at the folder's commit; refused in words, with no branch left behind | H |
| WT-14 | A worktree made inside the repository by `git worktree add` (`.claude/worktrees`), a new file beside it; another inside the first | The folder's changes; its worktrees; the first's changes | The new file only; both listed, the one inside with its change; its own change only | H |
| WT-15 | A worktree and the folder changed the same line | Merge from the worktree; take theirs; continue | Said to have stopped on conflicts, the folder left merging with the file listed, the worktree kept; merged, and nothing in the worktree is unmerged | H |
| WT-16 | A host with a client | A shell is started in a worktree from an older branch; one from a branch that is not there | At the older branch's commit; refused at once, in words | H |
| WT-17 (#217) | The Mac app, a folder with changes and no worktree but its own | The Git tab; the worktrees' button, New Worktree in its popup; Create; a file written in the worktree; in the popup the first row; the second | The button with the folder's branch; the sheet with "agentterm/claude-1" suggested; a Claude session in that worktree, on show without the folder's changes; the button and its row say 1 file changed and that a session runs in it; the folder's changes; the worktree's | M |
| WT-18 (#217) | What a worktree's row in the popup says (a chip's words, before #217), and the panel's other numbers | The folder's own; one with changes and commits ahead; one in use; one that is missing; the questions before one is thrown away; a count of files and of commits | Its branch, or its folder with a detached HEAD; "3 changed · 2 ahead", in words since #50; said in a sentence for a tooltip; "missing"; what is not merged is named; "1 file", "3 files", "1 commit", "2 commits" | U |
| WT-19 (#217) | The Mac app and the iPhone | From another branch and a shell from the sheet; a name taken; ⋯ on a row of the popup: merge, pull request, throw away (none on the folder's own row; a pull request only for the worktree on show on the Mac, and one whose changes were read on the iPhone); on the iPhone the control that names the worktree on show, its list with the search, the rows, New Worktree and ⋯, a launch button's menu, a session's "Changes, History and Files" | As WT-2 and WT-13 say; refused in the banner; the iPhone the same as the Mac | hand |
| WT-20 | A project with a submodule; then the submodule's origin gone | A new worktree, its submodules checked out; another | The submodule's files are there and nothing is changed; the worktree is made and what git said is returned | H |
| WT-21 (#216) | A repository with a submodule | The submodule's worktrees are listed (`GitWorktrees.list`) | The first, its own, is the submodule's folder, written as the folder is, with its branch. Before the fix it was `<parent>/.git/modules/<name>`, which git names for a submodule and which holds no files. `WorktreeTests.testASubmodulesOwnWorktreeIsItsFolder` | H |
| WT-22 (#215, #217) | The Mac app, a repository open, its worktrees' button on show | The host is killed and started again by the app | The button is there again without the folder or the diff being changed: the worktrees are asked for again when the next host answers. Before the fix they were forgotten with the connection and asked for only on a change. The iPhone's folder screen asks again the same way once it is connected again, which no test reaches. `WorktreeUITests.testTheWorktreesAreShownAgainAfterTheHostCameBack` | M |
| WT-23 (#217) | The Mac app, a folder with a worktree a session runs in, a file changed in it; the same worktrees in words | The session is selected; the worktrees' button; "MAI" typed in the search; the row left; the button, New Worktree. In words: a search by branch, by folder, in another case, empty, matching nothing | The button alone outside, naming the worktree and its 1 file changed: no row, no New Worktree and no ⋯ outside. The popup lists both, the one on show marked, ⋯ on the one that is not the folder's own; the search leaves the folder's own; picking it shows the folder's changes and closes the popup, the button naming it; New Worktree closes the popup and opens the sheet. The search finds a branch or the name of a folder whatever the case, everything when empty. `WorktreeUITests.testWorktreesArePickedFromAPopupWithSearch`, `WorktreeSearchTests` | M, U; Escape, the arrows and Return, and the iPhone's list by hand |

### Schedules

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SCHED-1 | Each kind of time | The next time after a moment | Today's or tomorrow's for every day, the nearest weekday's, the moment for once until it passed, none for a limit reset | H |
| SCHED-2 | Each agent and mode | A run's command line | The agent's own switch for the mode and the prompt quoted; Copilot CLI's variable; Codex offers no "accept edits"; the warning names what Codex's runs do with hooks | H |
| SCHED-3 | Claude Code's and Copilot CLI's settings with other things in them | A schedule is saved | Its folder is trusted in them; the rest is as it was | H |
| SCHED-4 | A schedule that skips permissions | Saved without its warning accepted; with it; Codex with "accept edits" | Refused; saved, every client told with when it runs next; refused | H |
| SCHED-5 | Every day at nine, the clock at 8:59 | Nine comes | One session of its agent in its folder, named after it, marked as its run, started with the mode's switch and the prompt; recorded as started; once | H |
| SCHED-6 | The first run's agent at work | The next day's time comes | Skipped, and said to be | H |
| SCHED-7 | Three schedules: one that catches up, one that does not, one off | Three days pass at once | The first runs once, said to be missed; the second is recorded as missed; the third does not run | H |
| SCHED-8 | A schedule a minute away; then hours away | It is saved | The Mac is held awake; then let go | H |
| SCHED-9 | Copilot CLI skipping all | It runs | Started with `COPILOT_ALLOW_ALL=true` | H |
| SCHED-10 | Every day at nine, made at 9:31 | A moment passes | Nothing runs until tomorrow | H |
| SCHED-11 | The Mac app and the iPhone | A schedule is made with "skip all permissions" | The warning is shown, and only once it is accepted is the schedule saved; both show it | hand, until the UI tests cover it |
| SCHED-12 | A schedule for when the limit resets | The account's limit starts over | It runs two minutes later | hand: needs an account whose limit resets |
| SCHED-13 | The Mac's Schedules with a schedule half made | Sessions is picked, then Schedules again | The schedule is dropped; the middle asks for one | M |
| SCHED-14 | A daily schedule and a schedule a moment away | Its time comes; its run is picked; the run's session ends; the daily one is picked | Both under Scheduled, none running; then the run under Running, opening its session; then under Past Runs, saying how it ended and after how long; the daily one in the middle to change, with no runs. The iPhone shows the same three groups, in a tab of its own as the Mac's bar of places has it, not in Settings (#50) | H, M, P |
| SCHED-15 | Two schedules of Claude Code for when its limit starts over | The limit starts over | Both run two minutes later, once each | H |
| SCHED-16 | A run of Codex, whose hooks are not trusted, that has written nothing since it started | The next day's time comes; a day later | The next run starts, not skipped; the first is closed, the second kept | H |
| SCHED-17 | Two such runs, and a third schedule due half an hour after them | Its time comes; an hour after they started | It waits; then it runs | H |
| SCHED-18 | A schedule that skips permissions, whose folder was removed | Its time comes | Not started, not in the home folder either; recorded as not started, naming the folder | H |
| SCHED-19 | A schedule for when Claude Code's limit starts over, no session of it open (as after the host started again) | It is saved; the limit starts over | Its next run is known from the service; it runs | H |
| SCHED-20 | Claude Code's settings file, written by Claude Code between the host's read and its write; Copilot CLI's, written again every time it is looked at | A schedule's folder is trusted | The folder is trusted in what Claude Code wrote, which is kept, with slashes unescaped; the file that keeps changing is not overwritten, and the trust is said to have failed | H |
| SCHED-21 | A host with its own clock, a repository with changes not committed, a schedule | Run now; run again while it goes; the run commits a change and makes a file; three minutes pass; stop; its output asked for; a run nothing was kept of; stop again | A session, recorded as "Run now"; refused; "Stopped by you, after 3 min", "1 commit, 1 file changed, 1 insertion, 1 new file not tracked" without what was changed before, and what it printed; nothing; said to be over | H |
| SCHED-22 | A schedule whose runs wait for the one before | The next comes due while the first goes on; the first is ended | Neither skipped nor started beside it; then started | H |
| SCHED-23 | A schedule with a longest time of 30 minutes | 29 minutes pass; 31; saved with 0 | Still going; stopped, saying so, and the banner told; refused in words | H |
| SCHED-24 | A schedule that runs only when the folder has changes; then only after a pull, in a repository that follows nothing | Due with nothing changed; with a change; due after a pull | Skipped, saying so, and no banner; run; not started, in the list and in the banner | H |
| SCHED-25 | A repository with a remote, a schedule that runs after a pull | Due with nothing new; due after someone pushed | Skipped; pulled, and run | H |
| SCHED-26 | A schedule whose runs have a worktree of their own | Run now; the run ended | Its agent starts in `.agentterm/worktrees/schedule/<name>-<time>`, on a branch of that name, the run saying where; the folder untouched; the worktree kept | H |
| SCHED-27 | A schedule | Duplicated; its time and longest time changed; saved to run every 2 minutes; all paused over its time; let go again | A copy with a name of its own, off; what was changed, in words, with it; refused; nothing runs and nothing is due; not caught up, the next at its time | H |
| SCHED-28 | Schedules every 30 minutes, every 2 hours between 9 and 18, on two dates; one saved by an earlier build | When each comes due; in words; read; a run's summary; a copy; what changed | After, not at, over midnight, inside the window; "Every 2 hours, 09:00 to 18:00"; reads with the new things off; "Done, after 12 min"; its own name and id, off; a line for each thing | U |
| SCHED-29 | The Mac app, a schedule | Run Now from the list; Stop on its run; the schedule, Output; Duplicate; Pause All; again | A run going on; among the past runs, "Stopped by you"; what it printed; a copy that is off; said to be paused, each "Paused"; let go | M |
| SCHED-30 | The Mac app and the iPhone | Every…, between two times, on certain dates; only when changed, only after a pull; wait for the run before; a longest time; a worktree of its own; the changes to a schedule; on the iPhone all of it, and a run's output | As SCHED-21 to SCHED-28 say; the same on the iPhone | hand |
| SCHED-31 | A run whose agent takes no notice of being hung up | Stopped by the user; another, its time up | Each ends within three seconds and says how. Before the fix neither ended | H |
| SCHED-32 | A run going when the host stops; then the same as a host that died leaves it | The host starts again; the user opens a session of the number the run's had; 45 minutes on, past the run's longest time; Stop on the run | Ended with the host, its session forgotten, not listed as going; the user's session is neither stopped nor taken for the run; "That run is not going on any more." Before the fix the user's session was ended for the run | H |
| SCHED-33 | A run that waited 20 minutes for the one before it, 30 minutes its longest | 45 minutes after it came due; 51 | Still going; stopped, 31 minutes long. Before the fix it was stopped at once, and said to be 45 minutes long | H |
| SCHED-34 | A run after a pull, a commit here and one on the remote that change the same line | It comes due | Not started: "the pull stopped on conflicts, and was undone", and the banner says so; the folder as it was, nothing half merged | H |
| SCHED-35 | A schedule for when a limit starts over, all paused before it does and let go after | The minutes after | No run: nothing is caught up. Before the fix it ran as it was let go | H |

### When an agent is done or needs you

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| NOTE-1 | Sessions whose agents wait, work, are done | Their states change | Told once when done or waiting, again when asked something else, not while it keeps waiting; what waits is told on connecting; an ended session is forgotten | P |
| NOTE-2 | An agent waiting for permission | A reply to what it asked before; then one to what it asks now | The first is dropped and the device is told the agent moved on; the second is typed, then Return | H |
| NOTE-3 | The Mac left alone for six minutes | Its app comes to the front and goes behind; a key is pressed | Every client is told in use, not in use, in use | H |
| NOTE-7 | The Mac app in front, someone at the keyboard | The iPhone takes a session; it goes; the Mac app is used | No one is at the Mac from the iPhone's use, also once it is gone, until the Mac app is used | H |
| NOTE-4 | The Mac app with a shell in front and History shown, an agent in another session | The agent comes to wait for permission | A banner names the session and what it asks; Open selects it | M |
| NOTE-5 | The iPhone in the sessions list, an agent in a session | The agent finishes | iOS's banner (#66), which opens the session | hand, until the iPhone tests cover it |
| NOTE-6 | The iPhone just left, an agent asks a question | The notification is answered with a reply | The reply is typed into the session after unlocking | hand: needs a real phone |
| NOTE-8 | An agent asks a question with choices; one with more than nine; a permission | What its notification is made of | The body is the question alone; a button for each choice, the first nine at most, each standing for its choice; none for a permission | P; hand on a real phone for what iOS shows and for answering with a button |
| NOTE-9 | The Mac app in front, with a banner for an agent's session and a shell shown; a device | The agent's session is chosen in the list, then the shell again | The banner goes when the agent's session is in front, and does not come back; the device is told that it was seen | M; the iPhone by hand, until the iPhone tests cover it |
| NOTE-10 | Two devices, an agent waiting for permission | One says it saw what the agent said before; then what it asks now; a third device connects; the agent goes on and a fourth connects | Only what the agent still says is passed on, to the other device and not to the one it was seen on; the third is told on connecting, the fourth is not | H |
| NOTE-11 | The Mac app behind another app, with a banner for an agent's session | The agent's session is chosen in the list; the app is brought to the front | The banner stays, and no device is told, while the app is behind; it goes once the app is in front | M |
| NOTE-12 | The iPhone, a notification posted for an agent's session | The session is opened in the app; or it is opened on the Mac | The notification goes from Notification Center, and the banner in the app with it | hand: needs a real phone |
| NOTE-13 | An agent that finished with a long message; one with a short one; a question with choices | What its notice gives; on the Mac, the banner, then Show All, then Show Less | The end of what it said, 300 characters, and all of it to be had; the banner shows the end on up to six lines, opens out to the whole, scrolled when long, and closes again; a long session name gives way in the middle | U, M |
| NOTE-14 | Claude Code, Copilot CLI and Antigravity asking a question with three choices; a question without; a finished task; a stand-in that writes down what is typed into it | An answer that is the second choice, the first, one in other letters; one that is none of them; an answer to the others | Down for each choice before it, then Return; the user's own words after Down past the choices, with a Return first in Antigravity; text and Return for a prompt; the stand-in is typed Down and Return | H; with the real agents by hand, as on 2026-11-14 |
| INBOX-1 (#67) | A stand-in agent and a phone; the agent done; then working and done again with the same words | The phone says it saw the done state; the agent works; it is done again | Unseen once done, no longer once seen; working, not unseen; done again, unseen again | H |
| INBOX-2 (#67) | Sessions waiting, done and not seen, done and seen, working; a failure | The Inbox is made of them | The waiting first, then the failure, then the unseen; a waiting item cannot be dismissed. The Mac's Next was taken away (the owner's decision, 2026-11-21) | U |
| INBOX-3 (#67, #66) | The Mac app, a shell in front; stand-ins that wait for a permission, and three that are done; a device | The Inbox's place; the waiting item, a done one picked, Open; back, one deleted; one seen on the device; Delete All | The place says 4 unread; each row says why and what was said, no terminal; the waiting one has no Delete; the item picked is read here and still unseen; Open shows its terminal and it is seen on the device too, and stays, as opened; the deleted one goes here only; the one seen elsewhere stays, as opened; Delete All leaves only what waits | M |
| USAGE-12 (#130) | What each agent recorded on 2026-11-17: Claude Code's status line, Codex's `turn_context`, Copilot CLI's `session.usage_record` and `session.model_change`, Antigravity's model id | Read | `xhigh`, `medium`, `high`, `medium`, `medium`; none from a model id without a level; the bar's name is "Opus 5.5 · xhigh", and the agent's name alone when nothing is known | U |
| TURN-1 (#71) | A stand-in Claude Code in a repository with a file changed before; its record with two commands, one failed | It is given a prompt, changes a file and adds one, and is done; then a device connects | Every device is told the prompt, the answer, `swift test` exit 0 and `make lint` exit 2, the file it changed and the one it added and not the one changed before; the device that connects is told the same; with the switch off in Settings, the next turn is told nothing | H |
| TURN-2 (#71) | The records of the four agents as they wrote them on 2026-11-17, each with a turn before the last | Read | The last prompt and answer, and the two commands of the last turn with their codes, 0 and 3, for each; Codex's by its turn's id | U |
| TURN-3 (#71) | Two looks at a repository: a file changed again, one changed before and not touched, one put back, one new | Compared | The one changed again, marked changed before; the one put back, with no status; the new one; not the one left alone | U |
| INBOX-6 (#71) | The Mac app, two stand-ins in the same repository, each with a record of two commands, done while a shell is in front | One's item is picked; Open Diff; the other's picked, an instruction written in Continue and sent | What it was asked and said, the two commands with exit 0 and exit 2, the files with the one changed before marked, and that another agent worked there; Open Diff shows its terminal with the Git panel; the instruction is typed into the other's session | M |
| INBOX-5 (#67) | The four real agents at the versions installed, in this repository, the host with the user's home and the development build's `agenttermd` in dist/, a shell in front on the Mac | Each asked to run `sleep 3` and answer in a sentence | Each works, then is done, unseen, and in the Inbox; what each said is shown where its hooks tell it (Claude Code, Codex). Passed on 2026-11-17 with Claude Code 2.1.326, Codex 0.169.0, Copilot CLI 1.0.112, Antigravity 1.5.9 | hand: `AGENTTERM_REAL_AGENTS=1 scripts/test-mac.sh RealAgentsTests`, which spends a little of each account |
| NOTE-15 | A finished task, its agent having asked for bracketed paste; a stand-in that does so and writes down what is typed into it | A next instruction of more than 64 characters; a short one; a long answer to a question | The long instruction inside bracketed paste, then Return; the short one and the answer typed as before. The stand-in gets the paste | H |
| PUSH-1 | A notice of an agent or a failure; its device's key; another key; another identifier; the longest notice | It is sealed, then opened | It opens with its key and identifier only, and cannot be read sealed; a shortened state is named whole by its digest; the longest fits in 3000 characters | H |
| PUSH-2 | A paired phone registered for push, then away; a stand-in relay | Its agent asks permission, keeps waiting, moves on, then is done; the phone comes back | A push for the question, opened with the phone's key and naming the notice; none while it keeps waiting; one that takes it back (`gone`) when the agent moves on; one for done; back, the log, and no notice again | H |
| PUSH-3 | A registered phone, away, then back | The agent asks while someone is at the Mac; later it is done with the phone connected | The Mac's app told at once, pushed after the wait (#180); the connected phone told over its connection, not pushed, and told when it is handled | H |
| PUSH-4 | A registered phone, away | The relay answers 410, or cannot be reached | The banner of both apps says a notification to the phone could not be sent through Apple, with the relay's reason; after 410 the phone is told `pushState(.off)` when it comes back, after an unreachable relay it stays on | H |
| PUSH-5 | A registered phone | It is revoked; its agent asks | Its key is gone from `pushes.json`, which is mode 0600; nothing is pushed | H |
| PUSH-6 | A host without a relay (a development build) | A phone registers | It is told it cannot be, in the words for a build without push; the relay is not asked | H |
| PUSH-7 | The released app on a real iPhone, from TestFlight, with the relay deployed | Agents ask and finish while the app is in front, behind, asleep, closed; handled on the Mac; after a reconnect; with a token APNs no longer knows | Each told once, iOS's banner in front too, with its reply and buttons; taken back when handled elsewhere (at once with the filtering entitlement, else when the background push arrives or the app opens); a reply from a pushed notification typed only while the agent still asks it | hand: needs a real phone and a TestFlight build |
| PUSH-8 (#180) | A registered phone, away; someone at the Mac; the wait shortened | The agent asks | In the Mac's Inbox at once; a notification nowhere before the wait; then `noticeAlert` to the Mac and a push to the phone at the same moment | H |
| PUSH-9 (#180) | A registered phone, away; no one at the Mac; the wait shortened | The agent asks; then it is done, and read on the Mac within the wait | The question shown at once on both; the done one shown on neither | H |
| PUSH-10 (#190) | A registered phone, connected, that says its app went to the background (`deviceInBackground(true)`) | The agent asks; the phone comes back to the front | Pushed through the relay, in its Inbox over the connection, but no `noticeAlert` over it; none on coming back, told through Apple already | H |
| PUSH-11 (#190) | A phone not registered for push, connected, in the background | The agent asks; the phone comes back to the front, twice | No `noticeAlert` while in the background; one when back in front, once | H |
| PUSH-12 (#193) | A registered phone, away; someone at the Mac; the wait shortened; the notices kept in a file | A session is killed, which waits; the host starts again within the wait | No notification before the wait is over; then pushed and `noticeAlert` to the Mac | H |
| PUSH-13 (#190) | A device's app going to the background and coming back | Encoded and decoded | `deviceInBackground(Bool)`, a message of its own, read from the wire as written; `appInFront`, the Mac app's, is another | U (`ProtocolTests`) |
| READ-1 (#180) | Two Macs' apps and a registered phone, away | A notice read on one Mac | The other told `noticesRead`; the phone's push taken back; the phone back finds it read in the log and is not shown it | H |
| NOTICE-1 | A session whose agent asks, works, is done, ends | The host's notices | One for each state done or waiting, once; handled as moved on when the agent works again or the session ends | H |
| NOTICE-2 | A notice | Answered, then dismissed | Handled once, as answered; another state of the session is not handled | H |
| NOTICE-3 | Failures of a session, of push, of keeping awake | Reported | Each is a notice for the Inbox; only the session's alerts; dismissing the failure handles its notice | H |
| NOTICE-4 | Notices, one told to a phone through Apple | The host starts again; 30 days pass | What was told and pushed is kept, what agents asked is over, numbers are not used again; older than 30 days goes; the file is mode 0600 | H |
| NOTICE-5 (#180) | Two notices of a host | One read on a device, again; one opened; one whose agent moves on | Read once and kept so; read is not to be shown; opened is read, moved on is not | H |
| NOTICE-6 (#193) | Two failures that wait, until different times | The host's notices are read again; one becomes due, the other is read | Both kept waiting, soonest first, with their times; due or read, no longer waiting | H |
| INBOX-7 | A device's Inbox | Notices come, are read, are handled | Kept after reading, newest first, brought up to date when handled | H |
| INBOX-8 | An Inbox with a waiting agent and done ones | One deleted, the read ones, all; the log comes again | Deleted ones stay deleted; the waiting one stays until answered | H |
| INBOX-9 | Notices of 30 days and older | Pruned | Older than 30 days goes by itself | H |
| INBOX-10 | The iPhone, an agent done in another session | The Inbox at the top of Sessions; the item; Open; back; All | Shown with what it said; its result; its terminal; read, it leaves the top of the list and is in the whole Inbox |P (`INBOX=only scripts/test-ios.sh`) |
| INBOX-11 (#180) | A device's Inbox | Read elsewhere, read in the log, handled by moving on and by opening, the log comes after reading while away | Read and never unread again; moved on is not read, opened is; what was read here only is what the host is told | H |
| INBOX-12 | An agent done that said more than 300 characters; a question with choices | Their notices in the Inbox, on both apps; an item touched on the iPhone | All of what was said in the item's detail (`Notice.fullBody`), its end in the list since #218 (INBOX-13), the notification's end only (`body`); the question with its choices; on the iPhone the item shown whole (`NoticeScreen`), the same as the Mac's `InboxDetail`, never the terminal by itself (the owner's report and decisions, 2026-11-21) | U; the iPhone's screen by hand |
| INBOX-13 (#218) | What an agent said: a few words; 200 words; several paragraphs; one word of 500 letters. Then the Mac app and the iPhone with an item whose agent said a long answer in Markdown | What a row of the list may show (`Inbox.rowTexts`); the list; the item picked; Preview Markdown; Show as Text | Short: whole, not marked. Long: its end, begun at a word, "…" in front, the longest first for the app to take the first that fits in three lines; line breaks are spaces. In the list the row is three lines at most and the item's detail has all of it; the button shows it rendered, then as written again, in History's words. `InboxRowTests`; on the Mac `SessionTests.testALongAnswerIsCutInTheListAndWholeInItsDetail`; the iPhone's row and button by hand | H, M; the iPhone by hand |
| NOTIFY-1 (#180) | The iPhone app at its first launch, told to ask (`AGENTTERM_ASK_NOTIFICATIONS`) | Opened; Allow Notifications | A screen of its own that asks only whether the app may notify, with Not Now; gone once answered | U |
| NOTIFY-2 (#195) | The iPhone app installed afresh, iOS not asked, at its first launch | Not Now; the phone pairs; a stand-in Claude Code says it is done, and the notice's time to be a notification comes (`Notice.pushWait`) while it is unread; Settings; the switch turned on | iOS does not ask when it pairs, nor when the notice comes or its time comes (the notice is in the Inbox); "Tell me when an agent is done or needs me" is off, and "Also While the App Is Closed" under it shows off too (#211, NOTIFY-4), not only dimmed; iOS asks once it is turned on; "Also While the App Is Closed" stays off, and its footnote says this build has no push (NOTIFY-5, #212): that it shows again what it was kept at is NOTIFY-4's | P (`NOTNOW=only scripts/test-ios.sh`) |
| NOTIFY-4 (#211) | A switch that depends on another (`DependentSwitch`), set on or off | The switch it depends on off, then on | While that one is off it shows off and cannot be changed, and what it was set to is kept; once that one is on it shows what it was set to. Before the fix "Also While the App Is Closed" showed on, dimmed, after Not Now. `DependentSwitchTests`; on the iPhone, NOTIFY-2 | H |
| NOTIFY-5 (#212) | A switch that the system or the build stops (`DependentSwitch.stoppedBy`), set on; "Also While the App Is Closed" in a development build and in the released one | Shown | While something stops it, it shows off, cannot be changed and says why, and what it was set to is kept: in a development build, with notifications on, "Also While the App Is Closed" is off with `PushWords.notInThisBuild` in its footnote; in the released build it shows what it was set to. Before the fix it showed on, dimmed or not. `DependentSwitchTests`; on the iPhone, NOTIFY-2 | H |
| NOTIFY-6 (#213) | "Also While the App Is Closed" in the released build, set on, notifications on | iOS has notifications turned off for the app; then on | It shows off, cannot be changed and says `PushWords.notAllowed`, and what it was set to is kept; a build with no push says that instead; allowed, it shows what it was set to. Before the fix it showed on. `DependentSwitchTests`; that the iPhone reads iOS's setting when it comes to the front is not reached by a test | H |
| NOTIFY-3 (#200) | The iPhone, iOS not asked yet whether the app may notify | Pairing asks, then registering for pushes asks, before the user answers iOS's question; the user allows | Both are told yes, the first first: who asks while the question is open waits for its answer, and the settings ("not determined" until then) are read only after it. While "Tell me when an agent is done or needs me" is off, each is told no and iOS is not asked (NOTIFY-2). Before the fix the second was told no at once. `PermissionAskTests`, which `AgentNotifications.askOnce` goes by; iOS's own question is not reached by a test | H |
| LIVE-3 | Sessions working, needing permission, asking, done seen and not, failures | `AgentsStatus.of` | Each kind counted, failures of the host and sessions only, the names of what waits and is done, the summary in words | H |
| LIVE-4 | A phone away with a start token, then an activity token | An agent works, asks, is done | Started with the start token, then updated with the activity's token, a burst in one update; with none working or waiting updated to done, not ended, then ended once that has lasted (shortened) and never started again (#180) | H |
| LIVE-5 (#192) | A registered phone, connected, with an activity token | An agent works and is done; nothing works for longer than `keptIdle` (shortened); the phone goes to the background, then closes | Nothing through Apple while it is connected; the end to its activity's token when it goes to the background, and not again when it closes | H |
| LIVE-6 (#194) | A phone away with a start token and an activity token | An agent works and is done until the activity ends; another works, then asks; the phone gives a new activity's token; the agent works again | The end to the activity's token; then `start` to the start token, not an update to the ended one; nothing more, no second `start`, while the new token is not known; then `update` to the new token | H |
| LIVE-7 (#212) | The Live Activity switch set on, iOS allowing Live Activities for the app or not | Shown | While iOS does not, it shows off, cannot be changed, and the Agents section's footnote says `AgentsStatus.notAllowed`; what it was set to is kept and shown once iOS allows them. Before the fix it showed on. `DependentSwitchTests`; turning them off in the simulator's Settings is by hand | H; the iPhone's screen by hand |
| RELAY-1…11 | The relay, with a stand-in for APNs | A token registers, too often from one address; a push with its ticket, a forged or expired one, a payload that is not a sealed notice, a token APNs no longer knows, too many pushes, no key set; a notification taken back; a Live Activity updated, started, ended | A ticket, refused (429) past 5 a minute from one address and not from another; the push as it was sealed with `mutable-content`, the collapse identifier and a JWT the key's public half verifies, made once and used again; 401; 400; 410; 429; 500 that says the key is not set up; a background push, or an alert with `FILTERING`; `liveactivity` to the activity's token at its own topic, priority 5 (10 to start), with its stale and dismissal dates | `node --test relay/test/*.test.js` |

### The Live Activity

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LIVE-1 | Agents working, waiting, done; the switch | What the Live Activity does (#168) | Shown while an agent works or waits, whoever is at the Mac; kept, updated, for 15 minutes after all are done (#180), then left showing "done"; ended at once when switched off | H |
| LIVE-2 | The released app on a real iPhone, an agent working | The lock screen and the Dynamic Island, the app in front, behind, asleep; updates stopped | They show each count and which wait; updated while asleep, started while asleep; shown out of date when updates stop; touching it opens the session that waits | hand: needs a real phone and a TestFlight build |

### Shells an agent opens

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| MCP-1 | The MCP server outside a session of AgentTerm | It is started, asked for its tools | It answers MCP's handshake and offers no tools | H |
| MCP-2 | The MCP server in a session, a host standing in | Each tool is called | Each asks the host what it does and says what came of it; a refusal is an error | H |
| MCP-3 | A screen that changes, then stays | `shell_wait` for a text; for stillness; for a text that never comes | Returns when the text is there, when the screen is still, or when the time is up, with the screen | H |
| MCP-4 (#129) | A host and a stand-in Claude Code that writes down how it was started | Its session starts | Nothing on its command line; its environment names the file for its hooks, the file for its status line and its server's key; its session waits to hear from both | H |
| MCP-5 | A stand-in agent that starts the real `agenttermd mcp` | It opens a shell running `cat`, lists the shells, types into it, waits, reads it | A session in its folder, marked as opened by it, that a second device lists; it lists it as its own; what it types reaches the program and is on the screen it reads | H |
| MCP-6 | Two agents, one with a shell it opened, and the user's own session | Each reads and types into the user's session and the other agent's session | Refused: an agent never reaches the user's sessions, nor an agent's | H |
| MCP-7 | An agent | It opens a shell running `claude` | Refused | H |
| MCP-8 | An agent with a shell it opened | The agent ends by itself (ended by the user, its shells end with it: MCP-32); a third agent lists the shells, reads the shell, types into it; the second closes it; the user ends it | The shell stays, the user's: no agent lists it, reads it, types into it or closes it, and the rows say its agent has ended | H |
| MCP-9 | The Mac app and the iPhone, a host that gives the agents the server | Settings | No switch for the server, for running commands in the shells or for the marks, on either device | M (SHELL-4), hand on the iPhone |
| MCP-10 (#129) | A stand-in Claude Code | Started as by default; then with its words emptied in Settings > Agents | By default: its session's variable says `use`, and the words are where its server finds them, to give as its instructions; emptied: neither; nothing on its command line either way | H |
| MCP-11 (#129) | Codex, which gives an MCP server only the variables its configuration names | `agenttermd setup` writes its plugin | Its `.mcp.json` names the session's variable in `env_vars` | U |
| MCP-12 | A shell an agent opened | The Mac shows it | The Mac is the one using it, at its size: the agent's server only asks and is not attached, so nothing says another device uses it | H |
| MCP-13 (#129) | Copilot CLI and Antigravity, told by default, then told nothing | Copilot CLI's session starts; Antigravity's plugin is written | Copilot CLI a folder of instructions after the user's own, in its environment; Antigravity a rule always on in its plugin; told nothing, neither | U |
| MCP-14 | A session's variable, and the two builds' servers | The variable is written for a build and read by each build's server; the server is asked who it is | It names the port, the key and the build; only that build's server takes it, and one that names no build is the released build's; the server and its instructions go by the build's name | H |
| MCP-15 (#129) | A released build and a development build, both set up in Claude Code | The development build's taken out | The released build's plugin and status line are left; with both set up, the one set up last has the status line, and the other's is not known, not said missing (SETUP-4) | H |
| MCP-16 | The real `agenttermd mcp`, a host | It is started with the variable of a session of its own build, then of the other build | Its own build's: the eight of the shells and the browser's. The other build's: none, and it does not sign in | H |
| MCP-17 | The real `agenttermd mcp`, its host stopped | A tool is called | Refused at once, not after fifteen seconds, with words that say the host is not running on its port and what to do | H |
| MCP-18 | The real `agenttermd mcp` with another copy's token; a client of the host | A tool is called; then by a server with the host's own token | Refused at once, with words that say its sign-in was refused; the host tells the client `agentShellsFaults` with a sign-in fault, and none once a server has signed in | H |
| MCP-20 | Two agents, the first with a shell it opened | The second lists the shells, reads the first's, waits on it, types into it, closes it, then opens its own | Not listed to it; reading, waiting, typing and closing refused, with words that say it sees only its own and to open one, and nothing reaches the program; its own it types into and closes, and the first neither sees nor reaches it | H |
| MCP-21 | The Mac app and the iPhone, an agent's shell | The lists of sessions | The row of a shell an agent opened names that agent's session under its title, or says its agent has ended | hand, until the UI tests cover it |
| PROMPT-1 (#129) | Claude Code and Codex; the default with both switches on | The server is started with words, and asked | Its instructions are the words; the default names the shells' and the browser's tools and the server they are of (Claude Code 2.1.326 was seen to give them to the model) | U |
| SETUP-1 (#129) | A stand-in Claude Code with a status line of the user's, which answers `mcp add`, `mcp get` and `mcp remove` as Claude Code 2.1.327 does | Install; Install again; Remove | The commands said as typed, Claude Code's own for the server first, then AgentTerm's; the server added with `claude mcp add --scope user`, not in the plugin; its hooks in a plugin it installs, at the user's scope; AgentTerm's status line, the user's kept; again, the server of before goes first and all is there once; then none, and the status line the user's again | H |
| SETUP-2 (#129) | Stand-in Codex, Copilot CLI and Antigravity, each answering `mcp add`, `mcp get` or `mcp list`, and `mcp remove` as the real one does (2026-11-18) | Install; Remove | Each: the server with its own command. Codex: no plugin, the session's variable named in the table its command wrote, its hooks in config.toml, read back with `features list`; Copilot CLI: its hooks in a plugin from AgentTerm's marketplace; Antigravity: its hooks in a plugin from AgentTerm's folder, with its rule; each has both, then neither, the server taken out with its own command | H |
| SETUP-3 (#129) | A stand-in that refuses to install; Codex that cannot read its config.toml | Install | The refusal said in the agent's own words; the config.toml put back as it was, and why said | H |
| SETUP-4 (#129) | See MCP-15 | | | H |
| SETUP-5 (#129) | An agent not installed | Asked; Install | Said not installed, nothing known of it, nothing run | H |
| SETUP-6 (#129) | A host with stand-in agents; the Mac's app | The host starts; the app asks; Install | Nothing run in the agents until asked; asking runs no install; the app told it is being set up, then that it is | H |
| SETUP-7 (#140) | A stand-in Codex that answers of the server its sessions share as Codex 0.169.1 does: it starts it by itself; the user had that off; it has no such server; both builds set up | Install; one from before still runs, then not; Remove | Turned off with `codex features disable daemon_auto_start`, said before Install is pressed, its hooks kept; while one runs: not set up, said, with `codex app-server daemon stop` among Install's steps, run by Install (#153), and then off; Remove turns it on again, not one the user had off, and not while the other build is set up; a Codex without one is asked nothing of it | H |
| SETUP-10 (#155) | A host with stand-in agents; the Mac's app, and a device paired through it | The Mac installs Claude Code; the device removes it | Both run, the device not refused, every client told how it went | H |
| SETUP-8 (#142) | Codex's config.toml with the user's own and AgentTerm's hooks; a table written where Codex 0.169.1 writes one it adds (above the comments the file ends with); hooks a build before wrote between marks, a table of Codex's between them | Install again; Remove | What Codex added is there after both, each hook once; taken out, the file is the user's and Codex's to the letter; the marks of before go with their hooks, and what was between them stays | H |
| SETUP-9 (#129) | The stand-ins; the agent's own command for the server run as the user copies it; AgentTerm's own command alone (`agenttermd setup <agent>`) | AgentTerm's command; the agent's; taken out, each its part. Codex: its command first, then AgentTerm's; its command again | AgentTerm's command adds only what the agent has no command for, and takes only that out; the server is the agent's command's. Codex's server, added and given nothing of its session, is said so, with what to do; AgentTerm's command names the variable under the lines Codex wrote; Codex's command run again loses it, and that is said; taken out, config.toml is empty of both | H |
| LINK-2 (#129) | A stand-in Claude Code whose hook writes its start, and whose server says it started | Its session starts | Its link: not known, then hooks heard, then both | H |
| LINK-3 (#129) | A stand-in that says nothing | Its session starts | Both said missing once the grace is over | H |
| LINK-4 (#129) | A shell; a program named `claude` typed in it, its hook said first | Typed; Control C | The shell is the agent's while it runs, its hooks heard (its state shown), its server said missing; then a shell again, with nothing of the agent's | H |
| LINK-5 (#129) | Each link | Said | "Connecting…", "Hooks and MCP connected", "No hooks", "No MCP", "No hooks, no MCP", in the same words on both apps | U |
| LINK-6 (#129) | A stand-in Claude Code on the Mac | Its session | Its usage band's mark says "No hooks, no MCP" once the grace is over, with what to do | M |
| LINK-7 (#129) | A stand-in Claude Code that runs its hook and AgentTerm's MCP server as one `agenttermd setup` set up does, started from the iPhone | Its terminal | Its usage band ends with the mark, which says "Hooks and MCP connected" | P |
| LINK-8 (#129) | A shell of the user's on the Mac; a shell of an agent's, the iPhone beside it | A shell opened with its key, as an agent typed in it does | The new shell is the user's: in the list, and in the row of the Shells tab; listed by the iPhone with the folder's shells | M, X |
| LINK-9 (#129) | A shell of the user's on the Mac | A program named `claude` typed in it; Control C | While it runs, the shell shows the usage band and the mark of its hooks and server; then a shell again, without them | M |
| LINK-10 (#140) | The processes of a hook and of a server as each real agent starts them (2026-11-18): Claude Code and Codex with `--no-daemon`, whose hooks have no terminal; Copilot CLI and Antigravity; Codex's shared app server; a shell between; a test that starts the server itself; an agent that ended | Asked which agent in no terminal started it | The agent that started it is looked for past the shells; only Codex's app server, in no terminal, is found; a program that is no shell is not looked past; one that cannot be asked is not said to have no terminal | U |
| LINK-11 (#140) | A host and an agent's session; the real `agenttermd`; a program named `codex`, in no terminal, with that session's environment, as Codex's shared app server has the one of the session that started it; the same program in a session's terminal | It runs its hook of a prompt and AgentTerm's MCP server | In no terminal: the server offers no tools, the hook writes nothing, the session's link and state stay as they were. In a terminal: all of the tools, the hooks and the server heard, the state shown | H |
| LINK-12 (#172) | Claude Code and Codex with their MCP server heard, not heard, not yet; Copilot CLI; Antigravity; no instructions saved | What the instructions came to | Given, not given, checking; given; unverified; disabled, whatever the agent | U |
| LINK-13 (#172) | Instructions saved for Claude Code; the stand-in, which has neither hooks nor an MCP server | Its session's mark is opened | Three rows, Hooks, MCP and System Prompt, each with its mark and state: not heard, not connected, not given, red | M |
| LINK-14 (#172) | A host that gives Claude Code AgentTerm's MCP server and its instructions; a stand-in | Its session started; its server heard, or not within the grace | Checking until the server is heard, then given; not given when it is not heard. A host with no instructions (a test's) says disabled from the start, whatever is heard | H |
| LINK-15 (#172) | Instructions saved for Claude Code; a stand-in heard when the test says, its hooks first, then its MCP server; the mark's popover open from the start | The session goes on with the popover open | Checking for all three; the hooks heard (green), the MCP server still checking; then all green, the instructions given; the popover's rows follow the mark's (pictures looked at) | M |
| LINK-16 (#172) | A stand-in Claude Code whose hooks are heard and which starts no MCP server; then no instructions for it; a stand-in Antigravity with instructions | Its session started; the instructions taken out in Settings; a new session; Antigravity's | Hooks green, MCP red, the instructions not given; the running session still says so after the edit; the new one, disabled; Antigravity's, unverified, in the popover (pictures looked at) | M |
| HOOKS-1 (#129) | Stand-in Claude Code and Codex; Copilot CLI and Antigravity not installed | Settings > Hooks & MCP; Install Claude Code; Remove | Each agent and what it has; not installed said, with no button; the commands shown, each with what it is for: Claude Code's own for the server, AgentTerm's for its hooks and status line, and those that take them out; Install runs them, at the user's scope; all of it there; then none | M |
| HOOKS-2 (#140) | A stand-in Codex that starts its shared server by itself, one running | Settings > Hooks & MCP; Install Codex; the server stopped, the pane opened again; Remove | "Shared server on", what Install does to Codex with which command, before it is pressed, and that command among those shown, between the server's and AgentTerm's, then `codex app-server daemon stop` (#153); Install for All above the agents; Install runs both; then "Shared server off"; Remove turns it on again | M |
| ONBOARD-1 (#129) | Stand-in agents not set up | The app opens; Next through the steps; Skip; opens again; Install for All; opens again; Settings' Show the Onboarding Again; Don't Show This Again | Shown, step after step; shown again after Skip; not shown with every agent set up; shown from Settings | M |
| ONBOARD-2 | Stand-in agents not set up, the Mac app told to show the reporting question (`AGENTTERM_REPORTING_PREVIEW`) | Opened; the host has said the agents miss their setup; Next to Reports, Next; opened again | One onboarding, at once, whose Reports step has the question, never a sheet over another; answered by Next; opened again, no Reports step (the owner's decision, 2026-11-21) | M |
| USAGE-13 (#129) | Claude Code's settings with the user's own status line | AgentTerm's put in; run in a session and outside one; taken out | The command runs as the shell unquotes it; in a session the input is saved, outside nothing; the user's line shows either way; then the user's again | U |
| SCHED-36 (#11, #129) | Antigravity's settings with trusted folders | A schedule's run is started | Its folder trusted for that run, next to the user's, whose settings are left as they are | U |
| PROMPT-2 | A host, the Mac, a stand-in Claude Code | The Mac saves words for it; it starts and asks its server for its instructions; the Mac goes back to the default | Every device is told; the host keeps them; the server's instructions are those words; back to the default, they are gone | H |
| PROMPT-3 | A session's variable and the server | The variable names the agent; a server given words | Read back the same; its instructions are those words | U |
| PROMPT-4 | Settings > Agents on the Mac | Write words for Claude Code, save, reset to the default | "Edited, not saved", then "Your words", told by the host; reset, the default again | M |
| SHELL-1 | A host and a client | A shell program that does not run is asked for; then a program of the test's, what is run first in the user's shells and in the agents' | Refused with why; then kept and told to every device | H |
| SHELL-2 | The settings of SHELL-1 | The user opens a shell | The program picked starts, and what is to be run first is typed at its prompt and run | H |
| SHELL-3 | An agent; what is run first in its shells set | It opens a zsh and runs a command; then a bash, which is not set up to say when a command ends, and runs one | What was run first is in the shell, and the agent's command is told as its own (exit code 0, its output only); in the bash, the screen once still, no exit code | H |
| SHELL-4 | Settings on the Mac | Look at General, then Shell; save what is run first; a larger size | Shell has the program, what is run first, font, size, cursor and scrollback; no switch of the agents' shells in either; the host keeps what was saved; the size changes | M |
| SHELL-5 (#91) | An interactive zsh with no startup files, in a pseudo terminal | A heredoc of 25 lines of about a hundred characters written at once, 20 times | Each time the file has the text as it was sent | H |
| MCP-22 | The Mac app and the iPhone, a host that tells a fault | The window; the banner is dismissed; the fault goes and comes back | A banner at the top says what is wrong and what to do; dismissed, it stays away until the fault has gone and come back | hand, until the UI tests cover it |
| MCP-23 | A server whose shells do not yet say what two waits are for | Two `shell_wait`s on two shells; then `shell_read`, `shell_send` and `shell_list`; the second shell says its text; the first wait is cancelled and its text then comes; a wait after it; cancelling what is over | The three answered while both waits go on; the second wait answered; the first never; the later one answered; nothing; each request answered once, under its id. With calls answered in turn it fails | U |
| MCP-24 | A host and the real `agenttermd mcp` in an agent's session, a shell running `cat` | A `shell_wait` for a line; `shell_read`, `shell_list` and `shell_send` of that line meanwhile; a `shell_wait` cancelled, and its text typed | Each answered at once, and what was typed ends the wait; the cancelled one is not answered, and the first was answered once | H |
| MCP-25 (#84) | Claude Code, Codex, Copilot CLI and Antigravity, each with the real `agenttermd mcp` of a host of the test's own | A `shell_wait` of 15 seconds, `shell_list` and `shell_read` asked at the same time; then a `shell_wait` of 120 seconds stopped as the user stops a call | Claude Code, Codex and Copilot CLI send the three at once and take the two answers that come at once, then the wait's 15 seconds later; Antigravity sends one call at a time, so its answers never come out of order. Each sends `notifications/cancelled` for the stopped wait as soon as it is stopped: Escape in Claude Code, Codex and Antigravity, ctrl+c in Copilot CLI. Seen 2026-11-16 with Claude Code 2.1.325, Codex 0.169.0, Copilot CLI 1.0.112 and Antigravity 1.5.9 | hand |
| MCP-26 | A host, an agent with the real server, a shell it opened and a session the user started, each with 3,000 lines; a shell whose program clears the lines above its screen (`ESC [ 3 J`) | Each opened on a device with 500 lines above the screen; the agent's again while its agent waits on it; the cleared one | Its screen and the lines above it, each time, the agent's shell no later than half a second after the user's (measured 2026-11-14, debug build: 45 to 75 ms each, 47 ms while the agent waits); the cleared one comes without those lines, which the program took away on the host itself | H |
| MCP-27 | A shell's output with its commands' marks (OSC 133), in pieces | The marks are looked for; one is cut in two; other strings and output without an escape | Each found whole, ended by BEL or by ESC \, with its exit code; nothing else taken for one | U |
| MCP-28 | The screen of a shell that says its commands | A prompt, a command writing lines and a progress line, more lines than the screen, its end with exit code 2, the next prompt, the next command | The output is what the command wrote as a terminal shows it, its last lines asked for and how many were left out; the exit code kept; the prompt not in it; the next starts with none | U |
| MCP-29 | The server's tools | Their annotations | The shells' are named `shell_…`; those that only look say so (`readOnlyHint`), those that end something say so (`destructiveHint`) | U |
| MCP-30 | A host, an agent with the real server, a zsh it opened with the startup files of the test's home | `shell_open`; `shell_run` of a command that ends with 3, of two lines, of a look at `ZDOTDIR`; one longer than the call, another meanwhile, `shell_wait`; one stopped with Control C, `shell_wait` | Ready when answered; exit code 3 and only what it wrote; the two lines as one command; the user's `ZDOTDIR` back, the host's not in it; "Still running", the other refused, the wait ends with exit code 0 and its output; exit code 130 | H |
| MCP-31 | A host, an agent with the real server, a zsh it opened; another agent | `shell_stop` with nothing running; of a command that outlasted its `shell_run`; a command after it; of one that ignores Control C; by the other agent | "Nothing runs"; "Stopped. Exit code 130." with its output, in under 5 seconds, and `shell_run` had named `shell_stop`; the next command runs; said to still run, with what to do, as a failure; refused, the shell still open | H |
| MCP-32 (#145) | A host with an app showing the browser; two agents with a shell and a page each; a shell of the user's | `kill` of the first agent | It and its shell end; the app is asked to close its page only; the other agent, its shell and page, and the user's shell go on | H |
| MCP-33 (#156) | The words an agent is told of the shells and of the browser | Read them | Both say to load the server's tools by name when they are not loaded yet, before the first command | U |
| MCP-34 (#156) | The four real agents at the versions installed, each with its cheapest model and least thinking, in a folder of the trial's own inside this repository (`.build/agent-trial`) | Asked to run three commands (`AGENTTERM_REAL_AGENTS=1 scripts/test-mac.sh RealAgentsTests/testTheRealAgentsRunTheirCommandsInAgentTermsOwnShells`) | Which each ran them with is written out: the shells it opened, its link, its state; pictures looked at. By hand: it spends the user's accounts | hand |
| MCP-35 (#156) | The four real agents at the versions installed, each with its cheapest model and least thinking, started as sessions of the development build the owner runs (whose MCP server they are set up for), in `.build/agent-trial` | Asked to run three commands (`AGENTTERM_TRIAL_DEV=1 swift test --filter DevAgentTrialTests`, with the owner's leave; `AGENTTERM_TRIAL_ONLY=<agent>` for one) | Which each ran them with is written out (the shells it opened, its link, its state); its sessions are ended after. Its output has none of the terminal's control characters, which a terminal would answer into the shell running it | hand |
| MCP-36 (#201) | A fault of the agents' server: a sign-in refused, for Codex; a cause this build does not know | Its headline, with a Mac's name and without; its advice; both put in a message and read back | The headline names the Mac when given one; the advice says to start that agent's session again; both faults read back as sent, the unknown cause still in words | H |

### The browser (#76)

The Mac's tests of the browser run the app bundle, where Chromium runs:
`scripts/test-mac.sh` builds it into `.build/uitest-app` under the
identifier `com.manhpham.agentterm.uitest`, never into `dist/`. The test
plays the agent: a stand-in agent writes down its session's variable,
and the test talks to the real `agenttermd mcp` with it.

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| BROWSER-1 | A host, an agent with the real server, no app showing the browser | `browser_open` | Refused at once, in under five seconds, with words that say the browser is in the app on that Mac and it is not open there | H |
| BROWSER-2 | A host, a client that says it shows the browser, an agent, a device | `browser_tabs`; the device asks for the tabs and to click; `browser_snapshot` that is not answered, then the client goes | The client is asked for the agent's session and its answer reaches the agent; the device gets the tabs from the host and its click is refused; the waiting agent is answered with why, and the device told there are no tabs | H |
| BROWSER-3 | The real `agenttermd mcp` in a session of its own build | It is asked for its tools | The eight of the shells and the twenty-two of the browser (MCP-16) | H |
| BROWSER-4 | The MCP server with a browser standing in | Each tool; one with a ref missing; an unknown device; a picture | Each makes its request; what is missing is said without asking; a picture is an image of its type; the instructions name the browser | U |
| BROWSER-5 | Devices by name; a tab of an agent's, a tab of the user's | Looked up; which agents may drive each | Found whatever their case; only the agent that opened it, and no agent the user's; a look is not an action | U |
| BROWSER-6 | An agent and a page with a form | Open it, take a snapshot, type, pick, click, wait, read the console and the page's script, take a picture, follow a link, use an old ref, go back | The tab beside the agent and in its row (#127), not a tab of the strip nor in the Browser tab; each answered with what came of it; the page shows it; the picture is a PNG; the old ref refused with what to do | M |
| BROWSER-7 | An agent's tab | The user takes it over; the agent navigates and takes a snapshot; the user gives it back | The navigation refused with why, the snapshot not; after, it navigates | M |
| BROWSER-8 | An agent's tab, then a tab the user opens | A port nothing answers on; a tab that is not there; `browser_tabs`, and a snapshot, a navigation and a close of the user's tab; shown as an iPhone 16, as a Pixel 9 and as itself; scripts that give a promise, and a function's body; Settings > Browser looked at; the tab closed | Nothing answers, said so; no such tab of the agent's; only its own tab listed, the user's refused as not its own; the screen 393 wide at three times, an iPhone's user agent and platform, the button says so, the page 393 wide, in a part of the agent's no narrower than its bar needs (460); the Pixel's user agent with this Chromium's version, `Linux armv81`, its client hints (mobile, Android, brands, model, version); itself, `MacIntel` again; the promise waited for (#95), the body run; Settings has no switch for the agents' browser, and the agent still reads the page; closed, the tab goes and the window stays | M |
| BROWSER-17 | An agent with its page beside it (#94) | It opens a shell | The page stays shown, and so does the agent's terminal | M |
| BROWSER-9 | The user's own tab | Opened from the Browser menu at a page; the app quit and opened again | No tab comes back | M |
| BROWSER-10 | One profile, then two; an agent; the header's Browser button | `browser_open`; a second profile made; another agent's `browser_open` with no profile, with one that is not there, with "profile 2"; another; `browser_profiles`; the Browser button's menu: Profile 2, then Private | Used without a word; refused with the profiles' names, to ask the user; refused, naming them; opened in Profile 2, which its bar says; the next in it too, which `browser_profiles` says; Chromium made the profile's folder; the user's tab in Profile 2, then a private one | M |
| BROWSER-22 | An agent, another agent | Private tabs: one keeps something in its storage; a second; a tab in the default profile; the other agent's private tab; both closed, then a new private tab | The second has it; the default's and the other agent's do not; the new one has nothing; no folder of a private profile | M |
| BROWSER-23 | An agent's page with a file field and a button, a file in the agent's project | `browser_upload` the file, by a path from its folder; one outside the project; one that is not there; the button's ref | The page has the file; refused: not the project's, no file, not a file field | M |
| BROWSER-24 | A server of the Mac's own: a page that signs in with a cookie, a page that says whether it is | The agent signs in in one tab; opens the other in a second tab, in a private tab, and in a second profile's | Signed in in the second tab; not in the private one nor the other profile's | M |
| BROWSER-25 | A page with two frames | `browser_snapshot`; `browser_navigate` to a frame's address | The snapshot names the frames and their addresses, their insides not read; the frame's page read in the tab | M |
| BROWSER-26 | An agent's page | A snapshot; a link clicked to another page; the old ref used; the tab closed by a device; the agent acts on it | Where it went; the old ref refused as from another page; the tab refused as not its, none left | M |
| BROWSER-27 (#107) | An agent's page shown as a phone taller than its pane, of three pixels to the point, which says its viewport and has a mark in its bottom right corner; a device watching it | Watched while the Mac draws it; again with the window minimized | The page as wide as the phone's screen and as tall as its pane, never drawn smaller, still told the phone's whole screen; each picture sent is in the shape of the size sent with it, the mark in its bottom right corner and not at its middle; drawn, with a pixel to the page's point, which is what Chromium streams; minimized, as many pixels as the device asked for | M |
| BROWSER-28 (#109) | An agent; three pages of three sites (127.0.0.1, localhost, a file), each in a process of its own | Opened; closed with `browser_close` | Each page's process is named for the browser (`<App> Browser (Chromium)`), as Activity Monitor lists it; closed, their processes end within 20 seconds, one spare at most kept by Chromium | M |
| BROWSER-29 | An agent's page with a button; the Pick button on its bar | Picking turned on; the button touched from a device; a note written, sent; touched again; cancelled; picking turned off | The button says Picking; the sheet shows the element (`#greet`), the project's agent picked; the note and the element typed into the agent's session; picking still on, the next touch opens the sheet again; off, the button says Pick | M |
| BROWSER-30 | No page; then three of the user's | One opened from the menu, two more from New Page in the row under the strip; the first picked, then closed; the tab closed, cancelled, closed; one page, the tab closed | One Browser tab in the strip, saying 3 pages; each page shown when picked; closed, the one beside it shown; the question "Close 2 pages?", nothing closed when cancelled, all closed when confirmed; with one page, closed without a question | M |
| BROWSER-31 | An agent with a page beside it | + Page in its row (#127); an address typed in the new page; `browser_tabs`; the agent navigates it; the user gives it back; the agent navigates it | A second page beside the agent, not in the user's Browser tab, saying "You have this tab"; the agent lists both, the new one as the user's for now; refused with that reason; then done | M |
| BROWSER-32 | A page of the user's | Show As on its bar: iPhone SE, iPad Mini, Pixel 7, iPhone 12 Pro, iPhone SE again, each from the list; the list opened; This Mac | The bar names This Mac first, then each device in turn, and the page is as wide as each one's screen; the one in use is marked in the list; as this Mac the page is as wide as before | M |
| BROWSER-33 (#111, #113) | A project; a page of the user's in front; then an agent started; one profile for all | The agent opens a page; the user opens a second; the agent a second; the agent's tab picked, then the Browser tab | The agent's session comes to the front when started, the page that was in front giving way; its pages are beside it, in its row, and the only ones `browser_tabs` lists; the user's two are in the Browser tab, which says 2 pages; neither kind is among the other | M |
| BROWSER-12 | The Mac app with an agent that opened a shell and a page through the MCP server; the iPhone | The list; the agent's page; a touch on its field, "hi" typed; Let … Go On; Browser in the folder, an address typed; Show As iPhone SE; Close Tab | The shell and the page under the agent, under Shells and Browser; the page live, the keyboard up for its field, the page typed in and the user's, then the agent's again, titled "typed hi" on both; the new page loaded, shown as iPhone SE, then gone. On an iPad, on its side, the agent's terminal beside the page. The agent's shell, once shown on the phone, is narrower than the Mac's and as wide as the shells the phone opened, whatever the app's text size: the test had a number of columns, which held only at the text size a full `test-ios.sh` run left in the simulator (#208) | X (`CrossTests`) |
| BROWSER-21 | An agent's page, a device | A touch on its field; "ab", Backspace and "c" sent without waiting; a touch off any field; Show As; a new tab, a page loaded in it; stop; both closed | Touched a field, then not; the field says "ac"; the tab shown as the device; the new one the user's, in the project, the agent's page still shown; the agent has no tab left | M |
| BROWSER-18 | An agent's page, a device that speaks the protocol | It watches the page; touches a field, types, touches a button; stops watching | Pictures no wider than asked, with the page's size; the page does it; the tab is the user's, the agent waits; no picture after | M |
| BROWSER-19 | An agent's page shown on the Mac as a phone of three pixels to the point, standing still (#100) | A device watches it; pictures of the window, 14 of them | The page's part of each is as it was before the device watched | M |
| BROWSER-20 | An agent's page, the Mac's window minimized | A device watches it; touches a field, types, touches a button | Pictures come; the page does it | M |
| BROWSER-13 | A page asking for the camera, a download, a page that opens a window | The page does it | A bar asks the user, not the agent; the file in Downloads, shown under the page; a tab instead of a window | hand |
| BROWSER-14 | A tab, picking on | Pick an element; send it with a note | The picture in the project's `.agentterm/shots/`, the address, selector, HTML and styles typed into the agent's session with the note | hand |
| BROWSER-16 | Two tabs of the user's, a red page and a blue page | Pick one, the other, the first again, the other again | Each time the page on top in the pane is the tab's own (#92) | M |
| BROWSER-15 | An agent's page with a form | The agent reads it, types, clicks and takes a picture while it is shown; with its page hidden, from the agent's row; with the window minimized; shown again | Each works within seconds, and each picture shows what was just typed | M |
| BROWSER-34 | Three pages of the user's of three sites and one with nothing loaded, in the Browser tab | Close Tab on the empty one and on the first; Close Browser for the rest | Their processes end within 20 seconds, one spare at most kept by Chromium: a closed page is not made again by the pane that showed it | M |
| BROWSER-35 (#117) | A page of the user's shown | Close it, the last one; open one again; close it | No page process is left 20 seconds after, none kept in reserve by Chromium; the page opened again loads | M |
| BROWSER-36 (#122) | Three pages of the user's in a project | Look at the list on the left; pick a page's row; with a shell in front, pick the Browser row; Close Browser from its row | One row "Browser (3)" ("Browser, 3 pages"), the three pages set in under it; a page's row shows that page; the Browser row shows the page its tab shows; closing asks first, then all three go. Before the fix each page was a row of its own | M |
| BROWSER-37 (#131) | A page of the user's with a line of text and a link | The menu of a right click on the text, Reload chosen; then on the link, Open Link in New Tab chosen (opened through accessibility, `AXShowMenu`, the pages laid out for it with `AGENTTERM_WEB_ACCESSIBILITY`) | On the text: Back, Forward, Reload and Inspect, not the link's items; Reload reads the page again, as its file is by then, and it is the same page. On the link: Open Link in New Tab, Copy Link Address and Inspect, not Reload; the link opens as another page of the Browser tab. Copy is not chosen: it would write to the user's pasteboard | M |
| BROWSER-38 (#125) | A page of the Chrome Web Store's, an extension's (Dark Reader), in the test's own profile | Add to Chrome, then Add extension in Chrome's prompt; then Open in Chrome Window in the bar | The extension is installed (Chrome's prompt and its bubble are left as they are); the window of Chrome's own it opens (its help page) does not show, and the Browser tab says Chrome opened it; the button shows it, with the extension's button in Chrome's toolbar. Seen on 2026-11-17: after that, Chrome opened one more window, a New Tab, which is held back in turn (not known why) | hand: `AGENTTERM_EXTENSION_TRIAL=1 scripts/test-mac.sh ExtensionTrial`, which reaches Google's site |
| BROWSER-39 (#133) | The browser's C layer (`CAgentTermCEF`), compiled as a build made without Chromium's headers compiles it: `scripts/fetch-cef.sh` not run, as in CodeQL's build of the Swift code | Looked at for each function its header declares | Each is defined, as a stub: the app links, and says the browser is not in the build. A build with the headers never compiles the stubs; the one that was missing (`atc_open_chrome_window`) stopped CodeQL's build only | H |
| BROWSER-42 (#149) | Two agents of a project, the second with a page it opened | Pick an element in that page, Send | The sheet names the second agent and offers no choice; the note reaches it, not the first | M |
| BROWSER-43 (#155) | A change to the profiles | Asked by a device | Allowed to a device, about no tab; refused to an agent, as a device's own | U |
| BROWSER-44 (#148) | Two folders | New Browser Tab in the first; pick the second, its Browser tab | The page of no folder; the Browser row above the folders; in the second's strip one Browser tab, the same page | M |
| BROWSER-45 (#161) | A page whose editor keeps its own state and draws it into a node of its own, as Draft.js (X's post box) | `browser_type` into it; again, not appending | The text shows in it, its count right; typed again, replaced, in the editor's state too; a field that shows none of it is said to fail | M |
| BROWSER-46 (#162) | A page whose button opens a sign-in popup that posts its answer to its opener and closes | An agent clicks the button | The answer comes back to the page ("Signed in: …"); the popup's tab goes when it closes itself | M |
| BROWSER-41 (#139) | A page of the user's whose title changes five times a second | A right-click menu opened on it (`AXShowMenu`) and left open two seconds; then closed with no choice | The title shown goes on changing while the menu is open (it stood still before the fix: CEF runs the menu from inside its own work, and every other turn of it waited for the menu to close); the menu stays open; the title goes on after | M |
| BROWSER-40 (#134) | A page of the user's, shown as this Mac | Show As, the first device picked from its list and Show As pressed again at once; back to this Mac; Show As as it is found then, pressed once another device has been picked | The list opened again at once stays, the device in use marked in it, when the page comes to be shown as the device; the button found before the device was picked opens its list after: it is one button whatever the page is shown as. Its label was of another shape with a device's name in it, and the button was made anew: the list was closed with the button left as open, and the press was lost though reported as done | M |
| BROWSER-47 (#170) | A page open in the Browser; a folder never opened before, added | The folder is picked | Its own empty workspace, "Start an agent in this folder."; the Browser's tab in its strip, behind | M, U |
| BROWSER-49 (#147) | A page with an element that changes the title on hover, a line of words and a link; a device asking as a Mac showing this Mac does | The pointer moved over the first; pressed, moved across the words and released; `copy`; `contextAt` on the link, then on the words | The page saw the hover, the agent kept its tab until the press; the words selected and copied; the link's address and the selection given; no menu opened on this Mac. The requests are a device's, a move or a press acting, asking not (`ProtocolTests`) | M |
| BROWSER-50 (#191) | A page with two lines of words; a device asking as a Mac showing this Mac does | A drag across the first, moved, pressed, five held moves and released, all sent without waiting for their answers, then `copy` at once; the same across the second, then `contextAt` at once | The copy gives the whole first line, the menu's selection the whole second: each is done after the device's input before it (`followsTheDevicesInput`), not refused while the user has the tab, and asking still not acting (`ProtocolTests`). On the viewing Mac, ⌘C and a right click wait in the same queue as the mouse's events (`RemotePageView`), which the tests cannot make: they drive the app by accessibility, which cannot drag. Depends on timing: before the fix the copy reached Chromium while the moves still waited for theirs | M, U |
| BROWSER-54 (#199) | A Mac showing another Mac's page; that Mac's answer to a click's release, a drag's press, or ⌘C held back | Text typed and a key pressed right after the click; two scrolls right after the drag; a click (a press by accessibility) right after ⌘C. On the Mac whose page it is, a click into a field then text, and a drag then a scroll, all sent without waiting for their answers | Nothing is sent while the answer is held; then, in the order done, the release, the text joined ("hi"), the key; the drag's latest move, its release, the scrolls added up; the click once the copy is answered. Everything the view sends of the mouse, the keys and its menu waits its turn, a watch and a new tab do not (`PageInputQueueTests`, `RemoteMacTests`). The field has the text, the copy the whole line, the page scrolled after (`BrowserUITests`: the host kept that order before the fix too). Before the fix the keys, text, the wheel and a press by accessibility were sent at once, past what waited | U, M |
| BROWSER-55 (#107) | A picture of a page and the room a device has for it: a page shown as a phone of 440 × 956 in an iPhone's room (402 × 874 points) and an iPad's, a page shown as a tablet and a wide page of the Mac's. A page the Mac draws, watched by a device that asks for more pixels than it has; then changed; then with the window minimized; then shown as a phone of three pixels to the point | The picture is laid into the room; a finger touches it and drags over it. The page stands still, changes, and stands still again | The picture is drawn whole, in its own shape whatever the size sent with it, never past the room, and a touch is the page's point under the finger; a device asks for its room's pixels, an iPad's 2064 and not a phone's 1290; the largest picture fits a message; a page that stood still for 0.7 s has one picture taken, not again until it changes, not sent when the page changed meanwhile, and what is streamed the same as the last is not a change (`PagePictureTests`). On the real Chromium: every picture sent is in the shape of the size sent with it; the last one of a page standing still has the pixels the Mac draws it with, a streamed one a pixel to the point; no more come while it does not change; the same after it changed, and minimized; shown as a phone whose pixels are not the screen's, none is taken and none has more than a pixel to the point (#100) (`BrowserUITests`, which prints what the app wrote of each picture with `AGENTTERM_LOG_FRAMES`) | U, M |
| BROWSER-48 (#164) | A page that replaces an element every 15 ms, as one that renders again does | The element is picked for an agent | It is read before its picture is taken; what is sent has its styles, or says the page replaced it and its styles are not known, never empty styles | M |

### Vietnamese input

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| VN-1 | Vietnamese text with combining marks | Send it through a PTY and through a session | It arrives byte for byte | H |
| VN-2 | Telex, VNI, and a tool that retypes with backspaces | Type in zsh and in each agent on the Mac | The words come out right, with nothing doubled or lost | hand (issue #4) |
| VN-3 | The Vietnamese keyboard on a real iPhone | Write in the message field and send | The words arrive as written | hand |

### The tests themselves

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| TEST-1 | A host and an app started by a test or a test script | A session starts through the login shell | Its `HOME` is the test's home folder: none of the startup files of the person running the tests is read. The hosts and apps get the test's home as `HOME`, `ZDOTDIR` and `CFFIXED_USER_HOME` | M |
| TEST-2 | The host's tests, run by a person who has `ZDOTDIR` set | A session's shell, or a command run through the login shell, is given its environment | Its `ZDOTDIR` is the tests' own empty folder, not theirs | H |
| TEST-3 | The host's tests, run by a person with a global git configuration | git is run by the host, with an environment given or not, or in a session | It reads no global configuration (`GIT_CONFIG_GLOBAL=/dev/null`); what it would have read is not printed | H |
| TEST-4 | The tests, or the host, run from a terminal; a helper command that was stopped | An agent writes a commit message through the login shell; a stopped command is asked to end, and one reaches its timeout | The shell runs in a session of its own, with no terminal to reach for, so it is not stopped by one; a stopped command is let go on and ends, and is said to have timed out | H; in a terminal by hand: `swift test --filter CommitWriterTests` ends, where it hung |
| TEST-5 | A test that throws a file away | The host, or the Mac app, is given `AGENTTERM_TRASH_DIR` | The file is moved into that folder, a second of the same name under a number, and never into the Trash of the person running the tests | H, M |
| TEST-6 | An interactive shell started by itself that stays the parent of the program it runs (`zsh -i -c "sleep 60; true"`) | Stopped | Over within five seconds, with nothing of its session left; before the fix it went on for the program's whole minute, which is how the commit writer's test failed on CI and not here | H |
| TEST-7 | A shell started by itself that ends at the first request, waiting for a program that ignores being asked | Stopped | The program is killed three seconds on. Before the fix it was left running | H |
| TEST-8 | A host whose figures of the Mac come as often as they can | A session's command ends | The last list of sessions is empty, whatever came after it. The test looked at the last message only, and failed on CI whenever the figures came right after the list | H |
| TEST-9 (#203) | A Mac UI test over, all it started stopped | Any program of the build is still running with the test's state folder (a host the app started by itself on a proxy's port, the app, a helper) | It is named and ended, and the test fails. Before the fix `WaitingTests` stopped its `SlowProxy` before the app quit, and with `ALL_SHOTS` a host on the proxy's port outlived every run of it, unseen by `test-mac.sh` | M |
| TEST-10 (#207) | The host's tests, run from a session of the installed app: its hooks' file, its status line's and its MCP server's key, of either build, in the test runner's environment | A session of a test's host starts | It has none of them: those names have its own host's values, or none. Before the fix the other build's two came through | H |
| TEST-11 (#207) | The Mac UI tests, with those variables and another of AgentTerm's in the test runner's environment | A test starts its host and its app, and a session in it | None of the three is given any of them. Before the fix `ownHome` passed every one on to the host and the app | M |
| SET-1 | The Mac app's Settings left on Privacy | Left for Sessions, opened again with ⌘, | It opens on General | M |
| SET-2 | A setting the host tidies (a blank model, an unknown agent; keep awake options; the display) | A client asks for what, once tidied, the host keeps already | The asker is told what the host keeps | H |
| SET-3 | Start at Login on | The launch agent is removed outside AgentTerm | Every client is told it is off, without asking | H |
| SET-4 | The iPhone, its Mac out of reach | Look at Settings | The Mac's settings are shown as it last said and cannot be changed, and it says so; reached again, they can | P |
| SET-5 | The Mac with another Mac on screen, which has a schedule | That Mac goes out of reach | None of its schedules shows | M |
| TEL-1 | A build with a reporting service, opened for the first time | An event and a problem before the screen is answered; the screen answered as it comes; again | Nothing is sent, of either kind; both kinds on, and sent from then | U |
| TEL-2 | The same | A switch of the screen turned off; Continue; the next launch; both turned off | Nothing sent or saved by the switch itself; that kind stays off; not asked again; answered all the same | U |
| TEL-3 | The Mac app, told to show the question though it has no service (`AGENTTERM_REPORTING_PREVIEW`), the onboarding turned off for the tests | Opened; its Reports step; usage statistics turned off; Next; Skip; Settings > Privacy; opened again | The onboarding all the same, its Reports step with both switches on; answered; crash reports on and usage statistics off; the onboarding not shown again | M |
| TEL-4 | A released build of each app, never opened before | Opened | The screen, in the same words on both; on the iPhone it cannot be swiped away | hand |
| TEL-5 (#212) | A build with no reporting service, both switches kept on; a build with one | Settings > Privacy, on both apps | With no service both show off, dimmed, with `TelemetryPreferences.Wording.unavailable` beside them, and what they keep stays; with one, nothing stops them. Before the fix they showed what they kept, under words that said nothing was sent "whatever these switches say". `TelemetryTests` (what stops them), `DependentSwitchTests` (what is shown) | H |

## What the tests found

Bugs that came to light while these tests were written, as a record of
what the layers are good for:

- Ending one session on the Mac (⌘W, End Session) did not ask first, though
  closing many tabs did and the iPhone always asks. It asks now (SES-10).
- The two main switches of Settings > General on the Mac had no name for
  VoiceOver: they were read as "checkbox" (AWAKE-2).
- Rows of the Mac's sidebar, of its Files tab, of its changes and of its
  History could not be pressed without a pointer; a conversation's Resume
  and Hand Off only showed under the pointer, and what a tab's or a file's
  menu holds (End Session, Close Other Tabs, Hand Off, Rename, Move to
  Trash) was only in a menu that opens under the pointer (TAB-1, TAB-4,
  FILE-2, FILE-3, GIT-4, HIST-3, HAND-6).

The review of 0.5.0 found these by reading the code. Each was then shown by
a test that failed, and fixed:

- A commit on another Mac that a slow hook refused lost its message: the
  changes read again meanwhile were taken for the commit's answer
  (REMOTE-14).
- A file on another Mac that could not be saved counted as saved, and the
  next look at the files put the old text over the changes (REMOTE-15).
- Opening the app on another Mac did not start this Mac's host
  (REMOTE-18).
- This Mac's arrangement of tabs was sent to a host that had none
  (REMOTE-16).
- Forgetting the Mac on screen with unsaved changes left it on screen and
  out of the menu (REMOTE-17).
- A title that was never ended had everything after it sent twice to a
  client that attached (SES-19), and an image too long to keep was sent in
  part and drawn as text (SES-20).
- A host started in another way, or one of a build run by hand, rewrote
  the launch agent (LOGIN-5). Another copy of the app itself still takes
  it when opened: telling that from an app that moved would mean looking
  at the path the launch agent names, which code scanning refuses.
- What an app sent while connecting again arrived before its hello, and
  the host closed the connection (SES-22).
- Each attach wrote out the whole screen again, most of a second for a
  long session, on the queue all of the host's work goes through (SES-21).

Found while #20 was built (0.6.0), each shown by a test that failed first:

- A host that was killed left the Mac app saying nothing: its sessions
  were gone and the window showed none (HOST-5). A Mac showing another Mac,
  and the iPhone, showed a list that had emptied (REMOTE-19, HOST-8).
- The app started its host again only the first time it was lost: after
  the second, it waited, then said the host did not answer (HOST-6).
- A host that could not start was tried twenty times and then reported
  with the connection's error, not the host's own reason (HOST-7).
- With the app closed, a host that was killed was not started again: the
  launch agent had no `KeepAlive`, and the iPhone could not reach the Mac
  until the app was opened (LOGIN-6).

Found while #20 was built, the third part, each shown by a test that
failed while the host reported nothing:

- A session's program that was killed closed its tab with nothing said
  (SES-23).
- A hold on sleep that macOS refused was not known to anyone (AWAKE-4).
- Usage the status line relay could not save left the usage band with
  its old figures, without a word (USE-5).

Found while #11 was built: a schedule made after its time of today ran at
once for that time (SCHED-10).

Found on CI in 0.6.0 (#32): SES-21 asked that a long session be written
out in less than 2 seconds, which held here and failed on a slower runner
(2.01 seconds). It now compares writing out a long session with writing
out a short one, and was seen to fail when each line was made to cost more
the more lines there are.

Found by running the real agents before 0.10.0 (INBOX-5 by hand, #140):
the test's Codex opened its shell in the development build that was
running on the Mac, in another Codex session's folder. Codex 0.169 runs
its sessions through one app server, which starts their hooks and MCP
servers in the environment of the session that started it. No stand-in
had shown it: each started its hook and its server itself. LINK-10 holds
how each real agent was then seen to start them, and LINK-11 runs the
real `agenttermd` under a program named `codex` that has no terminal.
Setting Codex up for the fix, in a home of the trial's own, showed that
Codex writes a table it adds above the comments its `config.toml` ends
with, inside the marks AgentTerm's hooks were between (#142, SETUP-8).

## What stays by hand

Some of this cannot be automated here, and is checked before a release:

- Anything that needs a second machine or a real phone: Tailscale between
  devices, the camera scanning a pairing code, a cellular link.
- What macOS decides: permission prompts, sleep, starting the host at
  login, the menu bar icon after the window closes.
- Real input methods (VN-2, VN-3).
- The agents' own services (USE-3): the figures need a signed-in account.
- On the iPhone, what a slow link shows (LOAD-1, LOAD-2): the test that
  drives the app waits for it to be still, which a spinner never is. It
  was looked at once by capturing the simulator from outside.
- What the Mac's terminal draws: accessibility does not give its text.
  What a session holds is checked through the host instead.
- The real agents (INBOX-5, `AGENTTERM_REAL_AGENTS=1 scripts/test-mac.sh
  RealAgentsTests`): they are signed in in the user's home, and run the
  hooks and the server of the development build in `dist/`. It is not
  run while Codex's shared app server runs (the test says so and is
  skipped): through it the test's Codex speaks to the AgentTerm the user
  has open, not to the test's (#140).
- The agents' own commands for the server (`mcp add`, `mcp get`, `mcp
  remove`): tried with the real agents, each in a configuration folder of
  the trial's own, then `agenttermd setup <agent>` of the build after
  them; the stand-ins answer as they were seen to (`docs/AGENT-CLIS.md`).
  Antigravity in a session was not: it is signed in in the user's home.
- Codex's shared app server itself (#140): tried with the real Codex in
  a `CODEX_HOME` of the trial's own, with a key that is nobody's, so
  that nothing of the user's Codex is read or changed. `agenttermd setup
  codex` of the build is run there, then `/mcp` in a `codex` started
  plainly says how many tools AgentTerm's server offers: all of them once
  set up, none through the shared server (`docs/AGENT-CLIS.md`).
