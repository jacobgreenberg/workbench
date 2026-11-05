#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SI=vendor/ghostty-src/src/shell-integration
TI=vendor/ghostty-src/zig-out/share/terminfo   # compiled by the same fork build as libghostty
[ -d "$SI" ] || { echo "missing $SI: run scripts/ghosttykit.sh" >&2; exit 1; }
[ -d "$TI/78" ] || { echo "missing $TI: run scripts/ghosttykit.sh" >&2; exit 1; }

CONFIG=release
APP=build.noindex/Workbench.app   # .noindex: Spotlight/launchers list only the /Applications copy
if [ "${1:-}" = "--debug" ]; then   # the test harness's app (run with PANE_STATE_DIR): the GUI needs a bundle, notifications abort without one
  CONFIG=debug
  APP=build.noindex/Workbench-debug.app
fi
swift build -c "$CONFIG"

STAGE="build.noindex/.$(basename "$APP" .app).new.app"   # built here, renamed over $APP at the end: the running app's paths never vanish
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/ghostty"
cp .build/$CONFIG/Workbench "$STAGE/Contents/MacOS/Workbench"
cp -R .build/$CONFIG/TreeSitter*.bundle "$STAGE/Contents/Resources/"   # grammar highlight queries (Syntax.swift)
mkdir -p "$STAGE/Contents/Helpers"; ln -s ../MacOS/Workbench "$STAGE/Contents/Helpers/pane"
cp .build/$CONFIG/wbhost "$STAGE/Contents/Helpers/WorkbenchHost"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp -R Resources/themes "$STAGE/Contents/Resources/themes"
cp -R Resources/speech "$STAGE/Contents/Resources/speech"   # Read Aloud's voice helper (Speaker.swift)
cp Resources/claude-hooks.json Resources/AppIcon.icns "$STAGE/Contents/Resources/"
cp -R "$TI" "$STAGE/Contents/Resources/terminfo"
cp -R "$SI" "$STAGE/Contents/Resources/ghostty/shell-integration"

if [ "$CONFIG" = release ]; then
  # Symbols are dead weight on disk (the dSYM below symbolicates crash logs); strip before signing.
  strip -Sx "$STAGE/Contents/MacOS/Workbench" "$STAGE/Contents/Helpers/WorkbenchHost"
  DSYM="build.noindex/dSYMs/Workbench-$(git rev-parse --short HEAD).dSYM"   # .build's copy is overwritten every build
  mkdir -p build.noindex/dSYMs && rm -rf "$DSYM" && cp -cR .build/release/Workbench.dSYM "$DSYM"
  ls -t build.noindex/dSYMs | tail -n +6 | while read -r d; do rm -rf "build.noindex/dSYMs/$d"; done   # keep the last 5
fi

# A real identity keeps macOS privacy grants (Full Disk Access, Documents, ...) across rebuilds: an ad-hoc
# signature's designated requirement is the cdhash, which every build changes, so each build re-prompted.
ID="${WORKBENCH_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
[ -n "$ID" ] || [ "$CONFIG" = debug ] || { echo "no valid Apple Development identity (privacy grants would reset); set WORKBENCH_SIGN_ID=- to sign ad hoc" >&2; exit 1; }
codesign --force --sign "${ID:--}" --options runtime --identifier com.jgreenberg.workbench.host "$STAGE/Contents/Helpers/WorkbenchHost"   # its own privacy grants (Session.spawn disclaims)
codesign --force --sign "${ID:--}" --options runtime "$STAGE"
mv "$APP" "$APP.old" 2>/dev/null || true
mv "$STAGE" "$APP"
rm -rf "$APP.old"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  # File by file into the existing bundle, never moving it: each file is written beside its target and renamed over it,
  # so the helper, hooks and terminfo are never missing. A running process's path follows its bundle, and macOS keys
  # WorkbenchHost's privacy grants (Removable Volumes, Accessibility) by that path: renaming the old bundle away would
  # strip them from every running session until its pane restarts.
  rsync -a --delete "$APP/" /Applications/Workbench.app/
fi
