#!/bin/sh
# SPDX-License-Identifier: MIT
# build-weston-clients.sh — build the patched weston 14.0.2 clients for lmi.
#
# The phone's persistent rootfs ships two patched weston clients (see
# tools/m1/weston-patches/):
#   - weston-terminal: text-input v1 support so the Weston OSK can type here
#   - weston-keyboard: symbols `_ . ,`, key width fitted to 540 logical px,
#     immediate commit (no preedit buffering)
#
# Run this ON THE DEVICE (Alpine rootfs, aarch64, root). It installs build deps
# via apk, builds in /root/work/weston, and installs the two binaries (with
# .orig backups of the stock ones). ~700 MB of build deps are installed.
#
# Pitfalls (device-verified 2026-09-15):
#   - meson MUST be configured with -Dprefix=/usr: the default /usr/local makes
#     the clients look for theme files in /usr/local/share/weston, fail to load
#     them, and crash in window_frame_create (segfault at startup).
#   - weston-terminal needs the text-input v1 protocol sources added to its
#     clients/meson.build target (patch 0003).
#   - patches apply with -p0 (no a/ b/ prefixes).
set -eu

SRC_URL=https://gitlab.freedesktop.org/wayland/weston/-/releases/14.0.2/downloads/weston-14.0.2.tar.xz
SRC_SHA256=b47216b3530da76d02a3a1acbf1846a9cd41d24caa86448f9c46f78f20b6e0ac
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORK=${WORK:-/root/work/weston}
PATCHES=$HERE/weston-patches
[ -d "$PATCHES" ] || { echo "FATAL: patches dir not found: $PATCHES" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f weston-14.0.2.tar.xz ]; then
  echo "downloading weston 14.0.2"
  wget -O weston-14.0.2.tar.xz.part "$SRC_URL"
  mv weston-14.0.2.tar.xz.part weston-14.0.2.tar.xz
fi
echo "$SRC_SHA256  weston-14.0.2.tar.xz" | sha256sum -c - || {
  echo "FATAL: tarball sha256 mismatch" >&2; exit 1; }
rm -rf weston-14.0.2
tar -xf weston-14.0.2.tar.xz
cd weston-14.0.2

echo "installing build deps (this takes a while)"
apk add --no-cache build-base meson ninja pkgconf patch wayland-dev wayland-protocols \
  libxkbcommon-dev pixman-dev cairo-dev pango-dev libdrm-dev libinput-dev \
  libevdev-dev libseat-dev libdisplay-info-dev libwebp-dev libjpeg-turbo-dev \
  freetype-dev fontconfig-dev mtdev-dev dbus-dev eudev-dev libcap

for p in "$PATCHES"/*.patch; do
  echo "--- applying $(basename "$p")"
  patch -p0 -f < "$p"
done

meson setup build \
  -Dprefix=/usr \
  -Dbackend-drm=false -Dbackend-default=headless \
  -Dbackend-drm-screencast-vaapi=false -Dbackend-pipewire=false \
  -Dbackend-rdp=false -Dbackend-vnc=false -Dbackend-wayland=false -Dbackend-x11=false \
  -Drenderer-gl=false \
  -Dxwayland=false -Dsystemd=false -Dremoting=false -Dpipewire=false \
  -Dshell-desktop=true -Dshell-fullscreen=true -Dshell-ivi=false -Dshell-kiosk=true \
  -Dcolor-management-lcms=false \
  -Dimage-jpeg=true -Dimage-webp=true \
  -Dtools=terminal -Ddemo-clients=false -Dsimple-clients=im \
  -Dwcap-decode=false -Dtests=false -Ddoc=false
ninja -C build clients/weston-keyboard clients/weston-terminal

echo "installing (backups: *.orig)"
cp -n /usr/libexec/weston-keyboard /usr/libexec/weston-keyboard.orig 2>/dev/null || true
cp -n /usr/bin/weston-terminal /usr/bin/weston-terminal.orig 2>/dev/null || true
cp build/clients/weston-keyboard /usr/libexec/weston-keyboard
cp build/clients/weston-terminal /usr/bin/weston-terminal
chmod 755 /usr/libexec/weston-keyboard /usr/bin/weston-terminal
echo "done: $(sha256sum /usr/bin/weston-terminal /usr/libexec/weston-keyboard)"
