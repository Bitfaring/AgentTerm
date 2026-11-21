# Sourced by the test scripts first (#207): takes every AGENTTERM_ variable
# out of their environment but the settings named, which the person running
# them may give.
#
#   own_environment [SETTING...]
#
# Run from a session of the installed AgentTerm, a script has that
# session's own variables (its hooks' file, its status line's, its MCP
# server's key). Kept, they reached the tests' hosts, apps and sessions,
# which could then report to the installed host or use its key. What the
# tests are given of AgentTerm's is what the script sets after this.

own_environment() {
    local name keep=" $* "
    for name in $(compgen -e); do
        case "$name" in
            AGENTTERM_*) case "$keep" in *" $name "*) ;; *) unset "$name" ;; esac ;;
        esac
    done
}
