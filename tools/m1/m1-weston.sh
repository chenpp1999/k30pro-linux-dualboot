#!/bin/sh
# m1-weston: bring Weston up on the DSI panel (based on the verified D80
# lmi-weston-wrapper sequence): release the bootloader splash KMS state with
# modetest, then run weston with the DSI-only config and pixman renderer.

export XDG_RUNTIME_DIR=/run/lmi-weston
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "m1-weston: splash release"
work=$(mktemp -d /tmp/m1-weston.XXXXXX)
fifo=$work/input
mkfifo "$fifo"
tail -f /dev/null > "$fifo" &
feeder=$!
modetest -a -s '29@129:#0@XR24' -P '58@129:1080x2400@XR24' < "$fifo" &
mtest=$!
sleep 3
kill "$feeder" 2>/dev/null
wait "$mtest"
mtest_exit=$?
rm -rf "$work"
echo "m1-weston: splash release done (modetest exit=$mtest_exit)"

echo "m1-weston: starting weston (pixman, DSI-1)"
weston --config=/etc/xdg/weston/weston.ini \
  --backend=drm-backend.so --drm-device=card0 \
  --renderer=pixman --socket=wayland-0 --idle-time=0 \
  --continue-without-input --debug --log=/var/log/weston.log &
wpid=$!

i=0
while [ $i -lt 20 ]; do
  if [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then break; fi
  if ! kill -0 "$wpid" 2>/dev/null; then echo "m1-weston: weston died"; exit 1; fi
  i=$((i + 1))
  sleep 1
done
echo "m1-weston: wayland socket ready after ${i}s"

WAYLAND_DISPLAY=wayland-0 weston-terminal --maximized --font-size=16 &
WAYLAND_DISPLAY=wayland-0 weston-editor &
echo "m1-weston: clients launched"
wait "$wpid"
