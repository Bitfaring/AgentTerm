# Rule 3. Nothing of the user's is touched while testing

Part of the rules in [`CLAUDE.md`](../../CLAUDE.md), which says when this file is read.

- Hosts and apps run for a test use a state folder (`AGENTTERM_STATE_DIR`), a port (`AGENTTERM_PORT`) and a home folder of their own, never `~/Library/Application Support/AgentTerm` or the installed app's port.
- An app's preferences are kept under its bundle identifier, whatever home folder it is given. A copy of the app built for a test gets an identifier of its own (`IDENTIFIER=... scripts/bundle-mac.sh`), and is never built into `dist/`, where a copy may be running.
- What a test throws away goes to a folder of its own (`AGENTTERM_TRASH_DIR`), never into the user's Trash.
- The iPhone tests reset the keychain of the simulator they run in: use "iPhone Air", not a simulator an app is paired in.
- No pairing code, token or other secret is printed.
