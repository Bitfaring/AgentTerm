# AgentTerm product spec

## Summary

AgentTerm is a native terminal for running coding agents on a Mac and steering
them from an iPhone. The Mac runs the agents in real pseudo terminals. The
iPhone is a remote control for those same terminals: it shows them, resizes
them to fit its screen and sends input.

AgentTerm is open source under the MIT license.

## Who it is for

Developers who run agent CLIs (Claude Code, Codex, Antigravity, Copilot CLI)
for long tasks and want to check on them, answer a prompt or start a new task
without sitting at the Mac.

## What should make it better than the alternatives

These three are the reasons to pick AgentTerm, and they take priority when
trading off scope:

1. **A beautiful, easy interface.** Nothing to configure before the first
   session. Starting an agent is one click. The layout is familiar.
2. **Pairing by QR code.** The iPhone scans a code shown by the Mac and is
   connected. No addresses, ports or keys to type.
3. **Vietnamese typing that just works.** Telex and VNI input, with any input
   method, must produce the right text in the shell and inside every agent,
   on the Mac and on the iPhone.

## Platforms

| Platform | Role | Minimum OS |
|---|---|---|
| macOS | Runs the sessions and shows them | macOS 14 |
| iPhone | Remote control for sessions on the Mac | iOS 17 |
| iPad | The iPhone app, laid out for the iPad's screen (#88) | iPadOS 17 |

iOS does not allow apps to start processes, so the iPhone never runs an agent
itself.

The iPad has what the iPhone has (principle 1): the same tabs and screens,
a session's terminal over the whole screen, one window. What takes careful
editing stays the Mac's there too. The lists (sessions, History, Schedules,
Settings) keep a column's width in the middle of its screen; narrowed by
Split View or Stage Manager it is laid out as the iPhone is. What the app
says names the device it runs on.

## Features

### Sessions

- A session is one program running in a PTY on the Mac: an agent or a shell.
- Sessions belong to the host daemon, not to a window. Closing the app or
  losing the phone's connection does not stop them.
- Any number of clients can attach to a session and all see the same output.
- A client that attaches gets the session's screen as it is at that moment,
  also that of a full screen program, which does not have to draw again
  for it, and the 10,000 lines above it to scroll back through. All of it
  is laid out for the size the session has now. A terminal scrolls back
  20,000 lines, on the Mac and on the iPhone.
- The iPhone opens a session with its screen and the 500 lines above it.
  Scrolled to the top of those, a strip at the top says "Loading earlier
  lines…", the next 1,000 come, and the line that was in view stays in
  view. What it has is kept: going back to the session, or reconnecting,
  brings only what was written since. A session started on the iPhone
  comes whole. The Mac gets all of it.
- The iPhone's terminal is drawn on the GPU.
- **Files into a terminal** (Mac, #160): a file dropped on a terminal, or
  copied in the Finder and pasted, has its path typed into the session,
  quoted for the shell as Terminal.app does, as a paste, not submitted. A
  picture on the clipboard with no text, a screenshot say, is sent as
  Control V when ⌘V is pressed: an agent such as Claude Code then takes the
  clipboard's picture itself; nothing is saved. A session of another Mac
  takes neither, and says why: its agent would look on that Mac.

### Session names

- A session is named after what it is about: the title of the conversation
  its agent is having, the same title the History tab shows.
- Until the agent has saved a conversation the session keeps the agent's
  name ("Claude Code"), and it changes by itself once there is one. A shell
  keeps the shell's name.
- The name and the agent's icon are the same on the Mac (folder list and
  tabs) and on the iPhone.

### What the agent is doing

- Each agent's session shows whether its agent is working, waiting for
  permission, waiting for an answer, or done: a mark next to its name in
  the folder list and on its tab on the Mac, in the sessions list and the
  terminal's title on the iPhone. A folder's row says when one of its
  sessions waits.
- The state comes from what the agent says about itself, through
  AgentTerm's hooks in the agent's own configuration (see "Hooks and MCP"),
  never from the screen. A state that is shown is true; where it is not
  known, nothing is shown.
- A shell has no state, unless an agent typed in it has the hooks. An
  agent that has just started has none until it says something. After
  Escape or Control C is typed to a working agent, its state is not known
  until the agent says more.
- Codex asks to review AgentTerm's hooks, in its `config.toml`, the first
  time it starts after they were added or changed (seen with Codex 0.169).
  Until its hooks first report, a Codex session says that its state shows
  once they run, and to choose "Trust all and continue" if Codex asks;
  told to go on without them, Codex shows no state.
- Antigravity does not say when it waits for permission. For a tool of
  AgentTerm's own (a shell, the browser) AgentTerm knows all the same: the
  call Antigravity said it is about to make does not come, and its session
  waits for permission, named by the tool, as Antigravity's question names
  it, until the call comes or the turn is stopped (#141). While it runs
  any other tool, its state is not shown, and its session says why.

### Worktrees

- **A session in a worktree of its own** (#23): an agent's launch button,
  or the shell's, has "Start … in a New Worktree" in its menu. AgentTerm
  makes a branch (`agentterm/<agent>-<number>` unless named) cut from the
  folder's current commit, a git worktree for it in
  `<folder>/.agentterm/worktrees/<branch>`, and starts the session there.
  Nothing is brought along: no uncommitted change, nothing git ignores;
  with changes not committed, the app asks first. What the worktree needs
  (`npm install`, a `.env`) is done in it by its user, or the agent: no
  command is run in it by AgentTerm (decided on 2026-11-16, #75).
- The session is listed under its folder with its branch, on the Mac and
  the iPhone. Selecting it, the Git, History and Files tabs show its
  worktree; on the iPhone its menu has "Changes, History and Files",
  which opens its folder on that worktree.
- **The worktree bar** (#33, #43): at the top of the side panel of a
  folder that is a repository, its worktrees as chips. The folder's own
  branch is always the first; each worktree follows, whoever made it
  (AgentTerm, Claude Code in `.claude/worktrees`, `git worktree add`), with
  how many files are changed in it, how many commits it is ahead by, a dot
  when a session runs in it, and "missing" when its folder is gone. A
  click makes Git, History and Files about that one, with the same actions
  as the folder; the first chip goes back to the folder. A worktree that
  lies inside the repository is not listed among the folder's changes as
  a file nobody tracks.
- **+** makes a new one: the branch's name, suggested and editable, the
  branch it starts from (the folder's own unless another, local or of a
  remote, is picked; the new branch follows none), and what is started
  there, an agent or a shell. The sheet says when the folder has changes
  that the worktree will not have. An agent can begin fresh or **continue
  a conversation** (#150), one of the folder's or of its worktrees', and
  only those (#165), the newest picked: it is handed off into the new worktree (see Handoff), and the
  handoff file says to work there only, not at the folder's paths the
  conversation names. Its own conversation is not resumed there: it holds
  the folder's paths, and the agent would go on changing the folder.
- **⋯** is for the worktree on show: merge its branch into the folder's
  and remove it (with its branch, for one AgentTerm made), open a pull
  request with `gh`, or throw it away, which asks first and says what is
  not merged; the folder's own chip has none. A merge that conflicts is
  left in the folder to be resolved and continued, or aborted, as any
  other, and the worktree is kept. A worktree a session runs in is not
  removed.
- The iPhone has all of it, the same, in a folder's screen (#34); "Start
  … in a New Worktree…" in the menu of a launch button opens the same
  sheet.
- `.agentterm/` is listed in the repository's own exclude file and is not
  shown in the Files tab.

### Schedules

- A schedule starts an agent with a prompt in a folder: once at a time,
  every day at a time, on some weekdays at a time, every so many minutes
  or hours (5 minutes at the most often; all day, or only between two
  times of the day), on certain dates, or a little after the agent's
  account limit starts over. On or off without being deleted. Made
  and changed in the Mac's Schedules, a place of the window, and the
  iPhone's Schedules tab; the host keeps them and runs them, with
  the app closed too.
- **Schedules** shows them in three groups, the same on both: **Running**,
  the runs whose session still runs, each opening its session; **Scheduled**,
  every schedule, the next to run first, then those waiting for a limit,
  then those turned off; and **Past Runs**, the runs that are over, newest
  first, with what came of each (started, skipped, missed). On the Mac the
  list is at the left, each schedule with its switch, and the schedule
  picked, or one being made with +, is in the middle with every run it
  had; one half made is dropped when Schedules is left.
- **Permissions.** A schedule says how its agent handles permissions:
  skip all (the default: nobody is there to answer), accept edits, or ask.
  Codex offers no "accept edits". Before a schedule that skips them is
  saved, the app says in words what each run may do on the Mac, and it is
  saved only once that is accepted. Sessions started by hand keep asking.
- **Nothing to do when it runs.** A run gives itself what it needs: its
  agent's switch for the mode, and the folder trusted where the agent would
  ask. Claude Code's trust is written into its settings when the schedule
  is saved; Codex's hooks run without the user's trust; Copilot CLI and
  Antigravity are told for the run.
- **Runs.** A run is a session like any other, in the folder, named after
  the schedule and marked as its run, and stays open when the agent is done,
  for a day, so what it did can be read. A run whose turn before it is
  still going is skipped and said to be. At most two run at the same
  moment; a third waits for its turn. A run whose agent never says what it
  is doing counts as done once it has shown nothing new for an hour. A run
  whose folder is gone is not started, and says so. A run missed while the Mac slept or
  was off runs once when it is next awake, or is skipped, as the schedule
  says; never more than once for all the times missed. A schedule made
  after its time today first runs at its next time.
- A schedule about to run keeps the Mac awake from ten minutes before,
  whatever the keep-awake switch says. Waking a sleeping Mac is not done.
- Each schedule lists its last runs: when, and what came of it.
- **Run Now** (#47), from a schedule's menu in the list or from the
  schedule itself, starts a run whatever its time. **Stop** ends a run
  that is going on, from the list or from the schedule; one that still
  waits to start is taken off the list. **Duplicate** makes a copy with
  a name of its own, turned off, to be changed. **Pause All** holds every
  schedule back: none comes due meanwhile, and what would have run is not
  caught up when they are let go again.
- **What a run did.** While it goes on, its session. Once it is over, how
  it ended (its agent done, stopped by the user, stopped for taking too
  long, its session ended) and how long it took; what it changed in git
  since it started, in words (commits, files changed, new files), not
  counting what was changed in the folder before; and **Output**: what it
  printed, its screen and up to 5,000 lines that scrolled by, kept as
  long as the run is listed.
- **Being told.** A run is a session, so the iPhone says when its agent is
  done or needs an answer as for any agent. A run that was not started
  when it should have been (its folder gone, its agent not found, its
  pull failed or stopped on conflicts, its worktree could not be made or
  made ready) or was stopped for taking too long is said
  in the top banner of both apps. A pull that stops on conflicts before a
  run is undone, since nobody is there to resolve them, and a worktree
  whose submodules failed is kept, to be looked at, with
  no agent started in it. A run skipped as its schedule says
  (nothing changed, nothing pulled, the run before still going) is in the
  list of runs only.
- **When a run starts.** Every time it comes due; only when the folder
  has changes that are not committed; or only after a pull, done first,
  brought new commits. A run that comes due while the one before it is
  still going is skipped, or waits for it, as the schedule says. A
  schedule may name the longest a run may take, from when it started,
  after which it is stopped; how long a run took is counted from then
  too. A run going when the host stops, or dies, ends with it.
- **A worktree of its own.** A schedule may have each run in a new
  worktree of the folder, on a branch named after the schedule and the
  time, with its submodules checked out; the worktree is kept afterwards,
  in the folder's worktree bar, to
  be looked at, merged or thrown away.
- **Changes to a schedule** are kept with it, the last twenty: when, and
  what was changed, in words.

### When an agent is done or needs you

How both apps tell the user things without being asked was decided again
by the owner on 2026-11-19 (#66): three channels, each with its own
switch. Notifications tell events and are answered; the Inbox keeps what
happened; the Live Activity shows the host's state now (below).

- **What is told:** an agent that asks permission, asks a question, or is
  done, once for each state it is in (one that asks something else is
  told again, one that keeps waiting is not); and a failure that stopped
  work: the host or a session's program stopped, a schedule's run did not
  start or was stopped. Other failures (a push that could not be sent, the
  Mac not kept awake, usage not saved) are banners and Inbox items only.
- **Who is told: every device, and every one sounds**: the Mac and each
  paired iPhone or iPad, whether someone is at the Mac or not. The host
  makes each notice once for all of them. The session on an iPhone's or
  iPad's screen is not told there: it is seen there. On the Mac no session
  is left out, the one in front included (#180): being in front does not
  make it seen, something the user does there does (choosing it, typing
  into it, the notification).
- **When it is a notification** (#180, decided by the owner on
  2026-11-20): every notice is in each device's Inbox, and the Mac's
  banner, at once; it is a notification on the Mac and on every iPhone or
  iPad **at the same moment**, which the host says. An agent that is done
  waits 30 seconds first, always; anything else waits 30 seconds while
  someone is at the Mac, and is told at once otherwise. Handled or read
  within those 30 seconds (the agent works again; opened, answered,
  dismissed or read on some device), it is a notification nowhere. Short
  turns that end one after the other do not buzz the phone each time. A
  host that starts again within the wait still tells it once the wait is
  over (#193).
- **Handled on one, gone from all**: answered, opened or dismissed (from
  the banner, from Notification Center) on one device, or its agent moving
  on, and the notification goes from every other device.
- **Read on one, read on all** (#180, replacing what #66 decided): a
  notice read on one device (picked in the Inbox, its session opened, its
  notification tapped, answered or dismissed) is read on every device, and
  its notification goes from all of them. What is read while a device is
  not connected is said to the host once it is.
- **On the iPhone and the iPad**, iOS's own notification banner, also
  with the app open; the app draws none of its own. While the app is in
  the background or asleep, the released build is told through Apple's
  push service only, never also over its connection, so nothing shows
  twice (#190); back in front, what it was not told either way is shown
  then. "Also
  While the App Is Closed", on by default, under "Tell me when an agent is
  done or needs me". While that one is off it is dimmed and shows off,
  whatever it was set to, since nothing is shown while the app is closed
  either; what it was set to is kept, and shown again once notifications
  are turned on (#211). In a build with no push (a development build) it
  shows off and dimmed too, whatever it was set to, and its footnote says
  why (#212). What it says is encrypted on the Mac for that device
  alone; one that cannot be opened says "An agent needs you". A
  notification handled elsewhere while the app is asleep is taken back by
  a background push, which iOS limits and does not deliver to an app the
  user closed; what is left goes once the app is opened. (Removing it at
  once needs Apple's filtering entitlement, asked for on 2026-11-19.) The
  switch's footnote says when it does not work and why: a development
  build has none, the Mac has no relay, notifications are not allowed,
  the relay could not be reached. At its first launch, once the question
  about reports is answered, the app's first screen asks only whether it
  may notify (Allow Notifications, Not Now), not an onboarding like the
  Mac's (#180). Not Now turns "Tell me when an agent is done or needs me"
  off, as Settings then shows, and iOS is not asked, not when the phone
  pairs either, until that switch is turned on again (#195, decided by the
  owner). iOS asks once: what wants to know meanwhile (pairing, then the
  pushes) waits for the user's answer, and is not told no while the
  question is still on screen (#200).
- **On the Mac**, a banner while the app is in front, which opens the
  session; and a macOS notification, with the app in front or not (#180),
  with Reply and the choices as on the iPhone: "Notify when an agent is
  done or needs you" in Settings > General, on by default. macOS is asked
  whether the app may notify in the onboarding's Permissions step, where
  Notifications is one of the permissions listed. The banner shows what the agent said on up to six lines; Show
  All opens it out.
- A notification for a question, or for a finished task, takes a short
  reply, written or dictated, sent as the next message; on the iPhone it
  asks for the phone to be unlocked first. A question's choices are
  buttons, the question alone its text. A choice is picked in the agent's
  own list of them, a reply that is none of them is given as the agent's
  "other" answer. One for a permission has no buttons: touching it opens
  the session. A reply that arrives after the agent moved on is dropped,
  and the app says so. A reply from a notification that came through
  Apple is sent once the app has reached the Mac, only while the agent
  still asks exactly that. Tapping a notification opens its session, on
  its Mac.
- What the agent said shows on the lock screen only where iOS shows
  previews there; by default it does not.
- **Failures** are said in a banner at the top of both apps until they
  are dismissed on some device, and kept in the Inbox; a one-off error is
  always said, in an alert, on both apps alike.
- **Ongoing states** are said in the same words and with the same buttons
  on both apps: connecting, not reachable (why, and what to do), another
  release on the Mac, a session's size set by another device ("Use This
  Size").
- **The Inbox** (#66, after #67) is each device's own history of what it
  was told: kept after it is read, for 30 days. Deleted is that device's
  alone; read (#180), and whether a notice was handled and how (answered,
  opened, dismissed, the agent moved on), are the same everywhere. An item
  is deleted on its own, or the read ones, or all of them (asked first);
  one whose agent still waits for an answer is not deleted until it is
  answered. What was told while a device was asleep reaches its Inbox when
  it connects.
- On the Mac the Inbox is a place of the bar at the left edge, under
  Sessions, with how many items are unread on it. Its list is at the left,
  unread ones in bold, with a menu for Delete Read and Delete All; the
  item picked is shown in the middle, and is then read: what its agent
  said or asks, or what stopped, or, for one that is over, how it was
  handled. **Open** shows the session in Sessions; **Delete** (not for an
  agent that waits) takes it out of this Mac's Inbox. On the iPhone and
  the iPad, what is unread or waits is at the top of the Sessions list,
  with All, which opens the whole Inbox: swiped to delete one, the menu for
  the read ones or all. On both, an item touched or clicked shows that
  item, all of it, with Open for its session; it never opens the session
  by itself: an agent done whose session runs shows what its turn came to,
  anything else what was said or asked, its choices, and how it was
  handled. Each item of the list shows all of what was said, not its end
  only (the owner's decisions, 2026-11-21).
- **What a turn came to** (#71): an agent that is done shows, in the
  Inbox, what it was asked, what it answered, the commands it ran with
  their exit codes, and the files of its folder that changed while it
  worked. The commands are those of the agent's own record of the turn,
  with "exit 0", "exit 3", "failed" or "not known" beside each: what the
  agent says it ran or tested is in its answer, and is not taken for what
  it did. The files are what changed in the repository from the turn's
  start to its end, whoever changed them: when another agent worked in the
  same repository meanwhile, that is said; in a worktree of its own, that
  is said too. A file that had changes already when the turn began is
  marked so. When the agent's record cannot be read, which commands it ran
  is said to be not known; outside a git repository, what changed is said
  to be not known. A turn the user stopped is said to be stopped. The last
  turn of each session is kept by the host while it runs, and shown again
  after a device connects again.
- From the result: **Open Diff** shows the session in Sessions with its
  folder's changes beside it; **Continue** sends the next instruction,
  typed into the session as the user would (refused if the agent moved
  on); **Hand Off…** hands the conversation to another agent. On the Mac
  these are in the Inbox's middle; on the iPhone and the iPad a done item
  opens a screen with the result, the terminal one touch away (Open), and
  the session is seen once its terminal is opened.
- Looking at the folder and reading the agent's record is done by the app
  by itself, so it has a switch, on by default: Settings > Git > "Show
  what each turn came to", on both apps, shared through the host. Off, no
  turn is looked at, and the Inbox shows what the agent said.

### The Live Activity

Decided by the owner on 2026-11-19 (#168): a channel of its own, which
shows the host's state now rather than events.

- While an agent works or waits, the iPhone's lock screen and Dynamic
  Island show it, **whether someone is at the Mac or not**: how many work,
  need permission, ask a question, are done and not seen, and how many
  sessions or hosts stopped; the names of the sessions that wait, never
  what an agent said. Touching it opens the app on the session that waits.
- It is kept true while the app is asleep by Apple's push for Live
  Activities, which the Mac sends through the relay of #66 on a path of its
  own, in the released build only: the counts and the names reach the
  relay and Apple in the clear, since iOS draws the activity from them.
  The Mac starts it while the app is asleep, once: what changes after
  that waits until the app is opened, rather than starting a second one
  (#194, decided by the owner on 2026-11-21); a burst of changes is one
  update, and it is sent again every 15 minutes while agents work; one
  that gets no update is shown as out of date. **One activity is kept
  between turns and only updated** (#180, decided by the owner on
  2026-11-20): when every agent is done it shows that, and is ended only
  once nothing has worked or waited for 15 minutes, leaving the last state,
  which stays true; an iPhone that was connected then and goes away later
  is sent the end when it goes (#192). A new turn within those 15 minutes updates it rather
  than starting another, whose start through Apple comes with an alert. Without push (a development
  build), it goes out of date ten minutes after the app last updated it.
- "Live Activity of the Mac's agents" in the iPhone's Settings turns it
  off, apart from notifications. While iOS has Live Activities turned off
  for the app (in the iPhone's Settings) the switch shows off and dimmed,
  whatever it was set to, and the section's footnote says why (#212);
  what it was set to is kept, and shown again once iOS allows them.

### Hooks and MCP (#129)

AgentTerm starts an agent as the user would, with nothing of its own on
its command line: its hooks (what it is doing, the Inbox, notifications),
AgentTerm's MCP server (shells and pages of its own, and what AgentTerm
tells it), and for Claude Code the status line AgentTerm reads its usage
from, are in the agent's own configuration, at the user's scope, for every
folder. AgentTerm adds them only when the user asks, with each agent's own
commands, and takes them out the same way; outside AgentTerm they do
nothing (decided by the owner on 2026-11-17).

- **Settings > Hooks & MCP** (Mac) lists each agent: whether it is installed
  on the Mac, what it has (Hooks, MCP server, Status line for Claude Code,
  and for Codex whether the server its sessions share is off), asked of the
  agent itself, and whether its session running now was heard from;
  Install, Install for All, Remove. What does not work is said, in the
  agent's own words. Only AgentTerm on that Mac sets its agents up; another
  Mac shows them only.
- **Each part with the agent's own command, when it has one.** Under each
  agent the pane shows the commands Install runs, to run in a terminal
  instead, each with what it is for and Copy, and those that take them out:
  - the MCP server, with the agent's own command, which every agent has:
    `claude mcp add --scope user agentterm -- '<AgentTerm>/agenttermd' mcp`,
    `codex mcp add agentterm -- …`, `copilot mcp add agentterm -- …`, `agy
    mcp add agentterm …`; taken out with its `mcp remove`;
  - then AgentTerm's own, `'<AgentTerm>/agenttermd' setup claude` (or
    `codex`, `copilot`, `agy`, `all`; `--remove` takes that out; `setup
    status` says what each has), for what the agent has no command for: its
    hooks, which no agent has a command for; Claude Code's status line, in
    its settings, the one the user had kept and run after AgentTerm's; for
    Codex the session's variable its server needs, which `codex mcp add`
    cannot say. Run by itself, it says the agent's command for what is
    still missing.
- How each takes its hooks, as tried with the versions in use: Claude Code
  and Copilot CLI, a plugin of a marketplace in AgentTerm's folder, which
  they install (`plugin marketplace add`, `plugin install`); Antigravity, a
  plugin installed from AgentTerm's folder, with what it is told as a rule
  (installed again after changing those words); Codex, in its
  `config.toml`, each under a comment that says it is AgentTerm's, which it
  then asks to review (it takes hooks nowhere else). Claude Code has one
  status line: of the two builds, the one set up last has it, and runs the
  other's after its own. Taking AgentTerm's out of Codex's `config.toml`
  takes out its own lines and nothing else, whatever Codex wrote there
  since.
- **Codex's shared server.** Codex (0.169) runs its sessions through one
  background server they share, which starts each session's hooks and MCP
  server as the session that started it: AgentTerm cannot tell one session
  from another through it. Install turns that off for all of Codex, with
  Codex's own command (`codex features disable daemon_auto_start`), which
  the row names before Install is pressed and shows among its commands; Remove turns it on again, unless
  it was off before. While such a server still runs, Codex goes on using
  it: the row says "Shared server on" and that Install stops it, Codex
  counts as not set up, and Install stops it with Codex's own command
  (`codex app-server daemon stop`, #153), shown among its commands. Tried
  with Codex 0.169.1: sessions started with it off do not use it and go
  on; one started through it before may stop, which the row says before
  Install is pressed. **Install for All** is at the top of the agents'
  list, in Settings and in the onboarding.
  A session that runs through the shared server all the same has no shells
  or pages of AgentTerm's and its state is not shown: its mark says its
  hooks and its server were not heard. It never speaks as another session.
- **The onboarding** (Mac) shows over the window each time the app opens
  while an agent installed on the Mac misses its hooks or the MCP server:
  Welcome, Folders (add the projects' folders), Permissions, Hooks & MCP
  (the same rows, with Install for All), iPhone (pairing over Tailscale).
  Each step can be skipped; Don't Show This Again stops it; Settings >
  Hooks & MCP shows it again.
- **Each agent's session** has a mark at the end of its usage band, on the
  Mac and the iPhone: connected (both heard), missing (one or both not
  heard within 20 seconds of the agent's start), or connecting. Touched,
  it says which and what to do, in the same words on both.
- **Outside AgentTerm**, an agent set up works as before: its hooks write
  nothing, AgentTerm's server offers no tools and tells it nothing (it is
  listed among its servers, empty), Claude Code's status line shows the
  user's own (an empty one for a user who had none, and Claude Code then
  hides some of its keyboard hints), and what Antigravity is told says it
  holds only where the server has tools. Codex asks once to review the
  hooks, wherever it next starts.
- **An agent typed by hand in a shell** (`claude`, `codex`, `copilot`, `agy`
  at the prompt) is found from the program in front of the shell's
  terminal, as named when typed, and while it runs the shell is its
  session: its usage band and mark, its state and the Inbox when it has
  the hooks, its own shells and pages when it has the server. Every
  session, a shell's too, has what they need to reach the host in its
  environment. When the shell is in front again, it is a shell again.

### Shells an agent opens

- An agent can open a shell as a session the user sees: asked to "open an
  SSH session to the build server and check the logs", it opens it as a
  tab, works in it, and the user watches and can type in it too. On the
  Mac it is a tab and a row in its agent's folder, on the iPhone a row,
  marked as opened by an agent.
- It is done through AgentTerm's MCP server, in the agent's own
  configuration once Settings > Hooks & MCP added it (see "Hooks and
  MCP"), in every session of that agent, one started from AgentTerm or
  typed in its shells. Elsewhere it offers no tools. A shell the agent
  opens is its own while its session is an agent's; one opened by an agent
  typed in a shell of the user's is the user's.
- What builds before 0.8.0 put in the agents' settings is not taken out any
  more (principle 6).
- A development build has a server of its own, under another name
  (`agentterm-dev`), and each works only in the sessions of its own build:
  trying a change never takes the shells from the agents of the installed
  app.
- Its tools, all named `shell_…`: open a shell (with a command or
  without), **run a command in it and be told its exit code and its
  output once it ends**, in one call, list the shells, read a shell's
  screen, type into it (text and keys by name), wait until the command
  that runs ends, its screen shows a text or is still, close it. A
  command that outlasts the call goes on running, and waiting on it later
  tells how it ended. For this, a shell an agent opens says when each of
  its commands starts and ends, with its exit code (zsh is set up for it
  when it starts, after the user's own startup files; fish says so by
  itself); in another shell, a command is waited for until the screen is
  still, and its exit code is not known. The user's own shells are left
  as they are.
- An agent sees and uses only the shells it opened: it lists, reads,
  types into and closes those, and no other. Another agent's shell, the
  user's own sessions and the agents' sessions it neither sees nor
  reaches; one that has no shell of its own, or whose own is busy, opens
  another. So what runs in an agent's shell is what that agent started. A
  shell whose agent's session has ended is left as it is: it stays open
  for the user, and no agent sees it. An agent opens shells only, never
  another agent.
- A shell's row names the session of the agent that opened it, on the Mac
  and on the iPhone, or says that its agent has ended.
- When an agent's server cannot reach the host, the agent is told at once
  and why (the host is not running, its sign-in was refused, the
  connection was lost), rather than left waiting. When a server was
  refused, or could not be set up in an agent, both apps say so in a
  banner at the top, with what to do, until it is over or the banner is
  closed.
- When the agent's session ends, the shells it opened stay, for the user.
- Outside a session of AgentTerm (an agent run in another terminal), the
  server offers no tools.
- **Agents run their commands in shells you see**: each agent is asked to run its commands in a shell of
  the server, one already open if there is one free in its folder, rather
  than in its own out of sight, and to leave it open for the next task. Claude
  Code is told so in its system prompt; Copilot CLI and Antigravity in
  instructions files of AgentTerm's, which they read as they read a
  project's; Codex through the server's instructions, which it follows. An
  agent still decides for itself. There is no switch for it: the user who
  wants it otherwise changes what the agent is told (below).
- Each agent is also told to use AgentTerm's
  browser, through the server's `browser_` tools, whenever the user asks
  for anything in a browser ("the browser", "Chrome", a site, localhost),
  and not another browser tool or extension it may have (such as Claude in
  Chrome) unless the user names that one.
- **Settings > Shell** on the Mac. Which program a new shell is (the
  login shell by default, or one of the Mac's shells, or any other
  program), here and from the iPhone; a session that runs a command, an
  agent's, still starts through the login shell. What is run first in a
  shell: in the user's own, typed at the prompt with Return as the user
  would; in an agent's, before its first prompt, so that it is not one of
  the agent's commands. A zsh an agent opens always says when each command
  ends, with no switch: another shell does not, and there an agent waits
  for the screen to be still and is not told the exit code. How the terminals look on this Mac: font, size, cursor
  (block, underline, bar, blinking or not) and how far back they scroll.
  The host keeps all but the looks.
- **What the agents are told**, in Settings > Agents on the Mac: one text
  for each agent (Claude Code, Codex, Copilot CLI, Antigravity), filled
  with what AgentTerm tells it by default (the two above). The user edits it, saves it (⌘S) or puts the default back
  (Reset to Default); empty, the agent is told nothing by AgentTerm. The
  host keeps it, so an agent started from the iPhone or by a schedule is
  told the same; sessions started after it is saved are told it, those
  running keep what they were told. It is given where each agent reads it:
  Claude Code's system prompt, Copilot CLI's and Antigravity's
  instructions files, and the MCP server's instructions, which Codex
  reads. It is edited on the Mac, and in the iPhone's Settings (#155).

### The browser (Mac)

The Mac app has a browser (#76): Chromium itself, embedded with CEF, used
by the user and by the agents alike. An agent drives the very tab the
user sees.

- **For the user.** The user's pages belong to no folder (#148): they are
  one Browser, a tab in the strip of every folder, the same pages whichever
  is on show, as a window of Chrome holds its tabs: the row under the
  strip holds the pages, each shown when picked and closed by its ×, and
  New Page for one more (see Panes). The tab says how many pages it holds;
  a page closed shows the one beside it, the last one closed closes the
  tab, and closing the tab while it holds several is asked first. The list on the left holds them the
  same way (#122): one Browser row above the folders, its pages set in under
  it; the row shows the page the tab shows, and closes them all from its
  menu. A page is started as a shell is: the
  Browser button next to Shell in the header, on the launch screen, the +
  of the row, or Browser > New Browser Tab (⌥⌘T). It opens in
  the one Browser, whatever folder is on show,
  in the profile picked (see Profiles). A right click in a page opens a
  menu as Chrome's (#131): in a text field Cut, Copy, Paste and Select
  All; on selected text Copy; on a link Open Link in New Tab and Copy Link
  Address; on an image Open Image in New Tab and Copy Image Address;
  elsewhere on the page Back, Forward and Reload; Inspect always, which
  opens the page's DevTools. A link or an image opened in a new tab is a
  page of the user's in the Browser tab.
- **Extensions** (#125) can be installed from the Chrome Web Store, in the
  profile of the page, as in Chrome; Chrome asks first, in its own prompt.
  A window of Chrome's own that Chrome opens by itself, an extension's
  welcome page say, does not show: the Browser tab says Chrome opened it,
  with Open in Chrome Window, which shows it outside AgentTerm (where the
  extensions' buttons are), and Close It. A page can be opened in such a
  window from the bar's menu too (Open in Chrome Window). These windows
  close with the app. Its bar has back, forward, reload or stop, the
  profile it uses, and the
  address, where words that are not an address are searched for (⌘L to
  reach it, ⌘R, ⌘[ and ⌘] too). Show As, a button of the bar that names the device
  in use, lists the devices by kind with their screens, the one in use
  marked and this Mac first, with a field to find one by name; a device
  that cannot be shown is said, with why. Its menu finds in the page (⌥⌘F), zooms. Shown as a device
  (Show As: some forty phones, tablets
  and computers, Chrome's DevTools' own, by kind: iPhones, Pixels,
  Galaxies, iPads, Surfaces, laptops; their screen's size and density,
  user agent with this Chromium's version, `navigator.platform`, client
  hints and touch; the page is then as wide and as tall as the device's
  screen, and beside an agent its part gets just that width, though
  never less than its bar needs for its buttons (460 points), and the
  agent the rest; a screen taller than its room has the room's height, never
  drawn smaller: the page is as wide as the device's screen, the rest of
  it is reached by scrolling, and the page is still told the device's
  whole screen. The devices watching it are sent what the Mac shows, as
  sharp, and show it in its own shape, never squeezed into another), opens Chromium's own Developer Tools
  (⌥⌘I) with the console, sends an element to an agent, and closes it. Text is selected, copied
  and pasted as anywhere. A page that opens a window opens a tab instead,
  in the same project and for the same agent, which keeps its opener: a
  sign-in in a popup, as "Sign in with Google", hands its answer back to
  the page, and a page that closes itself closes its tab (#162). A download goes to the
  Downloads folder and is shown under the page. A page asking for the
  camera, the microphone, the location, notifications and the like asks
  the user in a bar over the page; an agent never answers it. A page that
  did not load says why, and a development server of the Mac that does
  not answer is said to be maybe not running. The tabs are not kept: the
  app opens with none, an agent's that still runs included (it opens
  another when it needs one). A profile keeps its sign-ins and cookies.
- **Profiles.** The user keeps named profiles in Settings > Browser
  ("Work", "Personal", "Test account"): each has its own sign-ins,
  cookies, storage and cache. Each shows what it keeps on disk; a profile
  is made, renamed, cleared of its data and deleted there (each asked
  first), the last one is never deleted, and one is the default. With a
  single profile, every tab uses it. **With several, the Browser button
  asks which** (a menu of them, the default first, and Private; Browser >
  New Browser Tab opens one in the default), and so does Browser among
  what a folder can start on the iPhone. **An agent asks the user in its
  conversation**: its first `browser_open` that names no profile is
  answered at once with the profiles' names and asks it to ask the user;
  the one it then names is its own, and its next tabs use it without
  naming it (`browser_profiles` lists them). A **private tab** (Browser >
  New Private Tab, ⇧⌥⌘T; Private in the Browser button's menu, or its
  own menu with a single profile; `private: true` for an agent, which is
  not asked) has a profile of its own in memory: it keeps nothing on
  disk, has none of the profiles' sign-ins, and what it has is gone with
  the last of its tabs. The user's private tabs share one, each agent's
  share another of its own. A tab says which profile it uses, or Private,
  in its bar. A page that opens a window opens it in its own profile.
  Data that Chromium has open is cleared, or a
  deleted profile's thrown away, the next time the app opens, and the
  app says so. The user's own browser's profile is never read. The
  released and the development builds keep their profiles apart, and
  their keychain items.
- **For the agents.** Through AgentTerm's MCP server, with its shells'
  tools: an agent opens tabs of its own (`browser_open`), which are in
  its tab (see Panes), reads a page as text with a ref for what can be
  acted on (`browser_snapshot`), clicks, types, picks, presses keys,
  scrolls and waits (`browser_click`, `browser_type`, `browser_select`,
  `browser_press`, `browser_scroll`, `browser_wait`; a field is typed into
  as a user types: emptied by selecting all of it and a real Backspace,
  which an editor that keeps its own state, as X's Draft.js, handles
  itself, then the caret put at its end; a field that shows none of what
  was typed is said to have failed, #161), chooses files for a
  file field (`browser_upload`: files of its project only, so that nothing
  else of the Mac is sent to a site), looks at it
  (`browser_screenshot`), reads its console and its requests
  (`browser_console`, `browser_network`), runs its scripts
  (`browser_evaluate`), shows it as a device (`browser_emulate`), goes
  back, forward or reloads, and closes its own tabs. Each action says what
  came of it: where the page is now, whether it changed, what was
  downloaded or opened, whether the console has new errors. A ref of a
  page that changed since is refused with what to do. A snapshot does not
  read the insides of a page's frames: it names them, with their
  addresses, to be opened in a tab instead. An agent sees and
  drives only the tabs it opened: the user's tabs, and another agent's,
  it is neither listed nor reaches, and no tab is shared with it. To have
  an agent work on a page, the user asks it to open it; a tab of the same
  profile has the same sign-ins. An agent's page goes on working while it
  is not shown (another agent or project on show, the window covered or
  minimized); Chromium then holds it back as Chrome does a tab in the
  background, and the page can tell.
- **Who has the tab.** Over a tab an agent opened, a bar says which
  agent uses it and what it did last. The user takes it over with Take
  Over, or by clicking in the page; the agent is then refused, told why,
  until the user gives it back ("Let … Go On"). It may still read the page.
- **Sending part of a page to an agent.** A page has two modes, switched
  by the Pick button on its bar, in sight beside reload, or Browser > Pick
  an Element for an Agent: browsing it, and picking its elements. While
  picking, the button says so ("Picking"), and an element clicked is not
  clicked but sent: its picture, the address, a selector, its HTML and its
  main styles are shown with a note to write and the agent to send it to
  (#149): in an agent's page, that agent, named and not to be changed; in
  a page of the user's, any running agent, those of the folder on show
  first and the first picked already. Sent, the picture is
  saved in the agent's folder's `.agentterm/shots/` and the rest is typed into the
  agent's session, with the picture's path, and submitted. Picking stays
  on, sent or not, for the next element, until the button turns it off.
- **What fails is said.** With the app closed, or showing another Mac, an
  agent is told at once that the browser is in the app on that Mac and it
  is not open there. The agents always have the browser, as they have
  their shells: Settings has no switch for it (the owner's decision,
  2026-11-16, as for the shells' three).
- **A Mac showing another Mac** (#147) has that Mac's browser as the iPhone
  has it: its pages in the Browser tab and beside its agents, each drawn
  from the pictures that Mac sends while it is shown, and used from here:
  a click, a double click, the pointer passing over the page (hover), a
  drag, selecting text by dragging and ⌘C copying it to this Mac,
  scrolling, the keys and typing, ⌘V pasting what this Mac copied, a right
  click's menu (this Mac's: Copy, Open Link in New Tab, Copy Link Address,
  Back, Forward, Reload; a page's own right-click menu is not shown), the
  address, back, forward, reload, stop, close, taking a page
  from its agent and giving it back, and a new page of the user's (in that
  Mac's default profile). What the mouse, the keys and the wheel do reaches
  that Mac in the order it was done, however slow the link: text typed
  right after a click goes where the click put the caret, and a scroll
  never passes the drag before it (#191, #199). What is done in a Mac's own Chromium (picking an
  element, Show As, finding, zooming, the developer tools, a page beside an
  agent) is on that Mac, and the page's menu says so.
- **On the iPhone**, as on the Mac: an agent's own shells and pages are
  listed right under it, set in, under the headings Shells and Browser;
  the user's pages, which belong to no folder, under "Browser on the Mac". Ending an agent there ends its shells and closes its pages
  too, asked first in the Mac's words (#145). An agent's screen has Agent, Shells and
  Browser, each with its tabs when it has several: a shell is its
  terminal, a page is shown live, about ten pictures a second, which come
  while the Mac does not show it too. On an iPad on its side, the app on
  all of its screen, the page is beside the agent, on the right, and the
  left shows the agent or one of its shells (Agent, Shells); upright, or
  sharing the screen, it is as on the iPhone. The page is used as on the
  Mac: a touch clicks where it lands, and on a field brings the keyboard
  up, whose keys go to the page (a keyboard of the iPad's own too, with
  its arrows, Tab and Escape); a drag scrolls it; two fingers zoom into
  the picture, and 1× fits it again. Over it are back, forward, reload or
  stop, the address bar, which takes an address or words to search for,
  the keyboard, and a menu with Show As (the Mac's devices) and Close
  Tab. An agent's page becomes the user's at the first thing done to it,
  as a click on the Mac makes it, and Let … Go On gives it back; showing
  it as a device or closing it does not take it. Browser, among what a
  folder can start, opens a page of the user's in it, on the Mac but not
  in front there: with several profiles, in the one picked from its menu,
  or private; with one, in it, and a private one from its own menu. The
  user's pages open in a sheet. Picking an element to send to an agent
  is the Mac's only (principle 1). What the iPhone asked of the page and
  the Mac had not answered when the connection to it closes, or when
  another Mac is picked, is answered at once as on the Mac: refused, in
  words that name the Mac and say it may not have been done, under the
  page or where opening it is said (#198). A page left open while the connection
  is away says it asks nothing then, and is asked for again by itself when
  the connection comes back, the line under it gone once the Mac answers
  (#209); on the Mac, another Mac's page shown again with the connection
  is asked for again too.

### Usage

Under an agent's terminal, on the Mac and on the iPhone, a band shows the
few figures worth a glance: the model, how full the context is, and what the
account's main limits have left, each in a cell of its own with a small bar
(and, on the Mac, when it starts over). As many cells are shown as fit.
Clicking the band opens everything the agent's own usage screen shows.

The model's name is followed by how hard it thinks, in the agent's own word,
when the agent records it (#130): "Opus 5.5 · xhigh", "gpt-6-astra ·
medium". It follows a change made in the agent (`/effort`, its model menu).
Nothing is shown of a level that is not known. Claude Code says it to its
status line, Codex and Copilot CLI in their session files, Antigravity only
as the end of its model's id.

| Agent | What is shown, as `/usage` or `/status` shows it |
|---|---|
| Claude Code | Current session, current week (all models), current week per model, each as "% used" with its reset time. The plan, extra usage, and banked limit resets where Anthropic reports them (it does not to Claude Code's own sign-in on every account). Context with its share of the window |
| Codex | 5h limit and weekly limit, each as "% left" with its reset time. The plan, banked limit resets and when the first expires, credits. Context with its share of the window |
| Antigravity | Each group of models (Gemini, Claude and GPT, and any separate quota such as Gemini 4 Argon) with its weekly and five-hour limit, as "% left" with reset times. The plan. Context tokens |
| Copilot CLI | Premium requests left of the month's allowance, with the reset date. The plan. Context with its share of the window |

Every agent's band has the same cells in the same order: the model, the
context, then the limits, the short one before the week. A figure that is
not known yet shows as a dash. Before a session's first reply the model is
the one the agent's settings name (Codex, Antigravity) or the one it
reports (Claude Code); Copilot CLI names its model only after its first
reply.

A limit turns amber at 70% used and red at 90%. The session's figures update
every few seconds, the account's every five minutes while the agent has a
session or a schedule for when its limit starts over, and on request.

Where the figures come from:

- **The account's limits** come from the agent's own service: Anthropic,
  ChatGPT, Google, GitHub. The request needs the agent's sign-in, which
  AgentTerm reads where the agent keeps it on this Mac (the login keychain for
  Claude Code and Antigravity, `~/.codex/auth.json` for Codex, `gh` for
  Copilot). It is used for that request, sent only to the service that
  issued it, never renewed, saved, logged or sent to an iPhone. When a
  sign-in has run out, the line says so and the agent renews it itself with
  its next message. `agenttermd --no-account-usage` turns all of this off.
- **The context** comes from what the agent records on this Mac. Claude
  Code also reports it, with its limits, to its status line: once Settings >
  Hooks & MCP added AgentTerm's to its settings, which then runs the status
  line the user had set up, so theirs still shows. For someone without one,
  Claude Code hides some of its keyboard hints once any status line is set,
  which is Claude Code's doing.

These are the services' own endpoints for their own apps, not public APIs,
and may change without notice. A figure that cannot be read is left out
rather than guessed.

### The Mac at a glance

In a line under the Mac's launch buttons while Sessions is shown, and above the sessions on the
iPhone, six figures say how the Mac itself is doing, the ones a system monitor shows:
processor in use across all cores, memory in use (as a share, and as
gigabytes of what is installed), network speed down and up, temperature,
battery, and how long the Mac has been up. On the iPhone they are the
figures of the Mac it is connected to, not the phone's own. They update
every three seconds. On the Mac the line is there from the start, each
figure shown as not known ("—") until the host's first come, so that
nothing under it moves when they do (#206).

The temperature is shown in Celsius or Fahrenheit, chosen in Settings >
General on the Mac or in the iPhone's Settings tab. Like the other choices
of how things are shown, it is the host's, so both apps show the same. It is the hottest processor sensor where the Mac reports one
(Apple silicon); otherwise it is what macOS says about the Mac's heat:
Normal, Warm, Hot, Very hot. A Mac without a battery shows "Plugged in".
Memory turns amber at 75% and red at 90%, as the processor does; a battery
under 20% that is not charging turns amber.

### Terminal size

- The terminal resizes to fit the device being used. Opening a session on the
  iPhone, coming back to it there after the phone was away, or typing in it
  there, gives the PTY the iPhone's size and the program redraws for it,
  without a button.
- A device that was using a session and goes (the phone put away, out of
  reach) leaves it at its size: the session is not handed back to the Mac
  until someone uses it there.
- A device that only shows a session never changes its size. The Mac app
  lists and shows every session, including the ones a phone is typing in; it
  takes a session's size only when the user types or clicks in it on the Mac
  or presses "Use This Window's Size".
- While another device is using a session, the Mac shows that device's
  terminal centered in a frame, like a preview of its screen, with a line
  above saying so. This is the same for shells and for agents.
- The other way round, while the Mac is using a session that is open on the
  iPhone, the iPhone shows the Mac's whole terminal scaled down to fit, with a
  line saying so and a "Fit This Screen" button that takes the session back.
- That line names who uses the session, in the same words on both apps
  (#120): "In use on MacBook Pro · 180×48", the Mac by its name, a device by
  the name it gives itself ("In use on Manh's iPad · 90×50"), so that a
  phone watching a session an iPad uses does not say it is used on the Mac.
  Beside it, and on the session's tab and row on the Mac, is that device's
  own icon (#157): an iPhone's, an iPad's, and none for a Mac. Each device
  says what it is when it pairs and when it connects; the paired devices'
  list shows each by its icon the same way, a Mac's and one that has not
  said yet with none.
- Handing a session back and forth redraws the program for the new size each
  time.
- What a terminal sends by itself (answers to the program's questions, focus
  changes, the pointer passing over the window) is not use of the session and
  never changes its size.
- On the iPhone, rotating the device, changing the font size and showing or
  hiding the keyboard all resize the terminal.

### Quick launch

- Buttons start Claude Code (`claude`), Codex (`codex`), Antigravity (`agy`),
  Copilot CLI (`copilot`) or a plain shell in the selected folder.
- AgentTerm detects which CLIs are installed. Detection uses the user's login
  shell so it matches what a terminal would find, and can be re-run without
  restarting. In the Mac's header, an agent that is not installed is there
  all the same, dimmed, by its symbol and a mark (#50): pressed, it says how
  to install it, with its maker's command for macOS, another way where its
  maker gives one, what it needs, and its maker's page. The command can be
  copied, or typed into a new shell on the Mac by **Install in a New Shell**,
  not run: the user reads it there and presses Return. AgentTerm runs no
  installer by itself. **Look Again** has the agents looked for again; once
  it is found, the sheet says so and starts it. Everywhere else, the menus,
  the empty folder's buttons and the iPhone, list the agents that are
  installed only.
- An **SSH** menu lists the hosts of the Mac's `~/.ssh/config`, the files it
  includes too, and opens `ssh <host>` as a session with one click. Entries
  that are patterns (`*`, `?`, `!`) are not hosts and are left out. The menu
  is not shown when the configuration names no host. From the iPhone the
  session still runs on the Mac, which makes the Mac the way to that host.
  The configuration is only read: creating keys or editing it is not part of
  this, and only the names ever leave the Mac.

### Handoff

Handing off passes the work of one agent's conversation on to another agent.
The typical case: an agent runs out of quota in the middle of a task and
another one should finish it.

- Any conversation can be handed off: a session that is running, or a past one
  in the History tab. The agent that had the conversation does not need to be
  able to answer any more.
- A sheet asks which installed agent should continue; the agent picked last
  time is preselected. It shows the prompt the agent will start with, which
  can be edited and reset, and offers a field for the user's own
  instructions: what to focus on, what to leave alone, anything that is not
  in the conversation. The instructions are optional and are added after the
  prompt.
- AgentTerm writes a handoff file into the project with the conversation so far
  (what the user and the agent said, without tool output) and the state of the
  working tree, then starts the receiving agent in a new session with a prompt
  to read that file and continue.
- Handoff files live in `.agentterm/handoffs/` and are kept out of git through
  the repository's local exclude file. The project's `.gitignore` is not
  changed.
- The original session and conversation are left as they are.

A handoff can also move the work to another folder: the sheet's **Continue
in** lists the folders of the Mac's list, the conversation's own first. The
handoff file is then written in the folder chosen, the receiving agent
starts there, and the file says which folder the conversation happened in.
In another folder the same agent can be picked too, which carries a
conversation over to a neighbouring project.

### macOS window

Like a code editor: a bar of places at the left edge, then three panes. The
bar has the window's places, as the iPhone has its tabs: **Sessions**,
**Inbox** (with how many items it holds), **History** and **Schedules** at
its top, **Settings** (⌘,) at its foot. The
place shown is marked; pressing it again hides its list, and pressing it
once more shows it. The toolbar follows the panes: the launch buttons for
the agents are in the middle, followed by the pairing button, which is filled so it
stands out, and in the far right corner is the button that hides the side
panel.

- **Left: the place's list.** In Sessions, the folders. In the Inbox, what
  needs the user, the item picked shown in the middle (see When an agent
  is done or needs you). In History, the
  conversations (below). In Schedules, the runs and the schedules (see
  Schedules). In Settings, its panes, General, Git, Permissions and
  Privacy; the pane picked takes the middle of the window, over the
  terminals, which keep running and come back as they were when another
  place is picked. Settings opens on General each time. Settings is not a
  window of its own.
- **The folders.** Project folders the user added, each with what its
  strip holds underneath (#127): each running agent, with the pages and
  shells it has right under it, set in; then the user's Shells, Browser,
  Diffs and Files, each a row that says how many it holds, with them set
  in under it. A session shows its agent's icon and a name. The list belongs to the host, so the iPhone shows the
  same folders. Sessions started elsewhere are listed under "Other".
  A folder is dragged onto another to go before it, or moved up and down
  from its menu; a folder dragged in from the Finder is added. A folder's
  agents are in the order of their tabs and can be dragged the same way.
- **Middle: terminal.** What the tab in front shows, under two rows
  (#127). With nothing open, a launch screen for the selected folder. The
  strip holds a tab for each running agent of the project on show, and
  one for each kind of thing the user opened there: **Shells**, **Browser**,
  **Diffs** (a diff picked in the Git tab, one more each time) and
  **Files**, each saying how many it holds. The row under the strip holds
  what the tab in front holds: an agent first, then the pages and the
  shells it has; or the user's shells, pages, diffs or files. It is where
  they are picked, opened and closed. One of the user's tabs shows one of
  its items, the whole pane for it: the one picked in the row, which the
  tab shows again when it is picked again. An agent's tab shows the agent
  with its page and its shell beside it (Panes, below): its row picks
  which page and which shell, and at its end has a button each that hides
  and shows the page and the shell beside the agent. An agent's row has
  + Page and + Shell, which open one more for that agent: a page it lists
  and drives (the user's until it is given back), and a shell in its
  folder, which it lists and uses as one it opened itself. The Shells and
  Browser rows have a + for one more of the user's. A Shells tab splits as
  an agent's area does (the owner's request, 2026-11-21): the two buttons
  at the end of its row show a shell on the right and one below, the first
  not on show, or a new one when none is left; the shell picked stays on
  the left. A part waiting for its new shell takes that one only, once it
  is in the row: not a shell the tab already had, nor one started
  elsewhere meanwhile (File > New Shell, the iPhone); the right and below
  can both wait, each for its own (#189). A launch the host refuses ends
  that part's wait alone, and the refusal is said. The parts are parted and framed as an
  agent's area's, and dragged the same; a click in a part, or its shell
  picked in the row, puts the keyboard there, and a shell picked that is
  not on show is shown in the part the keyboard is in. A shell's menu in
  the row shows it on the left, on the right or below, and a shell
  dragged from the row and dropped on a part is shown there; either turns
  that part on, and one already shown in another part changes places with
  it. A shell is never shown in two parts (#188): the left's shell moved
  to a part that was off leaves the left the first shell not on show,
  and with none the move is refused, the app saying why at once ("The
  left always shows a shell, and this tab has none free to take this
  one's place. Open another shell first."); a shell moved from the right
  or below to a part that was off leaves the part it was in turned off;
  the left's shell ended with every other one on show, the right's (else
  the one below's) moves to the left. Turned off, a part's shell keeps
  running and stays in the row. The Browser tab is not split; the split is not
  kept when the app quits. A tab is started from the header
  (the agents, Shell, Browser) or the File and Browser menus. Command and
  a number (⌘1 to ⌘9) shows the tab in that place of the strip, ⌘⇧] and
  ⌘⇧[ the next and previous tab, and in one of the user's tabs ⌥⌘→ and
  ⌥⌘← (View > Next and Previous Item in Group) the next and previous
  item it holds, with the keyboard in it; in an agent's tab the same keys
  move about its area (Panes). ⌥⌘ and a number (⌥⌘1 to ⌥⌘9, View > Item
  1 in Group and on) picks that item of the row of the tab in front, left
  to right, an agent's row being the agent, its pages, its shells, with the
  keyboard in it (#171); each of the first nine items shows the keys
  that pick it (⌥⌘1 and on) at its end, always, as each tab of the strip
  shows its ⌘1 to ⌘9, its × taking their place under the pointer, and
  its tooltip says them too (the owner's decision, 2026-11-21). ⌘W closes what is shown, a session is ended.
  An item's × closes it. **A tab's × closes all it holds** (#145): the
  Shells tab ends its shells ("End 2 shells?", asked first even for one),
  the Browser, Diffs and Files tabs close their pages, diffs and files
  (asked first when there are several), and an agent's tab ends the
  agent with the shells and pages it opened ("Its 2 shells and 1 page are
  closed with it."), always asked. The tab's menu does the same (End
  Shells, Close Browser, Close Diffs, Close Files, End Session); one item
  alone is closed by its own ×. An agent that ends by itself leaves its
  shells and pages to the user. A tab's menu (right click) also closes
  the other tabs of its pane, every file of its pane (terminals stay), or
  every tab of its pane. The Tab
  menu's do the same for the pane the keyboard is in. Whatever would end
  a session asks first. Files with unsaved changes are never closed
  without asking.
- **Panes** (#69). The user does not split the middle: it has one strip
  of tabs and shows the tab in front. What is shown side by side is an
  agent's own page and shell, beside it (below); a layout split by an
  earlier build is put back into one. A session is shown in one place
  only: the window is one device to the host, with one size for each
  session.
  **Each project has its own**: the middle shows the
  project on show, with its tabs only. Picking a folder in the list shows
  its tabs as they were left, and the folder's row is the one marked, not
  the item in front (#152); so is a Shells, Browser, Diffs or Files row
  picked, which shows what its tab shows and has a menu that closes them
  all (#145), and a file or a diff has one with Close, Open File (a diff),
  Show in Finder and Copy Path. Picking a session there, or a notice, shows
  that session's project, with the session in front. Sessions started in
  no listed folder have their own too. What is in front is kept by the app
  on the Mac, for each Mac it shows and each project, and comes back when
  the window opens again; a tab that ended meanwhile is simply gone.
  **An agent's own shells and pages are laid out beside it**: those it
  opens (see "Shells an agent opens"), and those the user opens for it
  from its row. Its tab shows its area: the agent on the left, the page
  picked on the right, the shell picked under both, the full width, the
  agent's usage under all of it. They are not tabs of their own, nor in
  the user's Shells and Browser tabs, and are not dragged, pinned or
  moved: they are in the agent's row under the strip (#127), and in the
  list at the left right under their agent, set in. The area belongs to
  the agent's session, so picking another agent shows that one's. A shell
  or page picked in the row, in the list or from a notice is shown in its
  part, with the keyboard in it; the row marks what is on show, and
  which of them has the keyboard. The parts are parted by a gutter
  lighter than them, with a grip in its middle, which is dragged; the
  part the keyboard is in is framed in the accent colour while more than
  one part is shown, and a click in a part, the agent's included, puts
  the keyboard and the frame there (the owner's request, 2026-11-21). The two
  buttons at the end of the agent's row hide the page and the shell
  beside it and show them again: hidden, a shell keeps running and a page
  stays open, both stay in the row and in the list, and picking one there
  shows its part again. An agent opening a shell or a page does not take
  the keyboard from where the user types. The View menu puts the keyboard
  in the agent (⌥⌘←), its page (⌥⌘→) or its shells (⌥⌘↓), and Show This
  Part Alone (⇧⌘Return) has the part the keyboard is in fill the area for
  a while, a bar under it saying so, until it is chosen again or Show All
  is clicked; it is not kept when the app quits. A shell the user opens is
  the user's, in the Shells tab, and so is a page in the Browser tab, and
  an agent's shell or page once its agent's session has ended.
  Tabs are arranged by hand. A tab is dragged onto another to go before it
  (or moved from its menu and the Tab menu). A **pinned** tab stays first
  and is left open by the commands that close many tabs; a tab takes on
  the place it is dropped in, pinned among the pinned. Tab groups, with
  their names and colors, were taken away (#127): the user's shells,
  pages, diffs and files are each held in one tab instead.
- **Right: side panel**, with three tabs, Git, History and Files. The panel can be hidden. It is there in Sessions only, and so is its button: in History, Schedules and Settings what is in the middle is what the window is about.
  - **History** of the panel: the conversations each agent had in the
    selected folder only; conversations that ran in a subfolder belong to
    that subfolder. One picked there is shown in a sheet over Sessions, with
    what History shows of it (below); Sessions stays.
  - **Git.** Uncommitted git changes of the selected folder: the changed files
    with added and removed line counts. Clicking a file shows its diff in the
    middle pane, in one diff tab that follows the file picked. A button in
    the diff's header switches between one panel, removed and added lines
    in turn, and two panels: the file as it was on the left, as it is now
    on the right, with line numbers and changed lines facing each other.
    The panels scroll down together and sideways each on its own. Which of
    the two a diff opens in is set in Settings > Git on the Mac and in the
    iPhone's Settings tab; the button is remembered too. This choice, and
    the list being flat or a tree, are shared: made on one device they
    show on the other. A
    diff that changes while it is being read, as an agent keeps editing,
    stays where it was scrolled to. An
    icon switches the file list between a flat list and a tree grouped by
    folder; folders in the tree can be collapsed and show the totals of what
    is inside. It refreshes on its own while the app is in front.
    The files are in two lists, **Staged** and **Changes**. A button on a
    file moves it to the other list, a button on a list's title moves all of
    them. A file changed again after it was staged is in both, each with its
    own diff. A change that is not staged can be **discarded**, from its
    row or its menu, and all of them from the title of **Changes**: a file
    git tracks goes back to what is staged of it, or to the last commit,
    and a new file is moved to the Trash of the Mac, where it can be put
    back from. It is asked first, saying which of the two will happen and
    that the first cannot be undone, and only what was asked about goes:
    not a change made since, nor a new file past those listed. A worktree
    of the repository inside the folder, as Claude Code keeps in
    `.claude/worktrees`, is not a change and is never thrown away. What is
    staged is never discarded: it
    is unstaged first. Above the lists is the commit message and the **Commit**
    button, which commits what is staged, with the identity and the hooks
    the repository is set up with. What git says when it refuses is shown.
    Next to it, **Write** asks an agent for the message of what is staged
    and puts the answer in the field, to be read and changed; it never
    commits, and the same button stops it. Which agent, which model and the
    prompt (style, language) are set in Settings > Git on the Mac and under
    Commit Messages in the iPhone's Settings tab; the default is the first agent
    installed, on a cheap model where AgentTerm knows one (Claude Code:
    Haiku).
    The name of the branch that is checked out, at the top, opens the
    **branches**: the repository's own, the checked out one first and the
    rest by their last commit, then its remotes', each with how far it is
    from the branch it follows and when it was last committed to; a field
    narrows them down. A branch is switched to by choosing it; a remote's
    is checked out as a branch of the repository's own that follows it,
    made the first time. Switching is refused, in words, when changes that
    are not committed would be lost, and nothing is changed then; a branch
    that another worktree has checked out cannot be switched to, and says
    where it is. **New Branch…** makes one from any branch, the checked
    out one unless another is picked, and switches to it or not. A branch
    of the repository's own is renamed and deleted from its menu: deleting
    is asked first, once when everything on the branch is on the checked
    out branch too, and twice, the second time saying its commits would be
    lost, when it has commits of its own. The checked out branch is not
    deleted, and a remote's branches are not changed from here.
    Above the changes, **Fetch**, **Pull** and **Push** act on the branch
    that is checked out, Pull and Push each with the number of commits
    waiting ("Push 1 commit"), next to the name of the branch it follows.
    A number in the panel says what it counts beside it (#50): the lines
    put in and taken out of what is not committed ("+5 −0 lines"), the
    files of each list ("Changes 3 files"), and on a worktree's chip its
    files changed and commits ahead ("3 changed · 2 ahead"); a file's own
    "+1 −0" is its lines, as git writes it. Fetch asks the
    remotes for what is new and changes neither the branch nor the files.
    It is also done by itself every five minutes while the folder's changes
    are shown and the app is in front, so that the numbers stay true; when
    that fails, a warning beside the buttons says so and why, and no alert
    interrupts. No button waits on it either: Pull, Push and the rest can
    be asked for while it is under way, and are done when it is over.
    **Fetch automatically**, in Settings > Git and shared with
    the iPhone, turns it off. The menu beside the buttons pulls **by merge**
    or **by rebase**, whatever the repository is set up to, and offers
    **Force Push…**: the remote is asked first, and the question names the
    commits on it that the branch does not have and that would be gone
    from it; confirmed, the push is forced only as long as the remote is
    still where it was just seen (`--force-with-lease`). A push the remote
    refuses because it has commits the branch has not says so, and that
    pulling or forcing is what there is to do. A branch that follows none yet shows
    **Publish Branch**, which says where the branch would go and, once
    confirmed, pushes it there and follows it from then on. git never waits
    for a password or a passphrase here: a remote that would ask fails with
    git's message. A pull that stops on a conflict is left to be resolved, and says so.
    The count of commits to pull is as of the last time the remote was
    asked; pulling asks.
    **Commits**, beside **Changes** under the buttons, lists the history of
    the branch that is checked out, or of another branch picked above the
    list: newest first, each with its author and how long ago, the branches
    and tags that point at it, and a graph at the left with a line for
    every line of history, so that where branches part and meet shows.
    Older commits are read a page at a time as the list is scrolled. A
    commit that is pressed opens out to its hash, with a button that copies
    it, the rest of its message, and the files it changed; a file shows
    what the commit did to it in the middle pane, in the same views as a
    change, under the commit's hash and with nothing to stage. A merge
    shows what it brought in. From a commit's menu it is **reverted**, by
    a new commit that takes its change back, or **cherry-picked** onto the
    checked out branch; each is asked first, and one that runs into
    conflicts is left to be resolved, and says so. A merge commit is not reverted or
    picked here: git has to be told which side to keep.
    **Stashes**, the third list, is the repository's stash. **Stash
    Changes…** puts what is staged and what is not aside, under a name
    when one is given, with the files git does not track yet unless that
    is turned off, and leaves the folder as it was committed. The stashes
    are listed newest first, each with the branch it was made on and how
    long ago; one that is pressed opens out to its files, which show their
    diffs in the middle pane under **STASH**. **Apply** brings it back and
    keeps it, **Pop** brings it back and takes it out of the stash, and
    **Drop…** throws it away, asked first, since nothing else holds what
    is in it. One that conflicts with what is in the folder says so: the
    files that conflict are marked there, and the stash is kept.
    The last commit can be **amended** and **undone**, from the menu
    beside Commit and from the newest commit in Commits. Amending puts the
    commit's message in the commit box, which says so above it and offers
    Cancel; the button then replaces the commit by one with the message as
    it is now and with whatever is staged added to it, the message alone
    when nothing is. Undoing, asked first, puts the branch back at the
    commit before and leaves what the commit changed staged, so nothing is
    lost. A commit that a remote has already is asked about once more,
    for undoing and before amending: changed here, the next push has to be
    forced, and whoever pulled it keeps it.
    A change can be taken apart. **Stage Parts…** in the diff of a change
    that is not staged, **Unstage Parts…** in that of a staged one, lists
    the hunks of the diff, each with its lines. A hunk is staged or
    unstaged whole, or only the lines of it that are ticked; one that is
    not staged can also be discarded, whole or by its ticked lines, asked
    first. What was taken is gone from the list at once, which is read from
    the file again. A part that no longer fits the file, because the file
    changed since, is refused in words. The hunk a long diff was cut off
    in is shown and not taken apart, which it says: what is left of it may
    end in the middle of a line. It is the same in both layouts of
    the diff, and on the Mac only: the iPhone stages and discards whole
    files.
    When a merge, a rebase, a cherry-pick or a revert **stops on
    conflicts**, whether a pull, a pick from Commits or something done in a
    terminal began it, it is left as it is and the top of Changes says so:
    what is going on, how many files conflict, and which side "ours" and
    "theirs" are, which is not the same in a rebase as in a merge. The
    files that conflict are a list of their own, each saying how it
    conflicts (both sides changed it, one deleted it). A file is resolved
    by **Take Ours**, **Take Theirs**, taking a side that deleted it
    deletes it, or by **Edit**, which opens it in the editor with its
    markers, and then **Mark Resolved**, refused while a marker is still in
    it. Pressed, it shows the file as it is against both sides. **Continue**
    finishes what was stopped once nothing conflicts, and says so when a
    rebase stops again at its next commit; **Abort…**, asked first, puts
    the folder and the branch back as they were. Stage all is refused while
    a file conflicts: it would take those files as they are.
    **Submodules** (#44): a submodule with changes inside it is a list of
    its own under the folder's, headed by its path and the branch checked
    out in it, or "detached HEAD". Its files are listed as the folder's
    are, staged and not, each with its diff, and are staged, unstaged and
    discarded in the submodule. Under them is a commit box of its own, as
    the folder's (#151): its message, **Commit**, which commits what is
    staged there, and **Write**, which asks the agent of Settings > Git for
    the message of what is staged there; the box says so when no branch is
    checked out in it. Amending and undoing are the folder's only. They are not
    changes of the folder. A submodule whose commit is another than the
    folder records is: a row of the folder's own that says from which
    commit to which, staged and committed in the folder as a file is.
    Discarding it, asked first, checks out the recorded commit again. A
    submodule inside a submodule is listed the same way under it. A new
    worktree has its submodules checked out, theirs too, before its
    session starts; when one cannot be fetched the worktree is made all the
    same, and the banner says so.
    Not part of it:
    choosing a remote, and adding, removing or updating submodules from
    their remotes.
- **History**, the place in the bar at the left: every conversation the
    agents had on the Mac, one section per agent, newest first, each with a
    title, its folder and how long ago it was. A conversation can be
    resumed, which opens it in its agent in a new session, or handed off to
    another agent. Picked, it is shown in the middle of the window, over the
    terminals, as the iPhone shows one: its agent, title and folder, Resume,
    Copy Resume Command, and under them two tabs: **Transcript**, which
    shows first, and **Hand Off**, with the handoff's folder, agent, prompt
    and instructions. Resuming or handing off goes to Sessions, on the new
    session. With none picked, the middle says to choose one.
    What History does with the conversations (#46), in the place and in
    the side panel's tab alike:
    - **Search**: a field above the list finds the conversations whose
      title or what was said in them holds the words, whatever their case,
      each with a piece of the text around them and in how many places
      they are. What a tool printed is not searched. The host searches
      every conversation, not only those listed. **Titles Only** beside
      the field (on the iPhone, in the menu beside it) searches the
      titles alone, which is faster on a long history; what was said is
      searched too by default, and the choice is kept on each device
      (#50).
    - **Group and filter**, from the menu beside the field: grouped by
      agent or by day (Today, Yesterday, then the date); only one agent's,
      only one folder's (a worktree AgentTerm made for it included), only
      today's, this week's or one day's. The list says when it is
      filtered, and Clear Filters shows all again.
    - **Transcript**: a conversation read before it is resumed. What its
      agent's file tells: how long it ran, its model, the tokens read and
      written, the branch and the worktree it ran in, how many tools it
      ran and the files they wrote; then what was asked and answered, and
      each tool with what it was run on. What an agent does not record is
      said to be not recorded: Codex and Antigravity run commands, which
      do not tell which files they wrote; Copilot tells once its session
      has ended, and its cost is in a unit of its own and is not shown. A
      long conversation is shown by its last 600 entries, and says so.
      **Copy Transcript** copies it as Markdown; **Open as a File** writes
      it out on the Mac and opens it as any file. **Preview Markdown**
      shows what was said with its Markdown rendered, headings, lists,
      tables and code as a file's preview shows them, and **Show as Text**
      as it was written; the choice is kept for the next transcript, on
      each device (#50). Each thing asked and answered has its own
      **Copy**, which copies it as it was written (#50).
    - **Pin** keeps a conversation in a group of its own at the top;
      **Hide** takes it out of the list, until Show Hidden is chosen.
      Both are kept by the Mac and are the same on every device.
    - **Delete…** deletes the agent's own record of the conversation,
      after two questions: its file is moved to the Trash of the Mac. A
      conversation a session is having is not deleted; Antigravity's
      cannot be, and it says why.
    - **Select**, above the list, picks conversations to delete together
      (#50): a click ticks one instead of opening it, and **Delete N…**
      deletes those picked after two questions. In History, not in a
      folder's list, **Delete All…** deletes every conversation on the Mac,
      after two questions too. Either way pinned ones stay, as does one a
      session is having, and Antigravity's; how many were kept is said,
      and nothing more when none was. **Done** ends the picking.
    - **Show Older Conversations**, at the end of a full list, brings the
      next 200.

    History's list is wider than the other places' lists, for the titles
    and what a search found in them (#50); it can be made wider still.

### What the app reports

A released build of either app can send two things to its developer
through Google's Firebase: crash reports, and usage statistics, counts of
which features are used. Never what a terminal shows, prompts, file names
or folders. At its first launch such a build asks it (#48), never in an
alert that could be taken for one of the system's, and never as a second
sheet over another (the owner's decision, 2026-11-21): on the Mac it is
the Reports step of the onboarding, which shows at once while it is not
answered, whatever else; on the iPhone it is the first part of the one
first screen, before whether the app may notify. It says what each kind
is, with a switch for each, both on; the step's Next (the Mac) or
Continue (the iPhone) answers it. Until it is answered nothing is sent, of
either kind, and an onboarding closed before it is asked again at the
next launch. Afterwards both switches are in Settings > Privacy on the
Mac and under Privacy in the iPhone's Settings tab, in the same words. A
build from source and AgentTerm Dev have no service to send to: they show
no screen and send nothing, and on both apps the two switches show off
and dimmed, whatever they were set to, with a line that says why (#212);
what they were set to is kept. `PRIVACY.md` says
all of what is sent.

### Keeping the Mac awake

A switch in the Mac's Settings, in its menu bar menu, and in the iPhone
app's Settings tab, keeps the Mac from going to sleep by itself while a session is
open, so agents keep working and the phone can still reach them. The host
holds the hold on sleep, so it works with the window closed, and lets go
when the last session ends. Closing the lid still puts the Mac to sleep.
Off by default.

Four options go with it, in the same places, and like the switch they are
the host's, so both apps show the same:

- **Turn off by itself** after 1, 2, 4 or 8 hours, counted from when it is
  switched on. When the time is up the switch goes off, and both apps show
  when that will be.
- **Keep the display on too.** Without it the display may turn off.
- **Only while the Mac is plugged in.** On battery the Mac sleeps as usual,
  and is kept awake again once power is back.
- **Only while an agent is working.** The Mac is kept awake while at least
  one agent is working (see "What the agent is doing"), and let go when
  none is: an agent that waits for the user, or is done, and a shell, hold
  nothing. Off by default; off, any open session keeps the Mac awake.

### Menu bar (Mac)

AgentTerm keeps an icon in the menu bar, and closing its window does not quit
it: the window and the Dock icon go, the menu bar icon stays. Its menu opens
the window again, lists the running sessions (picking one opens it), starts
an agent, a shell or an SSH session, switches Keep Mac Awake, opens pairing
and Settings, and quits. Quit is there and ⌘Q.

Settings > General also links to the project's page on manhdev.click and to
the source on GitHub; the iPhone has the same two links in its Settings tab.

The iPhone's Settings tab has, for the Mac it shows (#155), what the Mac's
Settings has of the Mac's own: **Hooks & MCP** (each agent's parts, Install,
Remove and Install for All at the top, run by the host there), **Shell**
(the program of new shells, what is run first in the user's and in the
agents'; the terminal's looks are each device's), **Browser** (the
profiles: the default one, a new one, Clear Data and Delete, both asked
first in the Mac's words) and **Agents** (the words each agent is told,
saved, or back to AgentTerm's). A Mac showing another Mac sets its agents
up the same way. Permissions stay on the Mac itself.

The setting "Keep AgentTerm in the menu bar when its window is closed", in
Settings (⌘,), is on by default. With it off there is no icon, and closing
the window quits the app. Sessions keep running either way, since the host
that holds them is a separate program.

### What agents may ask macOS for

macOS holds a terminal responsible for everything run inside it. An agent
that drives another app, takes a screenshot or reads a protected folder is
asking as AgentTerm, so AgentTerm has to be able to ask.

- **Asked by macOS when first used.** The app declares, with a sentence
  macOS shows the user, everything a program in a session may ask for:
  controlling other apps, camera, microphone, speech recognition, the Mac's
  audio, keyboard monitoring, Bluetooth, the local network, contacts,
  calendars, reminders, photos, the media library, location, and the Desktop,
  Documents, Downloads, removable, network and cloud storage folders. Without
  the declaration macOS refuses without asking. The released app carries the
  matching hardened runtime entitlements.
- **Never asked.** Settings (⌘,) > **Permissions** lists the ones agents
  rely on, says what each is for and whether it is allowed, and has a button
  that asks macOS for it or opens the right pane of System Settings:

| Permission | Used for |
|---|---|
| Accessibility | Clicking, typing and reading the screen in other apps: computer use in Claude Code and Codex, Antigravity's browser agent |
| Screen & System Audio Recording | Screenshots, which is how an agent sees an app or a page |
| Automation | Scripting another app, Chrome for one. Asked once per app |
| Full Disk Access | Folders macOS protects, such as Mail or other apps' data. Rarely needed |
| Microphone | Voice dictation in Claude Code and Antigravity |
| Camera | Only for a program that uses it |

Changes to Accessibility and Screen Recording apply to sessions started
after the app is reopened. A development build is a different app to macOS
and is asked separately.

### A host from another copy of the app

The host outlives the app, so a newly installed version can find the host of
an older one still running on its port, and would use it without a word. The
Mac app checks which program is the host. When it is not the one the app
ships with, a banner says so, with the other host's path, and offers **Use
This App's Host…**: the other host is stopped, after asking since its
sessions end with it, and the app's own is started.

Another copy's host is a program named `agenttermd`. When what listens on
the port is any other program (a proxy in front of the host, say), the
banner says instead that the port is in use by that program, by its name,
and that it is not an AgentTerm host (#204). Nothing offers to stop it: the
app never stops a program that is not an AgentTerm host, not even through
Restart Host.

### A host that stopped

A host that stops without being asked to (killed, by macOS or by another
program, or crashed) takes its sessions with it. When the next host
starts, every app is told so, also one that connects later, until the user
has dismissed it on one device:

- The Mac app starts its host again by itself, and a banner says that the
  host stopped unexpectedly, when, which sessions ended with it, and that
  it was started again.
- On the iPhone, and on a Mac showing another Mac, the same in words: "The
  host on <Mac> stopped unexpectedly … and was started again", with the
  sessions that ended, rather than a list that emptied.
- With the app closed, the host started at login (Start at Login on) is
  started again by macOS (launchd) when it is killed or crashes, so the
  iPhone still reaches the Mac; the next app to connect is told what
  ended. With Start at Login off and the app closed, nothing starts it
  again.
- A host that dies three times within sixty seconds is not started again
  by itself, by the app or by launchd: the Mac app says that it keeps
  stopping, how the last one ended when it knows, and offers Try Again.
- A host the app starts that cannot start (its port is taken, for one)
  is said so at once, with the host's own words why, and Try Again.
- While the Mac app is not connected to its host, or to the other Mac's,
  a session asked for (File > New Shell or New <agent>, the menu bar's, a
  worktree, an SSH host, resuming, a handoff) is not started, and the
  window's notice says at once why and what to do
  (`StateWords.notStarted`, #202); nothing waits to start later. A Shells
  tab's part is not on screen then, since the window shows why it is not
  connected in place of the tabs.

A stop that was asked for (Restart Host, replacing another copy's host,
logging out) is not reported.

### What the two apps share

The Mac and the iPhone offer the same things wherever the device allows:
folders (add, remove, reorder), the arrangement of the agents' sessions
(order and pins, kept by the host so both show the same and a change on
one appears on the other), sessions (start, end), the terminal with a text size
setting, the Git view as a list or grouped by folder with commit, push,
pull and a commit message written by an agent, History with both scopes,
resume, copying the resume command, handoff from a past conversation or a
running session with the prompt shown, SSH hosts, how the Mac itself is
doing, and keeping the Mac awake with
its options.

They differ where the device does:

- The Mac refreshes Git and History by itself while it is in front. The
  iPhone loads them when a screen opens and on pull to refresh.
- The iPhone starts an agent in any folder through its folder picker. The Mac
  adds the folder to its list first.
- Pairing is one sided: the Mac shows codes and manages devices, the iPhone
  scans and manages Macs.
- "Show in Finder" is on the Mac only. The key bar and the compose field are
  on the iPhone only.
- On the Mac files and diffs open in the Files and Diffs tabs next to the
  terminals; on the iPhone they open as screens. The Mac's tabs of the
  user's shells, pages, diffs and files are arranged with the agents' tabs
  but belong to its window; the iPhone leaves them alone.

### Files

A basic file manager and editor for the selected folder, enough to look at
and touch up what an agent wrote without leaving the app.

- The **Files** tab of the side panel is a tree of the folder's files and
  folders. Folders open in place. Files with uncommitted changes are marked
  the way the Git tab marks them.
- New file and new folder, in the folder itself or in any folder of the tree.
  Rename. Move to the Trash, after asking, so it can be put back. Show in
  Finder, copy the path. A name that is taken is refused; nothing is
  overwritten.
- Clicking a file opens it in the middle pane, as a tab next to the session
  tabs. Several files can be open. File tabs follow the session tabs, share
  their shortcuts (⌘1 to ⌘9, ⌘⇧], ⌘⇧[) and close with ⌘W. Starting or
  picking a session brings the terminal back to the front.
- Text opens in an editor with syntax coloring for the common languages. It
  saves with ⌘S, and a dot on the tab marks unsaved changes. Closing a tab
  with unsaved changes asks first.
- Markdown opens as a rendered preview, with a switch to the source, laid
  out as GitHub shows it, tables included, on the Mac and the iPhone
  (#126). Code blocks in it are colored, and blocks marked `mermaid` are
  drawn as diagrams. HTML written in the file is not run. A `.mmd` or `.mermaid` file is previewed as a diagram too.
- Images are shown. Files that are not text are not opened. A text file
  larger than 2 MB says so and offers **Open Anyway**, which opens it, up to
  20 MB.
- The tree, and open files without unsaved changes, follow changes made
  elsewhere, by an agent for one, within a few seconds.
- The files that were open come back as tabs the next time the app starts.
- **Search** (#45), from the magnifying glass at the top of the tab or
  from the File menu, shows in place of the tree. **Go to File…** (⌘P)
  finds the folder's files by part of their name as it is typed, the best
  first: a name that holds what was typed before one that holds its
  letters apart, the name before the folders it is in; with a slash, what
  was typed is matched against the path. **Find in Files…** (⌘⇧F) finds a
  word or a phrase as written, not as a pattern, with or without its case
  (**Aa**), and lists the lines that hold it file by file, each with its
  number and the words marked. The arrow keys walk the results and Return
  opens the one they are on; a line opens its file at that line, a
  Markdown file in its source. The folder searched is the one the side
  panel shows, a worktree's too, with its submodules. What git ignores,
  `.git` and AgentTerm's own folder are left out; binary files and files
  larger than the editor opens are not searched. A folder that is no
  repository is walked instead. At most 2,000 lines are given, and it says
  so when there were more; a search that goes on can be stopped, and gives
  what it finds while it goes. Not part of it: patterns, replacing, and
  searching more than one folder at a time.

The iPhone has the same under a folder's **Files** tab, the search too, in
a field above the tree, working on the
Mac's files through the host: the tree, new file and folder, rename, move
to the Mac's Trash and copy path (hold a row), and the same editor with
syntax coloring, Markdown and Mermaid preview and images. A file opens as
a screen; leaving it with unsaved changes asks first. It differs in three
ways: lines wrap, pictures a Markdown document refers to are not shown,
and what an agent changes shows after pulling down to refresh or reopening.

Not part of it: search, and a file changed on disk while it has unsaved
edits here is not merged; saving overwrites it.

### Pairing and remote access

- The Mac shows a QR code containing its Tailscale name, the port and a
  pairing code. The iPhone scans it and is paired. The same information can
  be copied from the Mac as a link and pasted into the iPhone app, or opened
  on the iPhone, for when scanning is not possible.
- A pairing code works once and for five minutes, and stops working when the
  pairing screen closes. The screen counts down, replaces a code that ran
  out, and can make a new one on demand. A code that leaked after it was used
  or after the screen closed is worth nothing.
- Pairing gives the iPhone a token of its own, kept in its Keychain. The Mac
  lists the paired devices, with when each last connected, and can remove
  one. A removed device is disconnected at once and has to pair again.
- All remote traffic between the devices goes through Tailscale, and
  AgentTerm does not open a port on the local network. The one relay is that
  of the iPhone's notifications through Apple, which passes on what it
  cannot read (When an agent is done or needs you).
- The pairing screen checks Tailscale on the Mac first. The code is shown only
  when Tailscale is installed, signed in and connected. Otherwise the screen
  shows what is missing (not installed, not signed in, or not connected) and
  the steps to fix it, with a button to get or open Tailscale, and switches to
  the code by itself once Tailscale is ready.
- Next to the code, the screen says that the iPhone needs Tailscale too, signed
  in to the same account.

### iPhone app

The app opens on **Macs**, the list of the Macs it is paired with, each with
whether it is connected and how many sessions it has. Picking one goes into
that Mac; pairing another adds it to the list, and holding a Mac forgets it.

Inside a Mac there are four tabs, the places of the Mac's bar but the
Inbox: **Sessions** (the Inbox when it holds something, how the Mac is
doing, then the folders and their sessions), **History**
(every conversation on the Mac), **Schedules** (as the Mac's Schedules
shows them, #50) and **Settings**, in the order of the Mac's Settings: General
(keeping the Mac awake with its options, the temperature's unit), Git
(commit messages, diffs), Privacy, then the Mac itself (switching to
another, forgetting this one) and About (the version and the links). The
button at the top right of Sessions goes back to the list of Macs.

- The iPhone can be paired with several Macs. The Macs screen lists them
  and pairs another one. It shows one Mac at a time, the one picked there.
  Forgetting a Mac leaves the others paired.
- List of sessions on the Mac on screen, by the folder each runs in, as
  the Mac lists them (#127): each agent with its own pages and shells set
  in under it, then the user's shells under a Shells heading that says how
  many there are, and the user's pages under a Browser heading. Groups of
  sessions, with their colors, were taken away. An agent's session is
  pinned and moved up or down from its menu, or dragged onto another.
- Full terminal for a session, sized to the screen.
- A key bar above the keyboard for keys a phone keyboard lacks: Esc, Tab,
  Shift+Tab, Ctrl, arrows, and Enter.
- A compose field for writing a prompt with the normal iOS keyboard,
  autocorrect and input methods, sent to the terminal in one go.
- Quick launch for the installed agents, and for the hosts of the Mac's
  SSH configuration, in any folder known to the Mac.
- A folder picker browses the Mac's folders, starting at home, to start an
  agent or a shell in any of them. The folder can be added to the list the
  Mac and the iPhone share.
- Each folder opens what the Mac's side panel shows. **Git**: the changed
  files with added and removed line counts, and the diff of a file, which
  scrolls sideways and can be shown as two panels as on the Mac; files can
  be staged, unstaged, discarded (from a file's menu, or all of them, asked
  first as on the Mac) and committed as on the
  Mac; the branch's name lists the branches, to switch to one or make one,
  and one of the repository's own is renamed or deleted from its menu,
  asked as on the Mac; Fetch, pulling by merge
  or by rebase and Force Push… are there as on the Mac, and the remotes
  are asked by themselves while the folder's changes are on screen;
  **Commits** opens the history of the checked out branch, or of another
  picked above it, with the graph, and a commit shows its message, its hash
  to copy, and its files with their diffs, and is reverted or picked onto
  the checked out branch, asked as on the Mac; **Stashes**
  stashes the changes, lists the stashes with their files and diffs, and
  applies, pops and drops one, as on the Mac; the last commit is amended
  and undone from the menu beside the branch; what git is stopped in is
  said at the top with the files that conflict, which show as they are,
  and can be aborted, or continued once they were resolved on the Mac
  (resolving a conflict is on the Mac); a submodule's changes are listed
  under it with a commit box of its own, the branch pushed and pulled, and the commit message written by an
  agent. **History**: the conversations each agent had in the
  folder only, as on the Mac; every conversation is in the History tab; both
  searched, grouped and filtered, a conversation read as a transcript
  ("Read the Transcript"), pinned, hidden and deleted as on the Mac (#46). **Files**: see
  Files above.
- A conversation can be resumed in its agent, or handed off to another
  installed agent. The handoff sheet shows the prompt the agent will start
  with, which can be edited and reset, and takes optional instructions. Both
  open the new session's terminal on the iPhone.
- A running session can be handed off too, from its terminal's menu.
- A folder can be taken off the shared list.
- Text size can be changed, which changes how many columns fit.
- When the connection drops, the app reconnects on its own and returns to the
  session that was open.


## Vietnamese input requirements

- The host forces a UTF-8 locale for every session.
- Input bytes travel unchanged from the client to the PTY.
- macOS: composition with the built-in Telex and VNI input methods shows the
  text being composed at the cursor and commits the final text only.
  Third-party tools that retype text with backspaces (EVKey, OpenKey,
  GoTiengViet) must also give the right result.
- iPhone: the compose field is the default way to type prose, so composition
  never happens inside the terminal emulator.
- Each release is checked against a matrix: {built-in Telex, built-in VNI,
  EVKey or OpenKey} × {zsh, Claude Code, Codex, Antigravity, Copilot CLI}.

## Out of scope

- Running agents on the iPhone or on a server AgentTerm hosts.
- Remote access without Tailscale.
- A code editor. The changes pane is read-only.
- Windows and Linux hosts.

## Planned work

What is planned is kept in the
[issues](https://github.com/manhpham90vn/AgentTerm/issues), not in this file.
