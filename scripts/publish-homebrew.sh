#!/usr/bin/env bash
# Points the agentterm cask in the Homebrew tap at a release, from packaging/homebrew/agentterm.rb.
#
#   scripts/publish-homebrew.sh 0.2.0
#   DRY_RUN=1 scripts/publish-homebrew.sh 0.2.0     # print the cask, push nothing
#
# The cask's checksum is the one published with the GitHub release (AgentTerm-<version>.sha256),
# what `brew` will check the download against (#316). A dist/AgentTerm-<version>.dmg that is
# there and is not that one (built on this Mac, say) is refused, never hashed in its place. In
# the release job HOMEBREW_TAP_TOKEN holds a token with contents write access to the tap;
# without it, git's own sign-in on this machine is used.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: publish-homebrew.sh VERSION (without the v prefix)}
VERSION=${VERSION#v}
TAP_REPO=${TAP_REPO:-Bitfaring/homebrew-tap}
TAP_BRANCH=${TAP_BRANCH:-main}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/agentterm-homebrew.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

gh release download "v$VERSION" --repo Bitfaring/AgentTerm --pattern "AgentTerm-$VERSION.sha256" --dir "$WORK"
SHA256=$(cut -d' ' -f1 "$WORK/AgentTerm-$VERSION.sha256")
if ! printf '%s' "$SHA256" | grep -Eqx '[0-9a-f]{64}'; then
    echo "publish-homebrew.sh: the release's AgentTerm-$VERSION.sha256 holds no checksum" >&2
    exit 1
fi
DMG="dist/AgentTerm-$VERSION.dmg"
if [ -f "$DMG" ] && [ "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" != "$SHA256" ]; then
    echo "publish-homebrew.sh: $DMG is not the disk image that was released (its checksum differs): the cask is not changed" >&2
    exit 1
fi

if [ -n "${DRY_RUN:-}" ]; then
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA256/g" packaging/homebrew/agentterm.rb
    exit 0
fi

if [ -n "${HOMEBREW_TAP_TOKEN:-}" ]; then
    git clone --quiet --depth 1 "https://x-access-token:$HOMEBREW_TAP_TOKEN@github.com/$TAP_REPO.git" "$WORK/tap"
else
    gh repo clone "$TAP_REPO" "$WORK/tap" -- --quiet --depth 1
fi
mkdir -p "$WORK/tap/Casks"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA256/g" packaging/homebrew/agentterm.rb > "$WORK/tap/Casks/agentterm.rb"

cd "$WORK/tap"
git add Casks/agentterm.rb
if git diff --cached --quiet; then
    echo "[ok]      $TAP_REPO already at $VERSION"
    exit 0
fi
git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "agentterm $VERSION"
git push --quiet origin "HEAD:refs/heads/$TAP_BRANCH"
echo "[ok]      $TAP_REPO -> $VERSION"
