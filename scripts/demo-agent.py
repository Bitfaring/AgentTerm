#!/usr/bin/python3
"""A stand-in for an agent, for the screenshots.

scripts/screenshots.sh puts this under the agents' names. Started in a
terminal it draws what an agent's screen looks like after one answer, and
draws it again for the new width whenever the terminal is resized, as the
real ones do. Nothing is asked of any service and no account is used.

With AGENTTERM_DEMO_TOOL, AgentTerm's program, in its environment, it
stands in for an agent `agenttermd setup` set up (#129), and runs that
program as such an agent runs it: it tells its hooks it started, runs
AgentTerm's MCP server beside it for as long as it runs, and as `claude`
reports usage through AgentTerm's status line, so the usage band has
figures. With AGENTTERM_DEMO_DONE_AFTER=<seconds> as well, it tells its
hooks that a turn began, half that time after it starts, and that it is
done, that many seconds after (the iPhone's test of the Inbox, #67, #71).
With AGENTTERM_DEMO_ASK_AFTER=<seconds>, `claude` asks a question with
choices that many seconds after it starts, and is done once it is
answered; what it is sent is written down (`ask_later`, #232).
"""
import json
import os
import subprocess
import sys
import textwrap
import threading
import time

NAME = os.path.basename(sys.argv[0])
TOOL = os.environ.get("AGENTTERM_DEMO_TOOL")
# Each agent's first event, which says its hooks are there.
START_EVENTS = {"claude": "SessionStart", "codex": "SessionStart", "agy": "SessionStart", "copilot": "sessionStart"}
ESC = "\x1b["
DIM, BOLD, RESET = ESC + "2m", ESC + "1m", ESC + "0m"

ASK = "Explain in short lines how Parser.parse works and which edge cases the tests should cover."
ANSWER = [
    ("How parse works", [
        "It takes one line of text and returns an array of strings.",
        "First it splits the text on every comma.",
        "The split uses Swift's default, which drops empty pieces.",
        "So \"a,,b\" yields two fields, not three.",
        "Leading and trailing commas also vanish for the same reason.",
        "Each remaining piece is then trimmed with the whitespaces set.",
        "That set covers spaces, tabs and other Unicode horizontal spaces.",
        "Trimming only touches the ends; spaces inside a field are kept.",
        "There is no quote handling: a comma inside quotes still splits.",
        "There is no escaping, and nothing ever throws.",
    ]),
    ("Edge cases the tests should cover", [
        "Spaces before, after and on both sides of a field.",
        "Tabs around a field.",
        "Inner spaces preserved, for example \"a b\" staying intact.",
        "Empty string input returns an empty array.",
        "Input with no commas returns one trimmed field.",
        "Consecutive commas: pin down that empty fields are dropped.",
        "A field of only spaces: pin down the empty string result.",
        "Quoted field containing a comma, to document that it splits.",
    ]),
]
CLOSING = (
    "The dropped empty fields are the part most likely to be a bug rather than intended: if column "
    "positions matter, every later column shifts. Decide what you want there before writing tests "
    "that lock it in."
)
# What it says at the end in place of CLOSING, when given: a test's own
# answer, such as one an Inbox row once crashed on (#240).
CLOSING = os.environ.get("AGENTTERM_DEMO_CLOSING") or CLOSING
NEXT = "add tests for those edge cases"


def size():
    try:
        return os.get_terminal_size(sys.stdout.fileno())
    except OSError:
        return os.terminal_size((80, 24))


def run_tool(arguments, given):
    """AgentTerm's program, run as a set up agent runs it, given JSON."""
    subprocess.run([TOOL] + arguments, input=json.dumps(given).encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def set_up():
    """Its start told to its hooks, and AgentTerm's MCP server started
    beside it, which says to the host that it did; kept while this runs."""
    if not TOOL or NAME not in START_EVENTS:
        return None
    event = START_EVENTS[NAME]
    run_tool(["hook", NAME, event], {"hook_event_name": event})
    return subprocess.Popen([TOOL, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def report_usage():
    """What Claude Code tells its status line: the model, the context, the
    limits, given to AgentTerm's, which keeps it for the usage band."""
    if not TOOL:
        return
    try:
        now = time.time()
        week = now + 2 * 86400 - (now % 86400) + 4 * 3600
        report = {
            "model": {"display_name": "Fable 5.2"},
            "effort": {"level": "high"},
            "context_window": {"context_window_size": 1_000_000, "used_percentage": 5},
            "rate_limits": {
                "five_hour": {"used_percentage": 12, "resets_at": now + 4 * 3600 + 28 * 60},
                "seven_day": {"used_percentage": 38, "resets_at": week},
            },
        }
        run_tool(["statusline"], report)
    except OSError:
        pass


def tell_done_later():
    """Claude Code's Stop hook, run as it runs it, after a while."""
    after = os.environ.get("AGENTTERM_DEMO_DONE_AFTER")
    if not after or not TOOL:
        return

    def tell(name, event):
        run_tool(["hook", "claude", name], event)

    for at, name, event in [
        (float(after) / 2, "UserPromptSubmit", {"hook_event_name": "UserPromptSubmit", "prompt": ASK}),
        (float(after), "Stop", {"hook_event_name": "Stop", "last_assistant_message": CLOSING}),
    ]:
        timer = threading.Timer(at, tell, args=(name, event))
        timer.daemon = True
        timer.start()


QUESTION = "Which parser should the tests cover first?"
CHOICES = ["The CSV parser", "The JSON parser"]
# What the stand-in asks, while it asks (AGENTTERM_DEMO_ASK_AFTER).
asking = threading.Event()
redraw = threading.Event()


def ask_later():
    """Claude Code's question with choices (AskUserQuestion), told to its
    hooks as it tells them, a while after it starts; and what it is sent,
    written down, for scripts/test-ios.sh to see where the iPhone's prompt
    and answer went (#232): `~/.demo-agent/claude-input`, a line for each
    line received, ASKED and ANSWERED where the question began and ended."""
    after = os.environ.get("AGENTTERM_DEMO_ASK_AFTER")
    if not after or not TOOL:
        return
    folder = os.path.expanduser("~/.demo-agent")
    os.makedirs(folder, exist_ok=True)
    log = os.path.join(folder, NAME + "-input")

    def note(line):
        with open(log, "a") as written:
            written.write(line + "\n")

    def ask():
        note("ASKED")
        asking.set()
        redraw.set()
        options = [{"label": choice, "description": ""} for choice in CHOICES]
        tool_input = {"questions": [{"question": QUESTION, "header": "Parser", "options": options, "multiSelect": False}]}
        run_tool(["hook", "claude", "PreToolUse"], {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": tool_input})

    def read():
        while True:
            try:
                received = os.read(sys.stdin.fileno(), 4096)
            except OSError:
                return
            if not received:
                return
            note("INPUT " + json.dumps(received.decode(errors="replace")))
            if asking.is_set() and (b"\r" in received or b"\n" in received):
                # Answered: the question is over, and the turn with it.
                asking.clear()
                redraw.set()
                note("ANSWERED")
                run_tool(["hook", "claude", "PostToolUse"], {"hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"})
                run_tool(["hook", "claude", "Stop"], {"hook_event_name": "Stop", "last_assistant_message": "The tests start with that parser."})

    threading.Thread(target=read, daemon=True).start()
    timer = threading.Timer(float(after), ask)
    timer.daemon = True
    timer.start()


def claude(cols):
    out = []
    width = max(cols - 4, 20)
    asked = textwrap.wrap(ASK, width)
    for index, line in enumerate(asked):
        out.append(ESC + "48;5;237m" + (DIM + "❯ " + RESET + ESC + "48;5;237m" if index == 0 else "  ") + line.ljust(cols - 2) + RESET)
    out.append("")
    number = 0
    for index, (title, lines) in enumerate(ANSWER):
        out.append(("● " if index == 0 else "  ") + BOLD + title + RESET)
        out.append("")
        for line in lines:
            number += 1
            label = f"{number}. "
            wrapped = textwrap.wrap(line, max(width - len(label) - 2, 10))
            out.append("  " + label + wrapped[0])
            out.extend("  " + " " * len(label) + more for more in wrapped[1:])
        out.append("")
    out.extend("  " + line for line in textwrap.wrap(CLOSING, width))
    out.append("")
    out.append(DIM + "✻ Baked for 10s · done " + time.strftime("%-I:%M %p") + RESET)
    out.append("")
    rule = DIM + "─" * cols + RESET
    out.append(rule)
    if asking.is_set():
        # Its question, in place of its input, as Claude Code draws one.
        out.append(BOLD + QUESTION + RESET)
        out.extend(("❯ " if index == 0 else "  ") + f"{index + 1}. {choice}" for index, choice in enumerate(CHOICES))
        out.append(f"  {len(CHOICES) + 1}. Type something.")
        return out
    out.append("❯ " + ESC + "7m" + NEXT[0] + ESC + "27m" + DIM + NEXT[1:] + RESET)
    out.append(rule)
    hint = " (shift+tab to cycle)" if cols >= 46 else ""
    out.append("  " + ESC + "33m⏵⏵ auto mode on" + RESET + DIM + hint + RESET)
    return out


def other(cols):
    names = {"codex": "Codex", "agy": "Antigravity", "copilot": "Copilot CLI"}
    return [BOLD + names.get(NAME, NAME) + RESET, DIM + os.path.basename(os.getcwd()) + RESET, "", "❯ "]


def draw(cols, rows):
    lines = claude(cols) if NAME == "claude" else other(cols)
    # The end of it is what shows, as in a terminal that scrolled.
    sys.stdout.write(ESC + "?25l" + ESC + "H" + ESC + "2J" + "\r\n".join(lines[-max(rows - 1, 1):]))
    sys.stdout.flush()


def main():
    # Asked of its own configuration, as Settings > Hooks & MCP asks an
    # agent (#155): a stand-in has none, and says so at once rather than
    # start a session that waits.
    if sys.argv[1:2] and sys.argv[1] in ("mcp", "plugin", "features", "app-server"):
        print(f"{NAME}: this stand-in has no {sys.argv[1]} command")
        sys.exit(1)
    # Asked for one answer, as when the app has an agent write a commit message.
    if "-p" in sys.argv or "exec" in sys.argv[1:2]:
        sys.stdin.read()
        print("feat: trim the spaces around each field")
        return
    # Held while this runs: its input closed, the server ends.
    server = set_up()  # noqa: F841
    if NAME == "claude":
        report_usage()
        tell_done_later()
    # The screenshots drive the agent's MCP server as the agent would, to
    # open a shell and a page beside it: they find its session's variable
    # here, a line for each session of this agent, the first first.
    variable = os.environ.get("AGENTTERM_MCP")
    if variable:
        folder = os.path.expanduser("~/.demo-agent")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, NAME), "a") as told:
            told.write(variable + "\n")
    os.system("stty -echo 2>/dev/null")
    if NAME == "claude":
        ask_later()
    # Drawn again whenever the terminal has another size, or the question
    # comes or goes. Looked at now and then rather than on the signal: a
    # signal in the middle of drawing would leave the screen half drawn.
    drawn = None
    while True:
        now = size()
        if now != drawn or redraw.is_set():
            redraw.clear()
            drawn = now
            draw(now.columns, now.lines)
        time.sleep(0.2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
