# The agents on the command line

AgentTerm works with each agent through its command line program: it starts
it in a terminal with nothing of its own added, reads what the hooks and the
MCP server the user added to its own configuration (#129) report, and types
into it. This file is what is known
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

`HostServer` starts the agent's program in a terminal of its own, with
nothing of AgentTerm's on its command line (#129, decided by the owner on
2026-11-17); only what the user chose (a resume, a schedule's permissions,
and for a schedule's run of Antigravity its folder trusted for that run).
What the agent gets of AgentTerm is in its own configuration, at the user's
scope, once `agenttermd setup` (Settings > Hooks & MCP) added it:

| Agent | Hooks | MCP server | What AgentTerm tells it (`AgentPrompts`) | Claude Code's status line |
|---|---|---|---|---|
| Claude Code | a plugin (`claude plugin marketplace add <folder> --scope user`, `claude plugin install <name>@<name> --scope user`) | the same plugin's `.mcp.json` | the server's instructions, which reach the model | in `~/.claude/settings.json`, the user's kept and run after it |
| Codex | between marks in `~/.codex/config.toml`: it takes hooks nowhere else | a plugin (`codex plugin marketplace add`, `codex plugin add`), `env_vars` naming the session's variable | the server's instructions | |
| Copilot CLI | a plugin of its own layout (`copilot plugin marketplace add`, `copilot plugin install`) | the same plugin's `.mcp.json` | a folder of instructions its environment names, in every session: it does not give a server's instructions | |
| Antigravity | a plugin of its own layout (`agy plugin install <folder>`, a copy) | the same plugin's `mcp_config.json` | a rule of the plugin, always on: installed again after the words change | |

- Every hook runs `<agenttermd> hook <agent> <event>`, the host's program of
  the build that set it up (`/Applications/AgentTerm.app/Contents/MacOS/agenttermd`
  for the release). It saves what it is given, replacing the last, in the
  file the session's environment names (`AGENTTERM_EVENTS`, or
  `AGENTTERM_DEV_EVENTS` for a development build); the host reads it
  (`AgentHooks.change`). Outside a session of AgentTerm's it does nothing.
- The events asked for: Claude Code `SessionStart UserPromptSubmit PreToolUse
  PermissionRequest PostToolUse Notification Stop`; Codex `SessionStart
  UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop Interrupt`;
  Copilot CLI `sessionStart userPromptSubmitted preToolUse permissionRequest
  postToolUse postToolUseFailure agentStop`; Antigravity `SessionStart
  PreInvocation PreToolUse PostToolUse Stop`. The start's says at once that
  the hooks are there.
- Claude Code's status line runs `<agenttermd> statusline`, which saves what
  Claude Code gives it (its rate limits among it) in the file its session's
  environment names, then runs the status line it took the place of.
- The MCP server is `<agenttermd> mcp`, of the same build (`AppChannel.mcpServerName`:
  `agentterm`, or `agentterm-dev` for a development build). It says to the
  host that it started, and for which agent: the one among its forebears.

### How each takes hooks and an MCP server by its own commands (#129, 2026-11-17)

Tried with the real agents, each with the plugin loaded for that one session
only (`--plugin-dir`, or a scratch `CODEX_HOME`), nothing written into the
user's own configuration; a stand-in hook and MCP server wrote down that
they ran and whether `AGENTTERM_MCP` reached them:

| Agent | Version | Found |
|---|---|---|
| Claude Code | 2.1.326 | `claude plugin marketplace add` takes a URL, a path or a GitHub repository; `claude plugin details` lists a plugin's hooks and servers. `claude -p "hi"`: SessionStart, UserPromptSubmit and Stop ran; the server started with the variable; the server's instructions reached the model (it said the word they asked for). `--scope` is `user` unless told otherwise |
| Copilot CLI | 1.0.112 | `copilot plugin marketplace add` takes a local path, and reads a marketplace of Claude Code's layout; a local one's plugin is read live, not copied. `copilot -p "hi"`: sessionStart, userPromptSubmitted and agentStop ran; the server started with the variable; its instructions did not reach the model (`--allow-all-mcp-server-instructions` exists) |
| Codex | 0.169.0 | `codex plugin marketplace add` takes a local or Git marketplace, of Claude Code's layout too; `codex plugin add` copies the plugin into its cache. `codex exec "hi"`: the server started; the variable reached it only once its `.mcp.json` named it in `env_vars`. No hook of the plugin ran, with `--enable plugin_hooks` either: `codex features list` says `plugin_hooks  removed  false`, and `hooks  stable  true` for those of `config.toml`, which it asks to review |
| Antigravity | 1.5.9 | `agy plugin install <folder>` converts Claude Code's layout (a hook of an event it has not is skipped and said); `agy plugin validate` says how it loads a plugin, which can hold rules, hooks and servers. Its own `~/.gemini/config/hooks.json` and `mcp_config.json` exist too. Not tried in a session: its sign-in is in its home |

An agent typed at a zsh prompt is the leader of the terminal's foreground
process group, named as typed (`claude`, `codex`, `copilot`, `agy`) by the
first word of its command line; `proc_name` gives the file's own name,
`2.1.326` for Claude Code, whose command is a link to its version. Tried
with the programs installed on the Mac on 2026-11-17, each a program of its
own (Mach-O): Claude Code's own installer, Codex's standalone release, Copilot
CLI's Homebrew cask, Antigravity's. One installed with npm runs in Node,
whose first word may be `node`: not tried.

## What each asks about itself

What an agent asks the user about itself (trusting a folder or a hook, an
update, a sign-in) is the user's to answer: a test or an agent of AgentTerm
does not answer it unless the owner says so.

- **Codex** asks to review hooks it was not given before ("Hooks need review:
  6 hooks are new or changed"). What was trusted is kept in
  `~/.codex/config.toml`, one entry per event and place,
  `[hooks.state."<file>:<event>:<group>:<hook>"]`, with the hash of the hook
  (`trusted_hash`). Tried on 2026-11-17: trusted once, the same command was
  not asked about again. Hooks given with `-c` counted as one place for
  every build (`/<session-flags>/config.toml`), each build's trust replacing
  the other's (#124); since #129 each build's hooks are a block of their
  own in `config.toml`, each its own places.
- **Antigravity** keeps its trusted folders in
  `~/.gemini/antigravity-cli/settings.json` (`trustedWorkspaces`). A
  schedule's run gets its folder trusted for that run through `--settings`,
  which is not saved. A file outside the workspace is asked
  about one at a time ("Allow access to this file? 1. Yes 2. Yes, and always
  allow non-workspace access 3. No"). Seen on 2026-11-17: the saved list holds
  the development build's hooks folder, not the release's. **What it asks each
  time a session is started in AgentTerm is not known yet**: it was not asked
  when tried with the hooks of the release in the AgentTerm repository.
- **Claude Code** asks whether to trust a folder it has not been in; the
  answer is kept per project in `~/.claude.json` (`hasTrustDialogAccepted`).
  A plugin's hooks were not asked about.
- **Copilot CLI** asks whether to trust a folder; its plugin's hooks were not
  asked about. `copilot --version` says to run `copilot update` when there is
  one.

## What was found by running them (group 0 of #114, 2026-11-17)

Run in the AgentTerm repository, which all four trust, with the command line
AgentTerm gave the agents before #129 (their hooks on it), pointed at the release's
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

### What a turn came to (#71) and the thinking level (#130)

Each was asked to run `echo hello` and `sh -c 'echo oops >&2; exit 3'`, one
call each, then to answer in a sentence (2026-11-17).

| | The prompt | The last answer | A command and its exit code | The thinking level |
|---|---|---|---|---|
| Claude Code 2.1.326 | `UserPromptSubmit` `prompt` | `Stop` `last_assistant_message` | `PostToolUse` for one that succeeded, without its code; one that failed has **no `PostToolUse`** but `PostToolUseFailure` (not asked for) with `error: "Exit code 3\noops"`. Its record (`transcript_path`): `tool_use` `Bash` and its `tool_result`, `is_error` with "Exit code N" | Status line input `effort.level` (`xhigh`), `thinking.enabled`; every hook event's `effort.level` |
| Codex 0.169.0 | `UserPromptSubmit` `prompt`, `turn_id` | `Stop` `last_assistant_message` | `PostToolUse` for both, `tool_response` the output only, **no code**. Its record (`transcript_path`, the rollout): `item_completed` with a `CommandExecution`, its `exit_code` and `turn_id` | The rollout's `turn_context` `effort` (`medium`), `model` |
| Copilot CLI 1.0.112 | `userPromptSubmitted` `prompt` | **Not in `agentStop`**; its record (`transcriptPath`, `events.jsonl`): the last `assistant.message` | `postToolUse` `textResultForLlm` "…completed with exit code 3", `resultType` "success" all the same. Its record: `tool.execution_complete` `shellExecution.exitCode` | `session.model_change` and `session.usage_record` `reasoningEffort` (`medium`) |
| Antigravity 1.5.9 | Every event's `lastUserInput` | **Not in `Stop`**; its record (`transcriptPath`, `transcript_full.jsonl`): the last `PLANNER_RESPONSE` with `content` | `PostToolUse` has no code; its record: the step after a `run_command` call says "Command exited with code 3." | Only as the end of `modelName` (`gemini-4-hydrogen-medium`) |

So the commands of a turn and their codes are taken from each agent's own
record when the turn ends (`TurnTranscript`), not from the hooks: a hook's
file holds the last event only, and several quick ones are read as one.

## Not known yet

- What Antigravity asks each time a session is started in AgentTerm.
- How a turn of Copilot CLI is interrupted.
- What each agent shows and reports once a limit is reached.
- How Codex can keep the trust of both builds' hooks.
