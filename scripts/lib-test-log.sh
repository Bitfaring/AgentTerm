#!/bin/bash
# What a test run's log says was checked, for the test scripts (#137, #309).
#
# `swift test` and `xcodebuild test` end with a status of 0 when every test
# was skipped, or when a filter matched none: neither is a pass. A test that
# was skipped because this terminal may not use Accessibility skips every UI
# test after it the same way, so one of those is not a pass either.
#
# Sourced by test-mac.sh, test-both.sh and screenshots.sh.

# Prints why nothing in the log was checked and returns 0, or returns 1 when
# something was. $1: the log.
nothing_checked() {
    local log="$1" total executed skipped
    if grep -q "Test skipped - allow this terminal under System Settings > Privacy & Security > Accessibility" "$log"; then
        echo "this terminal may not use Accessibility, so the UI tests skipped themselves: allow it under System Settings > Privacy & Security > Accessibility"
        return 0
    fi
    # XCTest prints a count for each suite. `swift test` runs each test
    # bundle on its own, each ending with the count of its `.xctest` suite:
    # those are added up. `xcodebuild` and a single bundle end the same way.
    local counts
    counts="$(awk '
        /^Test Suite .*\.xctest. (passed|failed)/ { bundle = 1; next }
        bundle && /Executed [0-9]+ tests?, with / {
            line = $0
            sub(/.*Executed /, "", line); split(line, n, " "); executed += n[1]
            if ($0 ~ /tests? skipped/) { line = $0; sub(/.*, with /, "", line); split(line, s, " "); skipped += s[1] }
            bundle = 0
        }
        END { printf "%d %d", executed, skipped }' "$log")"
    executed="${counts% *}"
    skipped="${counts#* }"
    if [ "$executed" -eq 0 ]; then
        echo "no test was run"
        return 0
    fi
    if [ "$skipped" -ge "$executed" ]; then
        echo "every test that was run skipped itself ($skipped of $executed)"
        return 0
    fi
    return 1
}
