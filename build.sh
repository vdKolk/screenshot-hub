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

echo "Bouwen voor $(uname -m)..."
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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Screenshot Hub</string>
  <key>CFBundleDisplayName</key><string>Screenshot Hub</string>
  <key>CFBundleIdentifier</key><string>local.screenshothub</string>
  <key>CFBundleExecutable</key><string>ScreenshotHub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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

# Lokale ad-hoc handtekening, genoeg om hem op je eigen Mac te draaien.
codesign --force --sign - "$APP"

# Finder en het Dock laten weten dat de app (en zijn icoon) is veranderd.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "Klaar: $(pwd)/$APP"
echo "Sleep hem naar Programma's of start hem met: open \"$APP\""
