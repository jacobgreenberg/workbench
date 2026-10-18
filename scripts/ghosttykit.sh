#!/bin/bash
# Build GhosttyKit.xcframework from our Ghostty fork (jacobgreenberg/ghostty, branch workbench) at the pinned SHA.
# vendor/ghostty-src is that checkout: the source of the binary, its shell-integration and ghostty.h.
# No-op when the built SHA matches. Needs zig 0.16 (brew install zig@0.16) and Xcode's Metal toolchain.
set -euo pipefail
cd "$(dirname "$0")/../vendor"
SHA=8844e7bb4ec8c416af22b4b51373085ef6facd7a
ZIG="$(brew --prefix zig@0.16 2>/dev/null)/bin/zig"
[ -x "$ZIG" ] || ZIG=zig
[ "$(cat GhosttyKit.xcframework/.sha 2>/dev/null)" = "$SHA" ] && exit 0
if [ "$(git -C ghostty-src remote get-url origin 2>/dev/null)" != https://github.com/jacobgreenberg/ghostty ]; then
  rm -rf ghostty-src   # the old sparse checkout of the prebuilt's fork
  git clone -q --filter=blob:none https://github.com/jacobgreenberg/ghostty ghostty-src
fi
git -C ghostty-src fetch -q origin workbench
git -C ghostty-src checkout -q "$SHA"
(cd ghostty-src && "$ZIG" build -Dsentry=false -Di18n=false -Demit-xcframework=true -Demit-macos-app=false \
  -Dxcframework-target=native -Doptimize=ReleaseFast -Dmetal-swap-chain-count=2)
rm -rf GhosttyKit.xcframework
cp -R ghostty-src/macos/GhosttyKit.xcframework .
echo "$SHA" > GhosttyKit.xcframework/.sha
