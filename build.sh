#!/bin/bash
# Builds "Screenshot Hub.app" from ScreenshotHub.swift.
#
# Usage:
#   bash build.sh            local build for your own Mac (ad hoc signed)
#   bash build.sh --dmg      local build plus a DMG in dist/, for testing or trying it out
#   bash build.sh --release  build for sharing: requires a clean git state, a Developer ID
#                            (SIGN_IDENTITY) and notarization (NOTARY_PROFILE); also creates
#                            a signed and notarized DMG in dist/
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
MAKE_DMG=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1; MAKE_DMG=1 ;;
    --dmg) MAKE_DMG=1 ;;
    *) echo "Unknown option: $arg (usage: bash build.sh [--dmg] [--release])"; exit 1 ;;
  esac
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools first: xcode-select --install"
  exit 1
fi

APP="Screenshot Hub.app"
EXE="ScreenshotHub"

# Version from VERSION; build number, commit and date from git. The About window shows them.
VERSION="$(tr -d '[:space:]' < VERSION)"
# The files the app is built from. If one of them differs from the commit (modified or not
# yet in git), the build is "dirty" and does not belong to a known commit.
INPUTS=(ScreenshotHub.swift AppIcon.swift ScreenshotHub.entitlements VERSION build.sh)
DIRTY=0
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  COMMIT="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain -- "${INPUTS[@]}")" ]; then
    DIRTY=1
    COMMIT="$COMMIT-dirty"
  fi
else
  BUILD_NUMBER="0"
  COMMIT="unknown"
  DIRTY=1
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# What the app was built with, for the About window.
TOOLCHAIN="$(swiftc --version 2>/dev/null | head -n 1 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$RELEASE" = 1 ]; then
  # A build for sharing must belong to a known commit and be verifiable by Apple.
  if [ "$DIRTY" = 1 ]; then
    echo "--release: commit your changes first in: ${INPUTS[*]}"
    git status --short -- "${INPUTS[@]}" || true
    exit 1
  fi
  if [ "$SIGN_IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "--release: set SIGN_IDENTITY (Developer ID Application: …) and NOTARY_PROFILE; see README."
    exit 1
  fi
fi

echo "Building: version $VERSION, build $BUILD_NUMBER ($COMMIT) for $(uname -m)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  ScreenshotHub.swift \
  -o "$APP/Contents/MacOS/$EXE"

# Icon: only redrawn when AppIcon.swift has changed.
ICON=".build/AppIcon.icns"
if [ ! -f "$ICON" ] || [ AppIcon.swift -nt "$ICON" ]; then
  echo "Drawing icon..."
  rm -rf .build/AppIcon.iconset
  mkdir -p .build
  swift AppIcon.swift .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Screenshot Hub</string>
  <key>CFBundleDisplayName</key><string>Screenshot Hub</string>
  <key>CFBundleIdentifier</key><string>local.screenshothub</string>
  <key>CFBundleExecutable</key><string>ScreenshotHub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>ScreenshotHubCommit</key><string>$COMMIT</string>
  <key>ScreenshotHubBuildDate</key><string>$BUILD_DATE</string>
  <key>ScreenshotHubToolchain</key><string>$TOOLCHAIN</string>
  <key>ScreenshotHubSDK</key><string>$SDK_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Screenshot Hub shows and moves screenshots on your desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Screenshot Hub saves screenshots to folders in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Screenshot Hub saves screenshots to folders in Downloads.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.screenshothub.memory-shot</string>
      <key>UTTypeDescription</key><string>Screenshot in memory</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign with App Sandbox (ScreenshotHub.entitlements) and Hardened Runtime.
# Without SIGN_IDENTITY this is a local ad hoc signature: enough for your own Mac.
# With a Developer ID, e.g. SIGN_IDENTITY="Developer ID Application: Name (TEAMID)",
# the signature also gets a timestamp, so Apple can notarize it.
SIGN_ARGS=(--force --options runtime --entitlements ScreenshotHub.entitlements --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"

# Notarize with Apple, only with a Developer ID and a stored notarytool profile:
#   xcrun notarytool store-credentials <profile> --apple-id <email> --team-id <TEAMID>
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> bash build.sh
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "NOTARY_PROFILE only works together with SIGN_IDENTITY (a Developer ID)."
    exit 1
  fi
  echo "Notarizing..."
  rm -f .build/ScreenshotHub.zip
  mkdir -p .build
  ditto -c -k --keepParent "$APP" .build/ScreenshotHub.zip
  xcrun notarytool submit .build/ScreenshotHub.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# DMG for sharing the app: the app plus a shortcut to Applications, so you install it by
# dragging. With --release the DMG is also signed, notarized and stapled.
if [ "$MAKE_DMG" = 1 ]; then
  # No spaces: GitHub turns them into dots in release assets.
  DMG="dist/ScreenshotHub-$VERSION.dmg"
  STAGING=".build/dmg"
  echo "Creating DMG..."
  rm -rf "$STAGING" "$DMG"
  mkdir -p "$STAGING" dist
  ditto "$APP" "$STAGING/$APP"
  ln -s /Applications "$STAGING/Applications"
  # hdiutil sometimes fails temporarily with "Resource busy" (known on build servers): up to three attempts.
  for attempt in 1 2 3; do
    if hdiutil create -quiet -volname "Screenshot Hub $VERSION" -srcfolder "$STAGING" \
        -format UDZO -fs HFS+ "$DMG"; then
      break
    fi
    if [ "$attempt" = 3 ]; then
      echo "Creating the DMG failed three times."
      exit 1
    fi
    echo "Creating the DMG failed, retrying in 5 seconds..."
    rm -f "$DMG"
    sleep 5
  done
  rm -rf "$STAGING"
  if [ "$RELEASE" = 1 ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  hdiutil verify -quiet "$DMG"
  echo "DMG: $(pwd)/$DMG"
fi

# Tell Finder and the Dock that the app (and its icon) has changed.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "Done: $(pwd)/$APP"
echo "Drag it to Applications or start it with: open \"$APP\""
if [ "$RELEASE" = 0 ]; then
  echo "Note: this is a local build, for this Mac only. To share: bash build.sh --release"
  if [ "$MAKE_DMG" = 1 ]; then
    echo "This DMG is not notarized: on another Mac the user first has to allow the app"
    echo "via System Settings › Privacy & Security › Open Anyway. See README."
  fi
fi
