#!/bin/bash
# Bouwt "Screenshot Hub.app" uit ScreenshotHub.swift.
#
# Gebruik:
#   bash build.sh            lokale build voor je eigen Mac (ad-hoc ondertekend)
#   bash build.sh --dmg      lokale build plus een DMG in dist/, om te testen of uit te proberen
#   bash build.sh --release  build om te delen: vereist een schone git-stand, een Developer ID
#                            (SIGN_IDENTITY) en notarisatie (NOTARY_PROFILE); maakt ook een
#                            ondertekende en genotariseerde DMG in dist/
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
MAKE_DMG=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1; MAKE_DMG=1 ;;
    --dmg) MAKE_DMG=1 ;;
    *) echo "Onbekende optie: $arg (gebruik: bash build.sh [--dmg] [--release])"; exit 1 ;;
  esac
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc niet gevonden. Installeer eerst de Command Line Tools: xcode-select --install"
  exit 1
fi

APP="Screenshot Hub.app"
EXE="ScreenshotHub"

# Versie uit VERSION; buildnummer, commit en datum uit git. Het Over-venster toont ze.
VERSION="$(tr -d '[:space:]' < VERSION)"
# De bestanden waaruit de app wordt gebouwd. Wijkt een daarvan af van de commit (gewijzigd of
# nog niet in git), dan is de build "dirty" en hoort hij niet bij een bekende commit.
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
  COMMIT="onbekend"
  DIRTY=1
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Waarmee gebouwd is, voor het Over-venster.
TOOLCHAIN="$(swiftc --version 2>/dev/null | head -n 1 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo onbekend)"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$RELEASE" = 1 ]; then
  # Een build om te delen moet bij een bekende commit horen en door Apple te controleren zijn.
  if [ "$DIRTY" = 1 ]; then
    echo "--release: commit eerst je wijzigingen in: ${INPUTS[*]}"
    git status --short -- "${INPUTS[@]}" || true
    exit 1
  fi
  if [ "$SIGN_IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "--release: zet SIGN_IDENTITY (Developer ID Application: …) en NOTARY_PROFILE; zie README."
    exit 1
  fi
fi

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
  <key>ScreenshotHubToolchain</key><string>$TOOLCHAIN</string>
  <key>ScreenshotHubSDK</key><string>$SDK_VERSION</string>
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

# DMG om de app te delen: de app plus een snelkoppeling naar Programma's, zodat je hem
# er met slepen in zet. Bij --release wordt ook de DMG ondertekend, genotariseerd en gestapled.
if [ "$MAKE_DMG" = 1 ]; then
  # Geen spaties: GitHub maakt daar punten van in de bijlagen van een release.
  DMG="dist/ScreenshotHub-$VERSION.dmg"
  STAGING=".build/dmg"
  echo "DMG maken..."
  rm -rf "$STAGING" "$DMG"
  mkdir -p "$STAGING" dist
  ditto "$APP" "$STAGING/$APP"
  ln -s /Applications "$STAGING/Programma's"
  # hdiutil faalt soms tijdelijk met "Resource busy" (bekend op build-servers): tot drie pogingen.
  for attempt in 1 2 3; do
    if hdiutil create -quiet -volname "Screenshot Hub $VERSION" -srcfolder "$STAGING" \
        -format UDZO -fs HFS+ "$DMG"; then
      break
    fi
    if [ "$attempt" = 3 ]; then
      echo "DMG maken is drie keer mislukt."
      exit 1
    fi
    echo "DMG maken mislukte, opnieuw over 5 seconden..."
    rm -f "$DMG"
    sleep 5
  done
  rm -rf "$STAGING"
  if [ "$RELEASE" = 1 ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "DMG notariseren..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  hdiutil verify -quiet "$DMG"
  echo "DMG: $(pwd)/$DMG"
fi

# Finder en het Dock laten weten dat de app (en zijn icoon) is veranderd.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "Klaar: $(pwd)/$APP"
echo "Sleep hem naar Programma's of start hem met: open \"$APP\""
if [ "$RELEASE" = 0 ]; then
  echo "Let op: dit is een lokale build, alleen voor deze Mac. Om te delen: bash build.sh --release"
  if [ "$MAKE_DMG" = 1 ]; then
    echo "Deze DMG is niet genotariseerd: op een andere Mac moet de gebruiker de app eerst toestaan"
    echo "via Systeeminstellingen › Privacy en beveiliging › Open toch. Zie README."
  fi
fi
