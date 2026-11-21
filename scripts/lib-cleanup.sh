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

# What follows is #221's. A Mac app that loses its host starts the one in
# its own bundle, in a session of its own: stopped at the same moment as the
# script's host, an app that had not ended yet did so, and that host went on
# listening on the script's port after a run that had passed. The next run
# then failed inside a test. So a script asks for its ports before it starts
# anything, stops its app before its host, and at its end stops whatever of
# its own is still running, whoever started it.
#
#   ports_must_be_free <port>...
#   stop_what_is_left "<ports>" <folder>...
#
# A program is the script's own in two ways only, and in no other: the file
# it was started from is inside one of the script's own folders, or it is an
# `agenttermd` that listens on one of the script's own ports. Nothing is
# told apart by its name alone: an AgentTerm the user runs, from
# /Applications or from dist/, on its own port, is never one of them.

# The pids that listen on a TCP port of this Mac.
listeners_on() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | sort -u || true
}

# Stops the script, before it has started anything, when one of its ports is
# taken: with the port and the program that holds it.
ports_must_be_free() {
    local port pid path taken=""
    for port in "$@"; do
        for pid in $(listeners_on "$port"); do
            path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
            echo "$(basename "$0"): port $port is taken by ${path:-a program} (pid $pid). Stop it (kill $pid), then run this again." >&2
            taken="$taken $port"
        done
        case " $taken " in
            *" $port "*) ;;
            *)
                # Held by a program this user may not look at.
                if nc -z 127.0.0.1 "$port" 2>/dev/null; then
                    echo "$(basename "$0"): port $port is taken by a program that could not be named. Stop it, then run this again." >&2
                    taken="$taken $port"
                fi
                ;;
        esac
    done
    [ -z "$taken" ] || exit 1
}

# The script's own programs that run, a line each: "<pid> <path>".
running_of_ours() {
    local ports="$1" pid path folder real port
    shift
    # A folder is looked for as it was given and as it really is: a
    # temporary folder's path has a symbolic link in it.
    local folders=()
    for folder in "$@"; do
        [ -n "$folder" ] && [ "$folder" != / ] || continue
        folders+=("${folder%/}")
        real="$(cd "$folder" 2>/dev/null && pwd -P || true)"
        if [ -n "$real" ] && [ "$real" != / ] && [ "$real" != "${folder%/}" ]; then folders+=("$real"); fi
    done
    {
        if [ "${#folders[@]}" -gt 0 ]; then
            ps -xo pid=,comm= 2>/dev/null | while read -r pid path; do
                for folder in "${folders[@]}"; do
                    case "$path" in "$folder"/*) echo "$pid $path"; break ;; esac
                done
            done
        fi
        for port in $ports; do
            for pid in $(listeners_on "$port"); do
                path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
                if [ "${path##*/}" = agenttermd ]; then echo "$pid $path"; fi
            done
        done
    } | sort -u || true
}

# Stops them, and says which they were. Called while the folders are still
# there, before they are removed.
stop_what_is_left() {
    local left pid
    left="$(running_of_ours "$@")" || true
    [ -n "$left" ] || return 0
    echo "$(basename "$0"): still running at the end, now stopped:" >&2
    echo "$left" | cut -c1-300 | sed 's/^/  /' >&2
    for pid in $(echo "$left" | cut -d' ' -f1); do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 50); do
        left="$(running_of_ours "$@")" || true
        [ -n "$left" ] || return 0
        sleep 0.1
    done
    for pid in $(echo "$left" | cut -d' ' -f1); do kill -9 "$pid" 2>/dev/null || true; done
    return 0
}
