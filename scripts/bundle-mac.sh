#!/usr/bin/env bash
# Builds the Mac app into dist/. The app is ad-hoc signed, which is enough to
# run it on the Mac that built it.
#
#   CONFIG=debug ./scripts/bundle-mac.sh    # default: release
#   VERSION=0.2.0 ./scripts/bundle-mac.sh
#   CHANNEL=release ./scripts/bundle-mac.sh # default: dev
#   OUT=/some/folder ./scripts/bundle-mac.sh # default: dist, where a running copy may be
#   IDENTIFIER=com.example.app ./scripts/bundle-mac.sh # a bundle identifier of its own
#
# CHANNEL decides which app this is. "dev", the default, builds
# "AgentTerm Dev.app" (com.manhpham.agentterm.dev): it has its own data
# folder, port and pairing links, so it runs next to an installed AgentTerm
# without touching its sessions or paired devices. "release" builds
# AgentTerm.app itself, which is what the release lanes do.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
# What the host is built from (#121): its targets' sources and the packages
# they take. The app points out a host left running that was built from
# other sources than the host it comes with, and only then: a release that
# changes nothing of the host asks for no restart.
HOST_REVISION="$(find Sources/agenttermd Sources/AgentTermHost Sources/AgentTermClient Sources/AgentTermProtocol Sources/CAgentTermPTY Package.swift Package.resolved -type f -print0 \
    | xargs -0 shasum -a 256 | LC_ALL=C sort -k 2 | shasum -a 256 | cut -c1-16)"
CONFIG="${CONFIG:-release}"
CHANNEL="${CHANNEL:-dev}"
case "$CHANNEL" in
    release) NAME="AgentTerm"; BUNDLE_ID="com.manhpham.agentterm" ;;
    dev) NAME="AgentTerm Dev"; BUNDLE_ID="com.manhpham.agentterm.dev" ;;
    *) echo "bundle-mac.sh: CHANNEL must be dev or release" >&2; exit 2 ;;
esac
# macOS keeps an app's preferences under its bundle identifier, wherever
# the app is and whatever home folder it is given: a copy that must not
# share the development app's preferences needs an identifier of its own.
BUNDLE_ID="${IDENTIFIER:-$BUNDLE_ID}"
APP="${OUT:-dist}/$NAME.app"

# The browser's Chromium (#76): its headers are what the app is compiled
# against, and its framework goes into the app.
CEF="$(./scripts/fetch-cef.sh --print)"

swift build -c "$CONFIG" --product AgentTermMac
swift build -c "$CONFIG" --product agenttermd
swift build -c "$CONFIG" --product AgentTermBrowserHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AgentTermMac" "$APP/Contents/MacOS/AgentTerm"
cp "$BIN/agenttermd" "$APP/Contents/MacOS/agenttermd"

# Packages ship files of their own (the syntax highlighter's grammars and
# themes, for one) as resource bundles next to the binaries. Without them in
# the app, those packages only work on the machine that built it.
mkdir -p "$APP/Contents/Resources"
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# The icon is drawn by scripts/make-icons.swift and checked in.
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Usage statistics and crash reports go through Firebase, and only from a
# released app that was given its config file. Without FIREBASE_CONFIG_MAC,
# as in a build from source, the app has no service to report to and sends
# nothing. A development build never gets the file.
if [ "$CHANNEL" = release ] && [ -n "${FIREBASE_CONFIG_MAC:-}" ]; then
    [ -f "$FIREBASE_CONFIG_MAC" ] || { echo "bundle-mac.sh: FIREBASE_CONFIG_MAC is not a file: $FIREBASE_CONFIG_MAC" >&2; exit 1; }
    cp "$FIREBASE_CONFIG_MAC" "$APP/Contents/Resources/GoogleService-Info.plist"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AgentTerm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>AgentTermHostRevision</key><string>${HOST_REVISION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Firebase collects nothing by itself: the app switches each kind of
         report on only when the user's choices allow it. -->
    <key>FIREBASE_ANALYTICS_COLLECTION_ENABLED</key><false/>
    <key>FirebaseCrashlyticsCollectionEnabled</key><false/>
    <!-- macOS holds a terminal responsible for what runs inside it. Without
         these, a program in a session that wants one of these things is
         refused without the user ever being asked. -->
    <key>NSAppleEventsUsageDescription</key><string>A program running in ${NAME} wants to control another app.</string>
    <key>NSCameraUsageDescription</key><string>A program running in ${NAME} wants to use the camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>A program running in ${NAME} wants to use the microphone.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>A program running in ${NAME} wants to use speech recognition.</string>
    <key>NSLocalNetworkUsageDescription</key><string>${NAME} lets your iPhone reach its sessions, and programs running in it may use the local network.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>A program running in ${NAME} wants to use Bluetooth.</string>
    <key>NSCalendarsUsageDescription</key><string>A program running in ${NAME} wants to access your calendars.</string>
    <key>NSContactsUsageDescription</key><string>A program running in ${NAME} wants to access your contacts.</string>
    <key>NSRemindersUsageDescription</key><string>A program running in ${NAME} wants to access your reminders.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>A program running in ${NAME} wants to access your photos.</string>
    <key>NSLocationUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSDesktopFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>A program running in ${NAME} wants to access files on a removable volume.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>A program running in ${NAME} wants to access files on a network volume.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>A program running in ${NAME} wants to access your calendars.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>A program running in ${NAME} wants to access your reminders.</string>
    <key>NSPhotoLibraryAddUsageDescription</key><string>A program running in ${NAME} wants to add to your photos.</string>
    <key>NSAppleMusicUsageDescription</key><string>A program running in ${NAME} wants to access your media library.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSFileProviderDomainUsageDescription</key><string>A program running in ${NAME} wants to access files kept by a cloud storage app.</string>
    <key>NSAudioCaptureUsageDescription</key><string>A program running in ${NAME} wants to record this Mac's audio.</string>
    <key>NSInputMonitoringUsageDescription</key><string>A program running in ${NAME} wants to watch the keyboard.</string>
    <key>NSSystemAdministrationUsageDescription</key><string>A program running in ${NAME} wants to administer this Mac.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Chromium's framework, in the versioned layout codesign wants, cloned
# rather than copied where the disk allows it (340 MB).
FRAMEWORKS="$APP/Contents/Frameworks"
CEF_FRAMEWORK="$FRAMEWORKS/Chromium Embedded Framework.framework"
mkdir -p "$CEF_FRAMEWORK/Versions"
cp -Rc "$CEF/Release/Chromium Embedded Framework.framework" "$CEF_FRAMEWORK/Versions/A" 2>/dev/null \
    || cp -R "$CEF/Release/Chromium Embedded Framework.framework" "$CEF_FRAMEWORK/Versions/A"
ln -s A "$CEF_FRAMEWORK/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
    ln -s "Versions/Current/$item" "$CEF_FRAMEWORK/$item"
done

# The helper apps Chromium starts its other processes from: one program,
# under the five names Chromium looks for (scripts/browser-helpers.sh
# says which entitlements each gets when the app is signed for release).
# Named for the browser, as Activity Monitor lists them: the memory of the
# pages open is then seen to be the browser's, not the terminal's.
HELPER_NAME="$NAME Browser (Chromium)"
for kind in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
    HELPER="$FRAMEWORKS/$HELPER_NAME$kind.app"
    suffix="$(echo "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$HELPER/Contents/MacOS"
    cp "$BIN/AgentTermBrowserHelper" "$HELPER/Contents/MacOS/$HELPER_NAME$kind"
    cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${HELPER_NAME}${kind}</string>
    <key>CFBundleDisplayName</key><string>${HELPER_NAME}${kind}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.helper${suffix:+.$suffix}</string>
    <key>CFBundleExecutable</key><string>${HELPER_NAME}${kind}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
done

# Inside out: what is inside a bundle is signed before the bundle.
for library in "$CEF_FRAMEWORK/Versions/A/Libraries/"*.dylib; do
    codesign --force --sign - "$library"
done
codesign --force --sign - "$CEF_FRAMEWORK"
for HELPER in "$FRAMEWORKS/$HELPER_NAME"*.app; do
    codesign --force --sign - --entitlements "$(./scripts/browser-helpers.sh entitlements "$HELPER")" "$HELPER"
done
codesign --force --sign - --entitlements assets/AgentTerm.entitlements "$APP/Contents/MacOS/agenttermd"
codesign --force --sign - --entitlements assets/AgentTerm.entitlements "$APP"
echo "Built $APP"
