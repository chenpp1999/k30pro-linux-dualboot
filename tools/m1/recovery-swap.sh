#!/system/bin/sh
# SPDX-License-Identifier: MIT
# recovery-swap — fail-safe Linux boot deployment + one-shot BCB switch (M2 v0.1).
#
# Architecture (ADR-0001): the Android boot partition is never modified. The
# Linux boot image goes to `recovery`, entered via a one-shot BCB command in
# `misc` (`boot-recovery`); the Linux initramfs clears the BCB early so any
# later reboot returns to Android.
#
# Interruption safety: the recovery image is written and verified *before* the
# BCB is set, so a power cut during the (long) image write leaves the BCB
# empty and the next boot is Android. Only a cut inside the short
# BCB-write -> reboot window can leave the device in Linux; even then the next
# reboot returns to Android (the Linux init clears the BCB).
#
# Deployment gate (issue #1): `to-linux` refuses images without a recorded
# method-A RAM-boot (attestation) and a sha256 manifest. If the kernel never
# starts, the BCB is never cleared and the device may loop into fastboot.
# Rescue from a USB host:  fastboot erase misc && fastboot reboot
# (`misc` is the only erase exception, ever — see docs/m0-runbook.md §5.)
#
# Usage (as root):
#   recovery-swap.sh backup                                    # MUST run first
#   recovery-swap.sh attest-ramboot <img>                      # after method A
#   recovery-swap.sh to-linux [--dry-run] [--force] [--no-reboot] <img>
#   recovery-swap.sh bcb show|clear|boot-recovery [--dry-run]
#   recovery-swap.sh restore-twrp [--dry-run]
#   recovery-swap.sh status
#
# Test overrides (tools/tests/m2-switch-test.sh): LMI_RECOVERY_DEV,
# LMI_MISC_DEV and LMI_BOOT_DEV may point at plain files.
set -eu

DIR=${LMI_DB_DIR:-/data/local/lmi-dualboot}
# Partition nodes are whitelisted by-name symlinks on lmi (docs/architecture.md §2).
RECOVERY=${LMI_RECOVERY_DEV:-/dev/block/by-name/recovery}
MISC=${LMI_MISC_DEV:-/dev/block/by-name/misc}
BOOT=${LMI_BOOT_DEV:-/dev/block/by-name/boot}
TWRP_IMG=$DIR/recovery-twrp.img
BOOT_IMG=$DIR/boot-android.img
LOG=$DIR/switch.log
BCB_CMD=boot-recovery

die() { echo "FATAL: $*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
sha_stdin() { sha256sum | awk '{print $1}'; }
file_size() { stat -c %s "$1" 2>/dev/null || echo ""; }
part_size() { blockdev --getsize64 "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo ""; }
magic_md5() { dd if="$1" bs=1 count=8 2>/dev/null | md5sum | awk '{print $1}'; }
ANDROID_MAGIC_MD5=$(printf 'ANDROID!' | md5sum | awk '{print $1}')

# `reboot` is not always in PATH (e.g. a Magisk su shell from Termux): resolve it
# once, preferring the absolute toybox binary.
REBOOT_BIN=/system/bin/reboot
[ -x "$REBOOT_BIN" ] || REBOOT_BIN=$(command -v reboot) || REBOOT_BIN=reboot

log() {
  mkdir -p "$DIR"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

bcb_hex() { dd if="$MISC" bs=1 count=32 2>/dev/null | od -An -v -tx1 | tr -d ' \n'; }

bcb_show() {
  echo "bcb hex : $(bcb_hex)"
  echo "bcb text: $(dd if="$MISC" bs=1 count=32 2>/dev/null | tr -d '\000')"
}

bcb_write() {
  CMD=$1
  [ "${#CMD}" -le 31 ] || die "BCB command too long: $CMD"
  dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null || die "BCB zero failed"
  printf '%s' "$CMD" | dd of="$MISC" bs=1 conv=notrunc 2>/dev/null || die "BCB write failed"
  sync
  WANT=$(printf '%s' "$CMD" | od -An -tx1 | tr -d ' \n')
  GOT=$(bcb_hex)
  case "$GOT" in
    "$WANT"*) echo "BCB set and verified: $CMD" ;;
    *) die "BCB verify failed (want prefix $WANT got $GOT)" ;;
  esac
}

bcb_clear() {
  dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null || die "BCB clear failed"
  sync
  GOT=$(bcb_hex)
  ZERO=$(printf '%064d' 0)
  [ "$GOT" = "$ZERO" ] || die "BCB clear verify failed: $GOT"
  echo "BCB cleared and verified"
}

cmd_backup() {
  [ -e "$RECOVERY" ] || die "recovery partition not found"
  [ -e "$BOOT" ] || die "boot partition not found"
  mkdir -p "$DIR"
  echo "backing up recovery -> $TWRP_IMG"
  dd if="$RECOVERY" of="$TWRP_IMG" bs=1M 2>/dev/null || die "dd recovery failed"
  echo "backing up boot     -> $BOOT_IMG"
  dd if="$BOOT" of="$BOOT_IMG" bs=1M 2>/dev/null || die "dd boot failed"
  sha "$TWRP_IMG" > "$TWRP_IMG.sha256"
  sha "$BOOT_IMG" > "$BOOT_IMG.sha256"
  log "backup recovery=$(sha "$TWRP_IMG") boot=$(sha "$BOOT_IMG")"
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
  # Refresh the sha256 manifest too: to-linux requires it (issue #6).
  printf '%s  %s\n' "$GOT" "$IMG" > "$IMG.sha256"
  {
    echo "# Method-A RAM boot (fastboot boot) verified on this device. Do not edit."
    echo "sha256=$GOT"
    echo "verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$IMG.ramboot-ok"
  log "attest-ramboot img=$IMG sha256=$GOT"
  echo "attestation written: $IMG.ramboot-ok"
  echo "  sha256 manifest:   $IMG.sha256"
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
  NOREBOOT=0
  IMG=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY=1 ;;
      --force) FORCE=1 ;;
      --no-reboot) NOREBOOT=1 ;;
      -*) die "unknown option: $arg" ;;
      *) [ -z "$IMG" ] || die "unexpected extra argument: $arg"; IMG=$arg ;;
    esac
  done
  [ -n "$IMG" ] || die "usage: recovery-swap.sh to-linux [--dry-run] [--force] [--no-reboot] <boot.img>"
  [ -f "$IMG" ] || die "image not found: $IMG"
  [ -f "$TWRP_IMG" ] || die "no TWRP backup found; run 'backup' first"
  [ -e "$RECOVERY" ] || die "recovery partition not found: $RECOVERY"
  [ -e "$MISC" ] || die "misc partition not found: $MISC"

  if [ "$FORCE" = 1 ]; then
    echo "WARNING: --force: skipping sha256/attestation gates; BCB residue can lock the device into fastboot"
  else
    require_sha256
    require_attestation
  fi

  GOT=$(magic_md5 "$IMG")
  [ "$GOT" = "$ANDROID_MAGIC_MD5" ] || die "$IMG is not an Android boot image (no ANDROID! magic)"

  ISZ=$(file_size "$IMG")
  [ -n "$ISZ" ] || die "cannot stat image: $IMG"
  PSZ=$(part_size "$RECOVERY")
  if [ -n "$PSZ" ]; then
    [ "$ISZ" -le "$PSZ" ] || die "image too large for recovery partition ($ISZ > $PSZ bytes)"
    echo "preflight: image fits recovery partition ($ISZ <= $PSZ bytes)"
  else
    echo "WARN: could not determine partition size; skipping size check"
  fi

  WANT_SHA=$(sha "$IMG")

  if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: preflight passed; would write $IMG -> recovery and verify readback,"
    echo "DRY-RUN: then set BCB '$BCB_CMD' on misc and reboot recovery"
    echo "DRY-RUN: (no partition was written)"
    exit 0
  fi

  # 1) recovery image first: long phase, a cut here leaves the BCB empty.
  echo "writing $IMG -> recovery"
  dd if="$IMG" of="$RECOVERY" bs=1M conv=notrunc 2>/dev/null || die "dd write failed"
  sync
  echo "verifying recovery readback (sha256)"
  R_SHA=$(dd if="$RECOVERY" bs=4096 count=$(( (ISZ + 4095) / 4096 )) 2>/dev/null | head -c "$ISZ" | sha_stdin)
  [ "$R_SHA" = "$WANT_SHA" ] || die "post-write verify failed: recovery=$R_SHA image=$WANT_SHA"
  echo "post-write verify OK ($R_SHA)"

  # 2) one-shot BCB last: short phase, immediately followed by the reboot.
  echo "setting one-shot BCB '$BCB_CMD' on $MISC"
  bcb_write "$BCB_CMD"

  REBOOT_MODE=recovery
  if [ "$NOREBOOT" = 1 ]; then
    REBOOT_MODE=none
  fi
  log "to-linux img=$IMG sha256=$WANT_SHA recovery_verified=yes bcb=$BCB_CMD reboot=$REBOOT_MODE"

  if [ "$NOREBOOT" = 1 ]; then
    echo "not rebooting (--no-reboot). BCB is set: the next boot enters Linux."
    echo "run 'reboot recovery' when ready, or 'recovery-swap.sh bcb clear' to cancel."
    exit 0
  fi

  echo "done. rebooting into recovery (Linux)..."
  echo "NOTE: if Linux never starts and the device loops into fastboot, rescue from a USB host:"
  echo "      fastboot erase misc && fastboot reboot"
  "$REBOOT_BIN" recovery
}

cmd_bcb() {
  SUB=${1:-}
  [ -e "$MISC" ] || die "misc partition not found: $MISC"
  case "$SUB" in
    show)
      bcb_show
      ;;
    clear)
      [ "${2:-}" = "--dry-run" ] && { echo "DRY-RUN: would clear the BCB command field on $MISC"; exit 0; }
      bcb_clear
      log "bcb clear"
      ;;
    boot-recovery)
      [ "${2:-}" = "--dry-run" ] && { echo "DRY-RUN: would set BCB '$BCB_CMD' on $MISC"; exit 0; }
      bcb_write "$BCB_CMD"
      log "bcb $BCB_CMD"
      ;;
    *)
      die "usage: recovery-swap.sh bcb show|clear|boot-recovery [--dry-run]"
      ;;
  esac
}

cmd_restore_twrp() {
  DRY=0
  [ "${1:-}" = "--dry-run" ] && DRY=1
  [ -f "$TWRP_IMG" ] || die "no TWRP backup found"
  [ -e "$RECOVERY" ] || die "recovery partition not found: $RECOVERY"
  WANT=$(sha "$TWRP_IMG")
  if [ -f "$TWRP_IMG.sha256" ]; then
    M_WANT=$(awk '{print $1}' "$TWRP_IMG.sha256")
    [ "$M_WANT" = "$WANT" ] || die "TWRP backup sha256 mismatch (manifest $M_WANT file $WANT)"
    echo "preflight: backup sha256 verified: $WANT"
  else
    echo "WARN: no $TWRP_IMG.sha256; skipping backup verification"
  fi
  if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: preflight passed; would restore $TWRP_IMG -> recovery"
    exit 0
  fi
  echo "restoring TWRP -> recovery"
  dd if="$TWRP_IMG" of="$RECOVERY" bs=1M conv=notrunc 2>/dev/null || die "dd restore failed"
  sync
  TSZ=$(file_size "$TWRP_IMG")
  [ -n "$TSZ" ] || die "cannot stat $TWRP_IMG"
  R_SHA=$(dd if="$RECOVERY" bs=4096 count=$(( (TSZ + 4095) / 4096 )) 2>/dev/null | head -c "$TSZ" | sha_stdin)
  [ "$R_SHA" = "$WANT" ] || die "post-write verify failed: recovery=$R_SHA backup=$WANT"
  echo "post-write verify OK ($R_SHA)"
  log "restore-twrp sha256=$WANT"
  echo "TWRP restored. Run 'reboot recovery' to enter TWRP."
}

cmd_status() {
  echo "dir: $DIR"
  if [ -d "$DIR" ]; then ls -l "$DIR"; else echo "(no backup directory yet)"; fi
  if [ -f "$TWRP_IMG" ]; then echo "recovery backup sha256: $(sha "$TWRP_IMG")"; fi
  if [ -f "$BOOT_IMG" ]; then echo "boot backup sha256:     $(sha "$BOOT_IMG")"; fi
  if [ -e "$MISC" ]; then
    echo "BCB state:"
    bcb_show
  else
    echo "BCB state: misc not found ($MISC)"
  fi
  if [ -e "$RECOVERY" ]; then
    echo "recovery ANDROID! magic: $(magic_md5 "$RECOVERY")"
  fi
  echo "(RAM-boot attestations live next to each image as <img>.ramboot-ok)"
  if [ -f "$LOG" ]; then
    echo "switch log tail:"
    tail -n 3 "$LOG"
  fi
}

case "${1:-}" in
  backup) cmd_backup ;;
  attest-ramboot) shift; cmd_attest_ramboot "${1:-}" ;;
  to-linux) shift; cmd_to_linux "$@" ;;
  bcb) shift; cmd_bcb "$@" ;;
  restore-twrp) shift; cmd_restore_twrp "${1:-}" ;;
  status) cmd_status ;;
  *) die "usage: recovery-swap.sh {backup|attest-ramboot <img>|to-linux [--dry-run] [--force] [--no-reboot] <img>|bcb show|clear|boot-recovery [--dry-run]|restore-twrp [--dry-run]|status}" ;;
esac
