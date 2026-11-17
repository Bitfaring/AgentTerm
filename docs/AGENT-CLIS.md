# The agents on the command line

AgentTerm works with each agent through its command line program: it starts
it in a terminal, gives it hooks and AgentTerm's MCP server for that session
only, reads what it reports, and types into it. This file is what is known
of each, how a session is started, what each asks about itself, and what was
found by running the real program, with the version it was found with
(principle 5). It is the reference to check a change against, and it is
brought up to date when an agent's new version behaves otherwise.

| Agent | Program | Version last tried |
|---|---|---|
| Claude Code | `claude` | 2.1.326 (2026-11-17) |
| Codex | `codex` | 0.169.0 (2026-11-17) |
| Antigravity | `agy` | 1.5.9 (2026-11-17) |
| Copilot CLI | `copilot` | 1.0.112 (2026-11-17) |

## How a session of an agent is started

`HostServer` starts the agent's program in a terminal of its own, with what
`AgentHooks.launchArguments` adds to its command line, for that session only
and without a change to the user's own configuration of it:

| Agent | Hooks given by | MCP server given by | What AgentTerm tells it (`AgentPrompts`) given by |
|---|---|---|---|
| Claude Code | `--settings` (with the status line, `StatusLineRelay`) | `--mcp-config`, before `--settings` (it takes every word after it) | `--append-system-prompt` |
| Codex | `-c hooks.<Event>=[{hooks=[{type="command",command="…"}]}]`, one `-c` per event | `-c mcp_servers.<name>.command/args/env_vars` (it passes only the variables `env_vars` names) | the MCP server's instructions |
| Antigravity | `--add-dir <folder>`, a folder of the host's holding `.agents/hooks.json`, trusted for the session by `--settings '{"trustedWorkspaces":[…]}'` | `.agents/mcp_config.json` in that folder | a rule of that folder, `.agents/rules/agentterm.md` |
| Copilot CLI | `--plugin-dir <folder>`, a plugin of the host's holding `hooks.json` | `--additional-mcp-config` | instructions it is told of in its environment (`instructionsEnvironment`) |

- Every hook runs `<agenttermd> hook <agent> <event>`, the host's program of
  the build that started the session (`/Applications/AgentTerm.app/Contents/MacOS/agenttermd`
  for the release). It saves what it is given, replacing the last, in the
  file `AGENTTERM_EVENTS` names in the session's environment; the host reads
  it (`AgentHooks.change`).
- The events asked for: Claude Code `UserPromptSubmit PreToolUse
  PermissionRequest PostToolUse Notification Stop`; Codex `UserPromptSubmit
  PreToolUse PermissionRequest PostToolUse Stop Interrupt`; Copilot CLI
  `userPromptSubmitted preToolUse permissionRequest postToolUse
  postToolUseFailure agentStop`; Antigravity `PreInvocation PreToolUse
  PostToolUse Stop`.
- Claude Code's status line runs `<agenttermd> statusline <file>`, which saves
  what Claude Code gives it (its rate limits among it) and then runs the
  user's own status line, if any.
- The MCP server is `<agenttermd> mcp`, of the same build (`AppChannel.mcpServerName`:
  `agentterm`, or `agentterm-dev` for a development build).

## What each asks about itself

What an agent asks the user about itself (trusting a folder or a hook, an
update, a sign-in) is the user's to answer: a test or an agent of AgentTerm
does not answer it unless the owner says so.

- **Codex** asks to review hooks it was not given before ("Hooks need review:
  6 hooks are new or changed"). Hooks given with `-c` count as session flags;
  what was trusted is kept in `~/.codex/config.toml`, one entry per event and
  place, `[hooks.state."/<session-flags>/config.toml:<event>:<group>:<hook>"]`,
  with the hash of the hook (`trusted_hash`). Tried on 2026-11-17: trusted
  once, the same command was not asked about again. **Why it asks again and
  again**: the release and a development build give each their own program
  (principle 7), so the same entry holds the hash of one command at a time,
  and each build that starts Codex after the other is asked again, its trust
  replacing the other's. Not fixed yet.
- **Antigravity** keeps its trusted folders in
  `~/.gemini/antigravity-cli/settings.json` (`trustedWorkspaces`). AgentTerm
  adds its hooks folder and the session's folder for the session through
  `--settings`, which is not saved. A file outside the workspace is asked
  about one at a time ("Allow access to this file? 1. Yes 2. Yes, and always
  allow non-workspace access 3. No"). Seen on 2026-11-17: the saved list holds
  the development build's hooks folder, not the release's. **What it asks each
  time a session is started in AgentTerm is not known yet**: it was not asked
  when tried with the hooks of the release in the AgentTerm repository.
- **Claude Code** asks whether to trust a folder it has not been in; the
  answer is kept per project in `~/.claude.json` (`hasTrustDialogAccepted`).
  The hooks given by `--settings` were not asked about.
- **Copilot CLI** asks whether to trust a folder; its plugin's hooks were not
  asked about. `copilot --version` says to run `copilot update` when there is
  one.

## What was found by running them (group 0 of #114, 2026-11-17)

Run in the AgentTerm repository, which all four trust, with the command line
`AgentHooks.launchArguments` makes, the hooks pointed at the release's
`agenttermd`, `AGENTTERM_EVENTS` set to a file that was read every tenth of a
second. Prompts of a few words, to spend as little of the accounts as could
be.

### Files, images and text (#70)

| | `@VERSION` | The path of a PNG, typed as text | Two lines with LF between, no Return | Return sent right after the text, in one write |
|---|---|---|---|---|
| Claude Code | Read as a file | Read with its Read tool, its colour told | Two lines in the field, not sent; Return (CR) sends | Sent |
| Codex | Read | "Viewed image red.png", its colour told | Two lines, not sent | **Not sent**: taken for part of a paste; a Return written on its own afterwards sent it |
| Copilot CLI | Read | "[Image: … image/png 8x8]", told | Two lines, not sent | Sent (written apart, to be sure) |
| Antigravity | Read | Read, after asking: the file was outside the workspace | Two lines, not sent | Sent (written apart) |

So a file or an image is given to any of the four by writing its path into
the prompt; none needs the clipboard. A composer sends a text of several
lines with LF between them and a Return (CR) of its own, written apart from
the text.

### Ready for the next prompt (#72)

| | A turn | Interrupted (Esc) | Also |
|---|---|---|---|
| Claude Code | `UserPromptSubmit` (`PreToolUse` `PostToolUse` for each tool) `Stop` | **No `Stop`**: "Interrupted · What should Claude do instead?" | `Stop` carries `background_tasks` and `session_crons`; work left running in the background is listed there |
| Codex | `UserPromptSubmit` … `Stop` | **`Interrupt`**: "Conversation interrupted" | |
| Copilot CLI | `userPromptSubmitted` (`preToolUse`, `permissionRequest`, `postToolUse`) `agentStop` | Esc did nothing; Ctrl+C while a command ran sent it to the background, and the turn waited for it | When a background command ended, Copilot **started a turn by itself** (`userPromptSubmitted` `agentStop`, nobody typing) |
| Antigravity | `PreInvocation` for **each call of the model** (again after its tools), `PreToolUse` `PostToolUse`, `Stop` | **No `Stop`**: "Interrupted · What should Antigravity CLI do instead?" | `PreInvocation` is not "the user sent a prompt" |

So the end of a turn is told by every agent, an interruption only by Codex;
for the others it has to be taken from the key that interrupted
(`AgentHooks.mayStopATurn`). Copilot can begin a turn of its own after one
ended.

### Limits and quota (#80, #73, #81)

- **Claude Code**: the status line's input has `rate_limits.five_hour` and
  `rate_limits.seven_day`, each `{used_percentage, resets_at}` (seconds since
  1970). Near a limit it says so under the prompt: "You've used 86% of your
  weekly limit · resets Nov 21 at 4am (Asia/Saigon)".
- **Codex**: `/status` shows "5h limit: … left (resets 1:36 PM)" and "Weekly
  limit: … left (resets 4:29 PM on 21 Nov)" without asking the model. Its
  session file (`~/.codex/sessions/…/rollout-….jsonl`) has, in each
  `token_count` event, `rate_limits`: `primary` and `secondary` (`used_percent`,
  `window_minutes` 300 and 10080, `resets_at`), `credits`, `plan_type`, and
  **`rate_limit_reached_type`**, null while no limit is reached.
- **Copilot CLI** counts AI credits: "Session: 0.98 AIC used" under the
  prompt, "AI Credits 0.98" when it ends. The account's premium requests come
  from GitHub (`AccountUsageFetcher.copilot`).
- **Antigravity**: not looked at in its own screen; the account's figures
  come from `AccountUsageFetcher.antigravity`.
- What each says **once a limit is reached** was not seen: no limit was
  reached on purpose.

## Not known yet

- What Antigravity asks each time a session is started in AgentTerm.
- How a turn of Copilot CLI is interrupted.
- What each agent shows and reports once a limit is reached.
- How Codex can keep the trust of both builds' hooks.
