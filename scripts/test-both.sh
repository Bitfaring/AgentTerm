#!/usr/bin/env bash
# Runs the Mac app and the iPhone app together on one host, and checks that
# each shows what the other did: sessions, settings, the Git view, a commit,
# who is using a session, and the Mac's browser used from the phone.
#
#   ./scripts/test-both.sh                   # the simulator "iPhone Air"
#   ./scripts/test-both.sh "iPhone 17e"      # a simulator by name, or by UDID
#   SHOTS=/some/folder ./scripts/test-both.sh    # screenshots of both apps
#
# It goes in three parts: the Mac app does things, the iPhone app finds them
# and does its own, the Mac app finds those. The Mac app is driven through
# accessibility, so the terminal this runs in has to be allowed under System
# Settings > Privacy & Security > Accessibility. Nothing of the installed
# apps is touched: the host, its port, its state, the home folder and the Mac
# app's preferences are the test's own. The keychain of the simulator the
# test runs in is reset, so anything paired in that simulator has to pair again.
set -euo pipefail

cd "$(dirname "$0")/.."
# None of the installed app's variables reaches the tests (#207).
source scripts/lib-own-environment.sh
own_environment
command -v xcodegen >/dev/null || { echo "test-both.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
source scripts/lib-simulator.sh
source scripts/lib-cleanup.sh
source scripts/lib-test-log.sh
# It resets the simulator's keychain: never the booted one by default (#311).
choose_test_simulator "${1:-}"
DEVICE="$SIM_UDID"
echo "Testing on this Mac and on $SIM_NAME ($SIM_UDID)."
PORT=7795
# The proxy the iPhone reaches the host through (#198).
PROXY_PORT=$((PORT + 1))
ports_must_be_free "$PORT" "$PROXY_PORT"
ROOT="$(mktemp -d)"
STATE="$ROOT/state"
PROJECT="$ROOT/project"
FAKE_HOME="$ROOT/home"
AGENTS="$ROOT/agents"
LOG="$(mktemp)"
# The Mac app as a bundle, with its browser (#76), under an identifier of
# its own: its preferences are not those of an AgentTerm the user runs.
IDENTIFIER=com.manhpham.agentterm.both
mkdir -p "$STATE" "$PROJECT/docs" "$FAKE_HOME" "$AGENTS" "$ROOT/site"

swift build --build-tests
BIN="$(swift build --show-bin-path)"
IDENTIFIER="$IDENTIFIER" OUT="$ROOT/app" CONFIG=debug CHANNEL=dev ./scripts/bundle-mac.sh > "$LOG" 2>&1 || { tail -20 "$LOG" >&2; echo "test-both.sh: the Mac app did not build" >&2; exit 1; }
MAC_APP="$ROOT/app/AgentTerm Dev.app/Contents/MacOS/AgentTerm"

# A project with a remote and changes that are not committed yet.
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name t
git -C "$PROJECT" config user.email t@example.com
git -C "$PROJECT" config commit.gpgsign false
printf 'first line\n' > "$PROJECT/notes.txt"
git -C "$PROJECT" add . && git -C "$PROJECT" commit -q -m init
git init -q --bare -b main "$ROOT/remote.git"
git -C "$PROJECT" remote add origin "$ROOT/remote.git"
git -C "$PROJECT" push -q -u origin main
printf 'first line\nsecond line\n' > "$PROJECT/notes.txt"
printf '# Guide\n' > "$PROJECT/docs/guide.md"
printf '["%s"]' "$PROJECT" > "$STATE/folders.json"
# Stand-ins for the agents: the installed ones are signed in to someone's
# accounts. Claude's says how to reach AgentTerm's MCP server, for the Mac's
# part to drive the browser and shells as that agent.
printf '#!/bin/sh\nprintf "%%s" "$AGENTTERM_MCP" > "%s"\necho "stand-in claude started: $*"\nexec cat\n' "$ROOT/agent-variable" > "$AGENTS/claude"
printf '#!/bin/sh\necho "stand-in codex started: $*"\nexec cat\n' > "$AGENTS/codex"
chmod +x "$AGENTS/claude" "$AGENTS/codex"
# A page whose one field fills it; what is typed in it is its title.
cat > "$ROOT/site/page.html" <<'HTML'
<!doctype html>
<html><head><title>Cross page</title></head>
<body style="margin:0"><input id="field" aria-label="Field" style="position:fixed;inset:0;width:100%;height:100%;font-size:48px" oninput="document.title = 'typed ' + this.value"></body></html>
HTML

HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" "$BIN/agenttermd" --port "$PORT" --local-only --no-account-usage --home "$FAKE_HOME" --agents "$AGENTS" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
MAC=""
PROXY=""
cleanup() {
    local status=$?
    # The app first, and gone before its host is stopped: an app that
    # loses its host starts the one in its bundle (#221).
    stop_then_remove "$MAC"
    stop_then_remove "$PROXY $DAEMON"
    stop_what_is_left "$PORT $PROXY_PORT" "$ROOT"
    stop_then_remove "" "$ROOT"
    defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] || { echo "test-both.sh: the host did not start" >&2; cat "$STATE/daemon.log" >&2; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl keychain "$DEVICE" reset
software_keyboard "$DEVICE"
XCODEBUILD=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
    -destination "platform=iOS Simulator,id=$DEVICE"
    -derivedDataPath .build/ios -skipPackagePluginValidation)
if ! "${XCODEBUILD[@]}" build-for-testing > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-both.sh: build failed, full log in $LOG" >&2
    exit 1
fi

# The Mac app, starting from no preferences. A host it would start by itself
# listens on 127.0.0.1 only, as the script's own does (#221).
defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" AGENTTERM_PORT="$PORT" CFFIXED_USER_HOME="$FAKE_HOME" AGENTTERM_NO_SYSTEM_NOTIFICATIONS=1 AGENTTERM_LOCAL_ONLY=1 "$MAC_APP" > "$STATE/mac.log" 2>&1 &
MAC=$!

export AGENTTERM_CROSS_PID="$MAC" AGENTTERM_CROSS_PROJECT="$PROJECT" AGENTTERM_CROSS_APP="AgentTerm Dev"
export AGENTTERM_CROSS_TOOL="$BIN/agenttermd" AGENTTERM_CROSS_STATE="$STATE" AGENTTERM_CROSS_AGENT_VARIABLE="$ROOT/agent-variable"
export AGENTTERM_CROSS_PAGE="file://$ROOT/site/page.html" TEST_RUNNER_AGENTTERM_PAGE_URL="file://$ROOT/site/page.html"
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export AGENTTERM_SHOT_DIR="$SHOTS" TEST_RUNNER_AGENTTERM_SHOT_DIR="$SHOTS"; fi

part() {
    # $1: what it is called, the rest: the command. Its log is shown only when it fails.
    local name="$1"
    shift
    if "$@" > "$LOG" 2>&1; then
        # A part whose tests all skipped themselves checked nothing (#309).
        if why="$(nothing_checked "$LOG")"; then
            tail -3 "$LOG" >&2
            echo "test-both.sh: nothing was checked in: $name: $why. Full log in $LOG" >&2
            exit 1
        fi
        echo "  passed: $name"
    else
        grep -E "error:|Test Case .* failed|XCTAssert|TEST FAILED" "$LOG" | cut -c1-700 >&2
        echo "test-both.sh: failed in: $name. Full log in $LOG" >&2
        exit 1
    fi
}

part "the Mac app first" swift test --skip-build --filter "AgentTermMacUITests.CrossTests/testPart1"

# The iPhone reaches the host through a proxy the test can tell to hold
# what the host sends, and to close the connection (#198).
mkdir -p "$ROOT/proxy"
python3 scripts/hold-proxy.py "$PROXY_PORT" "$PORT" "$ROOT/proxy" > "$STATE/proxy.log" 2>&1 &
PROXY=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && break; sleep 0.1; done
export TEST_RUNNER_AGENTTERM_PROXY_DIR="$ROOT/proxy"
export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$BIN/agenttermd" pairing-link --port "$PROXY_PORT" --host 127.0.0.1 --name "First Mac")"
export TEST_RUNNER_AGENTTERM_LAUNCH="Start Shell"
export TEST_RUNNER_AGENTTERM_WITH_MAC=1
part "the iPhone app, finding what the Mac did" "${XCODEBUILD[@]}" test-without-building -only-testing:AgentTermUITests/CrossTests

part "the Mac app, finding what the iPhone did" swift test --skip-build --filter "AgentTermMacUITests.CrossTests/testPart2"

echo "Both apps passed."
rm -f "$LOG"
