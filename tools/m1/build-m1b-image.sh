#!/bin/sh
# SPDX-License-Identifier: MIT
# build-m1b-image.sh — assemble the M1b boot image (RAM initramfs + optional
# persistent-rootfs overlay) from a prepared rootfs tree.
#
# Never writes to a device (deployment is tools/m1/recovery-swap.sh).
#
# usage:
#   tools/m1/build-m1b-image.sh \
#     --tree <new-rootfs-tree> \
#     --initramfs-dir <dir> \
#     --kernel <vmlinuz> --dtb <dtb> --cmdline <file> \
#     --overlay-version <ver> --out <boot-m1b.img> \
#     [--base-image <rootfs.img> | --base-tree <deployed-tree>] \
#     [--overlay-out <file>] [--dry-run]
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/../.." && pwd)

TREE=
INITRAMFS_DIR=
KERNEL=
DTB=
CMDLINE=
OVERLAY_VERSION=
OUT=
BASE_IMAGE=
BASE_TREE=
OVERLAY_OUT=
DRY=0

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE=$2; shift 2 ;;
    --initramfs-dir) INITRAMFS_DIR=$2; shift 2 ;;
    --kernel) KERNEL=$2; shift 2 ;;
    --dtb) DTB=$2; shift 2 ;;
    --cmdline) CMDLINE=$2; shift 2 ;;
    --overlay-version) OVERLAY_VERSION=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --base-image) BASE_IMAGE=$2; shift 2 ;;
    --base-tree) BASE_TREE=$2; shift 2 ;;
    --overlay-out) OVERLAY_OUT=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$TREE" ] || die "--tree required"
[ -d "$TREE" ] || die "tree not found: $TREE"
if [ -z "$INITRAMFS_DIR" ] || [ ! -d "$INITRAMFS_DIR" ]; then
  die "--initramfs-dir required"
fi
for f in "$KERNEL" "$DTB" "$CMDLINE"; do
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    die "missing input: $f"
  fi
done
[ -n "$OVERLAY_VERSION" ] || die "--overlay-version required"
[ -n "$OUT" ] || die "--out required"

command -v mkbootimg >/dev/null || die "mkbootimg not found"
command -v cpio >/dev/null || die "cpio not found"
command -v gzip >/dev/null || die "gzip not found"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lmi-m1b-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

if [ "$DRY" = 1 ]; then
  echo "DRY-RUN: tree=$TREE"
  echo "DRY-RUN: initramfs=$INITRAMFS_DIR (init <- $ROOT/tools/m1/m1b-init.sh)"
  [ -n "$BASE_IMAGE" ] && echo "DRY-RUN: baseline image=$BASE_IMAGE (extract to diff)"
  [ -n "$BASE_TREE" ] && echo "DRY-RUN: baseline tree=$BASE_TREE"
  echo "DRY-RUN: would write overlay=$OVERLAY_VERSION, out=$OUT"
  exit 0
fi

# 1) init script into the initramfs
cp "$ROOT/tools/m1/m1b-init.sh" "$INITRAMFS_DIR/init"
chmod 755 "$INITRAMFS_DIR/init"

# 2) overlay (delta against the deployed rootfs)
rm -f "$INITRAMFS_DIR/m1b-overlay.tar.gz"
if [ -n "$BASE_IMAGE" ] || [ -n "$BASE_TREE" ]; then
  if [ -n "$BASE_IMAGE" ]; then
    debugfs -R "rdump / $WORK/base" "$BASE_IMAGE" >/dev/null 2>&1 \
      || die "failed to extract baseline image: $BASE_IMAGE"
    BASE_TREE=$WORK/base
  fi
  : "${OVERLAY_OUT:=$OUT.overlay.tar.gz}"
  python3 "$HERE/mk-overlay.py" --old "$BASE_TREE" --new "$TREE" \
    --out "$OVERLAY_OUT" --version "$OVERLAY_VERSION" || die "overlay generation failed"
  cp "$OVERLAY_OUT" "$INITRAMFS_DIR/m1b-overlay.tar.gz"
fi

# 3) initramfs cpio.gz (ownership forced to root in the archive; the build
#    tree may be owned by the unprivileged builder)
( cd "$INITRAMFS_DIR" && find . -print | cpio -o -H newc --owner root:root 2>/dev/null | gzip -9 ) > "$WORK/initramfs.cpio.gz"

# 4) boot image
mkbootimg --header_version 2 --pagesize 4096 \
  --kernel "$KERNEL" --ramdisk "$WORK/initramfs.cpio.gz" --dtb "$DTB" \
  --cmdline "$(cat "$CMDLINE")" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --second_offset 0x00000000 --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
  -o "$OUT"

# 5) manifest
sha256sum "$OUT" | tee "$OUT.sha256"
KERNEL_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
DTB_SHA=$(sha256sum "$DTB" | awk '{print $1}')
INITRAMFS_BYTES=$(stat -c %s "$WORK/initramfs.cpio.gz")
IMAGE_BYTES=$(stat -c %s "$OUT")
{
  echo "built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "overlay_version: $OVERLAY_VERSION"
  echo "kernel_sha256: $KERNEL_SHA"
  echo "dtb_sha256: $DTB_SHA"
  echo "initramfs_bytes: $INITRAMFS_BYTES"
  echo "image_bytes: $IMAGE_BYTES"
} > "$OUT.buildinfo"
ls -l "$OUT"
