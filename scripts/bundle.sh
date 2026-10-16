#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SI=vendor/ghostty-src/src/shell-integration
[ -d "$SI" ] || { echo "missing $SI: run scripts/fetch-ghosttykit.sh" >&2; exit 1; }

swift build -c release

APP=build.noindex/Workbench.app   # .noindex: Spotlight/launchers list only the /Applications copy
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ghostty"
cp .build/release/Workbench "$APP/Contents/MacOS/Workbench"
mkdir -p "$APP/Contents/Helpers"; ln -s ../MacOS/Workbench "$APP/Contents/Helpers/pane"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/themes "$APP/Contents/Resources/themes"
cp Resources/claude-hooks.json Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R /Applications/Ghostty.app/Contents/Resources/terminfo "$APP/Contents/Resources/terminfo"
cp -R "$SI" "$APP/Contents/Resources/ghostty/shell-integration"

codesign --force --sign - --options runtime "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Workbench.app && cp -R "$APP" /Applications/
fi
