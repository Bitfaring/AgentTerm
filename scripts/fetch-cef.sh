#!/usr/bin/env bash
# Fetches the Chromium Embedded Framework that the Mac app's browser is
# built on (#76) into .build/cef, and points .build/cef/current at it. Run it
# before the first `swift build`: the package's CAgentTermCEF target reads
# CEF's headers from there, and scripts/bundle-mac.sh copies the framework
# from there into the app. Nothing of CEF is kept in the repository.
#
#   ./scripts/fetch-cef.sh          # fetch the pinned version, if it is not here yet
#   ./scripts/fetch-cef.sh --print  # print the folder it is in, fetching it first
#
# The version is pinned with its checksum. A newer build of the same CEF
# branch (a Chromium security update) is taken by changing both lines below:
# the app is built against API version 15600 (CEF_API_VERSION in
# Package.swift), which later builds keep answering.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="156.0.30+g6028375+chromium-156.0.8078.96"
case "$(uname -m)" in
    arm64) PLATFORM=macosarm64; SHA1="6393d8a838d3b29f6b6939b970b5931dde2082aa" ;;
    x86_64) PLATFORM=macosx64; SHA1="${CEF_SHA1_X64:-}" ;;
    *) echo "fetch-cef.sh: no CEF for $(uname -m)" >&2; exit 2 ;;
esac
NAME="cef_binary_${VERSION}_${PLATFORM}_minimal"
DIR=.build/cef
FRAMEWORK="$DIR/$NAME/Release/Chromium Embedded Framework.framework"

PRINT=0
for argument in "$@"; do
    case "$argument" in
        --print) PRINT=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "fetch-cef.sh: unknown option $argument" >&2; exit 2 ;;
    esac
done

mkdir -p "$DIR"
if [ ! -d "$FRAMEWORK" ] || [ ! -f "$DIR/$NAME/include/cef_version.h" ]; then
    [ -n "$SHA1" ] || { echo "fetch-cef.sh: no checksum is pinned for $PLATFORM" >&2; exit 2; }
    ARCHIVE="$DIR/$NAME.tar.bz2"
    # "+" in the name is "%2B" in the address.
    URL="https://cef-builds.spotifycdn.com/${NAME//+/%2B}.tar.bz2"
    echo "Fetching CEF $VERSION ($PLATFORM), about 135 MB…" >&2
    curl -fSL --retry 3 -o "$ARCHIVE.part" "$URL"
    echo "$SHA1  $ARCHIVE.part" | shasum -a 1 -c - >&2
    rm -rf "${DIR:?}/$NAME"
    tar -xjf "$ARCHIVE.part" -C "$DIR"
    rm -f "$ARCHIVE.part"
fi
if [ "$(readlink "$DIR/current" 2>/dev/null || true)" != "$NAME" ]; then
    ln -sfn "$NAME" "$DIR/current"
    # CAgentTermCEF finds CEF's headers with __has_include: compiled before
    # they were here, it is not compiled again when they come, since a
    # header that was missing is not one SwiftPM watches (#181). Its source
    # is marked changed, so that the next build has Chromium.
    touch Sources/CAgentTermCEF/AgentTermCEF.m
fi

if [ "$PRINT" -eq 1 ]; then
    echo "$PWD/$DIR/$NAME"
fi
