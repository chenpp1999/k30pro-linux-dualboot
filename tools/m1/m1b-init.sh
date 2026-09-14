#!/bin/busybox sh
# M1b init — persistent rootfs bring-up.
#
# This initramfs is RAM-only and small. It clears the one-shot BCB, brings up
# the NCM gadget (plus a rescue dropbear), then loop-mounts the ext4 rootfs
# image that lives in the free space of the Android `super` partition
# (offset given by "lmi_root_off=" in the kernel cmdline, in 4096-byte blocks)
# and switch_roots into it. Everything else (udev, seatd, weston, ssh) runs
# from OpenRC inside the persistent rootfs.

BB=/bin/busybox

ROOT_OFF_BLOCKS=""
for w in $($BB cat /proc/cmdline); do
  case "$w" in lmi_root_off=*) ROOT_OFF_BLOCKS=${w#lmi_root_off=} ;; esac
done
[ -n "$ROOT_OFF_BLOCKS" ] || ROOT_OFF_BLOCKS=1596852

$BB mount -t proc none /proc
$BB mount -t sysfs none /sys
$BB mount -t devtmpfs none /dev 2>/dev/null
$BB mkdir -p /dev/pts
$BB mount -t devpts none /dev/pts 2>/dev/null
$BB mkdir -p /run /tmp /root /newroot /etc/dropbear
$BB mount -t tmpfs none /run 2>/dev/null
$BB mount -t tmpfs none /tmp 2>/dev/null
$BB mount -t configfs none /sys/kernel/config 2>/dev/null

echo "===== M1b init (persistent rootfs) ====="

# --- One-shot boot flag (BCB) cleanup ---
MISC=""
for b in /sys/class/block/sda*; do
  if $BB grep -q "^PARTNAME=misc$" "$b/uevent" 2>/dev/null; then
    MISC="/dev/$($BB basename "$b")"
    break
  fi
done
# whitelisted fallback node (lmi misc = sda11, docs/architecture.md §2)
[ -n "$MISC" ] || MISC=/dev/sda11
if [ -b "$MISC" ]; then
  $BB dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null
  echo "BCB cleared on $MISC"
fi

# --- USB network gadget: NCM preferred, RNDIS fallback ---
G=/sys/kernel/config/usb_gadget/g1
NETFUNC=""
if [ -d /sys/kernel/config/usb_gadget ] && [ ! -d "$G" ]; then
  $BB mkdir -p "$G"
  echo 0x0525 > "$G/idVendor"
  echo 0xa4a2 > "$G/idProduct"
  $BB mkdir -p "$G/strings/0x409"
  echo "lmi-m1b-0001" > "$G/strings/0x409/serialnumber"
  echo "k30pro-linux-dualboot" > "$G/strings/0x409/manufacturer"
  echo "M1b persistent" > "$G/strings/0x409/product"
  $BB mkdir -p "$G/configs/c.1/strings/0x409"
  if $BB mkdir -p "$G/functions/ncm.usb0" 2>/dev/null; then
    NETFUNC=ncm.usb0
  else
    $BB mkdir -p "$G/functions/rndis.usb0"
    NETFUNC=rndis.usb0
  fi
  echo "$NETFUNC" > "$G/configs/c.1/strings/0x409/configuration"
  $BB ln -s "$G/functions/$NETFUNC" "$G/configs/c.1/" 2>/dev/null
  UDC=$($BB ls /sys/class/udc 2>/dev/null | $BB head -n1)
  if [ -n "$UDC" ]; then echo "$UDC" > "$G/UDC"; fi
fi

i=0
while [ $i -lt 15 ]; do
  [ -e /sys/class/net/usb0 ] && break
  i=$((i + 1))
  $BB sleep 1
done
$BB ip link set usb0 up 2>/dev/null
$BB ip addr add 172.16.42.1/24 dev usb0 2>/dev/null

# --- locate the super partition (by GPT PARTNAME) ---
SUPER=""
for b in /sys/class/block/sda*; do
  if $BB grep -q "^PARTNAME=super$" "$b/uevent" 2>/dev/null; then
    SUPER="/dev/$($BB basename "$b")"
    break
  fi
done
# whitelisted fallback node (lmi super = sda32, docs/architecture.md §2)
[ -n "$SUPER" ] || SUPER=/dev/sda32
echo "super device: $SUPER"

# --- loop-mount the persistent rootfs at the recorded offset ---
# The rescue dropbear is started only if this fails, so it can never hold
# port 22 into the persistent system (issue found on the v1/v2 attempts).
[ -e /dev/loop0 ] || $BB mknod /dev/loop0 b 7 0
OFFSET=$((ROOT_OFF_BLOCKS * 4096))
if ! $BB losetup -o "$OFFSET" /dev/loop0 "$SUPER"; then
  echo "FATAL: losetup failed (offset=$OFFSET)"
  /usr/sbin/dropbear -R -p 22 2>/dev/null
  while true; do $BB sleep 3600; done
fi
if ! $BB mount -t ext4 -o rw /dev/loop0 /newroot; then
  echo "FATAL: mount ext4 failed (loop0@$SUPER offset=$OFFSET)"
  $BB losetup -d /dev/loop0 2>/dev/null
  /usr/sbin/dropbear -R -p 22 2>/dev/null
  while true; do $BB sleep 3600; done
fi
echo "persistent rootfs mounted ($SUPER offset=$OFFSET)"

# Belt-and-suspenders: kill any dropbear that might still be around (shell
# builtins only: read + kill; no pkill/kill applet dependency).
for pdir in /proc/[0-9]*; do
  comm=""
  read -r comm < "$pdir/comm" 2>/dev/null || true
  [ "$comm" = "dropbear" ] || continue
  pid=${pdir#/proc/}
  kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
done

# --- move pseudo filesystems into the new root, then switch_root ---
$BB mount --move /dev /newroot/dev
$BB mount --move /proc /newroot/proc
$BB mount --move /sys /newroot/sys
$BB mount --move /run /newroot/run 2>/dev/null || true
$BB mount --move /tmp /newroot/tmp 2>/dev/null || true

echo "switching root -> /sbin/init (OpenRC)"
exec $BB switch_root /newroot /sbin/init
