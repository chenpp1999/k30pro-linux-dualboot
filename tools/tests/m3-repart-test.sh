#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for lmi-repart.sh (M3 planner v0.1).
#
# Works on a synthetic GPT disk image: no real partition, no destructive
# operation.  Requires sgdisk (gdisk package) and a POSIX shell; runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPART=$HERE/../m3/lmi-repart.sh
[ -f "$REPART" ] || { echo "script not found: $REPART" >&2; exit 1; }

command -v sgdisk >/dev/null 2>&1 || { echo "SKIP: sgdisk not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export LMI_DISK="$TMP/disk.img"
export LMI_DB_DIR="$TMP/db"
export LMI_REPART_OFFLINE=1

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { sh "$REPART" "$@"; }

# Sparse 1 GiB disk, GPT with a 512 MiB userdata partition carrying an f2fs
# magic (octal escapes: dash's printf has no \xHH)
dd if=/dev/zero of="$LMI_DISK" bs=1M count=0 seek=1024 2>/dev/null
sgdisk -n 1:2048:+1048576 -c 1:userdata -t 1:8300 "$LMI_DISK" >/dev/null 2>&1
printf '\020\040\365\362' | dd of="$LMI_DISK" bs=1 seek=$((2048 * 512 + 1024)) conv=notrunc 2>/dev/null

echo "== T1: status"
out=$(run status) || fail "status failed"
echo "$out" | grep -q "userdata" && ok "status lists userdata" || fail "status output"
echo "$out" | sed 's/^/    /'

echo "== T2: plan (dry-run)"
if run plan --lnx-size 256M >"$TMP/plan.out" 2>&1; then
	ok "plan succeeded"
else
	fail "plan failed: $(cat "$TMP/plan.out")"
fi
grep -q "resize.f2fs" "$TMP/plan.out" && ok "plan mentions resize.f2fs" || fail "plan steps"
grep -q "sgdisk -n" "$TMP/plan.out" && ok "plan mentions the new GPT entry" || fail "plan steps"
[ -f "$LMI_DB_DIR/plan.json" ] && ok "plan.json written" || fail "plan.json missing"
sed 's/^/    /' "$TMP/plan.out"

echo "== T3: plan refuses a non-f2fs userdata"
dd if=/dev/zero of="$LMI_DISK" bs=1 seek=$((2048 * 512 + 1024)) count=4 conv=notrunc 2>/dev/null
if run plan --lnx-size 256M >/dev/null 2>&1; then
	fail "plan accepted a partition without an f2fs superblock"
else
	ok "plan refuses non-f2fs userdata"
fi
printf '\020\040\365\362' | dd of="$LMI_DISK" bs=1 seek=$((2048 * 512 + 1024)) conv=notrunc 2>/dev/null

echo "== T4: plan refuses an oversized lnx"
if run plan --lnx-size 2G >/dev/null 2>&1; then
	fail "plan accepted a 2G lnx on a 1G disk"
else
	ok "plan refuses the oversized lnx"
fi

echo "== T5: backup + verify"
run backup >"$TMP/backup.out" 2>&1 || fail "backup failed"
[ -f "$LMI_DB_DIR/gpt-backup.bin" ] && ok "GPT backup file" || fail "GPT backup missing"
[ -f "$LMI_DB_DIR/manifest.txt" ] && ok "manifest" || fail "manifest missing"
run verify >"$TMP/verify.out" 2>&1 && ok "verify passes right after backup" || fail "verify failed"
sed 's/^/    /' "$TMP/verify.out"

echo "== T6: verify detects a changed table"
sgdisk -c 1:userdata-renamed "$LMI_DISK" >/dev/null 2>&1
if run verify >/dev/null 2>&1; then
	fail "verify did not notice the table change"
else
	ok "verify detects table changes"
fi
sgdisk -c 1:userdata "$LMI_DISK" >/dev/null 2>&1

echo "== T7: restore requires --yes and works"
if run restore >/dev/null 2>&1; then
	fail "restore ran without --yes"
else
	ok "restore refuses without --yes"
fi
run restore --yes >"$TMP/restore.out" 2>&1 && ok "restore --yes succeeded" || fail "restore failed"
run verify >"$TMP/verify2.out" 2>&1 && ok "verify passes after restore" || fail "verify after restore"

echo "== T8: apply refuses (planner-only v0.1)"
if run apply >/dev/null 2>&1; then
	fail "apply executed (must refuse in v0.1)"
else
	ok "apply refuses in v0.1"
fi

if [ "$fails" -gt 0 ]; then
	echo "M3 repart tests: $fails failure(s)"
	exit 1
fi
echo "M3 repart tests: all passed"
