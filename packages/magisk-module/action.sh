#!/system/bin/sh
# SPDX-License-Identifier: MIT
# Magisk action button: one-key Android -> Linux (M2 v0.1, ADR-0001).
#
# Requires:
#   - recovery-swap.sh deployed (default: Termux home)
#   - a Linux boot image that passed method A (attestation); set
#     LMI_SWITCH_FORCE=1 only for rescue/testing (see docs/m2-runbook.md)
#
# The switch writes the image to `recovery`, sets the one-shot BCB in `misc`
# and reboots; the Linux init clears the BCB, so any later reboot returns to
# Android. The `boot` partition is never modified.
set -eu

SWAP=${LMI_SWITCH_SCRIPT:-/data/data/com.termux/files/home/recovery-swap.sh}
IMG=${LMI_SWITCH_IMG:-/data/local/lmi-dualboot/boot-m1b-v6.img}

[ -f "$SWAP" ] || { echo "switch script not found: $SWAP"; exit 1; }
[ -f "$IMG" ] || { echo "Linux boot image not found: $IMG"; exit 1; }

if [ "${LMI_SWITCH_FORCE:-0}" = "1" ]; then
  sh "$SWAP" to-linux --force "$IMG"
else
  sh "$SWAP" to-linux "$IMG"
fi
