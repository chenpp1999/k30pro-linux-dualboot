#!/bin/sh
# SPDX-License-Identifier: MIT
# P3: extract the on-device ADSP firmware from an Android device over adb.
#
# READ-ONLY on the device (it copies the vendor firmware into /data/local/tmp and
# pulls that; no partition is written). The firmware is Qualcomm proprietary and
# must NOT enter the repository: --out defaults to a local staging directory and
# the recorded sha256 manifest is docs/firmware-inventory.md.
#
# usage:
#   tools/p3/extract-adsp-firmware.sh --out <dir> [--serial <serial>]
#                                     [--source <dir>] [--dry-run]
#
# The on-device source is the `firmware_mnt` partition (Linux /dev/sde51) mounted
# at /vendor/firmware_mnt/image on the Android side by the vendor init.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$HERE/adsp-firmware.sha256"
ADB=${ADB:-adb}
OUT=
SERIAL=
SOURCE=/vendor/firmware_mnt/image
DRY=0

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --serial) SERIAL=$2; shift 2 ;;
    --source) SOURCE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$OUT" ] || die "--out required (firmware must not be written into the repo)"
[ -r "$MANIFEST" ] || die "manifest not found: $MANIFEST"

FILES=$(awk '{print $2}' "$MANIFEST")
COUNT=$(printf '%s\n' "$FILES" | wc -l)
[ "$COUNT" -ge 20 ] || die "manifest looks truncated: $MANIFEST"

adb_run() {
  if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi
}

if [ "$DRY" = 1 ]; then
  echo "DRY-RUN: stage $SOURCE -> /data/local/tmp/p3fw on the device (as root)"
  echo "DRY-RUN: sha256sum -c (device) + adb pull -> $OUT + sha256sum -c (local)"
  echo "DRY-RUN: $COUNT files per $MANIFEST"
  exit 0
fi

command -v "$ADB" >/dev/null 2>&1 || die "adb not found (set ADB=...)"

mkdir -p "$OUT"

STAGE=/data/local/tmp/p3fw
DEVSH=$STAGE-stage.sh
DEVMAN=$STAGE.sha256

WORK=$(mktemp -d "${TMPDIR:-/tmp}/p3-fw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# Device-side stage+verify script: copy the vendor blobs, then check them against
# the manifest *on the device* too (so we prove the device file, not just a pull).
{
  echo '#!/system/bin/sh'
  echo 'set -e'
  echo "SRC='$SOURCE'"
  echo "D='$STAGE'"
  echo 'rm -rf "$D" && mkdir -p "$D"'
  echo 'cd "$SRC"'
  for f in $FILES; do
    echo "cp -f '$f' \"\$D/$f\""
  done
  echo 'chmod 644 "$D"/*'
  echo "cd \"\$D\" && sha256sum -c '$DEVMAN'"
} > "$WORK/stage.sh"

info "staging on device ($SOURCE -> $STAGE)"
adb_run push "$WORK/stage.sh" "$DEVSH" >/dev/null || die "adb push failed"
adb_run push "$MANIFEST" "$DEVMAN" >/dev/null || die "adb push manifest failed"
adb_run shell "su -c sh $DEVSH" || die "device staging/verify failed (Android + Magisk root required?)"

info "pulling to $OUT"
adb_run pull "$STAGE/." "$OUT" >/dev/null || die "adb pull failed"

info "verifying the pulled copy"
( cd "$OUT" && sha256sum -c "$MANIFEST" ) || die "sha256 mismatch after pull"

BYTES=$(du -sk "$OUT" | awk '{print $1 * 1024}')
info "OK: $COUNT files, $BYTES bytes in $OUT"
echo
echo "Next: put $OUT on the device and run (as root on the Linux side)"
echo "  tools/p3/install-adsp-firmware.sh --from <dir> --boot"
echo "See docs/bluetooth-assessment.md 6c for the full bring-up chain."
