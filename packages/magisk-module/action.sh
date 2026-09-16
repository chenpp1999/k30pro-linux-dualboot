#!/system/bin/sh
# SPDX-License-Identifier: MIT
# Magisk action button + CLI entry: one-key Android -> Linux (M2, ADR-0001).
#
# What the button does (first match wins):
#   1. LMI_SWITCH_IMG=<path> set         -> deploy *that* image (FAST if recovery
#                                           already holds it, else FULL).
#   2. recovery already holds Linux      -> FAST: only write the one-shot BCB
#      (ANDROID! magic + lmi_root_off=)      and reboot.  No image selection and
#                                           no attestation gate (nothing is
#                                           overwritten).
#   3. otherwise (recovery = TWRP/blank) -> pick the newest *method-A attested*
#                                           image and FULL-deploy it.
#
# Case 2 is the normal state of an installed device: `recovery` already carries
# the current Linux image (deployed by tools/m1/rebuild-image-from-device.sh),
# so tapping the button must just switch.  It must NOT try to re-deploy some
# older image sitting in /sdcard -- 2026-09-16: it did (v11), the attestation
# gate rejected it, the FATAL went to stderr and Magisk showed nothing, so the
# button looked dead.
#
# Deploying a *different* image is deliberate: pass LMI_SWITCH_IMG, or leave
# recovery as TWRP so case 3 applies.  Case 3 only uses images with a matching
# <img>.ramboot-ok attestation, unless LMI_SWITCH_FORCE=1 (rescue/testing).
#
# Image dirs for case 3 (newest by version):
#   /data/local/lmi-dualboot/boot-m1b-v*.img
#   /sdcard/Download/phone-server/lmi-m1b/boot-m1b-v*.img
#
# LMI_SWITCH_DRY=1 prints the plan and exits without touching anything.
# Test overrides: LMI_RECOVERY_DEV, LMI_SWITCH_DIRS, LMI_SWITCH_SCRIPT.
set -eu
# Magisk shows stdout in the Action window and not necessarily stderr: keep the
# child's FATAL visible.
exec 2>&1

MODDIR=${0%/*}
SWAP=${LMI_SWITCH_SCRIPT:-$MODDIR/recovery-swap.sh}
[ -f "$SWAP" ] || SWAP=/data/data/com.termux/files/home/recovery-swap.sh
RECOVERY=${LMI_RECOVERY_DEV:-/dev/block/by-name/recovery}
DIRS=${LMI_SWITCH_DIRS:-/data/local/lmi-dualboot /sdcard/Download/phone-server/lmi-m1b}
ANDROID_MAGIC_HEX=414e44524f494421

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

list_images() {
	for d in $DIRS; do
		[ -d "$d" ] || continue
		ls -1 "$d"/boot-m1b-v*.img 2>/dev/null
	done | sed 's/.*-v\([0-9][0-9]*\)\.img/\1 &/' | sort -n -k1 | cut -d' ' -f2-
}

is_android_boot_image() {
	[ -e "$1" ] || return 1
	magic=$(dd if="$1" bs=1 count=8 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
	[ "$magic" = "$ANDROID_MAGIC_HEX" ]
}

# The Linux recovery image carries `lmi_root_off=` in its boot cmdline (offset
# 64); TWRP does not.  That is how we tell "Linux is already installed" from
# "recovery still holds TWRP".
linux_in_recovery() {
	is_android_boot_image "$RECOVERY" || return 1
	dd if="$RECOVERY" bs=1 skip=64 count=1536 2>/dev/null | grep -q 'lmi_root_off='
}

pick_attested_image() {
	# newest image whose <img>.ramboot-ok sha matches the file (method A)
	chosen=
	for c in $(list_images); do
		[ -f "$c.ramboot-ok" ] || continue
		want=$(awk -F= '$1=="sha256"{print $2}' "$c.ramboot-ok")
		[ -n "$want" ] || continue
		[ "$want" = "$(sha_of "$c")" ] || continue
		chosen=$c
	done
	[ -n "$chosen" ] && { echo "$chosen"; return 0; }
	return 1
}

pick_newest_image() { list_images | tail -n 1; }

diagnose_no_image() {
	echo "no deployable Linux boot image."
	echo "candidates:"
	for c in $(list_images); do
		if [ -f "$c.ramboot-ok" ]; then st="attested"; else st="NOT attested"; fi
		echo "  $st  $c"
	done
	echo "to deploy an image it must first be RAM-booted (method A) and attested:"
	echo "  fastboot boot <img>            # from a PC, into Linux"
	echo "  sh $SWAP attest-ramboot <img>"
	echo "or force it (rescue/testing only, skips the gate):"
	echo "  LMI_SWITCH_FORCE=1 $0"
}

do_fast() {
	echo "$1"
	if [ "${LMI_SWITCH_DRY:-0}" = "1" ]; then
		echo "DRY-RUN: would run: sh $SWAP bcb boot-recovery && reboot"
		exit 0
	fi
	sh "$SWAP" bcb boot-recovery
	sync
	reboot
}

do_full() {
	img=$1
	echo "recovery differs -> full deployment of $img"
	if [ "${LMI_SWITCH_DRY:-0}" = "1" ]; then
		echo "DRY-RUN: would run: sh $SWAP to-linux $img"
		sh "$SWAP" to-linux --dry-run "$img"
		exit 0
	fi
	if [ "${LMI_SWITCH_FORCE:-0}" = "1" ]; then
		echo "WARNING: forcing deployment without the method-A attestation gate"
		exec sh "$SWAP" to-linux --force "$img"
	fi
	exec sh "$SWAP" to-linux "$img"
}

switch_to_image() {
	img=$1
	[ -f "$img" ] || { echo "image not found: $img"; exit 1; }
	size=$(stat -c %s "$img")
	sha=$(sha_of "$img")
	if [ -f "$img.sha256" ]; then
		file_sha=$(cut -d' ' -f1 <"$img.sha256")
		[ "$file_sha" = "$sha" ] || { echo "FATAL: $img does not match its .sha256"; exit 1; }
	fi
	echo "image:  $img ($size bytes, sha256 $(printf '%s' "$sha" | cut -c1-8))"
	cur=$(dd if="$RECOVERY" bs=4096 2>/dev/null | head -c "$size" | sha256sum | cut -d' ' -f1)
	if [ "$cur" = "$sha" ]; then
		do_fast "recovery already holds this image -> fast path (BCB only)"
	else
		do_full "$img"
	fi
}

[ -f "$SWAP" ] || { echo "switch script not found: $SWAP"; exit 1; }

# --- 1. explicit image ------------------------------------------------------
if [ -n "${LMI_SWITCH_IMG:-}" ]; then
	switch_to_image "$LMI_SWITCH_IMG"
	exit 0
fi

# --- 2. Linux already installed in recovery ---------------------------------
if linux_in_recovery; then
	do_fast "recovery already holds a Linux boot image -> fast path (BCB only)"
	exit 0
fi

# --- 3. deploy an image -----------------------------------------------------
if [ "${LMI_SWITCH_FORCE:-0}" = "1" ]; then
	IMG=$(pick_newest_image || true)
	if [ -n "$IMG" ]; then
		switch_to_image "$IMG"
		exit 0
	fi
	diagnose_no_image
	exit 1
fi

IMG=$(pick_attested_image || true)
if [ -z "$IMG" ]; then
	diagnose_no_image
	exit 1
fi
switch_to_image "$IMG"
