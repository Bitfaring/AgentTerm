#!/usr/bin/env bash
# Runs the iPhone UI test in the iOS Simulator against two throwaway hosts.
#
#   ./scripts/test-ios.sh                   # asks which simulator
#   ./scripts/test-ios.sh "iPhone 17 Pro"   # a simulator by name, or by UDID
#   ./scripts/test-ios.sh --list            # show the simulators and stop
#   SHOTS=/some/folder ./scripts/test-ios.sh    # also save screenshots there
#   AGENTTERM_LAUNCH="Start Claude Code" ./scripts/test-ios.sh
#
# The hosts use their own state folders and ports, so your real pairing,
# folders and sessions are not touched. The keychain of the simulator the test
# runs in is reset, so anything paired in that simulator has to pair again,
# and its software keyboard is shown even after a Mac's keyboard was typed on.
set -euo pipefail

cd "$(dirname "$0")/.."
# None of the installed app's variables reaches the tests (#207).
source scripts/lib-own-environment.sh
own_environment AGENTTERM_LAUNCH
command -v xcodegen >/dev/null || { echo "test-ios.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
source scripts/lib-simulator.sh
source scripts/lib-cleanup.sh
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then print_simulators; exit 0; fi
# The fallback is not the simulator run-ios.sh falls back to: this test
# resets the simulator's keychain, which unpairs the app you are trying out.
if [ -z "${1:-}" ] && [ -z "${SIMULATOR:-}" ] && [ -t 0 ] && [ -t 1 ]; then
    echo "This test resets the chosen simulator's keychain: an app paired there has to pair again."
fi
# Unlike the other scripts, never the booted simulator by default: that is
# most likely the one in use.
if [ -z "${1:-}" ] && [ -z "${SIMULATOR:-}" ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
    choose_simulator "iPhone Air" "iPhone Air"
else
    choose_simulator "${1:-}" "iPhone Air"
fi
DEVICE="$SIM_UDID"
echo "Testing on $SIM_NAME ($SIM_UDID)."
PORT=7798
SECOND_PORT=7799
ports_must_be_free "$PORT" "$SECOND_PORT"
STATE="$(mktemp -d)"
SECOND_STATE="$(mktemp -d)"
LOG="$(mktemp)"

swift build --product agenttermd
AGENTTERMD="$(swift build --show-bin-path)/agenttermd"
# Something for the first host to show: a project with uncommitted changes,
# a conversation an agent had in it, and folders to browse.
PROJECT="$STATE/project"
FAKE_HOME="$STATE/home"
mkdir -p "$PROJECT" "$FAKE_HOME/Projects/demo"
git -C "$PROJECT" init -q -b main
# The test commits from the phone: an identity of its own, and no signing,
# whatever this machine is set up with.
git -C "$PROJECT" config user.name t
git -C "$PROJECT" config user.email t@example.com
git -C "$PROJECT" config commit.gpgsign false
printf 'first line\n' > "$PROJECT/notes.txt"
git -C "$PROJECT" add . && git -C "$PROJECT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init
# A remote the project follows, so the commit made from the phone can be pushed.
REMOTE="$STATE/remote.git"
git init -q --bare -b main "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
git -C "$PROJECT" push -q -u origin main
# Hosts for the SSH menu. Nothing connects to them.
mkdir -p "$FAKE_HOME/.ssh"
printf 'Host build-server\n  HostName 127.0.0.1\nHost *.internal\n' > "$FAKE_HOME/.ssh/config"
# A change long and wide enough that its diff has to scroll both ways.
{
    printf 'first line\nsecond line\n'
    printf 'a wide line %s\n' "$(printf 'x%.0s' $(seq 1 300))"
    for i in $(seq 1 150); do printf 'line %s\n' "$i"; done
} > "$PROJECT/notes.txt"
HISTORY="$FAKE_HOME/.claude/projects/$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HISTORY"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"write tests for the parser"}}\n' "$PROJECT" > "$HISTORY/c-1.jsonl"
# A repository of its own inside the project, which the project's git does not see.
git init -q -b main "$PROJECT/web"
printf 'web\n' >> "$PROJECT/.git/info/exclude"
printf '["%s"]' "$PROJECT" > "$STATE/folders.json"
# MARKDOWN=only: the documents the Mac's PERF-15 opens, for the phone's
# preview to be measured the same way (#126).
if [ "${MARKDOWN:-}" = only ]; then
    printf '# First\n\nThe first preview, which starts WebKit.\n' > "$PROJECT/first.md"
    printf '# Small\n\nA few words, and a [link](other.md).\n' > "$PROJECT/small.md"
    for doc in RELEASE SPEC DESIGN TESTING; do cp "docs/$doc.md" "$PROJECT/$doc.md"; done
fi

# A host that died on the first Mac before the one started here, with two
# sessions: the first host has to tell the phone (HOST-8). What a host
# leaves behind while it runs is a marker that names its process and its
# sessions; a process that is gone stands for the one that died.
sh -c 'exit 0' &
DEAD=$!
wait "$DEAD" || true
printf '{"pid":%s,"startedAt":%s,"sessions":[{"name":"build","cwd":"%s"},{"name":"tests","cwd":"%s"}]}' \
    "$DEAD" "$(date +%s)" "$PROJECT" "$PROJECT" > "$STATE/host-$PORT.json"

# Stand-ins for the agents, as the screenshots have (scripts/demo-agent.py):
# none of the installed ones is started, and Antigravity's session has the
# note the test reads (IOS-9).
AGENTS="$STATE/agents"
mkdir -p "$AGENTS"
for agent in claude codex agy copilot; do cp scripts/demo-agent.py "$AGENTS/$agent"; chmod +x "$AGENTS/$agent"; done

# Two hosts with their own state, standing in for two Macs.
# INBOX=only has the stand-in Claude Code say, a few seconds after it starts,
# that its turn is done (#67).
INBOX_DONE_AFTER=""
if [ "${INBOX:-}" = only ]; then INBOX_DONE_AFTER=8; fi
# NOTNOW=only too: a notice after Not Now asks nothing of iOS (NOTIFY-2).
if [ "${NOTNOW:-}" = only ]; then INBOX_DONE_AFTER=8; fi
# ASK=only has it ask a question with choices a while after it starts, time
# enough for the test to write a prompt first (IOS-12, #232).
ASK_AFTER=""
if [ "${ASK:-}" = only ]; then ASK_AFTER=15; fi
HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" AGENTTERM_DEMO_DONE_AFTER="$INBOX_DONE_AFTER" AGENTTERM_DEMO_ASK_AFTER="$ASK_AFTER" AGENTTERM_DEMO_TOOL="$AGENTTERMD" "$AGENTTERMD" --port "$PORT" --local-only --home "$FAKE_HOME" --agents "$AGENTS" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
# The second one says it is of an older release, to see the phone's warning.
AGENTTERM_STATE_DIR="$SECOND_STATE" "$AGENTTERMD" --port "$SECOND_PORT" --local-only --protocol-version 1 > "$SECOND_STATE/daemon.log" 2>&1 &
SECOND_DAEMON=$!
# SET-4: once the phone keeps the second Mac awake, that Mac goes out of
# reach, for the phone to show its settings as they were and not change them.
( while ! grep -q '"keepAwake":true' "$SECOND_STATE/settings.json" 2>/dev/null; do sleep 0.3; done; kill "$SECOND_DAEMON" ) &
GONE_WATCH=$!
TAKEOVER_PID=""
cleanup() {
    local status=$?
    stop_then_remove "$DAEMON $SECOND_DAEMON $GONE_WATCH $TAKEOVER_PID"
    # Whatever else is on the hosts' ports or runs from their folders (#221).
    stop_what_is_left "$PORT $SECOND_PORT" "$STATE" "$SECOND_STATE"
    stop_then_remove "" "$STATE" "$SECOND_STATE"
    exit "$status"
}
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] || { echo "test-ios.sh: the hosts did not start" >&2; cat "$STATE/daemon.log" "$SECOND_STATE/daemon.log" >&2; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl keychain "$DEVICE" reset
software_keyboard "$DEVICE"

# TEST_RUNNER_ variables are handed to the test process without the prefix.
XCODEBUILD=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
    -destination "platform=iOS Simulator,id=$DEVICE"
    -derivedDataPath .build/ios -skipPackagePluginValidation)

# Build first: a pairing link only lives five minutes, and a clean build can
# take longer than that.
if ! "${XCODEBUILD[@]}" build-for-testing > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: build failed, full log in $LOG" >&2
    exit 1
fi

export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$AGENTTERMD" pairing-link --port "$PORT" --host 127.0.0.1 --name "First Mac")"
export TEST_RUNNER_AGENTTERM_SECOND_PAIR_URL="$(AGENTTERM_STATE_DIR="$SECOND_STATE" "$AGENTTERMD" pairing-link --port "$SECOND_PORT" --host 127.0.0.1 --name "Second Mac")"
export TEST_RUNNER_AGENTTERM_LAUNCH="${AGENTTERM_LAUNCH:-Start Shell}"
export TEST_RUNNER_AGENTTERM_TEST_PROJECT=1
export TEST_RUNNER_AGENTTERM_EXPECT_HOST_DIED=1
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export TEST_RUNNER_AGENTTERM_SHOT_DIR="$SHOTS"; fi
# LANDSCAPE=only looks at the app with the phone on its side and nothing else.
if [ "${LANDSCAPE:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_LANDSCAPE=1; fi
# SCROLL=only measures how smoothly a long terminal scrolls, and nothing else.
if [ "${SCROLL:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_SCROLL=1; fi
# IDLE=only measures how long the steps around a session's menu wait for the
# app to be idle (#65), and nothing else. The figures are in the log.
if [ "${IDLE:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_IDLE=1; fi
# MENU=only counts how often a touch on an entry of a folder's menu is lost
# (#83), MENU_ROUNDS times (20 by default), and nothing else. The figures
# are in the log.
# MENU=after does the same where the whole test chooses it once, after
# everything before it.
if [ "${MENU:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_MENU=1; fi
if [ "${MENU:-}" = after ]; then export TEST_RUNNER_AGENTTERM_MENU_AFTER=1; fi
# MENU=terminal counts the same on the terminal's menu, with the keyboard up
# (MENU_KEYBOARD=down: with it down), and nothing else.
if [ "${MENU:-}" = terminal ]; then export TEST_RUNNER_AGENTTERM_ONLY_TERMINAL_MENU=1 TEST_RUNNER_AGENTTERM_MENU_KEYBOARD="${MENU_KEYBOARD:-up}"; fi
if [ -n "${MENU:-}" ]; then export TEST_RUNNER_AGENTTERM_MENU_ROUNDS="${MENU_ROUNDS:-20}"; fi
# MENU_HOLD=4 keeps the finger on the entry 4 seconds rather than tapping it.
if [ -n "${MENU_HOLD:-}" ]; then export TEST_RUNNER_AGENTTERM_MENU_HOLD="$MENU_HOLD"; fi
# TOUCHES=/some/file has the app write down every touch it receives (#83).
if [ -n "${TOUCHES:-}" ]; then export TEST_RUNNER_AGENTTERM_TOUCH_LOG="$TOUCHES"; fi
# INBOX=only checks the Inbox at the top of the Sessions list (INBOX-4), and
# nothing else.
if [ "${INBOX:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_INBOX=1; fi
# ASK=only writes a prompt in a stand-in Claude Code's session, answers the
# question it asks meanwhile from the place to answer, then sends the prompt
# (IOS-12), and nothing else. What the stand-in received is checked after.
if [ "${ASK:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_ASK=1; fi
# NOTE=only reads a stand-in agent's note on its row (IOS-9), and nothing else.
if [ "${NOTE:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_NOTE=1; fi
# NARROW=only narrows the iPad's window and looks at the list (IPAD-2), and
# nothing else. On an iPhone it checks nothing.
if [ "${NARROW:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_NARROW=1; fi
# MARKDOWN=only opens Markdown documents in their preview, scrolls the
# longest, and says how long the app's main thread was held up (PERF-16).
if [ "${MARKDOWN:-}" = only ]; then
    export TEST_RUNNER_AGENTTERM_ONLY_MARKDOWN=1 TEST_RUNNER_AGENTTERM_MEASURE_MAIN="$STATE/main-thread.txt"
fi
# NOTNOW=only answers Not Now on the first screen, pairs, and checks that
# iOS is not asked and the app's notifications are off (NOTIFY-2), and
# nothing else. The app is installed afresh for it, so that iOS was not
# asked before.
if [ "${NOTNOW:-}" = only ]; then
    export TEST_RUNNER_AGENTTERM_ONLY_NOT_NOW=1
    xcrun simctl uninstall "$DEVICE" com.manhpham.agentterm.dev || true
fi
# PAGES=only checks that a long session's earlier lines come a page at a time.
if [ "${PAGES:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_HISTORY=1; fi
# TAKEOVER=1 has something play the Mac: once the phone has a session open,
# it is taken at a Mac's size, with output to scroll through. TAKEOVER=only
# checks nothing else.
if [ -n "${TAKEOVER:-}" ]; then
    export TEST_RUNNER_AGENTTERM_EXPECT_MAC_TAKEOVER=1
    [ "$TAKEOVER" = only ] && export TEST_RUNNER_AGENTTERM_ONLY_MAC_TAKEOVER=1
    AGENTTERM_STATE_DIR="$STATE" "$AGENTTERMD" take-control --port "$PORT" --after 8 --hold 60 --type 'seq 1 400' > "$STATE/takeover.log" 2>&1 &
    TAKEOVER_PID=$!
fi

if "${XCODEBUILD[@]}" test-without-building > "$LOG" 2>&1; then
    # The test arranged the sessions; the host has to have kept that.
    if [ "${TAKEOVER:-}" = only ]; then echo "iOS UI test passed (Mac takeover only)."; rm -f "$LOG"; exit 0; fi
    if [ "${LANDSCAPE:-}" = only ]; then echo "iOS UI test passed (landscape only)."; rm -f "$LOG"; exit 0; fi
    if [ "${PAGES:-}" = only ]; then echo "iOS UI test passed (paged history only)."; rm -f "$LOG"; exit 0; fi
    if [ "${NOTNOW:-}" = only ]; then echo "iOS UI test passed (Not Now only)."; rm -f "$LOG"; exit 0; fi
    if [ "${IDLE:-}" = only ]; then grep -E "MEASURE idle" "$LOG" | sed 's/^.*MEASURE //' | cut -c1-200; echo "iOS UI test passed (idle waits measured)."; rm -f "$LOG"; exit 0; fi
    if [ "${NOTE:-}" = only ]; then echo "iOS UI test passed (a note read only)."; rm -f "$LOG"; exit 0; fi
    if [ "${INBOX:-}" = only ]; then echo "iOS UI test passed (the Inbox only)."; rm -f "$LOG"; exit 0; fi
    if [ "${ASK:-}" = only ]; then
        # IOS-12: the answer went in while the stand-in asked, as the keys of
        # its second choice; the prompt only after the question was over.
        INPUT="$FAKE_HOME/.demo-agent/claude-input"
        line() { { grep -nF -- "$1" "$INPUT" 2>/dev/null || true; } | head -1 | cut -d: -f1; }
        asked="$(line ASKED)"
        answered="$(line ANSWERED)"
        answer="$(line 'INPUT "\u001b[B\n"')"
        prompt="$(line 'add tests for the JSON parser first')"
        if [ -z "$asked" ] || [ -z "$answered" ] || [ -z "$answer" ] || [ -z "$prompt" ] \
            || [ "$answer" -le "$asked" ] || [ "$answer" -ge "$answered" ] || [ "$prompt" -le "$answered" ]; then
            echo "test-ios.sh: the prompt and the answer did not go where they were meant to; the stand-in received:" >&2
            cat "$INPUT" >&2 2>/dev/null || echo "(nothing)" >&2
            exit 1
        fi
        echo "iOS UI test passed (prompt and answer only)."; rm -f "$LOG"; exit 0
    fi
    if [ "${MARKDOWN:-}" = only ]; then grep -E "MEASURE markdown" "$LOG" | sed 's/^.*MEASURE //' | sort -u; echo "iOS UI test passed (Markdown measured only)."; rm -f "$LOG"; exit 0; fi
    if [ "${NARROW:-}" = only ]; then grep -E "MEASURE narrow" "$LOG" | sed 's/^.*MEASURE //'; echo "iOS UI test passed (the window narrowed only)."; rm -f "$LOG"; exit 0; fi
    if [ -n "${MENU:-}" ]; then grep -E "MEASURE menu" "$LOG" | sed 's/^.*MEASURE //' | cut -c1-200; echo "iOS UI test passed (menu touches counted)."; rm -f "$LOG"; exit 0; fi
    if [ "${SCROLL:-}" = only ]; then grep -E "Measured \[|average:" "$LOG" | cut -c1-300; echo "iOS UI test passed (scrolling measured)."; rm -f "$LOG"; exit 0; fi
    # TAB-6: the test pinned an agent's session that still runs.
    grep -q '"pinned":\["s:' "$STATE/tabs.json" || { echo "test-ios.sh: the host did not save the arrangement of the sessions" >&2; exit 1; }
    # The test committed and pushed from the phone; the remote has to have it.
    [ "$(git -C "$REMOTE" log -1 --format=%s main)" = "test: add a second line" ] || { echo "test-ios.sh: the push from the phone did not reach the remote" >&2; exit 1; }
    # A gesture that had to be made again (#83) is said, though the test passed.
    grep -E "MEASURE gesture" "$LOG" | sed 's/^.*MEASURE //' | cut -c1-200 || true
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test" "$LOG" | tail -3
    echo "iOS UI test passed."
    rm -f "$LOG"
else
    grep -E "error:|Test Case .* failed|XCTAssert|BUILD FAILED|TEST FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: failed, full log in $LOG" >&2
    exit 1
fi
