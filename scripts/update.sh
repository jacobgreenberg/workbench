#!/usr/bin/env bash
# Pull the latest main, rebuild, and install to /Applications. Running sessions are untouched;
# quit and reopen Workbench to switch to the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

git pull --ff-only
[ -d vendor/GhosttyKit.xcframework ] && [ -d vendor/ghostty-src ] || scripts/fetch-ghosttykit.sh
scripts/bundle.sh --install

if pgrep -xq Workbench; then
  echo "Installed. Quit and reopen Workbench to use the new version."
else
  open /Applications/Workbench.app
fi
