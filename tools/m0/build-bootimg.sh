#!/bin/sh
# Assemble the M0 Android boot image (header v2, 4096 pages) for lmi.
# Layout matches deviceinfo-xiaomi-lmi offsets; RAM boot only, never flashed.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORKDIR="${WORKDIR:-$HERE/out}"
OUT="${OUT:-$WORKDIR/boot-m0.img}"
CMDLINE=$(cat "$HERE/kernel-cmdline.txt")

mkbootimg \
  --header_version 2 \
  --pagesize 4096 \
  --kernel "$WORKDIR/vmlinuz" \
  --ramdisk "$WORKDIR/initramfs.cpio.gz" \
  --dtb "$WORKDIR/kona-v2.1-lmi.dtb" \
  --cmdline "$CMDLINE" \
  --base 0x00000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00000000 \
  --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 \
  -o "$OUT"

ls -l "$OUT"
sha256sum "$OUT"
