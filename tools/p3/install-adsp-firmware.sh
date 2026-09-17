#!/bin/sh
# SPDX-License-Identifier: MIT
# P3: install the ADSP firmware on the device (Linux side) and verify it.
#
# Run as root inside the persistent Linux rootfs. The kernel's PIL loader asks for
# `adsp.mdt` (DT `qcom,firmware-name = "adsp"`) via request_firmware(), so the
# split firmware must live in /lib/firmware/ (firmware is proprietary: it is NOT
# shipped in this repository, see docs/firmware-inventory.md).
#
# usage:
#   tools/p3/install-adsp-firmware.sh [--from <dir>] [--dest /lib/firmware]
#                                     [--manifest <file>] [--boot] [--dry-run]
#
# --boot writes the one-shot `1` to /sys/kernel/boot_adsp/boot (adsp-loader sysfs),
# which is what actually starts the ADSP. It does not touch any partition.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FROM=$HERE
DEST=/lib/firmware
MANIFEST=$HERE/adsp-firmware.sha256
BOOT=0
DRY=0

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=$2; shift 2 ;;
    --dest) DEST=$2; shift 2 ;;
    --manifest) MANIFEST=$2; shift 2 ;;
    --boot) BOOT=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -d "$FROM" ] || die "--from not found: $FROM"
[ -r "$MANIFEST" ] || die "manifest not found: $MANIFEST"
[ "$(id -u)" = 0 ] || die "must run as root"

FILES=$(awk '{print $2}' "$MANIFEST")

if [ "$DRY" = 1 ]; then
  echo "DRY-RUN: sha256sum -c $MANIFEST   (in $FROM)"
  echo "DRY-RUN: cp $FROM/<firmware> $DEST/   ($(printf '%s\n' "$FILES" | wc -l) files)"
  [ "$BOOT" = 1 ] && echo "DRY-RUN: echo 1 > /sys/kernel/boot_adsp/boot"
  exit 0
fi

info "verifying firmware source ($FROM)"
( cd "$FROM" && sha256sum -c "$MANIFEST" ) || die "source firmware does not match the manifest"

info "installing into $DEST"
mkdir -p "$DEST"
for f in $FILES; do
  cp -f "$FROM/$f" "$DEST/$f"
done
sync

info "verifying installed copy"
( cd "$DEST" && sha256sum -c "$MANIFEST" ) || die "installed firmware verification failed"

if [ "$BOOT" = 1 ]; then
  info "booting the ADSP (adsp-loader sysfs)"
  [ -w /sys/kernel/boot_adsp/boot ] || die "/sys/kernel/boot_adsp/boot missing (adsp-loader not bound?)"
  echo 1 > /sys/kernel/boot_adsp/boot
  sleep 6
  echo
  echo "--- dmesg (ADSP) ---"
  dmesg | grep -iE 'adsp|apr|q6|lpass' | tail -20 || true
fi

echo
echo "--- current state ---"
echo "sound cards:"; cat /proc/asound/cards 2>/dev/null || true
if command -v qrtr-lookup >/dev/null 2>&1; then
  echo "qrtr (service registry / audio):"
  timeout 10 qrtr-lookup 2>/dev/null | grep -iE 'registry|avs|audio|servreg' || echo "  (none yet)"
fi
echo
echo "See docs/bluetooth-assessment.md 6c: a sound card additionally needs the"
echo "apps-side SERVREG_LOC (0x40) service, i.e. a working pd-mapper."
