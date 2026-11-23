# CLAUDE.md

Guidance for Claude Code, and any other coding agent, working in this repository. This file is short on purpose: it says what always holds, and which file under `docs/rules/` is read before which kind of work. A rule's file is read in full before that work is begun, not from memory.

What is planned is in the GitHub issues and milestones, and what was decided is written in the issue it was decided for.

## Design principles

How the owner decides. When one of these answers a question, decide by it and go on, and say in the report what was decided and by which principle. In full: `docs/rules/principles.md`, read before a principle is used to decide.

1. The Mac has everything; the iPhone has what is used every day.
2. Clear and safe before convenient.
3. What fails is said at once, with its reason and what to do.
4. What the app does by itself is on by default, has a switch, and is written down.
5. Nothing is guessed that can be tried.
6. Until the official release, anything may change.
7. The released build and a development build never share anything.
8. An issue is kept only while it can be acted on.
9. Both apps say the same thing in the same words.

## Always asked

Whatever a principle says, these are asked first and done only when asked; being asked once is not being asked for the next time. The only exceptions are those of rule 4.

- Anything outward or hard to undo: committing, pushing, opening or merging a pull request, releasing, creating or editing issues and milestones, deploying, deleting.
- Anything of the user's own: their installed app, sessions, preferences, devices, simulators, accounts and tools.
- Security and privacy.
- Doing less than was asked.
- Planning: releases, milestones, closing an issue that is not done in full, release notes.

## Rules

| Rule | Read it | File |
|---|---|---|
| 1. Important decisions are asked, unless a principle answers them | when a decision comes up | `docs/rules/1-decisions.md` |
| 2. Work that is done is tested in full | before testing, and before reporting anything as done | `docs/rules/2-testing.md` |
| 3. Nothing of the user's is touched while testing | before running a host, an app or a simulator | `docs/rules/3-test-isolation.md` |
| 4. Done without asking | before committing, pushing, opening or closing an issue, or starting a real agent | `docs/rules/4-without-asking.md` |
| 5. How an issue is written | before creating or editing an issue | `docs/rules/5-issues.md` |
| 6. How a session goes | at the start of every session, and before closing an issue | `docs/rules/6-sessions.md` |

## Conventions

- Code, comments, commit messages and everything under `docs/` are in English. Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
- No force push, no rewriting of history, no deleting of branches.
- Work happens on the milestone's branch and reaches `main` through a pull request.
