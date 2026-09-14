#!/bin/sh
# SPDX-License-Identifier: MIT
# patch-rootfs-image.sh - patch files inside the M1b ext4 rootfs image offline.
#
# WHY: an image dumped from the super free area can carry a non-empty ext4
# journal (force reboot / unclean unmount). Writing with debugfs while the
# journal is pending is unsafe: the next `e2fsck -fy` (or the kernel mount)
# replays the journal and can silently revert the patch. Observed 2026-09-14:
# /etc/conf.d/dropbear came back as a 190-byte truncation after journal replay.
# This tool therefore replays the journal FIRST, patches, fixes counters, then
# verifies every file with dump+cmp.
#
# usage:
#   tools/m1/patch-rootfs-image.sh --image rootfs.img \
#     --put <local-file>:<path/in/image>[:<mode>] [--put ...] [--dry-run]
#
# Never touches a device (images only). Device deployment is TWRP `dd` /
# tools/m1/recovery-swap.sh. Requires: debugfs, e2fsck, sha256sum, cmp.
set -eu

IMG=
DRY=0
PUTS=

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMG=$2; shift 2 ;;
    --put) PUTS="$PUTS $2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$IMG" ] || die "--image required"
[ -f "$IMG" ] || die "image not found: $IMG"
[ -n "$PUTS" ] || die "at least one --put required"
for t in debugfs e2fsck sha256sum cmp; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

echo "== 1. replay journal + baseline check (e2fsck -fy then -fn) =="
if [ "$DRY" = 1 ]; then
  echo "dry-run: e2fsck -fy $IMG; e2fsck -fn $IMG"
else
  e2fsck -fy "$IMG" >/dev/null 2>&1 || true
  e2fsck -fn "$IMG" >/dev/null 2>&1 || die "filesystem not clean after replay"
fi

echo "== 2. apply files =="
for spec in $PUTS; do
  lf=${spec%%:*}
  rest=${spec#*:}
  ip=${rest%%:*}
  md=${rest##*:}
  [ "$md" = "$rest" ] && md=0644
  case "$md" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
    *) die "mode must be octal (e.g. 0644/0755): $md" ;;
  esac
  [ -f "$lf" ] || die "local file not found: $lf"
  echo "   $lf -> $ip (mode $md)"
  if [ "$DRY" = 1 ]; then continue; fi
  debugfs -w -R "rm $ip" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write $lf $ip" "$IMG" >/dev/null
  debugfs -w -R "sif $ip mode 010$md" "$IMG" >/dev/null
  debugfs -w -R "sif $ip uid 0" "$IMG" >/dev/null
  debugfs -w -R "sif $ip gid 0" "$IMG" >/dev/null
done

echo "== 3. counters (e2fsck -fy) =="
if [ "$DRY" = 1 ]; then
  echo "dry-run: e2fsck -fy $IMG"
else
  e2fsck -fy "$IMG" >/dev/null 2>&1 || true
fi

echo "== 4. verify (dump + cmp) =="
if [ "$DRY" != 1 ]; then
  for spec in $PUTS; do
    lf=${spec%%:*}
    rest=${spec#*:}
    ip=${rest%%:*}
    tmp=$(mktemp)
    debugfs -R "dump $ip $tmp" "$IMG" >/dev/null 2>&1
    if cmp -s "$tmp" "$lf"; then
      echo "   OK $ip"
    else
      rm -f "$tmp"
      die "verification failed for $ip"
    fi
    rm -f "$tmp"
  done
fi

echo "== 5. image sha256 =="
sha256sum "$IMG"
