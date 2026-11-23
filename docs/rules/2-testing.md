# Rule 2. Work that is done is tested in full

Part of the rules in [`CLAUDE.md`](../../CLAUDE.md), which says when this file is read.

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
