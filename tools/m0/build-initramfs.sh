#!/bin/sh
# Build the M0 initramfs: busybox + dropbear + eventdump + display + init.
# Reproducibility notes (issue #8): deterministic file order, gzip -n, no
# timestamps in the cpio listing order; fixed password hash.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORKDIR="${WORKDIR:-$HERE/out}"
ROOTFS="$WORKDIR/initramfs-root"

BB=$(command -v busybox-static || command -v busybox || echo /usr/bin/busybox)
DROPBEAR=$(command -v dropbear || echo /usr/sbin/dropbear)

echo "== initramfs -> $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/bin "$ROOTFS"/sbin "$ROOTFS"/usr/sbin "$ROOTFS"/etc/dropbear \
         "$ROOTFS"/dev "$ROOTFS"/proc "$ROOTFS"/sys "$ROOTFS"/run "$ROOTFS"/root "$ROOTFS"/lib

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

# busybox: copy via copy_with_libs so that a dynamically linked busybox also
# brings its libraries (issue #8). Prefer busybox-static when available.
echo "== busybox: $BB"
if command -v file >/dev/null 2>&1 && ! file "$BB" | grep -q "statically linked"; then
  echo "WARN: $BB is dynamically linked; copying its libraries"
fi
copy_with_libs "$BB"
cp -L "$BB" "$ROOTFS/bin/busybox"
chmod 755 "$ROOTFS/bin/busybox"
# /etc/passwd gives root the shell /bin/sh, but the initramfs only shipped
# bin/busybox: the rescue dropbear could therefore never exec a login shell
# (every exec request died with exit 1 and no output, 2026-09-17).  Add the
# applet link so the rescue SSH is actually usable.
ln -sf busybox "$ROOTFS/bin/sh"

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

# Root password for the ramboot image.
#
# The repository contains no password and no password hash on purpose: pass
# LMI_ROOT_PASSWORD to pin one (required for byte-reproducible builds, issue #8),
# otherwise a random password is generated and printed once below.
# Requires openssl (see the build dependencies in README.md).
if [ -n "${LMI_ROOT_PASSWORD:-}" ]; then
	PW="$LMI_ROOT_PASSWORD"
	PW_GENERATED=0
else
	PW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
	PW_GENERATED=1
fi
# deterministic salt derived from the password: same password -> same hash
SALT=$(printf '%s' "$PW" | sha256sum | cut -c1-16)
HASH=$(openssl passwd -6 -salt "$SALT" "$PW") ||
	{ echo "build-initramfs: openssl passwd failed (install openssl)" >&2; exit 1; }
printf 'root:%s:19000:0:99999:7:::\n' "$HASH" > "$ROOTFS/etc/shadow"
if [ "$PW_GENERATED" = 1 ]; then
	echo "== generated ramboot root password (save it now): $PW"
fi
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ROOTFS/etc/passwd"
printf 'root:x:0:\n' > "$ROOTFS/etc/group"
chmod 600 "$ROOTFS/etc/shadow"
chmod 700 "$ROOTFS/root"

# Packaging (issue #8, issue #22): sorted file order + gzip -n (no name/mtime)
# remove two sources of variance, but cpio's newc header still records each
# file's mtime/inode, so the archive is only truly byte-reproducible when cpio
# can zero them (GNU cpio >= 2.12 `--reproducible`). Fall back loudly otherwise
# instead of claiming determinism we do not have.
if cpio --help 2>&1 | grep -q -- '--reproducible'; then
	( cd "$ROOTFS" && LC_ALL=C find . | LC_ALL=C sort |
		cpio -o -H newc --reproducible 2>/dev/null | gzip -n -9 ) > "$WORKDIR/initramfs.cpio.gz"
else
	echo "build-initramfs: NOTE: cpio lacks --reproducible; archive bytes depend on file mtimes/inodes (issue #22)" >&2
	( cd "$ROOTFS" && LC_ALL=C find . | LC_ALL=C sort |
		cpio -o -H newc 2>/dev/null | gzip -n -9 ) > "$WORKDIR/initramfs.cpio.gz"
fi
ls -l "$WORKDIR/initramfs.cpio.gz"
sha256sum "$WORKDIR/initramfs.cpio.gz"
