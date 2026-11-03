#!/bin/bash
# Builds Ballast.app, bundles its font, ad-hoc signs it and installs it.
#   ./build.sh            build and install to /Applications
#   ./build.sh --no-install  build into ./build only
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Ballast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Ballast "$APP/Contents/MacOS/Ballast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Ballast.icns ] && cp Resources/Ballast.icns "$APP/Contents/Resources/"

FONT="$HOME/Library/Fonts/AspektaVF.ttf"
if [ -f "$FONT" ]; then
  cp "$FONT" "$APP/Contents/Resources/AspektaVF.ttf"
  [ -f Resources/Aspekta-OFL.txt ] && cp Resources/Aspekta-OFL.txt "$APP/Contents/Resources/"
else
  echo "note: Aspekta not found, the app will fall back to the system font"
fi

# macOS refuses UserNotifications to ad-hoc signed apps, so prefer a real
# Developer ID identity when one is installed and fall back to ad-hoc.
IDENTITY="${BALLAST_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null
  echo "signed as: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "signed ad-hoc (notifications will use the scripting fallback)"
fi
codesign --verify --strict "$APP" && echo "signature verified"

if [ "${1:-}" != "--no-install" ]; then
  TARGET="/Applications/Ballast.app"
  if [ ! -w /Applications ]; then
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/Ballast.app"
  fi
  pkill -x Ballast 2>/dev/null || true
  sleep 0.5
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo "installed $TARGET"
fi
