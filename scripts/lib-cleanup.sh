# Sourced by the test scripts: stops what they started, and removes their
# folders once it is gone (#98).
#
#   stop_then_remove "<pids>" <folder>...
#
# A host stopped with SIGTERM ends its sessions, whose shells go on for a
# moment after it is gone: zsh writes its history into the test's home
# folder as it ends. Removing the folder then failed with "Directory not
# empty", and as the last thing a script did, that made a script whose tests
# had passed exit with 1. So the programs and every program they started are
# waited for before the folders are removed. What cannot be removed is said,
# and does not change the script's result.

descendants_of() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants_of "$child"
    done
}

stop_then_remove() {
    local pids="$1" all pid alive=""
    shift
    all="$pids"
    # Found before they are stopped: once their parent is gone, they are
    # nobody's children any more.
    for pid in $pids; do all="$all $(descendants_of "$pid" | tr '\n' ' ')"; done
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 100); do
        alive=""
        for pid in $all; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
        [ -z "$alive" ] && break
        sleep 0.1
    done
    [ $# -eq 0 ] && return 0
    rm -rf "$@" 2>/dev/null || echo "$(basename "$0"): could not remove $*${alive:+; still running:$alive}" >&2
    return 0
}
