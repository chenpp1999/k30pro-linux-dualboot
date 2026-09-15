#!/system/bin/sh
# SPDX-License-Identifier: MIT
# Magisk action button + CLI entry: one-key Android -> Linux (M2 v0.1, ADR-0001).
#
# Two paths:
#   1. FAST  - `recovery` already contains the selected image (byte-identical
#              sha256): only the one-shot BCB is written and the device reboots.
#              Nothing is overwritten; no attestation gate needed.
#   2. FULL  - different image: delegates to recovery-swap.sh to-linux, which
#              writes the image, verifies the read-back, sets the BCB and
#              reboots.  Refuses images without a method-A attestation unless
#              LMI_SWITCH_FORCE=1 (rescue/testing only).
#
# Image selection (first hit wins):
#   $LMI_SWITCH_IMG                        explicit path
#   /data/local/lmi-dualboot/boot-m1b-v*.img    newest by version
#   /sdcard/Download/phone-server/lmi-m1b/boot-m1b-v*.img  newest by version
#
# LMI_SWITCH_DRY=1 prints the plan and exits without touching anything.
set -eu

MODDIR=${0%/*}
SWAP=${LMI_SWITCH_SCRIPT:-$MODDIR/recovery-swap.sh}
[ -f "$SWAP" ] || SWAP=/data/data/com.termux/files/home/recovery-swap.sh
RECOVERY=/dev/block/by-name/recovery

pick_image() {
	[ -n "${LMI_SWITCH_IMG:-}" ] && { echo "$LMI_SWITCH_IMG"; return; }
	# newest boot-m1b-vNN.img across all known dirs (highest NN wins)
	for d in /data/local/lmi-dualboot /sdcard/Download/phone-server/lmi-m1b; do
		[ -d "$d" ] || continue
		ls -1 "$d"/boot-m1b-v*.img 2>/dev/null
	done | sed 's/.*-v\([0-9]*\)\.img/\1 &/' | sort -n | tail -1 | cut -d' ' -f2-
}

IMG=$(pick_image)
[ -n "${IMG:-}" ] || {
	echo "no Linux boot image found (looked in /data/local/lmi-dualboot,"
	echo "/sdcard/Download/phone-server/lmi-m1b); set LMI_SWITCH_IMG=<path>"
	exit 1
}
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
[ -f "$SWAP" ] || { echo "switch script not found: $SWAP"; exit 1; }

SIZE=$(stat -c %s "$IMG")
IMG_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
if [ -f "$IMG.sha256" ]; then
	FILE_SHA=$(cut -d' ' -f1 < "$IMG.sha256")
	[ "$FILE_SHA" = "$IMG_SHA" ] || { echo "FATAL: $IMG does not match its .sha256"; exit 1; }
fi

echo "image:      $IMG ($SIZE bytes, sha256 ${IMG_SHA%????????????????????????????????????????????????????????})"
echo "switch:     $SWAP"

if [ "${LMI_SWITCH_DRY:-0}" = "1" ]; then
	echo "DRY-RUN: checking whether recovery already holds this image"
	CUR=$(dd if="$RECOVERY" bs=4096 2>/dev/null | head -c "$SIZE" | sha256sum | cut -d' ' -f1)
	echo "recovery:   sha256 ${CUR%????????????????????????????????????????????????????????}"
	if [ "$CUR" = "$IMG_SHA" ]; then
		echo "DRY-RUN: FAST path would run: sh $SWAP bcb boot-recovery && reboot"
	else
		echo "DRY-RUN: FULL path would run: sh $SWAP to-linux --dry-run $IMG"
		sh "$SWAP" to-linux --dry-run "$IMG"
	fi
	exit 0
fi

CUR=$(dd if="$RECOVERY" bs=4096 2>/dev/null | head -c "$SIZE" | sha256sum | cut -d' ' -f1)
if [ "$CUR" = "$IMG_SHA" ]; then
	echo "recovery already holds this image -> fast path (BCB only)"
	sh "$SWAP" bcb boot-recovery
	sync
	reboot
	exit 0
fi

echo "recovery differs -> full deployment"
if [ "${LMI_SWITCH_FORCE:-0}" = "1" ]; then
	echo "WARNING: forcing deployment without the method-A attestation gate"
	exec sh "$SWAP" to-linux --force "$IMG"
fi
exec sh "$SWAP" to-linux "$IMG"
