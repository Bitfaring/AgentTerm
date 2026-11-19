# CLAUDE.md

Guidance for Claude Code, and any other coding agent, working in this repository.

Read first: `README.md`, `docs/SPEC.md` (what the app does), `docs/DESIGN.md` (how it is built), `docs/TESTING.md` (how it is tested). What is planned is in the GitHub issues and milestones, and what was decided is written in the issue it was decided for.

## Design principles

How the owner decides. When one of these answers a question, decide by it and go on; the report then says what was decided and by which principle, so it can be undone. Ask only when none of them answers it, or when rule 1 says the matter is always asked.

1. **The Mac has everything; the iPhone has what is used every day.** What is looked at, started, answered and done in one step is on both. What takes careful editing (picking lines of a diff, resolving a conflict) is on the Mac only, and the iPhone says so rather than offer half of it.
2. **Clear and safe before convenient.** When a behaviour could be made handier at the price of someone not knowing what happens to their sessions, files or shells, the plain one is taken: a shell is typed into only by the agent that opened it, and nothing takes it over. More shells, more clicks or one more confirmation are an accepted price.
3. **What fails is said at once, with its reason and what to do.** An agent is answered immediately, never left to wait for a timeout that explains nothing. The user is told in the top banner of both apps, which stays until the fault is over and can be closed. Nothing fails silently, and a switch never says on while the thing it stands for does not work.
4. **What the app does by itself is on by default, has a switch, and is written down.** Anything done without the user asking (fetching, installing a server in an agent, asking a service) can be turned off in Settings, and `PRIVACY.md` says so when it reaches the network or reads data.
5. **Nothing is guessed that can be tried.** How an agent or a tool behaves is found out by running the real one, at the version in use, before anything is designed around it; what was found, and with which version, is written into the issue. A state that is shown is true, and what is not known is shown as not known.
6. **Until the official release, anything may change.** The protocol, the formats, what is stored and what is written into the agents' configuration change freely from one build to the next: no migration and no compatibility with an earlier 0.x build are owed. Both apps and the host are of one release, and the protocol's number goes up whenever a message changes. The official release is the one that takes the app out of beta.
7. **The released build and a development build never share anything.** A name, a port, a folder, a token, an entry in another program's configuration: each build has its own, and neither touches the other's.
8. **An issue is kept only while it can be acted on.** What cannot be reproduced is closed, to be opened again when it shows: a bug is tried 5 times, in the conditions it was seen in, and when it does not show in any of them, it is closed with a comment that says plainly it could not be reproduced, how it was tried and how many times. What waits on someone outside (a permission, a review) is closed or put in the backlog, not left open in a release.
9. **Both apps say the same thing in the same words.** A sentence the user reads (a banner, a refusal, a row's label) is written once, in `AgentTermProtocol`, and shown by both.

## Rules

### 1. Important decisions are asked, unless a principle answers them

When the work reaches a decision that matters, first look at the design principles above. If one of them answers it, decide by it, go on, and say in the report what was decided and by which principle. If none does, stop and ask the owner: say what the choices are, what each costs, and which one you would take, then wait for the answer. Do not pick one and report it afterwards.

A decision matters when it is any of these:

- **What the app does.** Adding, removing or changing a behaviour the user can see, or trading one behaviour for another: a fix that makes one case work by giving up another is a decision, not a fix.
- **Design.** A new protocol message or a change to one, a new dependency, a new component, where data is kept, anything `docs/DESIGN.md` would have to describe differently.

These are always asked, whatever a principle says:

- **Anything outward or hard to undo.** Committing, pushing, opening or merging a pull request, releasing, creating or editing issues and milestones, deploying, deleting. Each is done when asked, and being asked once is not being asked for the next time, except for what rule 4 allows without asking.
- **Anything of the user's own.** Their installed app, its sessions, its preferences, its paired devices, their simulators, their accounts, the tools installed on their Mac. This includes every question a tool asks about itself while it is being tried: an update, a sign-in, whether to trust something. Decline it or stop; do not answer it.
- **Security and privacy.** Dismissing or working around a code scanning alert, widening what a client or a plugin may do, anything that touches tokens, pairing, or what is sent off the machine.
- **Doing less than was asked.** Leaving part of a task undone, or solving it only in part.
- **Planning.** Which release an issue belongs to, what is in or out of a milestone, closing an issue, what is said in release notes.

Not decisions to ask about: how to name a local variable, which of two equal ways to write a loop, the order of tests in a file. When unsure whether a principle covers something, it does not: ask.

If a choice was made without asking, say so plainly in the report, with what was chosen and what the other choices were, so it can be undone.

### 2. Work that is done is tested in full

Nothing is reported as done before it has been tested, and the report says what was run and what came of it.

- **A bug is shown before it is fixed.** Write a test that fails because of the bug, run it and see it fail, fix the bug, run it again and see it pass. The test stays. A bug that cannot be shown by a test is said to be so, with what was done instead.
- **A bug is closed only when it is fixed at its root.** Its cause is found and taken away. What only bears it (a retry, a longer wait, a test that repeats a step until it works) does not close it: the issue stays open, saying what was done meanwhile and what is still not known. The one other way to close a bug is principle 8's: not reproduced in 5 tries.
- **Every layer the change touches is run**, as `docs/TESTING.md` says under "Running them":

  | Changed | Run |
  |---|---|
  | Anything | `swift build` and `swift test` |
  | The Mac app, or anything it uses | `scripts/test-mac.sh` |
  | The iPhone app, or code shared with it (`AgentTermClient`, `AgentTermProtocol`, `AgentTermTerminal`, `AgentTermEditor`) | `scripts/test-ios.sh "iPhone Air"` |
  | What one app shows of what the other did | `scripts/test-both.sh "iPhone Air"` |
  | What a picture shows (toolbar, lists, the terminal) | `scripts/screenshots.sh`, and look at each picture |

  Before a release, all of them.
- **When they are run.** While working, only the tests of what is being changed are run: `swift test --filter <suite or test>`, `scripts/test-mac.sh <test>`, a mode of `scripts/test-ios.sh`. Several fixes or changes are made first, and the layers of the table are run once for all of them, before they are committed, not after each one: the UI layers alone take about a quarter of an hour. A report given before that run says plainly that the full tests have not been run yet, and asks whether to run them.
- **Work goes by groups, as the owner decided (2026-11-19).** The open issues of a milestone are split into groups by what they need: code to change, tries of a bug that comes and goes (principle 8), trials with a real agent, a real iPhone with a TestFlight build. The groups are said before the work starts. All of one group's work is done, with its focused tests, and then the layers are run once for that group; that run counts as one of the tries of the bugs that come and go.
- **A change to what is seen is looked at.** Take a picture of the window (`SHOTS=... ALL_SHOTS=1 scripts/test-mac.sh <test>`) and look at it; a build that compiles has not been seen.
- **A new behaviour gets a case** in `docs/TESTING.md` and a test that names it.
- **The report is true.** Which commands ran, which passed and which failed, with the failing output. What was not run is said, with why: "not tested on the iPhone" is an acceptable sentence, silence about it is not. A check that is skipped ("Executed 0 tests", tests listed as skipped) checked nothing and is not reported as passing.
- **Tests that fail are not made to pass** by weakening them, skipping them or deleting them. If a test is wrong, say why and ask (rule 1).

### 3. Nothing of the user's is touched while testing

- Hosts and apps run for a test use a state folder (`AGENTTERM_STATE_DIR`), a port (`AGENTTERM_PORT`) and a home folder of their own, never `~/Library/Application Support/AgentTerm` or the installed app's port.
- An app's preferences are kept under its bundle identifier, whatever home folder it is given. A copy of the app built for a test gets an identifier of its own (`IDENTIFIER=... scripts/bundle-mac.sh`), and is never built into `dist/`, where a copy may be running.
- What a test throws away goes to a folder of its own (`AGENTTERM_TRASH_DIR`), never into the user's Trash.
- The iPhone tests reset the keychain of the simulator they run in: use "iPhone Air", not a simulator an app is paired in.
- No pairing code, token or other secret is printed.

### 4. Done without asking, as the owner decided (2026-11-15)

- **A bug found during a session** gets an issue at once, labelled `bug`, in the milestone being worked on, saying what was seen, what was tried and what is not known yet, written as rule 5 says.
- **Work that is done and tested** (rule 2) is committed on the milestone's branch and pushed, without asking. Then CI is run on the branch, which it does by itself only for pull requests and `main` (`gh workflow run ci.yml --ref <branch>`, then `gh run watch`), and what fails is fixed, shown and committed the same way, until it is green. A check that cannot be made green without a decision (rule 1) is reported and asked about.
- **A real agent is used when a trial needs one** (principle 5), as the owner decided (2026-11-19): Claude Code, Codex, Antigravity or Copilot CLI is started without asking, with its cheapest model and its lowest level of thinking (for Claude Code, Haiku with thinking off; for the others, their own smallest), and the issue says which agent, version, model and level were used. What rule 1 says of the user's tools still holds: a question the agent asks about itself (an update, a sign-in, whether to trust a folder) is declined or the trial is stopped, and the trial runs in a folder of its own, not in the user's projects.
- What stays asked: opening and merging a pull request, releasing, deploying, deleting, closing an issue that is not a fixed bug, and planning (rule 1).

### 5. How an issue is written, as the owner decided (2026-11-19)

Every issue, a bug or not, has two versions in its body, kept in step:

1. **English first**, as it has always been written: what was seen or is wanted, what was tried, what is not known yet, what was decided. Its boxes (`- [ ]`) are the only ones: a box is ticked in one place.
2. **`## Definition of done`** at the end of the English: a numbered list of what must be true for that issue to be closed, written for it, not copied. It takes from rule 2 and the principles what applies:
   - what has to be decided or found out first, and by whom (the owner's choice, a real agent tried at its version);
   - for a bug, a test that fails because of it and is seen failing, then passes and stays; the root cause found and taken away; or principle 8's way, 5 tries not reproduced and said so;
   - what the change must do and must never do, both apps where principle 1 asks it, the words in `AgentTermProtocol` (principle 9), the protocol's number raised for a changed message (principle 6);
   - which docs say it (`docs/SPEC.md`, `docs/DESIGN.md`, `docs/TESTING.md`, `PRIVACY.md`, `docs/PERFORMANCE.md`), and the case a test names;
   - which layers of rule 2's table are run, and which pictures are looked at;
   - `make format` and `make lint`, committed on the milestone's branch and pushed, CI on the branch green.
3. After a horizontal rule, **`# Tiếng Việt`**: the same content in Vietnamese, opened by a line that says it is the translation of the English above (and, where there are boxes, that they are in the English only); boxes become plain bullets. Code, paths, commands and names stay as they are.
4. **`## Định nghĩa hoàn thành`** at the end of the Vietnamese: the definition of done, translated.

When an issue changes (a decision, a finding, what is done), both versions are changed in the same edit. A comment may be in either language.

## Conventions

- Code, comments, commit messages and everything under `docs/` are in English. Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
- No force push, no rewriting of history, no deleting of branches.
- Work happens on the milestone's branch and reaches `main` through a pull request.
