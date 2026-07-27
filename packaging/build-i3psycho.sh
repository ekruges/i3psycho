#!/usr/bin/env bash
# Build i3psycho: upstream i3 + the patches/ series. Result: i3-build/build/i3
# Keep _i3_tag in sync with PKGBUILD so both install paths build the same tree.
set -euo pipefail
cd "$(dirname "$0")/.."

_i3_tag=4.25.1

# No --depth: `git am` wants real history for its three-way fallback, and a
# shallow clone cannot later be fetched to a tag it did not already have.
[ -d i3-build ] || git clone https://github.com/i3/i3 i3-build
cd i3-build
git am --abort 2>/dev/null || true
git fetch -q --tags origin
# Was `git checkout -q master`, which built whatever upstream had pushed that
# morning -- so the series applied one day and conflicted the next, against no
# i3 release in particular. Detach at the pinned tag and hard-reset, so a
# re-run over a dirty or already-patched i3-build starts from the same tree.
git checkout -q --detach "$_i3_tag"
git reset -q --hard "$_i3_tag"
git clean -qfd

# No `git apply --check` pre-flight: it tests all seven patches against the
# same pristine tree, so any patch touching a file an earlier one already
# changed is reported broken even though the series applies in order. That
# false negative blocked a series that builds fine. `git am` is the real check.
git am ../patches/00*.patch

meson setup --buildtype=release build >/dev/null
ninja -C build
echo "OK: i3-build/build/i3"
