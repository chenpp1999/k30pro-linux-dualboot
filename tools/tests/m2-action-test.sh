#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for the Magisk module action.sh image-selection logic (M2).
#
# Regression for 2026-09-16: the button picked the newest image in
# /sdcard (v11, unattested) while recovery already held the deployed Linux
# image, so FULL deploy hit the attestation gate and the FATAL was invisible.
#
# Everything runs with synthetic boot images, env overrides and
# LMI_SWITCH_DRY=1: no partition is written and nothing reboots.  CI-runnable.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/../.." && pwd)
ACTION=$REPO/packages/magisk-module/action.sh
SWAP=$REPO/tools/m1/recovery-swap.sh
[ -f "$ACTION" ] || { echo "script not found: $ACTION" >&2; exit 1; }
[ -f "$SWAP" ] || { echo "script not found: $SWAP" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# --- fixtures ---------------------------------------------------------------
python3 - "$TMP" <<'PY'
import os, struct, sys
tmp = sys.argv[1]
imgs = os.path.join(tmp, "imgs")
only = os.path.join(tmp, "imgs-newest")
os.makedirs(imgs); os.makedirs(only)

def boot(path, cmdline, filler=b""):
    b = bytearray(4096)
    b[0:8] = b"ANDROID!"
    struct.pack_into("<9I", b, 8, 0, 0, 0, 0, 0, 0, 0, 4096, 2)
    b[48:52] = b"test"
    b[64:64 + len(cmdline)] = cmdline
    b[512:512 + len(filler)] = filler
    open(path, "wb").write(bytes(b))

# the deployed Linux image (recovery) and a TWRP-like image
boot(os.path.join(tmp, "recovery-linux.img"), b"console=tty0 lmi_root_off=1596852")
boot(os.path.join(tmp, "recovery-twrp.img"), b"androidboot.hardware=qcom twrp")
# candidate images in /sdcard-style dirs
boot(os.path.join(imgs, "boot-m1b-v11.img"), b"console=tty0 lmi_root_off=1596852",
     filler=b"v11")
boot(os.path.join(imgs, "boot-m1b-v8.img"), b"console=tty0 lmi_root_off=1596852",
     filler=b"v8")
boot(os.path.join(only, "boot-m1b-v11.img"), b"console=tty0 lmi_root_off=1596852",
     filler=b"v11")
PY

add_attestation() { # $1 = image path  (sha256 manifest + .ramboot-ok)
	sha=$(sha256sum "$1" | cut -d' ' -f1)
	printf '%s  %s\n' "$sha" "$1" >"$1.sha256"
	{
		echo "# Method-A RAM boot (fastboot boot) verified on this device. Do not edit."
		echo "sha256=$sha"
		echo "verified_at=2026-09-16T00:00:00Z"
	} >"$1.ramboot-ok"
}
add_attestation "$TMP/imgs/boot-m1b-v8.img"

# fake partitions + the TWRP backup that recovery-swap.sh requires
dd if=/dev/zero of="$TMP/misc.img" bs=1M count=1 2>/dev/null
dd if=/dev/zero of="$TMP/boot.img" bs=1M count=8 2>/dev/null
cp "$TMP/recovery-linux.img" "$TMP/recovery.img"
mkdir -p "$TMP/db"
cp "$TMP/recovery-twrp.img" "$TMP/db/recovery-twrp.img"
cp "$TMP/boot.img" "$TMP/db/boot-android.img"

export LMI_SWITCH_SCRIPT="$SWAP"
export LMI_RECOVERY_DEV="$TMP/recovery.img"
export LMI_MISC_DEV="$TMP/misc.img"
export LMI_BOOT_DEV="$TMP/boot.img"
export LMI_DB_DIR="$TMP/db"
export LMI_SWITCH_DRY=1

# run with a given recovery image + image dir; prints combined output
run_action() { # $1 recovery image, $2 dirs, rest: extra env assignments via evaluate
	rec=$1
	dirs=$2
	cp "$rec" "$LMI_RECOVERY_DEV"
	LMI_SWITCH_DIRS=$dirs sh "$ACTION"
}

echo "== T1: recovery already holds Linux -> FAST, no image selection"
if out=$(run_action "$TMP/recovery-linux.img" "$TMP/imgs" 2>&1); then
	ok "exit 0"
else
	fail "exited non-zero: $out"
fi
case "$out" in
*"recovery already holds a Linux boot image"*) ok "fast path chosen" ;;
*) fail "did not choose the fast path: $out" ;;
esac
case "$out" in
*"full deployment"*) fail "tried to deploy an image: $out" ;;
*) ok "no deployment attempted" ;;
esac
case "$out" in
*v11*) fail "was distracted by the newer /sdcard image" ;;
*) ok "ignored the newer unattested image" ;;
esac

echo "== T2: recovery is TWRP -> newest *attested* image is deployed"
if out=$(run_action "$TMP/recovery-twrp.img" "$TMP/imgs" 2>&1); then
	ok "exit 0"
else
	fail "exited non-zero: $out"
fi
case "$out" in
*"boot-m1b-v8.img"*) ok "picked the attested v8" ;;
*) fail "did not pick v8: $out" ;;
esac
case "$out" in
*v11*) fail "picked the unattested v11" ;;
*) ok "skipped the unattested v11" ;;
esac

echo "== T3: only unattested images -> clear failure, no silent no-op"
if out=$(run_action "$TMP/recovery-twrp.img" "$TMP/imgs-newest" 2>&1); then
	fail "exited 0 with nothing deployable"
else
	ok "exited non-zero"
fi
case "$out" in
*"NOT attested"*) ok "diagnostic lists the unattested candidate" ;;
*) fail "missing diagnostic: $out" ;;
esac
case "$out" in
*"attest-ramboot"*) ok "diagnostic explains how to fix it" ;;
*) fail "missing fix hint: $out" ;;
esac

echo "== T4: LMI_SWITCH_FORCE=1 picks the newest image"
# (the unattested v11 still fails the child's gate in --dry-run, which is
#  correct; what matters here is the *selection*)
cp "$TMP/recovery-twrp.img" "$LMI_RECOVERY_DEV"
out=$(LMI_SWITCH_DIRS="$TMP/imgs" LMI_SWITCH_FORCE=1 sh "$ACTION" 2>&1) || true
case "$out" in
*v11*) ok "picked the newest v11 under FORCE" ;;
*) fail "did not pick v11: $out" ;;
esac
case "$out" in
*"boot-m1b-v8.img"*) fail "picked v8 instead of the newest" ;;
*) ok "did not fall back to v8" ;;
esac

echo "== T5: explicit LMI_SWITCH_IMG matching recovery -> FAST"
cp "$TMP/recovery-linux.img" "$TMP/explicit.img"
cp "$TMP/recovery-linux.img" "$LMI_RECOVERY_DEV"
if out=$(LMI_SWITCH_IMG="$TMP/explicit.img" LMI_SWITCH_DIRS="$TMP/imgs" sh "$ACTION" 2>&1); then
	ok "exit 0"
else
	fail "exited non-zero: $out"
fi
case "$out" in
*"recovery already holds this image"*) ok "fast path for the explicit image" ;;
*) fail "unexpected: $out" ;;
esac

echo "== T6: explicit unattested image -> gate error is visible"
if out=$(LMI_SWITCH_IMG="$TMP/imgs/boot-m1b-v11.img" LMI_SWITCH_DIRS="$TMP/imgs" \
	sh "$ACTION" 2>&1); then
	fail "accepted an unattested explicit image"
else
	ok "exited non-zero (gate)"
fi
case "$out" in
*FATAL*) ok "FATAL from the child is visible in the output" ;;
*) fail "gate error not visible: $out" ;;
esac

if [ "$fails" -gt 0 ]; then
	echo "M2 action tests: $fails failure(s)"
	exit 1
fi
echo "M2 action tests: all passed"
