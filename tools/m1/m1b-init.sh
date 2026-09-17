#!/bin/busybox sh
# M1b init — persistent rootfs bring-up.
#
# This initramfs is RAM-only and small. It clears the one-shot BCB, brings up
# the NCM gadget (plus a rescue dropbear), then loop-mounts the ext4 rootfs
# image that lives in the free space of the Android `super` partition
# (offset given by "lmi_root_off=" in the kernel cmdline, in 4096-byte blocks)
# and switch_roots into it. Everything else (udev, seatd, weston, ssh, wifi)
# runs from OpenRC inside the persistent rootfs.
#
# v5 additions (M1b wifi bring-up, issue #14):
#   - applies a one-shot rootfs overlay (m1b-overlay.tar.gz, shipped in this
#     initramfs) so the persistent rootfs can be updated without touching super
#     from Android (baseband_guard, issue #13);
#   - maintains a boot ledger (boot count/log) inside the rootfs as
#     persistence evidence;
#   - reports to the super mailbox (init/persist sections) so the state can be
#     read from Android after a reboot without USB or SSH.
#
# v6: logic unchanged; overlay version bumped to m1b-wifi-v2 so the overlay
#     tree carries the device-verified dropbear/wpa fixes (boot-m1b-v6).

BB=/bin/busybox

ROOT_OFF_BLOCKS=""
for w in $($BB cat /proc/cmdline); do
  case "$w" in lmi_root_off=*) ROOT_OFF_BLOCKS=${w#lmi_root_off=} ;; esac
done
[ -n "$ROOT_OFF_BLOCKS" ] || ROOT_OFF_BLOCKS=1596852

# Rootfs size in 4096-byte blocks (1.5 GiB) and the mailbox layout. Keep in
# sync with tools/m1/m1b/usr/sbin/m1-mailbox.
ROOT_SIZE_BLOCKS=393216
MBOX_GAP_BLOCKS=256
MBOX_SECTION_BLOCKS=16
OVERLAY_VERSION=m1b-ux-v17

$BB mount -t proc none /proc
$BB mount -t sysfs none /sys
$BB mount -t devtmpfs none /dev 2>/dev/null
$BB mkdir -p /dev/pts
$BB mount -t devpts none /dev/pts 2>/dev/null
$BB mkdir -p /run /tmp /root /newroot /etc/dropbear
$BB mount -t tmpfs none /run 2>/dev/null
$BB mount -t tmpfs none /tmp 2>/dev/null
$BB mount -t configfs none /sys/kernel/config 2>/dev/null

echo "===== M1b init v8 (persistent rootfs) ====="

# Locate the super partition (by GPT PARTNAME); whitelisted fallback sda32.
SUPER=""
for b in /sys/class/block/sda*; do
  if $BB grep -q "^PARTNAME=super$" "$b/uevent" 2>/dev/null; then
    SUPER="/dev/$($BB basename "$b")"
    break
  fi
done
# whitelisted fallback node (lmi super = sda32, docs/architecture.md §2)
[ -n "$SUPER" ] || SUPER=/dev/sda32

# M3: prefer the dedicated `lnx` partition (created by tools/m3/lmi-repart.sh),
# where the rootfs image lives directly at partition offset 0.  Falls back to
# the super free-space layout when the partition is absent.
ROOT_DEV=""
for b in /sys/class/block/sda*; do
  if $BB grep -q "^PARTNAME=lnx$" "$b/uevent" 2>/dev/null; then
    ROOT_DEV="/dev/$($BB basename "$b")"
    break
  fi
done

mbox() {
  # usage: mbox <section>   (body on stdin)
  sec=$1
  case "$sec" in
    init) idx=0 ;;
    rootfs) idx=1 ;;
    wifi) idx=2 ;;
    persist) idx=3 ;;
    m2) idx=4 ;;
    *) idx=0 ;;
  esac
  blk=$((ROOT_OFF_BLOCKS + ROOT_SIZE_BLOCKS + MBOX_GAP_BLOCKS + idx * MBOX_SECTION_BLOCKS))
  [ -b "$SUPER" ] || return 0
  {
    printf '### LMI-MAILBOX section=%s written=%s\n' "$sec" "$($BB date -u '+%Y-%m-%dT%H:%M:%SZ')"
    $BB cat
    printf '\n### end %s\n' "$sec"
  } | $BB dd of="$SUPER" bs=4096 seek="$blk" conv=notrunc,fsync 2>/dev/null
}

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
BCB="$($BB dd if="$MISC" bs=1 count=32 2>/dev/null | $BB od -An -tx1 2>/dev/null | $BB tr -d ' \n')"
if [ -b "$MISC" ]; then
  $BB dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null
  echo "BCB cleared on $MISC (was: $BCB)"
fi

printf 'init: start, super=%s, bcb=%s, root_off_blocks=%s\n' "$SUPER" "$BCB" "$ROOT_OFF_BLOCKS" | mbox init

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

echo "super device: $SUPER"

# --- loop-mount the persistent rootfs at the recorded offset ---
# The rescue dropbear is started only if this fails, so it can never hold
# port 22 into the persistent system (issue found on the v1/v2 attempts).
[ -e /dev/loop0 ] || $BB mknod /dev/loop0 b 7 0
OFFSET=$((ROOT_OFF_BLOCKS * 4096))
ROOT_SOURCE=""
if [ -n "$ROOT_DEV" ] && $BB mount -t ext4 -o rw "$ROOT_DEV" /newroot; then
  echo "persistent rootfs mounted from $ROOT_DEV (M3 lnx partition)"
  printf 'init: mounted lnx rootfs from %s\n' "$ROOT_DEV" | mbox init
  ROOT_SOURCE="$ROOT_DEV"
else
  [ -n "$ROOT_DEV" ] && echo "WARN: $ROOT_DEV mount failed; falling back to super offset"
  if ! $BB losetup -o "$OFFSET" /dev/loop0 "$SUPER"; then
    echo "FATAL: losetup failed (offset=$OFFSET)"
    printf 'init: FATAL losetup failed offset=%s super=%s\n' "$OFFSET" "$SUPER" | mbox init
    /usr/sbin/dropbear -R -p 22 2>/dev/null
    while true; do $BB sleep 3600; done
  fi
  if ! $BB mount -t ext4 -o rw /dev/loop0 /newroot; then
    echo "FATAL: mount ext4 failed (loop0@$SUPER offset=$OFFSET)"
    printf 'init: FATAL ext4 mount failed offset=%s super=%s\n' "$OFFSET" "$SUPER" | mbox init
    $BB losetup -d /dev/loop0 2>/dev/null
    /usr/sbin/dropbear -R -p 22 2>/dev/null
    while true; do $BB sleep 3600; done
  fi
  echo "persistent rootfs mounted ($SUPER offset=$OFFSET)"
  ROOT_SOURCE="$SUPER offset=$OFFSET"
fi

# --- one-shot rootfs overlay (persistent, applied before switch_root) ---
OVERLAY="/m1b-overlay.tar.gz"
OVERLAY_LOG=/newroot/var/log/m1b-overlay.log
$BB mkdir -p /newroot/var/log
CUR_VER=""
[ -r /newroot/etc/m1b-overlay-version ] && CUR_VER="$($BB cat /newroot/etc/m1b-overlay-version)"
OVERLAY_RESULT=skipped
if [ -f "$OVERLAY" ] && [ "$CUR_VER" != "$OVERLAY_VERSION" ]; then
  echo "applying rootfs overlay $OVERLAY_VERSION (current: ${CUR_VER:-none})"
  if $BB tar -xzf "$OVERLAY" -C /newroot 2>>"$OVERLAY_LOG"; then
    printf '%s\n' "$OVERLAY_VERSION" > /newroot/etc/m1b-overlay-version
    printf '%s applied %s -> %s\n' "$($BB date -u '+%Y-%m-%dT%H:%M:%SZ')" "${CUR_VER:-none}" "$OVERLAY_VERSION" >> "$OVERLAY_LOG"
    OVERLAY_RESULT=applied
  else
    echo "WARN: overlay extraction failed; see $OVERLAY_LOG"
    printf '%s FAILED to apply %s\n' "$($BB date -u '+%Y-%m-%dT%H:%M:%SZ')" "$OVERLAY_VERSION" >> "$OVERLAY_LOG"
    OVERLAY_RESULT=failed
  fi
fi

# --- post-overlay setup (runs only when the overlay was applied) ---
# Enables the time services and refreshes the font cache inside the new root;
# runlevel symlinks are not shipped in the overlay (repo is checked out on
# Windows), so enable them here instead. Failures are non-fatal.
if [ "$OVERLAY_RESULT" = applied ]; then
  echo "post-overlay setup (service enablement, font cache)"
  $BB chroot /newroot /bin/sh -c \
    '/sbin/rc-update del hwclock boot >/dev/null 2>&1; /sbin/rc-update add swclock boot >/dev/null 2>&1; /sbin/rc-update add ntpd default >/dev/null 2>&1; /sbin/rc-update add lmi-keys default >/dev/null 2>&1; /sbin/rc-update add lmi-power default >/dev/null 2>&1; /sbin/rc-update add lmi-chargectl default >/dev/null 2>&1; /sbin/rc-update add lmi-monitor default >/dev/null 2>&1; /sbin/rc-update add lmi-netwatch default >/dev/null 2>&1; /sbin/rc-update add lmi-adsp default >/dev/null 2>&1; /sbin/rc-update add pd-mapper default >/dev/null 2>&1; /sbin/rc-update add lmi-audio default >/dev/null 2>&1; /usr/bin/fc-cache --system-only >/dev/null 2>&1' \
    2>>"$OVERLAY_LOG" || echo "WARN: post-overlay setup failed (see $OVERLAY_LOG)"
fi
$BB sync

# --- boot ledger (persistence evidence; survives reboots) ---
LEDGER_DIR=/newroot/root
LEDGER_MARK="$LEDGER_DIR/m1b-boot-count"
$BB mkdir -p "$LEDGER_DIR"
COUNT=0
[ -r "$LEDGER_MARK" ] && read -r COUNT < "$LEDGER_MARK" 2>/dev/null
COUNT=$((COUNT + 1))
printf '%s\n' "$COUNT" > "$LEDGER_MARK"
printf '%s boot=%s kernel=%s bcb=%s overlay=%s root=%s\n' \
  "$($BB date -u '+%Y-%m-%dT%H:%M:%SZ')" "$COUNT" "$($BB uname -r)" "${BCB:-none}" "$OVERLAY_RESULT" \
  "$ROOT_SOURCE" \
  >> "$LEDGER_DIR/m1b-boots.log"
$BB sync

{
  printf 'init: OK, boot_count=%s overlay=%s (was %s)\n' "$COUNT" "$OVERLAY_RESULT" "${CUR_VER:-none}"
  printf 'ledger tail:\n'
  $BB tail -n 8 "$LEDGER_DIR/m1b-boots.log" 2>/dev/null
} | mbox persist

{
  printf 'init: OK, super=%s offset_blocks=%s bcb_was=%s overlay=%s boot_count=%s\n' \
    "$SUPER" "$ROOT_OFF_BLOCKS" "${BCB:-none}" "$OVERLAY_RESULT" "$COUNT"
} | mbox init

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
