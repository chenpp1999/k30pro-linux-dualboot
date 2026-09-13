#!/system/bin/sh
# SPDX-License-Identifier: MIT
# recovery-swap — fail-safe Linux boot deployment via the recovery partition.
#
# Architecture (ADR-0001): the Android boot partition is never modified.
# The Linux boot image goes to `recovery`, entered via a one-shot BCB command
# (`reboot recovery`); the Linux initramfs clears the BCB early so any later
# reboot returns to Android.
#
# Deployment gate (issue #1): `to-linux` refuses images without a recorded
# method-A RAM-boot (attestation) and a sha256 manifest. If the kernel never
# starts, the BCB is never cleared and the device may loop into fastboot.
# Rescue from a USB host:  fastboot erase misc && fastboot reboot
# (`misc` is the only erase exception, ever — see docs/m0-runbook.md §5.)
#
# Usage (as root):
#   recovery-swap.sh backup                    # MUST run first: back up recovery + boot
#   recovery-swap.sh attest-ramboot <img>      # mark image as method-A RAM-boot verified
#   recovery-swap.sh to-linux [--dry-run] [--force] <img>
#   recovery-swap.sh restore-twrp              # put the TWRP backup back into recovery
#   recovery-swap.sh status                    # show backup state
set -eu

DIR=${LMI_DB_DIR:-/data/local/lmi-dualboot}
# Partition nodes are whitelisted by-name symlinks on lmi (docs/architecture.md §2).
RECOVERY=/dev/block/by-name/recovery
BOOT=/dev/block/by-name/boot
TWRP_IMG=$DIR/recovery-twrp.img
BOOT_IMG=$DIR/boot-android.img

die() { echo "FATAL: $*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
file_size() { stat -c %s "$1" 2>/dev/null || echo ""; }
part_size() { blockdev --getsize64 "$1" 2>/dev/null || echo ""; }
magic_md5() { dd if="$1" bs=1 count=8 2>/dev/null | md5sum | awk '{print $1}'; }
ANDROID_MAGIC_MD5=$(printf 'ANDROID!' | md5sum | awk '{print $1}')

cmd_backup() {
  [ -b "$RECOVERY" ] || die "recovery partition not found"
  [ -b "$BOOT" ] || die "boot partition not found"
  mkdir -p "$DIR"
  echo "backing up recovery -> $TWRP_IMG"
  dd if="$RECOVERY" of="$TWRP_IMG" bs=1M 2>/dev/null || die "dd recovery failed"
  echo "backing up boot     -> $BOOT_IMG"
  dd if="$BOOT" of="$BOOT_IMG" bs=1M 2>/dev/null || die "dd boot failed"
  sha "$TWRP_IMG" > "$TWRP_IMG.sha256"
  sha "$BOOT_IMG" > "$BOOT_IMG.sha256"
  echo "backup OK:"
  echo "  recovery-twrp.img  $(sha "$TWRP_IMG")"
  echo "  boot-android.img   $(sha "$BOOT_IMG")"
}

cmd_attest_ramboot() {
  [ -n "${1:-}" ] || die "usage: recovery-swap.sh attest-ramboot <boot.img>"
  IMG=$1
  [ -f "$IMG" ] || die "image not found: $IMG"
  GOT=$(sha "$IMG")
  if [ -f "$IMG.sha256" ]; then
    WANT=$(awk '{print $1}' "$IMG.sha256")
    [ "$WANT" = "$GOT" ] || die "sha256 mismatch for $IMG (want $WANT got $GOT)"
  fi
  {
    echo "# Method-A RAM boot (fastboot boot) verified on this device. Do not edit."
    echo "sha256=$GOT"
    echo "verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$IMG.ramboot-ok"
  echo "attestation written: $IMG.ramboot-ok"
  echo "  sha256=$GOT"
}

require_sha256() {
  [ -f "$IMG.sha256" ] || die "no $IMG.sha256 manifest; refusing unverified image (create it with sha256sum; --force overrides as a last resort)"
  WANT=$(awk '{print $1}' "$IMG.sha256")
  GOT=$(sha "$IMG")
  [ "$WANT" = "$GOT" ] || die "sha256 mismatch for $IMG (want $WANT got $GOT)"
  echo "preflight: image sha256 verified: $GOT"
}

require_attestation() {
  [ -f "$IMG.ramboot-ok" ] || die "no $IMG.ramboot-ok attestation: image was not RAM-boot verified (method A). Run 'attest-ramboot' after a successful 'fastboot boot'; --force overrides as a last resort (BCB residue can lock the device into fastboot)"
  A_WANT=$(awk -F= '$1=="sha256"{print $2}' "$IMG.ramboot-ok")
  [ -n "$A_WANT" ] || die "malformed attestation file: $IMG.ramboot-ok"
  A_GOT=$(sha "$IMG")
  [ "$A_WANT" = "$A_GOT" ] || die "attestation mismatch: $IMG.ramboot-ok is for a different image (attested $A_WANT got $A_GOT)"
  echo "preflight: RAM-boot attestation verified ($A_GOT)"
}

cmd_to_linux() {
  DRY=0
  FORCE=0
  IMG=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY=1 ;;
      --force) FORCE=1 ;;
      -*) die "unknown option: $arg" ;;
      *) [ -z "$IMG" ] || die "unexpected extra argument: $arg"; IMG=$arg ;;
    esac
  done
  [ -n "$IMG" ] || die "usage: recovery-swap.sh to-linux [--dry-run] [--force] <boot.img>"
  [ -f "$IMG" ] || die "image not found: $IMG"
  [ -f "$TWRP_IMG" ] || die "no TWRP backup found; run 'backup' first"

  if [ "$FORCE" = 1 ]; then
    echo "WARNING: --force: skipping sha256/attestation gates; BCB residue can lock the device into fastboot"
  else
    require_sha256
    require_attestation
  fi

  GOT=$(magic_md5 "$IMG")
  [ "$GOT" = "$ANDROID_MAGIC_MD5" ] || die "$IMG is not an Android boot image (no ANDROID! magic)"

  ISZ=$(file_size "$IMG")
  PSZ=$(part_size "$RECOVERY")
  if [ -n "$ISZ" ] && [ -n "$PSZ" ]; then
    [ "$ISZ" -le "$PSZ" ] || die "image too large for recovery partition ($ISZ > $PSZ bytes)"
    echo "preflight: image fits recovery partition ($ISZ <= $PSZ bytes)"
  else
    echo "WARN: could not determine image/partition size; skipping size check"
  fi

  if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: preflight passed; would write $IMG -> recovery and 'reboot recovery'"
    exit 0
  fi

  echo "writing $IMG -> recovery"
  dd if="$IMG" of="$RECOVERY" bs=1M 2>/dev/null || die "dd write failed"
  sync
  GOT=$(magic_md5 "$RECOVERY")
  [ "$GOT" = "$ANDROID_MAGIC_MD5" ] || die "post-write verify failed (magic md5 $GOT)"
  echo "post-write verify OK (ANDROID! header present)"
  echo "done. rebooting into recovery (Linux)..."
  echo "NOTE: if Linux never starts and the device loops into fastboot, rescue from a USB host:"
  echo "      fastboot erase misc && fastboot reboot"
  reboot recovery
}

cmd_restore_twrp() {
  [ -f "$TWRP_IMG" ] || die "no TWRP backup found"
  echo "restoring TWRP -> recovery"
  dd if="$TWRP_IMG" of="$RECOVERY" bs=1M 2>/dev/null || die "dd restore failed"
  sync
  echo "TWRP restored. Run 'reboot recovery' to enter TWRP."
}

cmd_status() {
  echo "dir: $DIR"
  if [ -d "$DIR" ]; then ls -l "$DIR"; else echo "(no backup directory yet)"; fi
  if [ -f "$TWRP_IMG" ]; then echo "recovery backup sha256: $(sha "$TWRP_IMG")"; fi
  if [ -f "$BOOT_IMG" ]; then echo "boot backup sha256:     $(sha "$BOOT_IMG")"; fi
  echo "(RAM-boot attestations live next to each image as <img>.ramboot-ok)"
}

case "${1:-}" in
  backup) cmd_backup ;;
  attest-ramboot) shift; cmd_attest_ramboot "${1:-}" ;;
  to-linux) shift; cmd_to_linux "$@" ;;
  restore-twrp) cmd_restore_twrp ;;
  status) cmd_status ;;
  *) die "usage: recovery-swap.sh {backup|attest-ramboot <img>|to-linux [--dry-run] [--force] <img>|restore-twrp|status}" ;;
esac
