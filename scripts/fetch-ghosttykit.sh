#!/bin/bash
# Fetch the pinned GhosttyKit prebuilt (cmux fork) + matching shell-integration.
set -euo pipefail
cd "$(dirname "$0")/../vendor"
SHA=cb1ef7091cdef0b581ee2cbd83742b653253523e
SUM=413515af9e3739068f91bae98bc33fa1d89d4ea20b35d0fa96b317379bb17ae2
TAR=GhosttyKit.xcframework.tar.gz
if [ ! -d GhosttyKit.xcframework ]; then
  curl -fSL --retry 3 -o "$TAR" \
    "https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${SHA}-crashsubdir-cmux-crash-sentry-off-noi18n-v2/${TAR}"
  echo "${SUM}  ${TAR}" | shasum -a 256 -c
  tar --no-same-owner -xzf "$TAR"
  rm "$TAR"
  find GhosttyKit.xcframework -name '*.a' -exec xcrun ranlib {} \;
fi
if [ ! -d ghostty-src ]; then
  git clone -q --filter=blob:none --no-checkout https://github.com/manaflow-ai/ghostty ghostty-src
  git -C ghostty-src sparse-checkout set --no-cone src/shell-integration macos/Sources include
  git -C ghostty-src checkout -q "$SHA"
fi
