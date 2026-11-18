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
| Claude Code | `claude` | 2.1.327 (2026-11-18) |
| Codex | `codex` | 0.169.1 (2026-11-18) |
| Antigravity | `agy` | 1.5.10 (2026-11-18) |
| Copilot CLI | `copilot` | 1.0.113 (2026-11-18) |

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
| Codex | in `~/.codex/config.toml`, each under a comment that says it is AgentTerm's (#142): it takes hooks nowhere else | a plugin (`codex plugin marketplace add`, `codex plugin add`), `env_vars` naming the session's variable; and the server its sessions share turned off, `codex features disable daemon_auto_start` (#140, below) | the server's instructions | |
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

### Who starts a hook and a server, and in which terminal (#140, 2026-11-18)

A hook and the MCP server know their session from their environment, which
is the one of whatever started them. Each agent was started in a terminal
and asked one thing, with the hooks and the server of AgentTerm it already
had, and every process that appeared under it was written down: what started
it, and whether it has a terminal (a controlling one).

| Agent | Version | `agenttermd mcp` | `agenttermd hook` |
|---|---|---|---|
| Claude Code | 2.1.327 | started by `claude`, in its terminal | started by `claude` (`/bin/sh -c`, which becomes it), **in no terminal** |
| Codex, `--no-daemon` | 0.169.1 | started by `codex`, in its terminal | started by `codex` (`/bin/zsh -c`, which becomes it), **in no terminal** |
| Codex, as it starts by itself | 0.169.1 | started by `codex app-server`, **in no terminal** | not seen: by the app server too, as it runs the session |
| Copilot CLI | 1.0.113 | started by `copilot`, in its terminal | started by `copilot` (`/bin/bash --norc --noprofile -c`), in its terminal |
| Antigravity | 1.5.10 | started by `agy`, in its terminal | started by `agy` (`sh -c`), in its terminal |

So what an agent in a session starts is started by that agent, which has
the session's terminal, whether the hook itself has one or not. `agenttermd`
goes by that (`ProcessNames.agentInNoTerminal`): when the agent that started
it, looked for past the shells that only ran its command line, has no
terminal, it is no session's, and the hook, the server and the status line
do as they do outside AgentTerm.

**Codex's shared app server** (0.169.1; 0.169.0 has the feature and the
option too). Tried in a `CODEX_HOME` of the trial's own, with a key that is
nobody's, and a stand-in MCP server that wrote down who started it and a
variable of the trial's that said from which terminal:

- A `codex` started plainly starts, when none runs, a background server
  (`codex app-server --listen unix://…/app-server-control/app-server-control.sock`,
  kept by `codex app-server daemon pid-update-loop`; the feature
  `daemon_auto_start`, `stable`, on), and every `codex` after it uses that
  one. It has no terminal, and goes on after the sessions end, their MCP
  servers with it.
- It starts an MCP server for each session, in that session's folder, **with
  the environment of the session that started the app server**: the second
  session's server had the first one's variable. This is how a Codex session
  in AgentTerm spoke as another (#140).
- `codex --no-daemon` ("Run without the shared background server, even if it
  is already running") runs a session by itself, and so does configuration
  given on the command line with `-c`: the MCP server is then started by
  `codex` itself, with its own environment. Both tried. The program's own
  messages name more that "requires embedded mode" (`--profile`, `--oss`,
  `--strict-config`, `CODEX_EXEC_SERVER_URL`): read, not tried.
- `codex features disable daemon_auto_start` writes `[features]
  daemon_auto_start = false` into `config.toml`, and `codex features enable`
  writes `true`. With it off and no app server running, a `codex` started
  plainly runs by itself. **A server that runs is used whatever the feature
  says**, without a word. `codex --disable daemon_auto_start` while one runs
  asks ("Background server has incompatible features … 1. Run without daemon
  this time 2. Restart with these settings 3. Cancel").
- `codex app-server daemon version` says whether one runs (a line of JSON,
  `"status":"running"`; an error when none does), and starts nothing.
  `codex app-server daemon stop` stops it: a session that used it then waits
  ("Reconnecting to server…") and does not come back by itself.
- A table Codex adds to `config.toml` (`[features]` was) is written after
  the last table and **above the comments the file ends with**; a comment
  over a table stays with it, and what Codex did not change is left as it
  was written (#142).

`agenttermd setup codex` therefore turns the feature off with Codex's own
command, and says when a server still runs, with what to do; it stops
nothing, which would leave the user's sessions waiting. Tried with the real
Codex and this build's `agenttermd` in that home: set up and run by itself,
`/mcp` in Codex says "agentterm-dev: connected (30 tools)"; with the feature
turned on again and the shared server running, "connected (0 tools)".

**Not known.** Whether 0.169.0 used the shared server on the Mac this was
found on: a session of the day before had a server of its own. Whether
Codex asks to review its hooks again when only the comment over them
changes. What starts the shared server besides `codex` itself.

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
  the other's (#124); since #129 each build's hooks are its own in
  `config.toml`, each its own places.
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
