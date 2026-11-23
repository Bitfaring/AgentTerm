# Rule 6. How a session goes

Part of the rules in [`CLAUDE.md`](../../CLAUDE.md), which says when this file is read.

## At the start

Read `README.md`, and no other document in full. `docs/SPEC.md` (what the app does), `docs/DESIGN.md` (how it is built) and `docs/TESTING.md` (how it is tested) are too long to be read whole: together they fill a large part of a session before any work is done. Of each, read the list of its headings (`grep -n '^##' docs/DESIGN.md`), then only the sections the issue being worked on names under `## Read` (rule 5), by their line range. A section that turns out to be needed and was not named is read then, and added to the issue.

## One group, one session

A session works on one group (rule 2, "Work goes by groups") and no more. When the group is done, tested, committed and pushed, the report says so, names the next group, and stops: the next group is started by the owner in a new session. Nothing the next session needs is left in the conversation only: what was found, decided or left undone is written into the issue it belongs to before the report is given. A session that has been summarised (compacted) reads again, from GitHub, the definition of done of the issue it is on before it goes on.

## An issue is checked by someone who did not do it, before it is closed

The session that did the work does not judge its own work. It starts a subagent that is given only the issue's number and the commits, not the conversation: the subagent reads the issue from GitHub (`gh issue view <n>`), reads the diff, and answers for each numbered item of the definition of done whether it is true, with the file and line, the test or the command's output that shows it. An item it cannot show is not done. The table it gives is put in the closing comment; with any item not done, the issue stays open and the item is either done or asked about (rule 1, "doing less than was asked").
