#!/bin/sh
# Build the M0 initramfs: static busybox + dropbear + eventdump + init.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORKDIR="${WORKDIR:-$HERE/out}"
ROOTFS="$WORKDIR/initramfs-root"

BB=$(command -v busybox || echo /usr/bin/busybox)
DROPBEAR=$(command -v dropbear || echo /usr/sbin/dropbear)

echo "== initramfs -> $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/bin "$ROOTFS"/sbin "$ROOTFS"/usr/sbin "$ROOTFS"/etc/dropbear \
         "$ROOTFS"/dev "$ROOTFS"/proc "$ROOTFS"/sys "$ROOTFS"/run "$ROOTFS"/root "$ROOTFS"/lib

cp -L "$BB" "$ROOTFS/bin/busybox"
chmod 755 "$ROOTFS/bin/busybox"

copy_with_libs() {
  src=$1
  dst="$ROOTFS$src"
  mkdir -p "$(dirname "$dst")"
  cp -L "$src" "$dst"
  ldd "$src" 2>/dev/null | awk '/=> \// {print $3}' | while read -r lib; do
    mkdir -p "$ROOTFS$(dirname "$lib")"
    cp -L "$lib" "$ROOTFS$lib"
  done
  # the dynamic loader line has no "=>" and may start with whitespace
  ldd "$src" 2>/dev/null | awk '/ld-linux/ { if ($2 == "=>") { print $3 } else { print $1 } }' | while read -r lib; do
    mkdir -p "$ROOTFS$(dirname "$lib")"
    cp -L "$lib" "$ROOTFS$lib"
  done
  # glibc NSS modules are dlopen()ed; include if present
  for nss in /lib/aarch64-linux-gnu/libnss_files.so.2 \
             /usr/lib/aarch64-linux-gnu/libnss_files.so.2 \
             /lib/aarch64-linux-gnu/libnss_dns.so.2 \
             /usr/lib/aarch64-linux-gnu/libnss_dns.so.2; do
    [ -e "$nss" ] && { mkdir -p "$ROOTFS$(dirname "$nss")"; cp -L "$nss" "$ROOTFS$nss"; }
  done
}

copy_with_libs "$DROPBEAR"
mkdir -p "$ROOTFS/usr/sbin"
cp -L "$DROPBEAR" "$ROOTFS/usr/sbin/dropbear"
chmod 755 "$ROOTFS/usr/sbin/dropbear"

gcc -static -O2 -o "$ROOTFS/bin/eventdump" "$HERE/eventdump.c"
chmod 755 "$ROOTFS/bin/eventdump"

# m0-display: minimal DRM/KMS modeset (no fbdev in the kernel; see display.c)
gcc -static -O2 -I/usr/include/libdrm -o "$ROOTFS/bin/display" "$HERE/display.c"
chmod 755 "$ROOTFS/bin/display"

cp "$HERE/init" "$ROOTFS/init"
chmod 755 "$ROOTFS/init"

HASH=$(python3 - <<'EOF'
import crypt
print(crypt.crypt("<your-password>", crypt.mksalt(crypt.METHOD_SHA512)))
EOF
)
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ROOTFS/etc/passwd"
printf 'root:x:0:\n' > "$ROOTFS/etc/group"
printf 'root:%s:19000:0:99999:7:::\n' "$HASH" > "$ROOTFS/etc/shadow"
chmod 600 "$ROOTFS/etc/shadow"
chmod 700 "$ROOTFS/root"

( cd "$ROOTFS" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$WORKDIR/initramfs.cpio.gz"
ls -l "$WORKDIR/initramfs.cpio.gz"
sha256sum "$WORKDIR/initramfs.cpio.gz"
