#!/usr/bin/env bash
# Pull the latest main, rebuild, and install to /Applications. Running sessions are untouched;
# quit and reopen Pane to switch to the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

git pull --ff-only
[ -d vendor/GhosttyKit.xcframework ] && [ -d vendor/ghostty-src ] || scripts/fetch-ghosttykit.sh
scripts/bundle.sh --install

if pgrep -xq Pane; then
  echo "Installed. Quit and reopen Pane to use the new version."
else
  open /Applications/Pane.app
fi
