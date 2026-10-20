#!/bin/bash
# Bouwt "Screenshot Hub.app" uit ScreenshotHub.swift.
# Gebruik: bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc niet gevonden. Installeer eerst de Command Line Tools: xcode-select --install"
  exit 1
fi

APP="Screenshot Hub.app"
EXE="ScreenshotHub"

# Versie uit VERSION; buildnummer, commit en datum uit git. Het Over-venster toont ze.
VERSION="$(tr -d '[:space:]' < VERSION)"
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  COMMIT="$(git rev-parse --short HEAD)"
  # Niet-gecommitte wijzigingen in bestanden die git al kent, maken de build "dirty".
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    COMMIT="$COMMIT-dirty"
  fi
else
  BUILD_NUMBER="0"
  COMMIT="onbekend"
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Bouwen: versie $VERSION, build $BUILD_NUMBER ($COMMIT) voor $(uname -m)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  ScreenshotHub.swift \
  -o "$APP/Contents/MacOS/$EXE"

# Icoon: alleen opnieuw tekenen als AppIcon.swift veranderd is.
ICON=".build/AppIcon.icns"
if [ ! -f "$ICON" ] || [ AppIcon.swift -nt "$ICON" ]; then
  echo "Icoon tekenen..."
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
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>ScreenshotHubCommit</key><string>$COMMIT</string>
  <key>ScreenshotHubBuildDate</key><string>$BUILD_DATE</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Screenshot Hub toont en verplaatst screenshots op je bureaublad.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Screenshot Hub slaat screenshots op in mappen in Documenten.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Screenshot Hub slaat screenshots op in mappen in Downloads.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.screenshothub.memory-shot</string>
      <key>UTTypeDescription</key><string>Screenshot in geheugen</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ondertekenen met App Sandbox (ScreenshotHub.entitlements) en Hardened Runtime.
# Zonder SIGN_IDENTITY is het een lokale ad-hoc handtekening: genoeg voor je eigen Mac.
# Met een Developer ID, bijvoorbeeld SIGN_IDENTITY="Developer ID Application: Naam (TEAMID)",
# krijgt de handtekening ook een tijdstempel, zodat Apple hem kan notariseren.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --entitlements ScreenshotHub.entitlements --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"

# Notariseren bij Apple, alleen met een Developer ID en een opgeslagen notarytool-profiel:
#   xcrun notarytool store-credentials <profiel> --apple-id <e-mail> --team-id <TEAMID>
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profiel> bash build.sh
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "NOTARY_PROFILE werkt alleen samen met SIGN_IDENTITY (een Developer ID)."
    exit 1
  fi
  echo "Notariseren..."
  rm -f .build/ScreenshotHub.zip
  mkdir -p .build
  ditto -c -k --keepParent "$APP" .build/ScreenshotHub.zip
  xcrun notarytool submit .build/ScreenshotHub.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# Finder en het Dock laten weten dat de app (en zijn icoon) is veranderd.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "Klaar: $(pwd)/$APP"
echo "Sleep hem naar Programma's of start hem met: open \"$APP\""
