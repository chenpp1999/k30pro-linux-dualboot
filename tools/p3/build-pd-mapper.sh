#!/bin/sh
# SPDX-License-Identifier: MIT
# P3: build + install pd-mapper on the device (the apps-side servreg locator).
#
# Why: the kernel's audio PDR chain needs an apps-side SERVREG_LOC (QMI 0x40)
# service; without it apr_adsp_up() never runs and no sound card appears (see
# docs/bluetooth-assessment.md 6c). Upstream pd-mapper cannot run here, so we
# apply two downstream adaptations (tools/p3/pd-mapper-downstream.patch):
#   1. no /sys/class/remoteproc in this msm-4.19 PIL kernel -> scan *.jsn
#      directly (PD_MAPPER_FIRMWARE_DIR, default /lib/firmware);
#   2. publish SERVREG_LOC as (0x40, 0x01, 0x01) to match the downstream
#      service_locator's lookup (upstream publishes 0x101/0).
#
# Build NATIVELY on the device (musl/aarch64) -- like the weston clients, a
# cross/host build would not match the rootfs libc.
#
# usage:
#   tools/p3/build-pd-mapper.sh [--work <dir>] [--prefix /usr]
#                               [--source <pristine-upstream-tree>]
#                               [--no-install] [--dry-run]
#
# --source skips the (network) git clone and builds from a pristine upstream
# tree (e.g. an export of the pinned commit); the downstream patch is still
# applied.  Handy when the device has no/limited network.
#
# deps installed on demand: build-base git qrtr-dev xz-dev
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
UPSTREAM=https://github.com/linux-msm/pd-mapper
COMMIT=5ecd2fe926aca7abfe40724177f63b942cff3947
PATCH=$HERE/pd-mapper-downstream.patch
WORK=/root/p3-pd-mapper
PREFIX=/usr
SOURCE=
INSTALL=1
DRY=0

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    --source) SOURCE=$2; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -r "$PATCH" ] || die "missing patch: $PATCH"

if [ "$DRY" = 1 ]; then
  if [ -n "$SOURCE" ]; then
    echo "DRY-RUN: use source tree $SOURCE (skips git clone)"
  else
    echo "DRY-RUN: git clone $UPSTREAM -> $WORK/src && checkout $COMMIT"
  fi
  echo "DRY-RUN: apk add build-base git qrtr-dev xz-dev   (if missing)"
  echo "DRY-RUN: git apply $PATCH"
  echo "DRY-RUN: make -j2  &&  timeout 2 ./pd-mapper (sanity)"
  [ "$INSTALL" = 1 ] && echo "DRY-RUN: install pd-mapper -> $PREFIX/bin + /etc/init.d/pd-mapper + rc-update add pd-mapper default"
  exit 0
fi

[ "$(id -u)" = 0 ] || die "run as root (native build + install into /)"
command -v apk >/dev/null 2>&1 || die "apk not found (Alpine rootfs expected)"

have_build_deps() {
  command -v cc >/dev/null 2>&1 || return 1
  command -v make >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  [ -f /usr/include/libqrtr.h ] || return 1
  [ -f /usr/include/lzma.h ] || return 1
  return 0
}
if ! have_build_deps; then
  echo "==> installing build deps (build-base git qrtr-dev xz-dev)"
  apk add --no-cache build-base git qrtr-dev xz-dev
fi

echo "==> fetching pd-mapper @ $COMMIT"
mkdir -p "$WORK"
cd "$WORK"
if [ -n "$SOURCE" ]; then
  echo "==> using source tree $SOURCE"
  [ -d "$SOURCE" ] || die "--source not found: $SOURCE"
  rm -rf src
  cp -a "$SOURCE" src || die "failed to copy $SOURCE"
else
  if [ ! -d src/.git ]; then
    rm -rf src
    git clone "$UPSTREAM" src
  fi
  cd src
  git checkout -q -- . 2>/dev/null || true
  git fetch -q origin
  git checkout -q "$COMMIT" || die "cannot check out $COMMIT"
  git checkout -q -- .
  cd "$WORK"
fi
cd src

echo "==> applying downstream patch"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH" || die "patch failed to apply"
else
  echo "(patch already applied to the source tree)"
fi

echo "==> building (native musl)"
make clean >/dev/null 2>&1 || true
make -j2

echo "==> sanity check"
out=$(timeout 2 ./pd-mapper 2>&1 || true)
echo "$out"
case "$out" in
  *"no pd maps available"*)
    die "pd-mapper found no PD maps -- are the *.jsn in /lib/firmware? (tools/p3/install-adsp-firmware.sh)" ;;
esac

if [ "$INSTALL" = 1 ]; then
  echo "==> installing"
  install -D -m 755 pd-mapper "$PREFIX/bin/pd-mapper"
  install -D -m 755 "$HERE/pd-mapper.openrc" /etc/init.d/pd-mapper
  install -D -m 644 "$HERE/pd-mapper.confd" /etc/conf.d/pd-mapper
  rc-update add pd-mapper default >/dev/null 2>&1 || true
  rc-service pd-mapper restart >/dev/null 2>&1 || rc-service pd-mapper start || true
  sleep 1
  echo "==> pd-mapper: $(rc-service pd-mapper status 2>&1 | tail -1)"
  echo "==> qrtr services:"
  command -v qrtr-lookup >/dev/null 2>&1 && timeout 5 qrtr-lookup 2>/dev/null | grep -iE 'registry|service registry' || true
fi

echo
echo "NOTE: the kernel's service_locator only retries within one boot"
echo "(service_timedout is sticky), so REBOOT and then run"
echo "  tools/p3/audio-probe.sh   # expect a sound card in /proc/asound/cards"
