#!/system/bin/sh
# SPDX-License-Identifier: MIT
# recovery-swap — fail-safe Linux boot deployment via the recovery partition.
#
# Architecture (ADR-0001): the Android boot partition is never modified.
# The Linux boot image goes to `recovery`, entered via a one-shot BCB command
# (`reboot recovery`); the Linux initramfs clears the BCB early so any later
# reboot returns to Android.
#
# Usage (as root):
#   recovery-swap.sh backup                 # MUST run first: back up recovery + boot
#   recovery-swap.sh to-linux <boot.img>    # write image to recovery and reboot into it
#   recovery-swap.sh restore-twrp           # put the TWRP backup back into recovery
#   recovery-swap.sh status                 # show backup state
set -eu

DIR=${LMI_DB_DIR:-/data/local/lmi-dualboot}
RECOVERY=/dev/block/by-name/recovery
BOOT=/dev/block/by-name/boot
TWRP_IMG=$DIR/recovery-twrp.img
BOOT_IMG=$DIR/boot-android.img

die() { echo "FATAL: $*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }

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

cmd_to_linux() {
  [ -n "${1:-}" ] || die "usage: recovery-swap.sh to-linux <boot.img>"
  IMG=$1
  [ -f "$IMG" ] || die "image not found: $IMG"
  [ -f "$TWRP_IMG" ] || die "no TWRP backup found; run 'backup' first"
  if [ -f "$IMG.sha256" ]; then
    WANT=$(awk '{print $1}' "$IMG.sha256")
    GOT=$(sha "$IMG")
    [ "$WANT" = "$GOT" ] || die "sha256 mismatch for $IMG (want $WANT got $GOT)"
    echo "image sha256 verified: $GOT"
  else
    echo "WARN: no $IMG.sha256; skipping image verification"
  fi
  echo "writing $IMG -> recovery"
  dd if="$IMG" of="$RECOVERY" bs=1M 2>/dev/null || die "dd write failed"
  sync
  echo "done. rebooting into recovery (Linux)..."
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
}

case "${1:-}" in
  backup) cmd_backup ;;
  to-linux) shift; cmd_to_linux "${1:-}" ;;
  restore-twrp) cmd_restore_twrp ;;
  status) cmd_status ;;
  *) die "usage: recovery-swap.sh {backup|to-linux <img>|restore-twrp|status}" ;;
esac
