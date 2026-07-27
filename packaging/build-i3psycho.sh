#!/usr/bin/env bash
# Build i3psycho: upstream i3 + the patches/ series. Result: i3-build/build/i3
# Pin an upstream tag here once upstream releases past the base commit.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d i3-build ] || git clone --depth 50 https://github.com/i3/i3 i3-build
cd i3-build
git checkout -q master
git am --abort 2>/dev/null || true
git apply --check ../patches/00*.patch
git am ../patches/00*.patch
meson setup --buildtype=release build >/dev/null
ninja -C build
echo "OK: i3-build/build/i3"
