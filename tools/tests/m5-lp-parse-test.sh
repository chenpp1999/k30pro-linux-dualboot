#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for tools/install/lp-metadata.py (M5 installer groundwork).
#
# Builds a synthetic `super` image carrying real liblp metadata (geometry +
# header + table checksums computed the AOSP way) and asserts that the parser
# recovers the partitions and the free regions.  No device, no root: the image
# lives in a mktemp dir.  Runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PARSER=$HERE/../install/lp-metadata.py
[ -f "$PARSER" ] || { echo "script not found: $PARSER" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { python3 "$PARSER" "$@"; }

SUPER=$TMP/super.img
SUPER_BAD=$TMP/super-bad.img

# --- synthetic super image --------------------------------------------------
python3 - "$SUPER" "$SUPER_BAD" <<'PY'
import hashlib, struct, sys

GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
BLOCK = 4096          # LP logical block size
MAXSZ = 4096          # metadata_max_size (one slot)
SLOTS = 1
DEVICE_BYTES = 64 * 1024 * 1024          # 128 MiB / 512 = 262144 sectors
PART_START = 4096     # 512-byte sectors, 2 MiB in
PART_SECTORS = 8192   # 4 MiB

# LpMetadataGeometry
g = struct.pack("<II32sIII", GEOM_MAGIC, 52, b"\0" * 32, MAXSZ, SLOTS, BLOCK)
g = struct.pack("<II32sIII", GEOM_MAGIC, 52, hashlib.sha256(g).digest(), MAXSZ, SLOTS, BLOCK)

# tables: 1 partition, 1 extent, 1 group, 1 block device
partitions = struct.pack("<36sIIII", b"system", 0, 0, 1, 0)
extents = struct.pack("<QIQI", PART_SECTORS, 0, PART_START, 0)
groups = struct.pack("<36sIQ", b"qti_dynamic_partitions", 0, 0)
blockdev = struct.pack("<QIIQ36sI", 2048, 1048576, 0, DEVICE_BYTES, b"super", 0)
tables = partitions + extents + groups + blockdev
p_off, e_off, gr_off, b_off = 0, len(partitions), len(partitions) + len(extents), \
    len(partitions) + len(extents) + len(groups)
descs = struct.pack("<III", p_off, 1, 52) + struct.pack("<III", e_off, 1, 24) + \
    struct.pack("<III", gr_off, 1, 48) + struct.pack("<III", b_off, 1, 64)
header = struct.pack("<IHHI32sI32s", HDR_MAGIC, 10, 0, 128, b"\0" * 32,
                     len(tables), hashlib.sha256(tables).digest()) + descs
hcs = hashlib.sha256(header).digest()
header = header[:12] + hcs + header[44:]

def build(path, corrupt):
    with open(path, "wb") as f:
        f.truncate(DEVICE_BYTES)
        f.seek(0x1000); f.write(g)          # primary geometry
        f.seek(0x2000); f.write(g)          # backup geometry
        f.seek(0x3000); f.write(header)     # primary metadata slot 0
        f.seek(0x3000 + 128); f.write(tables)
        if corrupt:                          # clobber the header magic
            f.seek(0x3000); f.write(b"\x00\x00\x00\x00")

build(sys.argv[1], False)
build(sys.argv[2], True)
PY

echo "== T1: info recovers the partition table"
if run info "$SUPER" >"$TMP/info.out" 2>&1; then
	ok "info succeeded"
	grep -q "system" "$TMP/info.out" && ok "info lists the system partition" || fail "partition missing"
	grep -q "qti_dynamic_partitions" "$TMP/info.out" && ok "info lists the group" || fail "group missing"
else
	fail "info failed: $(cat "$TMP/info.out")"
fi
if grep -qi warning "$TMP/info.out"; then
	fail "unexpected checksum warning on valid metadata"
else
	ok "no checksum warnings on valid metadata"
fi
sed 's/^/    /' "$TMP/info.out"

echo "== T2: free regions (reserved prefix + partition extent are excluded)"
run info "$SUPER" >"$TMP/info2.out" 2>&1
# reserved prefix = 0x3000 + 2*4096 = 0x5000 = 20480 B = 40 sectors
grep -q "offset .* 40 .*size .* 4056 " "$TMP/info2.out" \
	&& ok "gap between reserved prefix and the partition is reported" \
	|| fail "expected free [40,4096) not found"
# tail free region: [4096+8192, 262144) = 249856 sectors = 128 MiB - 6 MiB
grep -q "offset .* 12288 .*" "$TMP/info2.out" \
	&& ok "tail free region starts after the last extent" \
	|| fail "tail free region missing"

echo "== T3: select picks the largest aligned region"
out=$(run select "$SUPER" --size 32M --align 1M) || fail "select failed"
echo "    $out"
case "$out" in
	*"offset_sectors=12288"*) ok "select chose the tail region" ;;
	*) fail "select chose the wrong region" ;;
esac

echo "== T4: select fails cleanly when nothing is big enough"
if run select "$SUPER" --size 1T >/dev/null 2>&1; then
	fail "select accepted a 1 TiB request on a 64 MiB device"
else
	ok "select exits non-zero when the request cannot fit"
fi

echo "== T5: corrupt metadata is rejected, not misparsed"
if run info "$SUPER_BAD" >/dev/null 2>&1; then
	fail "info accepted a clobbered header magic"
else
	ok "info rejects clobbered metadata"
fi

echo "== T6: a file that is not a super image is rejected"
head -c 65536 /dev/zero >"$TMP/not-super.img"
if run info "$TMP/not-super.img" >/dev/null 2>&1; then
	fail "info accepted a zero-filled file"
else
	ok "info rejects a non-super file"
fi

echo "== T7: json output is valid and machine-readable"
run json "$SUPER" >"$TMP/meta.json" 2>/dev/null || fail "json failed"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["partitions"][0]["name"] == "system", d["partitions"]
assert d["free"], "no free regions"
assert d["block_devices"][0]["size"] == 64 * 1024 * 1024, d["block_devices"]
' "$TMP/meta.json" && ok "json structure is as expected" || fail "json structure"

if [ "$fails" -gt 0 ]; then
	echo "M5 lp-metadata tests: $fails failure(s)"
	exit 1
fi
echo "M5 lp-metadata tests: all passed"
