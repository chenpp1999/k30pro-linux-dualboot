#!/bin/sh
# SPDX-License-Identifier: MIT
# make-patch.sh - regenerate tools/m1/weston-patches/0007-keyboard-pinyin.patch
#
# Rebuilds a clean weston 14.0.2 + patches 0001-0006 baseline, applies
# apply-keyboard-pinyin.py to the working tree, then emits the patch and
# builds weston-keyboard in the local build directory.
#
# Run on the WSL side:  sh tools/m1/ime/make-patch.sh
set -e
P=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATCHES=$P/../weston-patches
W=${WESTON_TREE:-$HOME/lmi/weston-14.0.2}
TARBALL=${WESTON_TARBALL:-$HOME/lmi/weston-14.0.2.tar.xz}
BASE=$(mktemp -d /tmp/weston-baseline.XXXXXX)

tar -xf "$TARBALL" -C "$BASE"
cd "$BASE/weston-14.0.2"
for f in "$PATCHES"/0001-*.patch "$PATCHES"/0002-*.patch "$PATCHES"/0003-*.patch \
         "$PATCHES"/0004-*.patch "$PATCHES"/0005-*.patch "$PATCHES"/0006-*.patch; do
	patch -p0 -f < "$f" >/dev/null
done
echo "baseline ready: $(basename "$BASE")"

cp clients/keyboard.c "$W/clients/keyboard.c"
cp clients/meson.build "$W/clients/meson.build"
rm -f "$W/clients/pinyin.c" "$W/clients/pinyin.h"
python3 "$P/apply-keyboard-pinyin.py" "$W"

WORK=$(mktemp -d /tmp/ime-diff.XXXXXX)
mkdir -p "$WORK/before/clients" "$WORK/after/clients"
for f in keyboard.c meson.build; do
	cp clients/$f "$WORK/before/clients/$f"
	cp "$W/clients/$f" "$WORK/after/clients/$f"
done
for f in pinyin.c pinyin.h; do
	: > "$WORK/before/clients/$f"
	cp "$W/clients/$f" "$WORK/after/clients/$f"
done
cd "$WORK"
{
	for f in keyboard.c meson.build pinyin.c pinyin.h; do
		if [ -s before/clients/$f ]; then
			diff -u --label clients/$f --label clients/$f \
			     before/clients/$f after/clients/$f
		else
			diff -u --label /dev/null --label clients/$f \
			     /dev/null after/clients/$f
		fi
	done
} > 0007-keyboard-pinyin.patch || true
cp 0007-keyboard-pinyin.patch "$PATCHES/0007-keyboard-pinyin.patch"
wc -l "$PATCHES/0007-keyboard-pinyin.patch"

echo "build with: tools/m1/build-weston-clients.sh (on device)"
rm -rf "$BASE" "$WORK"
