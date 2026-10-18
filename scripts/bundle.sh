#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SI=vendor/ghostty-src/src/shell-integration
[ -d "$SI" ] || { echo "missing $SI: run scripts/ghosttykit.sh" >&2; exit 1; }

swift build -c release

APP=build.noindex/Workbench.app   # .noindex: Spotlight/launchers list only the /Applications copy
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ghostty"
cp .build/release/Workbench "$APP/Contents/MacOS/Workbench"
cp -R .build/release/TreeSitter*.bundle "$APP/Contents/Resources/"   # grammar highlight queries (Syntax.swift)
mkdir -p "$APP/Contents/Helpers"; ln -s ../MacOS/Workbench "$APP/Contents/Helpers/pane"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/themes "$APP/Contents/Resources/themes"
cp Resources/claude-hooks.json Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R /Applications/Ghostty.app/Contents/Resources/terminfo "$APP/Contents/Resources/terminfo"
cp -R "$SI" "$APP/Contents/Resources/ghostty/shell-integration"

# A real identity keeps macOS privacy grants (Full Disk Access, Documents, ...) across rebuilds: an ad-hoc
# signature's designated requirement is the cdhash, which every build changes, so each build re-prompted.
ID="${WORKBENCH_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${ID:--}" --options runtime "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Workbench.app && cp -R "$APP" /Applications/
fi
