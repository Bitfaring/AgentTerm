#!/usr/bin/env bash
# Runs the Mac app's UI tests: the app is started against a host of its own,
# with stand-in agents, and driven through accessibility.
#
#   ./scripts/test-mac.sh                # all of them
#   ./scripts/test-mac.sh GitTests       # one class, or any name `swift test --filter` takes
#   SHOTS=/some/folder ./scripts/test-mac.sh   # a picture of the window for each test that fails
#   SHOTS=/some/folder ALL_SHOTS=1 ./scripts/test-mac.sh   # one for each test, at its end
#
# The terminal this runs in has to be allowed under System Settings >
# Privacy & Security > Accessibility. No pointer is moved and no key is sent:
# the tests press and read the app's own elements, as VoiceOver does.
# Nothing of the installed app is touched: the host, its port, its state,
# the home folder and the app's preferences are all the tests' own.
set -euo pipefail

cd "$(dirname "$0")/.."
# Chromium first, so that the first build already has it (#181).
./scripts/fetch-cef.sh
swift build --build-tests
export AGENTTERM_MAC_UI=1
# The browser's tests (#76) need the app bundle, where Chromium runs: built
# here, never into dist/ where a copy may be running, under an identifier
# of its own so that its preferences are the tests' only.
# Always: a filter that names one of its tests by itself would skip it.
TEST_BUNDLE_DIR="$PWD/.build/uitest-app"
CONFIG=debug OUT="$TEST_BUNDLE_DIR" IDENTIFIER=com.manhpham.agentterm.uitest ./scripts/bundle-mac.sh > /dev/null
export AGENTTERM_TEST_BUNDLE="$TEST_BUNDLE_DIR/AgentTerm Dev.app"
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export AGENTTERM_SHOT_DIR="$SHOTS"; fi
if [ -n "${ALL_SHOTS:-}" ]; then export AGENTTERM_SHOT_ALWAYS=1; fi
# MEASURE=1 runs the measurements of the app's main thread (#21), which the
# tests otherwise skip, and prints their figures: nothing fails on a figure.
if [ -n "${MEASURE:-}" ]; then export AGENTTERM_MEASURE_UI=1; fi
FILTER="AgentTermMacUITests"
if [ -n "${1:-}" ]; then FILTER="AgentTermMacUITests\..*$1"; fi
# The half of the test with the iPhone app is run by test-both.sh.
LOG="$(mktemp)"
# Stopped in the middle, by Control-C or by `kill`, the run ends what its
# tests started, apps and hosts included: left behind, the app bundled for
# the tests and its host kept a test's port, which a later run then met
# (#179). Run in the background and waited for, so that the signal is
# taken at once, not when the tests are over.
source scripts/lib-cleanup.sh
TESTS=""
stop_the_tests() {
    trap - INT TERM
    if [ -n "$TESTS" ]; then
        # Every one of them: an app does not end with the test that
        # started it, nor a host with its app.
        local all alive="" pid
        all="$TESTS $(descendants_of "$TESTS" | tr '\n' ' ')"
        kill $all 2>/dev/null || true
        for _ in $(seq 1 50); do
            alive=""
            for pid in $all; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
            [ -z "$alive" ] && break
            sleep 0.1
        done
        [ -n "$alive" ] && kill -9 $alive 2>/dev/null
    fi
    echo "test-mac.sh: stopped; what the tests started was ended. Log in $LOG" >&2
    exit 130
}
trap stop_the_tests INT TERM
swift test --skip-build --filter "$FILTER" --skip "CrossTests" > "$LOG" 2>&1 &
TESTS=$!
if wait "$TESTS"; then
    # A name that matches no test runs none, which `swift test` takes for a
    # pass: it is not one, and is said (#137).
    if ! grep -qE "Executed [1-9][0-9]* test" "$LOG"; then
        tail -3 "$LOG" >&2
        echo "test-mac.sh: no test was run, full log in $LOG" >&2
        exit 1
    fi
    grep -E "^MEASURE " "$LOG" | sed 's/^MEASURE //' || true
    grep -E "Test Case .* (passed|skipped)|Executed [1-9][0-9]* test" "$LOG" | sed 's/^Test Case .-\[AgentTermMacUITests\.//; s/\]. / /' | uniq
    echo "Mac UI tests passed."
    rm -f "$LOG"
else
    # Nothing of the kind when the run ended some other way: what it said
    # last is given instead, and the log is named all the same.
    grep -E "error:|Test Case .* failed" "$LOG" | cut -c1-600 >&2 || tail -3 "$LOG" >&2
    echo "test-mac.sh: failed, full log in $LOG" >&2
    exit 1
fi
