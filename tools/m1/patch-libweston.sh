#!/bin/bash
# SPDX-License-Identifier: MIT
# Patch Alpine's libweston-14.0.2 (v3.23) to tolerate duplicate DRM formats.
#
# The msm (lmi) kernel reports duplicate entries in a plane's IN_FORMATS blob.
# Upstream asserts in weston_drm_format_array_add_format (drm-formats.c:131)
# and weston aborts at startup. This replaces the `bl __assert_fail` in that
# function with a NOP so duplicates are simply appended (same behavior as the
# pmOS-patched weston build used by the D80 baseline).
#
# Usage: patch-libweston.sh <libweston-14.so.0.0.2> [output]
# Requires: aarch64-linux-gnu-readelf / -objdump (binutils), python3.
set -euo pipefail

IN=${1:?usage: patch-libweston.sh <lib> [output]}
OUT=${2:-${IN}.patched}
CROSS=${CROSS:-aarch64-linux-gnu-}
READELF="${CROSS}readelf"
OBJDUMP="${CROSS}objdump"

cp -f "$IN" "$OUT"

SYM=$("$READELF" --dyn-syms -W "$OUT" | awk '/weston_drm_format_array_add_format$/ {print $2; exit}')
SIZE=$("$READELF" --dyn-syms -W "$OUT" | awk '/weston_drm_format_array_add_format$/ {print $3; exit}')
[ -n "$SYM" ] || { echo "ERROR: symbol not found (already stripped?)" >&2; exit 1; }

START=$((16#$SYM))
END=$((START + 16#$SIZE))
"$OBJDUMP" -d --start-address="$START" --stop-address="$END" "$OUT" > /tmp/libweston-dis.txt

BL=$(awk '/bl.*__assert_fail/ {gsub(":", "", $1); print $1; exit}' /tmp/libweston-dis.txt)
[ -n "$BL" ] || { echo "ERROR: __assert_fail call not found in function" >&2; exit 1; }
echo "assert call at VA $BL"

python3 - "$OUT" "$BL" <<'EOF'
import sys
path = sys.argv[1]
bl_va = int(sys.argv[2], 16)
data = bytearray(open(path, 'rb').read())
cur = data[bl_va:bl_va + 4]
if cur[3] >> 2 != 0x25:  # BL opcode check (100101 << 26)
    print('unexpected instruction bytes at %#x: %s' % (bl_va, cur.hex()))
    sys.exit(1)
data[bl_va:bl_va + 4] = bytes.fromhex('1f2003d5')  # NOP
open(path, 'wb').write(data)
print('patched -> NOP')
EOF

sha256sum "$OUT"
echo "done: $OUT"
