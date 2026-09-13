#!/bin/busybox sh
# M1a ramboot init — full Alpine rootfs with Weston UI (RAM only, zero writes).
# Based on the proven M0 init (BCB clear, NCM gadget, dropbear) plus the
# D80-baseline Weston sequence (splash release via modetest, pixman renderer).

BB=/bin/busybox

$BB mount -t proc none /proc
$BB mount -t sysfs none /sys
$BB mount -t devtmpfs none /dev 2>/dev/null
$BB mkdir -p /dev/pts
$BB mount -t devpts none /dev/pts 2>/dev/null
$BB mkdir -p /run /tmp /root /var/log /var/run /etc/dropbear
$BB mount -t tmpfs none /run 2>/dev/null
$BB mount -t tmpfs none /tmp 2>/dev/null
$BB mount -t configfs none /sys/kernel/config 2>/dev/null

echo "===== M1a ramboot ====="

# --- One-shot boot flag (BCB) cleanup: do this as early as possible ---
MISC=""
for b in /sys/class/block/sda*; do
  if $BB grep -q "^PARTNAME=misc$" "$b/uevent" 2>/dev/null; then
    MISC="/dev/$($BB basename "$b")"
    break
  fi
done
[ -n "$MISC" ] || MISC=/dev/sda11
if [ -b "$MISC" ]; then
  $BB dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null
  echo "BCB cleared on $MISC"
else
  echo "WARNING: misc partition not found; BCB not cleared"
fi

# --- USB network gadget: NCM preferred, RNDIS fallback ---
G=/sys/kernel/config/usb_gadget/g1
NETFUNC=""
if [ -d /sys/kernel/config/usb_gadget ] && [ ! -d "$G" ]; then
  $BB mkdir -p "$G"
  echo 0x0525 > "$G/idVendor"
  echo 0xa4a2 > "$G/idProduct"
  $BB mkdir -p "$G/strings/0x409"
  echo "lmi-m1-0001" > "$G/strings/0x409/serialnumber"
  echo "k30pro-linux-dualboot" > "$G/strings/0x409/manufacturer"
  echo "M1a ramboot" > "$G/strings/0x409/product"
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
$BB hostname lmi-m1 2>/dev/null

# --- SSH (dropbear, runtime host keys) ---
/usr/sbin/dropbear -R -p 22 2>/dev/null

# --- udev: libinput needs it to enumerate input devices (touch/keyboard) ---
if [ -x /sbin/udevd ]; then
  $BB mkdir -p /run/udev
  /sbin/udevd --daemon 2>/dev/null
  sleep 1
  /bin/udevadm trigger --action=add 2>/dev/null
  /bin/udevadm settle --timeout=10 2>/dev/null
  echo "udev: started and triggered"
fi

# --- seatd for weston's DRM/input session ---
/usr/bin/seatd -g root -l info >>/var/log/seatd.log 2>&1 &
i=0
while [ $i -lt 10 ]; do
  [ -S /run/seatd.sock ] && break
  i=$((i + 1))
  $BB sleep 1
done

# --- Weston UI (proven D80-baseline sequence) ---
/usr/sbin/m1-weston >>/var/log/m1-weston.log 2>&1 &

echo ""
echo "==================================================="
echo " lmi M1a ramboot (Alpine + Weston, RAM only)"
echo " usb net : $NETFUNC 172.16.42.1/24  (host 172.16.42.2/24)"
echo " ssh     : root@172.16.42.1  (password <your-password>)"
echo " ui      : weston (DSI-1, pixman) + weston-terminal/editor"
echo " NOTE    : nothing is written to any partition"
echo "==================================================="

while true; do $BB sleep 3600; done
