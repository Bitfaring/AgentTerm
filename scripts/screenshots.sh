#!/usr/bin/env bash
# Takes the pictures of both apps again: the three of the Mac app in
# docs/screenshots (the README and the product page show them), and the six
# of the iPhone app, on an iPhone and on an iPad (#88), in
# fastlane/screenshots/en-US, the iPad's named ipad-*.png (the App Store,
# which `make store-screenshots` sends them to, and the product page).
#
#   ./scripts/screenshots.sh                  # all, the iPhone's on "iPhone Air", the iPad's on "iPad Pro 13-inch (M5)"
#   ./scripts/screenshots.sh "iPhone Air"     # the iPhone's simulator by name, or by UDID
#   IPAD="iPad Pro 13-inch (M5)" ./scripts/screenshots.sh  # the iPad's
#   ONLY=mac ./scripts/screenshots.sh         # only the Mac's
#   ONLY=ios ./scripts/screenshots.sh         # only the iPhone app's, on the iPhone and the iPad
#   ONLY=iphone or ONLY=ipad                  # only those of one of them
#   KEEP=/some/folder ./scripts/screenshots.sh  # put them there instead, to look at first
#
# What they show is made up here and the same every time: a small project
# with changes, a second folder, and stand-in agents (scripts/demo-agent.py)
# that draw an agent's screen and report usage without any account. Nothing
# of the installed apps is touched: the app is built into a folder of its
# own, and the host, its port, its state, the home folder and the app's
# preferences are this script's. The Mac app is driven through accessibility,
# so the terminal this runs in has to be allowed under System Settings >
# Privacy & Security > Accessibility. The keychain of the simulator is reset,
# so anything paired in that simulator has to pair again.
#
# The App Store wants the iPhone's pictures at 1260 x 2736, which is the
# iPhone Air: another simulator gives pictures the store does not take. The
# iPad's it wants at 13 inches, 2064 x 2752, the iPad Pro 13-inch's; fastlane
# tells the two apart by their size.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib-cleanup.sh
ONLY="${ONLY:-both}"
DO_MAC=yes DO_IPHONE=yes DO_IPAD=yes
case "$ONLY" in
    both) ;;
    mac) DO_IPHONE="" DO_IPAD="" ;;
    ios) DO_MAC="" ;;
    iphone) DO_MAC="" DO_IPAD="" ;;
    ipad) DO_MAC="" DO_IPHONE="" ;;
    *) echo "screenshots.sh: ONLY is mac, ios, iphone or ipad" >&2; exit 2 ;;
esac
PORT=7790
# The demo project's page, as a development server serves it, which the
# agent opens in AgentTerm's browser.
WEB_PORT=7791
# Not in the temporary folder: its path has a symbolic link in it, and a
# file is shown by its place in the project, which it is not found to be in
# when the two are named differently.
ROOT="$PWD/.build/screenshots"
rm -rf "$ROOT"
STATE="$ROOT/state"
FAKE_HOME="$ROOT/home"
AGENTS="$ROOT/agents"
PROJECT="$ROOT/my-app"
WEBSITE="$ROOT/website"
SHOTS="$ROOT/shots"
LOG="$(mktemp)"
# The app's preferences are kept under its identifier, so it gets one of
# its own: with the development app's it would read and write that app's.
IDENTIFIER=com.manhpham.agentterm.screenshots
defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
mkdir -p "$STATE" "$FAKE_HOME" "$AGENTS" "$PROJECT/src" "$PROJECT/docs" "$WEBSITE" "$SHOTS/mac" "$SHOTS/ios" "$SHOTS/ipad"

DEVICE="" IPAD_DEVICE=""
if [ -n "$DO_IPHONE$DO_IPAD" ]; then
    command -v xcodegen >/dev/null || { echo "screenshots.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
    source scripts/lib-simulator.sh
fi
if [ -n "$DO_IPHONE" ]; then
    choose_simulator "${1:-iPhone Air}" "iPhone Air"
    DEVICE="$SIM_UDID"
    echo "The iPhone's pictures are taken on $SIM_NAME ($SIM_UDID)."
fi
if [ -n "$DO_IPAD" ]; then
    choose_simulator "${IPAD:-iPad Pro 13-inch (M5)}" "iPad Pro 13-inch (M5)"
    IPAD_DEVICE="$SIM_UDID"
    echo "The iPad's pictures are taken on $SIM_NAME ($SIM_UDID)."
fi

# The demo project: one change staged, one file changed, one new.
# A prompt of the demo's own, not the name of the Mac taking the pictures.
echo "PROMPT='%1~ %# '" > "$FAKE_HOME/.zshrc"

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name demo
git -C "$PROJECT" config user.email demo@example.com
git -C "$PROJECT" config commit.gpgsign false
cat > "$PROJECT/src/Parser.swift" <<'SWIFT'
import Foundation

struct Parser {
    func parse(_ text: String) -> [String] {
        text.split(separator: ",").map(String.init)
    }
}
SWIFT
printf '# my-app\n\nA small demo project.\n\n## Usage\n\nRun `swift run`.\n' > "$PROJECT/README.md"
printf '# Notes\n\nWhat the parser does not do yet.\n' > "$PROJECT/docs/notes.md"
# The page the agent opens in AgentTerm's browser for the pictures, with the
# project from the start, so that it is not among its changes.
cat > "$PROJECT/docs/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Parser playground</title>
<style>
  body { font: 15px -apple-system, system-ui, sans-serif; margin: 0; background: #f6f7fb; color: #1d2433; }
  header { background: #2f5bea; color: white; padding: 22px 28px; }
  header h1 { margin: 0; font-size: 22px; }
  header p { margin: 6px 0 0; opacity: .85; }
  main { padding: 24px 28px; }
  label { font-weight: 600; display: block; margin-bottom: 8px; }
  input { font: 15px ui-monospace, Menlo, monospace; width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #c9cfdc; border-radius: 8px; }
  table { border-collapse: collapse; margin-top: 18px; width: 100%; background: white; border-radius: 8px; overflow: hidden; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #e6e9f0; }
  th { background: #eef1f8; font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: #5a6478; }
  td code { font: 14px ui-monospace, Menlo, monospace; }
  .ok { color: #1a7f4b; font-weight: 600; }
</style></head>
<body>
<header><h1>Parser playground</h1><p>Split a line on commas and see the fields it gives.</p></header>
<main>
  <label for="line">Line</label>
  <input id="line" value="  a, b ,c ,, d ">
  <table><thead><tr><th>#</th><th>Field</th><th>Trimmed</th></tr></thead>
  <tbody id="fields"></tbody></table>
</main>
<script>
  const line = document.getElementById('line'), fields = document.getElementById('fields');
  function show() {
    fields.innerHTML = line.value.split(',').filter(f => f.length).map((f, i) =>
      `<tr><td>${i + 1}</td><td><code>"${f}"</code></td><td class="ok"><code>"${f.trim()}"</code></td></tr>`).join('');
  }
  line.addEventListener('input', show); show();
</script>
</body></html>
HTML
git -C "$PROJECT" add . && git -C "$PROJECT" commit -q -m init
cat > "$PROJECT/src/Parser.swift" <<'SWIFT'
import Foundation

struct Parser {
    /// Splits a line on commas, trimming the spaces around each field.
    func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
SWIFT
git -C "$PROJECT" add src/Parser.swift
cat > "$PROJECT/src/ParserTests.swift" <<'SWIFT'
import XCTest

final class ParserTests: XCTestCase {
    func testFieldsAreTrimmed() {
        XCTAssertEqual(Parser().parse("a, b ,c"), ["a", "b", "c"])
    }
}
SWIFT
cat >> "$PROJECT/README.md" <<'MARKDOWN'

## How it works

```mermaid
flowchart LR
    A[Input line] --> B(Parser)
    B --> C[Fields]
    C --> D{Empty?}
    D -- no --> E[Trim spaces]
    D -- yes --> F[Drop]
```

| File | What |
|---|---|
| `src/Parser.swift` | splits a line into fields |
| `src/ParserTests.swift` | its tests |
MARKDOWN
git -C "$WEBSITE" init -q -b main
printf '["%s","%s"]' "$PROJECT" "$WEBSITE" > "$STATE/folders.json"
for agent in claude codex agy copilot; do cp scripts/demo-agent.py "$AGENTS/$agent"; chmod +x "$AGENTS/$agent"; done

# The app as it is released, but for its name: built into a folder of its
# own, since dist may hold a copy that is running.
IDENTIFIER="$IDENTIFIER" OUT="$ROOT/app" CONFIG=debug CHANNEL=dev ./scripts/bundle-mac.sh > "$LOG" 2>&1 || { tail -20 "$LOG" >&2; echo "screenshots.sh: the app did not build" >&2; exit 1; }
APP="$ROOT/app/AgentTerm Dev.app/Contents/MacOS"
swift build --build-tests > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | cut -c1-300 >&2; echo "screenshots.sh: the tests did not build" >&2; exit 1; }

HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" AGENTTERM_DEMO_TOOL="$APP/agenttermd" "$APP/agenttermd" --port "$PORT" --local-only --no-account-usage --home "$FAKE_HOME" --agents "$AGENTS" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 --directory "$PROJECT/docs" > /dev/null 2>&1 &
WEB=$!
MAC=""
cleanup() {
    local status=$?
    stop_then_remove "$MAC $DAEMON $WEB" "$ROOT"
    defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
    [ -n "${DEVICE:-}" ] && xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true
    [ -n "${IPAD_DEVICE:-}" ] && xcrun simctl status_bar "$IPAD_DEVICE" clear 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] || { echo "screenshots.sh: the host did not start" >&2; cat "$STATE/daemon.log" >&2; exit 1; }
sleep 0.5

export AGENTTERM_SHOTS_PORT="$PORT" AGENTTERM_SHOTS_TOKEN="$STATE/token" AGENTTERM_SHOTS_OUT="$SHOTS/mac"
export AGENTTERM_SHOTS_PROJECT="$PROJECT" AGENTTERM_SHOTS_WEBSITE="$WEBSITE" AGENTTERM_SHOTS_HOME="$FAKE_HOME"
# For the agent's MCP server, which the pictures of its area drive.
export AGENTTERM_SHOTS_TOOL="$APP/agenttermd" AGENTTERM_SHOTS_STATE="$STATE" AGENTTERM_SHOTS_PAGE="http://localhost:$WEB_PORT/"

part() {
    local name="$1"
    shift
    if "$@" > "$LOG" 2>&1; then
        echo "  done: $name"
    else
        grep -E "error:|Test Case .* failed|XCTAssert|TEST FAILED" "$LOG" | cut -c1-900 >&2
        echo "screenshots.sh: failed in: $name. Full log in $LOG" >&2
        exit 1
    fi
}

if [ -n "$DO_MAC" ]; then
    HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" AGENTTERM_PORT="$PORT" CFFIXED_USER_HOME="$FAKE_HOME" "$APP/AgentTerm" > "$STATE/mac.log" 2>&1 &
    MAC=$!
    AGENTTERM_SHOTS_PID="$MAC" part "the Mac app's pictures" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart1"
    kill "$MAC" 2>/dev/null || true
    MAC=""
    sleep 1
else
    # The session the Mac's part would have left.
    export AGENTTERM_SHOTS_FIRST=1
fi

# The iPhone app's pictures on one simulator: paired with the host by a
# link of its own (a pairing code is good once), into a folder.
pictures_on() {
    local device="$1" what="$2" into="$3"
    xcrun simctl bootstatus "$device" -b >/dev/null
    xcrun simctl keychain "$device" reset
    software_keyboard "$device"
    # Named as the store names it: the iPad shows the app's name in its
    # status bar. Its identifier stays the development build's.
    local xcodebuild=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
        -destination "platform=iOS Simulator,id=$device"
        -derivedDataPath .build/ios -skipPackagePluginValidation APP_DISPLAY_NAME=AgentTerm)
    part "building the app for the $what" "${xcodebuild[@]}" build-for-testing
    # The status bar the App Store's pictures have.
    xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$APP/agenttermd" pairing-link --port "$PORT" --host 127.0.0.1 --name "MacBook Pro")"
    export TEST_RUNNER_AGENTTERM_SCREENSHOTS=1 TEST_RUNNER_AGENTTERM_SHOT_DIR="$into"
    # Nothing on the simulator's pasteboard (#143): the Simulator copies the
    # Mac's there, and the keyboard offers to paste it, in the picture, with
    # what the user last copied. The simulator's own is emptied, the Mac's
    # is not touched. One copied on the Mac while the pictures are taken
    # comes back: they are looked at before they are committed.
    xcrun simctl pbcopy "$device" < /dev/null
    part "the $what's pictures" "${xcodebuild[@]}" test-without-building -only-testing:AgentTermUITests/ScreenshotTests/testThePictures
}

# The agent's page, live, on one simulator paired above: the Mac app shows
# the browser, and is running again by then.
page_on() {
    local device="$1" what="$2" into="$3" shown_as="$4"
    local xcodebuild=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
        -destination "platform=iOS Simulator,id=$device"
        -derivedDataPath .build/ios -skipPackagePluginValidation APP_DISPLAY_NAME=AgentTerm)
    part "building the app for the $what" "${xcodebuild[@]}" build-for-testing
    xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$APP/agenttermd" pairing-link --port "$PORT" --host 127.0.0.1 --name "MacBook Pro")"
    export TEST_RUNNER_AGENTTERM_SCREENSHOTS=1 TEST_RUNNER_AGENTTERM_SHOT_DIR="$into"
    # Shown as that device: laid out for its screen, and as sharp.
    AGENTTERM_SHOTS_DEVICE="$shown_as" part "the agent's page shown as an $what" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart4"
    part "the $what's picture of the agent's page" "${xcodebuild[@]}" test-without-building -only-testing:AgentTermUITests/ScreenshotTests/testTheAgentsPage
}

if [ -n "$DO_IPHONE$DO_IPAD" ]; then
    part "the sessions for the iPhone and the iPad" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart2"
    (cd iOS && xcodegen generate --quiet)
    [ -z "$DO_IPHONE" ] || pictures_on "$DEVICE" "iPhone" "$SHOTS/ios"
    [ -z "$DO_IPAD" ] || pictures_on "$IPAD_DEVICE" "iPad" "$SHOTS/ipad"
    # Started again once the terminals' pictures are taken, so that no
    # session was at the Mac's size for them; the agent opens its page.
    HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" AGENTTERM_PORT="$PORT" CFFIXED_USER_HOME="$FAKE_HOME" "$APP/AgentTerm" > "$STATE/mac.log" 2>&1 &
    MAC=$!
    part "the agent's page" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart3"
    [ -z "$DO_IPHONE" ] || page_on "$DEVICE" "iPhone" "$SHOTS/ios" "iPhone 16 Pro Max"
    [ -z "$DO_IPAD" ] || page_on "$IPAD_DEVICE" "iPad" "$SHOTS/ipad" "iPad Pro 13"
    kill "$MAC" 2>/dev/null || true
    MAC=""
fi

MAC_OUT="${KEEP:+$KEEP/mac}"
IOS_OUT="${KEEP:+$KEEP/ios}"
MAC_OUT="${MAC_OUT:-docs/screenshots}"
IOS_OUT="${IOS_OUT:-fastlane/screenshots/en-US}"
mkdir -p "$MAC_OUT" "$IOS_OUT"
[ -z "$DO_MAC" ] || cp "$SHOTS/mac/"*.png "$MAC_OUT/"
[ -z "$DO_IPHONE" ] || cp "$SHOTS/ios/"*.png "$IOS_OUT/"
# Beside the iPhone's, in the folder fastlane sends: it tells them apart
# by their size, and puts each device's in the order of their names.
if [ -n "$DO_IPAD" ]; then
    for picture in "$SHOTS/ipad/"*.png; do cp "$picture" "$IOS_OUT/ipad-$(basename "$picture")"; done
fi
echo "The pictures are in ${KEEP:-docs/screenshots and fastlane/screenshots/en-US}. Look at them before they are committed."
rm -f "$LOG"
