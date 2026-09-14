#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline functional tests for recovery-swap.sh (M2 switch v0.1).
#
# Uses plain files as stand-in recovery/misc/boot partitions through the
# LMI_*_DEV overrides: no real partition is touched, no reboot happens.
# Runnable on a Linux host (CI) or on-device.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SWAP=$HERE/../m1/recovery-swap.sh
[ -f "$SWAP" ] || { echo "script not found: $SWAP" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export LMI_DB_DIR="$TMP/db"
export LMI_RECOVERY_DEV="$TMP/recovery.img"
export LMI_MISC_DEV="$TMP/misc.img"
export LMI_BOOT_DEV="$TMP/boot.img"

# Fake partitions: recovery 8 MiB, misc 1 MiB, boot 8 MiB.
dd if=/dev/zero of="$LMI_RECOVERY_DEV" bs=1M count=8 2>/dev/null
dd if=/dev/zero of="$LMI_MISC_DEV" bs=1M count=1 2>/dev/null
dd if=/dev/zero of="$LMI_BOOT_DEV" bs=1M count=8 2>/dev/null

# Fake Linux boot image (< recovery size): ANDROID! magic + payload.
{ printf 'ANDROID!'; dd if=/dev/urandom bs=1k count=64 2>/dev/null; } > "$TMP/boot-linux.img"

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
sha_of() { sha256sum "$1" | awk '{print $1}'; }
run() { sh "$SWAP" "$@"; }
bcb_hex_now() { dd if="$LMI_MISC_DEV" bs=1 count=32 2>/dev/null | od -An -v -tx1 | tr -d ' \n'; }
bcb_want_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }

echo "== T1: backup"
run backup >/dev/null
if [ -f "$LMI_DB_DIR/recovery-twrp.img" ] && [ -f "$LMI_DB_DIR/boot-android.img" ]; then
  ok "backup files created"
else
  fail "backup files missing"
fi
if [ "$(sha_of "$LMI_DB_DIR/boot-android.img")" = "$(sha_of "$LMI_BOOT_DEV")" ]; then
  ok "boot backup matches partition"
else
  fail "boot backup mismatch"
fi

echo "== T2: --dry-run runs preflight and writes nothing"
R0=$(sha_of "$LMI_RECOVERY_DEV")
M0=$(sha_of "$LMI_MISC_DEV")
if run to-linux --dry-run "$TMP/boot-linux.img" >/dev/null 2>&1; then
  fail "dry-run passed an ungated image"
else
  ok "dry-run refused (no manifest/attestation)"
fi
if [ "$(sha_of "$LMI_RECOVERY_DEV")" = "$R0" ]; then ok "recovery untouched"; else fail "recovery modified"; fi
if [ "$(sha_of "$LMI_MISC_DEV")" = "$M0" ]; then ok "misc untouched"; else fail "misc modified"; fi

echo "== T3: gate refuses image without attestation"
if run to-linux "$TMP/boot-linux.img" >/dev/null 2>&1; then
  fail "to-linux accepted an unattested image"
else
  ok "refused (no attestation)"
fi
if [ "$(sha_of "$LMI_RECOVERY_DEV")" = "$R0" ]; then ok "recovery still untouched"; else fail "recovery modified"; fi

echo "== T4: attest then to-linux --no-reboot"
run attest-ramboot "$TMP/boot-linux.img" >/dev/null
if [ -f "$TMP/boot-linux.img.ramboot-ok" ]; then ok "attestation written"; else fail "attestation missing"; fi
R1=$(sha_of "$LMI_RECOVERY_DEV")
if run to-linux --dry-run "$TMP/boot-linux.img" >/dev/null; then
  ok "dry-run passed after attestation"
else
  fail "dry-run failed after attestation"
fi
if [ "$(sha_of "$LMI_RECOVERY_DEV")" = "$R1" ]; then ok "dry-run left recovery untouched"; else fail "dry-run modified recovery"; fi
if run to-linux --no-reboot "$TMP/boot-linux.img" >/dev/null; then
  ok "to-linux --no-reboot exit 0"
else
  fail "to-linux failed"
fi
ISZ=$(stat -c %s "$TMP/boot-linux.img")
if [ "$(head -c "$ISZ" "$LMI_RECOVERY_DEV" | sha256sum | awk '{print $1}')" = "$(sha_of "$TMP/boot-linux.img")" ]; then
  ok "recovery content matches image"
else
  fail "recovery content mismatch"
fi
case "$(bcb_hex_now)" in
  "$(bcb_want_hex boot-recovery)"*) ok "BCB boot-recovery set" ;;
  *) fail "BCB wrong: $(bcb_hex_now)" ;;
esac

echo "== T5: sha mismatch refused"
run attest-ramboot "$TMP/boot-linux.img" >/dev/null
printf 'x' >> "$TMP/boot-linux.img"
if run to-linux --no-reboot "$TMP/boot-linux.img" >/dev/null 2>&1; then
  fail "accepted a sha-mismatched image"
else
  ok "refused (sha mismatch)"
fi

echo "== T6: bcb subcommand"
run bcb clear >/dev/null
if [ "$(bcb_hex_now)" = "$(printf '%064d' 0)" ]; then
  ok "BCB cleared"
else
  fail "BCB not cleared: $(bcb_hex_now)"
fi
run bcb boot-recovery >/dev/null
case "$(bcb_hex_now)" in
  "$(bcb_want_hex boot-recovery)"*) ok "BCB set via bcb subcommand" ;;
  *) fail "bcb boot-recovery failed: $(bcb_hex_now)" ;;
esac
run bcb clear >/dev/null

echo "== T7: --force bypasses gates but keeps magic/size checks"
printf 'not-an-image' > "$TMP/bad.img"
if run to-linux --force --no-reboot "$TMP/bad.img" >/dev/null 2>&1; then
  fail "accepted a non-Android image"
else
  ok "refused (no ANDROID! magic)"
fi
if run to-linux --force --no-reboot "$TMP/boot-linux.img" >/dev/null; then
  ok "--force accepted a valid magic image"
else
  fail "--force failed"
fi

echo "== T8: oversize image refused"
{ printf 'ANDROID!'; dd if=/dev/zero bs=1M count=9 2>/dev/null; } > "$TMP/big.img"
if run to-linux --force --no-reboot "$TMP/big.img" >/dev/null 2>&1; then
  fail "accepted an oversize image"
else
  ok "refused (too large)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "$fails test(s) failed"
exit 1
