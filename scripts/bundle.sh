#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SI=vendor/ghostty-src/src/shell-integration
[ -d "$SI" ] || { echo "missing $SI: run scripts/fetch-ghosttykit.sh" >&2; exit 1; }

swift build -c release

APP=build/Pane.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ghostty"
cp .build/release/Pane "$APP/Contents/MacOS/Pane"
mkdir -p "$APP/Contents/Helpers"; ln -s ../MacOS/Pane "$APP/Contents/Helpers/pane"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/themes "$APP/Contents/Resources/themes"
cp Resources/claude-hooks.json "$APP/Contents/Resources/"
cp -R /Applications/Ghostty.app/Contents/Resources/terminfo "$APP/Contents/Resources/terminfo"
cp -R "$SI" "$APP/Contents/Resources/ghostty/shell-integration"

codesign --force --sign - --options runtime "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Pane.app && cp -R "$APP" /Applications/
fi
