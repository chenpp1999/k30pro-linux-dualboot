#!/bin/sh
# SPDX-License-Identifier: MIT
# make-patch.sh - regenerate tools/m1/weston-patches/0007..0010 from a clean
# weston 14.0.2 + patches 0001-0006 baseline.
#
# Run on the WSL side:  sh tools/m1/ime/make-patch.sh
#
#   0007 keyboard pinyin page + candidate strip + engine wiring
#   0008 terminal delete_surrounding_text
#   0009 keyboard shortcut bar (Esc/Tab/Ctrl/Alt/arrows/Home/End/PgUp/PgDn)
#   0010 terminal keysym modifiers (modifiers_map, Ctrl/Alt letters)
set -e
P=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATCHES=$P/../weston-patches
W=${WESTON_TREE:-$HOME/lmi/weston-14.0.2}
TARBALL=${WESTON_TARBALL:-$HOME/lmi/weston-14.0.2.tar.xz}
BASE=$(mktemp -d /tmp/weston-baseline.XXXXXX)
WORK=$(mktemp -d /tmp/ime-diff.XXXXXX)

snap() { # $1 = dir
	mkdir -p "$1/clients"
	for f in keyboard.c meson.build terminal.c; do
		cp "$W/clients/$f" "$1/clients/$f"
	done
	for f in pinyin.c pinyin.h; do
		if [ -f "$W/clients/$f" ]; then
			cp "$W/clients/$f" "$1/clients/$f"
		else
			: > "$1/clients/$f"
		fi
	done
}

tar -xf "$TARBALL" -C "$BASE"
cd "$BASE/weston-14.0.2"
for f in "$PATCHES"/0001-*.patch "$PATCHES"/0002-*.patch "$PATCHES"/0003-*.patch \
         "$PATCHES"/0004-*.patch "$PATCHES"/0005-*.patch "$PATCHES"/0006-*.patch; do
	patch -p0 -f < "$f" >/dev/null
done
echo "baseline ready"

# --- stage 1: 0007 + 0008 -------------------------------------------------
cp clients/keyboard.c "$W/clients/keyboard.c"
cp clients/meson.build "$W/clients/meson.build"
cp clients/terminal.c "$W/clients/terminal.c"
rm -f "$W/clients/pinyin.c" "$W/clients/pinyin.h"
python3 "$P/apply-keyboard-pinyin.py" "$W"
python3 "$P/apply-terminal-delete.py" "$W"
mkdir -p "$WORK/b1" "$WORK/a1"
snap_base() {
	mkdir -p "$1/clients"
	for f in keyboard.c meson.build terminal.c; do
		cp "$BASE/weston-14.0.2/clients/$f" "$1/clients/$f"
	done
	for f in pinyin.c pinyin.h; do
		: > "$1/clients/$f"
	done
}
snap_base "$WORK/b1"
snap "$WORK/a1"
cd "$WORK"
{
	for f in keyboard.c meson.build pinyin.c pinyin.h; do
		if [ -s b1/clients/$f ]; then
			diff -u --label clients/$f --label clients/$f \
			     b1/clients/$f a1/clients/$f
		else
			diff -u --label /dev/null --label clients/$f \
			     /dev/null a1/clients/$f
		fi
	done
} > 0007-keyboard-pinyin.patch || true
diff -u --label clients/terminal.c --label clients/terminal.c \
     b1/clients/terminal.c a1/clients/terminal.c > 0008-terminal-delete.patch || true

# --- stage 2: 0009 + 0010 -------------------------------------------------
mkdir -p "$WORK/b2"
snap "$WORK/b2"
python3 "$P/apply-keyboard-shortcuts.py" "$W"
python3 "$P/apply-terminal-keysym.py" "$W"
mkdir -p "$WORK/a2"
snap "$WORK/a2"
diff -u --label clients/keyboard.c --label clients/keyboard.c \
     b2/clients/keyboard.c a2/clients/keyboard.c > 0009-keyboard-shortcuts.patch || true
diff -u --label clients/terminal.c --label clients/terminal.c \
     b2/clients/terminal.c a2/clients/terminal.c > 0010-terminal-keysym-mods.patch || true

cd "$WORK"
for pair in "0007-keyboard-pinyin.patch:0007" "0008-terminal-delete.patch:0008" \
            "0009-keyboard-shortcuts.patch:0009" \
            "0010-terminal-keysym-mods.patch:0010"; do
	f=${pair%%:*}
	cp "$f" "$PATCHES/$f"
	wc -l "$PATCHES/$f"
	cp "$f" "<tmpdir>/$f"
done
echo "patches regenerated; build with tools/m1/build-weston-clients.sh on device"
rm -rf "$BASE" "$WORK"
