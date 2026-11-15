#!/usr/bin/env bash
# Which entitlements each helper app of the browser (#76) is signed with,
# for scripts/bundle-mac.sh and the release lane alike:
#
#   ./scripts/browser-helpers.sh entitlements "AgentTerm Helper (GPU).app"
#
# Chromium's pages run JavaScript compiled as they go, which the hardened
# runtime refuses without allow-jit: the renderer, the GPU process (its
# software renderer) and the plain helper (the proxy resolver) have it. The
# plugin helper loads code Chromium did not sign, as Chrome's does.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = entitlements ] && [ -n "${2:-}" ] || { echo "usage: $0 entitlements <helper app>" >&2; exit 2; }
case "$(basename "$2")" in
    *"(Plugin).app") echo "$PWD/assets/BrowserPlugin.entitlements" ;;
    *) echo "$PWD/assets/BrowserHelper.entitlements" ;;
esac
