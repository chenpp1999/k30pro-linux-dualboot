#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for the M5 PC installer (tools/install/lmi-install.sh) and the
# boot-image cmdline patcher (tools/install/patch-cmdline.py).
#
# Everything runs against synthetic files: a fake `super` with real LP metadata,
# a fake boot image, and a small fake rootfs.  No adb, no fastboot, no device.
# Runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INSTALL=$HERE/../install/lmi-install.sh
PATCHER=$HERE/../install/patch-cmdline.py
[ -f "$INSTALL" ] || { echo "script not found: $INSTALL" >&2; exit 1; }
[ -f "$PATCHER" ] || { echo "script not found: $PATCHER" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run_install() { sh "$INSTALL" "$@"; }
P=python3

# --- synthetic artifacts ----------------------------------------------------
python3 - "$TMP" <<'PY'
import hashlib, os, struct, sys

tmp = sys.argv[1]

# 1) fake supers: 3 GiB sparse, LP metadata, one partition starting at 2 MiB.
GEOM_MAGIC, HDR_MAGIC, BLOCK, MAXSZ, SLOTS = 0x616C4467, 0x414C5030, 4096, 4096, 1
DEVICE_BYTES = 3 * 1024 * 1024 * 1024
PART_START = 4096

def build_super(path, part_sectors):
    g = struct.pack("<II32sIII", GEOM_MAGIC, 52, b"\0" * 32, MAXSZ, SLOTS, BLOCK)
    g = struct.pack("<II32sIII", GEOM_MAGIC, 52, hashlib.sha256(g).digest(), MAXSZ, SLOTS, BLOCK)
    tables = struct.pack("<36sIIII", b"system", 0, 0, 1, 0) + \
             struct.pack("<QIQI", part_sectors, 0, PART_START, 0) + \
             struct.pack("<36sIQ", b"qti_dynamic_partitions", 0, 0) + \
             struct.pack("<QIIQ36sI", 2048, 1048576, 0, DEVICE_BYTES, b"super", 0)
    descs = struct.pack("<III", 0, 1, 52) + struct.pack("<III", 52, 1, 24) + \
            struct.pack("<III", 76, 1, 48) + struct.pack("<III", 124, 1, 64)
    header = struct.pack("<IHHI32sI32s", HDR_MAGIC, 10, 0, 128, b"\0" * 32,
                         len(tables), hashlib.sha256(tables).digest()) + descs
    header = header[:12] + hashlib.sha256(header).digest() + header[44:]
    with open(path, "wb") as f:
        f.truncate(DEVICE_BYTES)
        f.seek(0x1000); f.write(g)
        f.seek(0x2000); f.write(g)
        f.seek(0x3000); f.write(header)
        f.seek(0x3000 + 128); f.write(tables)

build_super(os.path.join(tmp, "super.img"), 8192)                       # 4 MiB used
build_super(os.path.join(tmp, "super-full.img"), DEVICE_BYTES // 512 - PART_START)  # full

# 2) fake boot images (header v2, one page)
def boot(path, cmdline):
    page = 4096
    hdr = bytearray(page)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<9I", hdr, 8, 0, 0, 0, 0, 0, 0, 0, page, 2)
    hdr[48:52] = b"test"
    hdr[64:64 + len(cmdline)] = cmdline
    open(path, "wb").write(bytes(hdr))

boot(os.path.join(tmp, "recovery-generic.img"), b"console=tty0 lmi_root_off=1596852")
boot(os.path.join(tmp, "twrp.img"), b"androidboot.hardware=qcom")

# 3) fake rootfs: 1 MiB (multiple of 4096), and an oversized one for the gate
with open(os.path.join(tmp, "rootfs.img"), "wb") as f:
    f.truncate(1024 * 1024)
with open(os.path.join(tmp, "rootfs-big.img"), "wb") as f:
    f.truncate(1536 * 1024 * 1024 + 4096)
PY

SUPER=$TMP/super.img
RECOVERY=$TMP/recovery-generic.img
ROOTFS=$TMP/rootfs.img
TWRP=$TMP/twrp.img
# expected: largest free region begins right after the partition extent
# partition: sectors [4096, 4096+8192) -> free tail starts at sector 12288.
EXPECT_BLOCKS=1536   # 12288 * 512 / 4096

echo "== T1: cmdline patcher sets and preserves keys"
$P "$PATCHER" "$RECOVERY" --set "lmi_root_off=$EXPECT_BLOCKS" --out "$TMP/recovery-patched.img" >/dev/null
patched=$($P "$PATCHER" "$TMP/recovery-patched.img" --show)
case "$patched" in
*"console=tty0"*) ok "original cmdline preserved" ;;
*) fail "lost console=tty0: $patched" ;;
esac
case "$patched" in
*"lmi_root_off=$EXPECT_BLOCKS"*) ok "lmi_root_off set to $EXPECT_BLOCKS" ;;
*) fail "lmi_root_off not patched: $patched" ;;
esac

echo "== T2: plan selects the LP free region and the offset"
if run_install plan --recovery "$RECOVERY" --rootfs "$ROOTFS" --super "$SUPER" --work "$TMP/work" \
	>"$TMP/plan.out" 2>&1; then
	ok "plan succeeded"
else
	fail "plan failed: $(cat "$TMP/plan.out")"
fi
grep -q "lmi_root_off=$EXPECT_BLOCKS" "$TMP/plan.out" \
	&& ok "plan reports lmi_root_off=$EXPECT_BLOCKS" || fail "plan offset wrong"
sed 's/^/    /' "$TMP/plan.out"

echo "== T3: install --dry-run prints the ordered steps and writes nothing"
if run_install install --recovery "$RECOVERY" --rootfs "$ROOTFS" --twrp "$TWRP" \
	--super "$SUPER" --work "$TMP/work-dry" --yes --dry-run >"$TMP/install.out" 2>&1; then
	ok "install --dry-run succeeded"
else
	fail "install --dry-run failed: $(cat "$TMP/install.out")"
fi
grep -q "dd of=/dev/block/by-name/super bs=4096 seek=$EXPECT_BLOCKS" "$TMP/install.out" \
	&& ok "rootfs write targets super @ $EXPECT_BLOCKS" || fail "super write command missing"
grep -q "dd of=/dev/block/by-name/recovery bs=4096 seek=0" "$TMP/install.out" \
	&& ok "recovery write targets the recovery partition" || fail "recovery write command missing"
grep -q "boot-recovery" "$TMP/install.out" && ok "BCB set to boot-recovery" || fail "BCB step missing"
grep -q "fastboot boot" "$TMP/install.out" && ok "enters TWRP via fastboot boot (no flash)" || fail "TWRP step missing"
[ -e "$TMP/work-dry" ] && fail "dry-run created the work dir" || ok "dry-run left no work dir"
super_line=$(grep -n "seek=$EXPECT_BLOCKS" "$TMP/install.out" | head -1 | cut -d: -f1)
recovery_line=$(grep -n "of=/dev/block/by-name/recovery" "$TMP/install.out" | head -1 | cut -d: -f1)
bcb_line=$(grep -n "boot-recovery" "$TMP/install.out" | head -1 | cut -d: -f1)
if [ "$super_line" -lt "$recovery_line" ] && [ "$recovery_line" -lt "$bcb_line" ]; then
	ok "write order: super -> recovery -> BCB"
else
	fail "write order wrong ($super_line/$recovery_line/$bcb_line)"
fi

echo "== T4: oversized rootfs is refused"
if run_install plan --recovery "$RECOVERY" --rootfs "$TMP/rootfs-big.img" --super "$SUPER" \
	>/dev/null 2>&1; then
	fail "plan accepted a rootfs larger than the slot"
else
	ok "plan refuses an oversized rootfs"
fi

echo "== T5: a non-Android recovery image is refused"
head -c 4096 /dev/zero >"$TMP/notboot.img"
if run_install plan --recovery "$TMP/notboot.img" --rootfs "$ROOTFS" --super "$SUPER" \
	>/dev/null 2>&1; then
	fail "plan accepted a non-boot recovery image"
else
	ok "plan refuses a non-boot recovery image"
fi

echo "== T6: a super whose only free gap is too small is refused"
# super-full.img has a logical partition spanning to the end of super, so the
# only gap is the tiny one before it -> no 1.5 GiB slot exists -> refuse.
if run_install plan --recovery "$RECOVERY" --rootfs "$ROOTFS" --super "$TMP/super-full.img" \
	>/dev/null 2>&1; then
	fail "plan accepted a super with no usable free region"
else
	ok "plan refuses a super with no usable free region"
fi

if [ "$fails" -gt 0 ]; then
	echo "M5 install tests: $fails failure(s)"
	exit 1
fi
echo "M5 install tests: all passed"
