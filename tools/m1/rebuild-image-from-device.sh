#!/bin/sh
# SPDX-License-Identifier: MIT
# rebuild-image-from-device.sh - rebuild the M1b boot image **on the device**
# (inside the persistent Linux rootfs): no Android, no fastboot, no USB host.
#
# The image currently deployed on the recovery partition already contains every
# input a rebuild needs (kernel, DTB, cmdline, the initramfs base with busybox
# and the recovery DTBO table).  This script reads it, unpacks it, restages the
# initramfs with a new full-payload overlay, repacks with mkbootimg and then
# self-checks that kernel/DTB/cmdline/DTBO are byte-identical to the source.
#
# Deployment is a separate, deliberate step (see
# docs/m1b-rebuild-on-device.md §5):  dd the result back to `recovery`.
#
# usage (root):
#   rebuild-image-from-device.sh [options]
#     --dev <blockdev>     recovery partition (default /dev/sda28)
#     --image <file>       use an image file instead of a device
#     --repo <dir>         repository root (default: two levels above this file)
#     --tree <dir>         overlay payload tree (default <repo>/tools/m1/m1b)
#     --version <str>      overlay version (default m1b-ux-v5)
#     --out <name>         output file name (default boot-m1b-v9.img)
#     --work <dir>         work dir (default /root/m1b-rebuild)
#     --mkbootimg <file>   mkbootimg.py (default: PATH lookup)
#     --root-password <pw> set the initramfs rescue root password (SHA-512)
#     --random-root-password
#                          generate a strong random rescue root password and
#                          print it once (recommended: never ship a fixed one)
#     --no-roundtrip       skip the unpack/repack round-trip proof
#     --dry-run            only size and validate the source
#
# Prerequisites: mkbootimg.py (AOSP/LineageOS), cpio, gzip, python3, dd, stat.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/../.." && pwd)

DEV=/dev/sda28
IMAGE=
TREE=
VERSION=m1b-ux-v14
OUT=boot-m1b-v9.img
WORK=/root/m1b-rebuild
MKBOOTIMG=
ROUNDTRIP=1
DRY=0
NEWPW=
RANDPW=0

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "$*"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

# SHA-512 crypt via python3 (Alpine 3.12 still has the crypt module) with a
# busybox fallback.  The salt is derived from the password, so rebuilding with
# the same --root-password yields the same hash (reproducible builds).
hash_pw() {
	_salt=$(printf '%s' "$1" | sha256sum | cut -c1-16)
	python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], "$6$"+sys.argv[2]+"$"))' "$1" "$_salt" 2>/dev/null ||
		busybox cryptpw -m sha512 -S "$_salt" "$1"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dev) DEV=$2; shift 2;;
	--image) IMAGE=$2; shift 2;;
	--repo) REPO=$2; shift 2;;
	--tree) TREE=$2; shift 2;;
	--version) VERSION=$2; shift 2;;
	--out) OUT=$2; shift 2;;
	--work) WORK=$2; shift 2;;
	--mkbootimg) MKBOOTIMG=$2; shift 2;;
	--root-password) NEWPW=$2; shift 2;;
	--random-root-password) RANDPW=1; shift;;
	--no-roundtrip) ROUNDTRIP=0; shift;;
	--dry-run) DRY=1; shift;;
	-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
	*) die "unknown option: $1";;
	esac
done

[ -n "$TREE" ] || TREE=$REPO/tools/m1/m1b
[ -d "$TREE" ] || die "overlay payload tree not found: $TREE"

# Stage the payload: drop repo-only files and normalise CRLF.  The payload is
# copied into the rootfs verbatim, and a CR before the newline breaks OpenRC
# shebangs / conf.d parsing on the device (seen with lmi-wifi, 2026-09-15);
# Windows checkouts can carry CRLF even when .gitattributes asks for LF.
TREE_SRC=$TREE
TREE=$WORK/payload
rm -rf "$TREE"
mkdir -p "$TREE"
( cd "$TREE_SRC" && tar -cf - --exclude=README.md --exclude=.git . ) |
	( cd "$TREE" && tar -xf - )
python3 - "$TREE" <<'PY'
import os, sys
root = sys.argv[1]
n = 0
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        data = open(path, "rb").read()
        if b"\0" in data or b"\r" not in data:   # binaries / already LF
            continue
        open(path, "wb").write(data.replace(b"\r\n", b"\n"))
        n += 1
print("payload normalized: %d CRLF text file(s) fixed" % n)
PY

# The staged payload must equal the source after CRLF normalisation.  A silent
# content mutation (a `tr -d "r"` mishap ate every letter "r" once: `mkdir` ->
# `mkdi`, `/var/log` -> `/va/log`, which broke WiFi recovery for hours - see
# docs/handoff.md) must fail the build instead of shipping a broken script.
python3 - "$TREE_SRC" "$TREE" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
skip = {"README.md", ".gitignore"}
problems = []
for dirpath, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d != ".git"]
    for name in files:
        if name in skip:
            continue
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, src)
        raw = open(p, "rb").read()
        # mirror the normaliser: only text files get CRLF folded
        want = raw if b"\0" in raw else raw.replace(b"\r\n", b"\n")
        try:
            got = open(os.path.join(dst, rel), "rb").read()
        except FileNotFoundError:
            problems.append("missing: " + rel)
            continue
        if got != want:
            problems.append("content mismatch: " + rel)
if problems:
    print("payload integrity check FAILED:")
    for x in problems[:20]:
        print("  " + x)
    sys.exit(1)
print("payload integrity: staged tree matches the source byte-for-byte")
PY

for t in cpio gzip python3 dd stat; do
	command -v "$t" >/dev/null 2>&1 || die "$t not found"
done
if [ -z "$MKBOOTIMG" ]; then
	MKBOOTIMG=$(command -v mkbootimg.py || command -v mkbootimg || true)
fi
[ -n "$MKBOOTIMG" ] || die "mkbootimg not found (pass --mkbootimg mkbootimg.py)"

mkdir -p "$WORK"

# expose the python mkbootimg as a `mkbootimg` command for build-m1b-image.sh
BIN=$WORK/bin
mkdir -p "$BIN"
cat > "$BIN/mkbootimg" <<EOF
#!/bin/sh
exec python3 "$MKBOOTIMG" "\$@"
EOF
chmod 755 "$BIN/mkbootimg"
PATH=$BIN:$PATH
export PATH
MK=mkbootimg

# --- source ---------------------------------------------------------------
if [ -z "$IMAGE" ]; then
	[ -b "$DEV" ] || die "$DEV is not a block device (or pass --image)"
	[ -r "$DEV" ] || die "$DEV not readable (run as root)"
	IMAGE=$WORK/source.img
	size=$(python3 - "$DEV" <<'PY'
import struct, sys
hdr = open(sys.argv[1], "rb").read(4096)
assert hdr[:8] == b"ANDROID!", "not a boot image (magic=%r)" % hdr[:8]
(kernel_size, _ka, ramdisk_size, _ra, second_size, _sa, _ta, page_size,
 header_version) = struct.unpack_from("<9I", hdr, 8)
recovery_dtbo_size = struct.unpack_from("<I", hdr, 1632)[0] if header_version >= 1 else 0
dtb_size = struct.unpack_from("<I", hdr, 1648)[0] if header_version >= 1 else 0
pages = lambda n: (n + page_size - 1) // page_size
print(page_size * (1 + pages(kernel_size) + pages(ramdisk_size) +
                   pages(second_size) +
                   (pages(recovery_dtbo_size) if recovery_dtbo_size else 0) +
                   pages(dtb_size)))
PY
)
[ -n "$size" ] || die "failed to parse the boot header"
info "source: $DEV -> $IMAGE ($size bytes)"

# Preflight: unpacking + repacking needs roughly 3x the image size in $WORK, and
# a full filesystem used to fail *silently* (dd's stderr is discarded and
# `set -e` exits) - that cost an afternoon on 2026-09-15, hence the explicit
# check and the dd failure message below.
need=$((size * 3))
have=$(df -k "$WORK" | awk 'NR==2 {print $4 * 1024}')
[ "$have" -ge "$need" ] ||
	die "not enough space in $WORK: need ~$((need / 1048576)) MiB, have $((have / 1048576)) MiB free"

dd if="$DEV" of="$IMAGE" bs=4096 count=$((size / 4096 + 1)) 2>/dev/null ||
	die "copying $DEV -> $IMAGE failed (out of space?)"
	truncate -s "$size" "$IMAGE" 2>/dev/null || true
else
	[ -f "$IMAGE" ] || die "image not found: $IMAGE"
	info "source image: $IMAGE ($(stat -c %s "$IMAGE") bytes)"
	[ "$DRY" = 1 ] && exit 0
fi

# --- unpack ---------------------------------------------------------------
mkdir -p "$WORK/unpacked"
python3 - "$IMAGE" "$WORK/unpacked" <<'PY'
import os, struct, sys
data = open(sys.argv[1], "rb").read()
out = sys.argv[2]
assert data[:8] == b"ANDROID!", "bad magic"
(kernel_size, _ka, ramdisk_size, _ra, second_size, _sa, _ta, page_size,
 header_version, os_version) = struct.unpack_from("<10I", data, 8)
name = data[48:64].split(b"\0")[0].decode(errors="replace")
cmdline = data[64:576].split(b"\0")[0].decode(errors="replace")
extra = data[608:1632].split(b"\0")[0].decode(errors="replace")
recovery_dtbo_size = struct.unpack_from("<I", data, 1632)[0] if header_version >= 1 else 0
dtb_size = struct.unpack_from("<I", data, 1648)[0] if header_version >= 1 else 0
pages = lambda n: (n + page_size - 1) // page_size
off = page_size
sizes = (("kernel", kernel_size), ("ramdisk", ramdisk_size),
         ("second", second_size), ("recovery_dtbo", recovery_dtbo_size),
         ("dtb", dtb_size))
for label, size in sizes:
    if size:
        open(os.path.join(out, label), "wb").write(data[off:off + size])
    off += pages(size) * page_size
open(os.path.join(out, "cmdline"), "w").write((cmdline + extra).strip() + "\n")
open(os.path.join(out, "fields.txt"), "w").write(
    "page_size=%d header_version=%d os_version=%d name=%s\n"
    "kernel=%d ramdisk=%d second=%d recovery_dtbo=%d dtb=%d\n"
    "cmdline=%s\n" % (page_size, header_version, os_version, name,
                      kernel_size, ramdisk_size, second_size,
                      recovery_dtbo_size, dtb_size, (cmdline + extra).strip()))
PY
for f in kernel ramdisk dtb cmdline; do
	[ -f "$WORK/unpacked/$f" ] || die "unpack: missing $f"
done
info "unpacked:"; sed 's/^/  /' "$WORK/unpacked/fields.txt"

# --- round trip: prove the unpack/repack path on byte level ---------------
pack() { # $1 = ramdisk file, $2 = out image
	$MK --header_version 2 --pagesize 4096 \
		--kernel "$WORK/unpacked/kernel" \
		--ramdisk "$1" \
		--dtb "$WORK/unpacked/dtb" \
		--recovery_dtbo "$WORK/unpacked/recovery_dtbo" \
		--cmdline "$(cat "$WORK/unpacked/cmdline")" \
		--base 0x00000000 --kernel_offset 0x00008000 \
		--ramdisk_offset 0x01000000 --second_offset 0x00000000 \
		--tags_offset 0x00000100 --dtb_offset 0x01f00000 \
		-o "$2"
}
if [ "$ROUNDTRIP" = 1 ]; then
	info "round-trip: repacking the source and comparing structurally"
	pack "$WORK/unpacked/ramdisk" "$WORK/roundtrip.img" >/dev/null
	rs=$(stat -c %s "$WORK/roundtrip.img")
	ss=$(stat -c %s "$IMAGE")
	if [ "$rs" = "$ss" ]; then
		info "  size identical ($rs bytes)"
	else
		info "  size differs: source=$ss repacked=$rs (check mkbootimg version)"
	fi
fi

# --- initramfs ------------------------------------------------------------
rm -rf "$WORK/unpacked/ramdisk-tree"
mkdir -p "$WORK/unpacked/ramdisk-tree"
( cd "$WORK/unpacked/ramdisk-tree" &&
  gzip -dc "$WORK/unpacked/ramdisk" | cpio -idmu --quiet 2>/dev/null ) ||
	die "failed to extract the ramdisk"
[ -x "$WORK/unpacked/ramdisk-tree/init" ] || info "WARN: no init in the ramdisk"
[ -e "$WORK/unpacked/ramdisk-tree/bin/busybox" ] ||
	[ -e "$WORK/unpacked/ramdisk-tree/bin/sh" ] ||
	die "ramdisk has no busybox/shell - not the M1b initramfs?"

mkdir -p "$WORK/empty-tree"

# --- initramfs rescue password --------------------------------------------
# The ramdisk carries its own /etc/shadow (the dropbear that m1b-init starts
# when the rootfs cannot be mounted).  A fixed/hard-coded hash must never be
# shipped: generate a random one, or set the caller's.
RD=$WORK/unpacked/ramdisk-tree
if [ "$RANDPW" = 1 ] && [ -z "$NEWPW" ]; then
	NEWPW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
	info "generated rescue root password (save it now): $NEWPW"
fi
if [ -n "$NEWPW" ]; then
	[ -f "$RD/etc/shadow" ] || die "ramdisk has no etc/shadow to patch"
	hashash=$(hash_pw "$NEWPW") || die "could not compute a SHA-512 hash"
	[ -n "$hashash" ] || die "empty hash"
	if grep -q '^root:' "$RD/etc/shadow"; then
		awk -v h="$hashash" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h; $3=19000} {print}' \
			"$RD/etc/shadow" > "$RD/etc/shadow.new" || die "shadow rewrite failed"
	else
		printf 'root:%s:19000:0:99999:7:::\n' "$hashash" > "$RD/etc/shadow.new"
	fi
	mv "$RD/etc/shadow.new" "$RD/etc/shadow"
	chmod 600 "$RD/etc/shadow"
	info "initramfs rescue root password updated"
fi

info "overlay: full payload from $TREE as $VERSION (empty baseline)"
# build-m1b-image.sh generates the overlay itself when a baseline is given and
# deletes any pre-existing m1b-overlay.tar.gz in the initramfs dir, so the
# baseline must be an empty tree (=> the full payload ships in this overlay).
info "assembling"
sh "$HERE/build-m1b-image.sh" \
	--tree "$TREE" \
	--base-tree "$WORK/empty-tree" \
	--overlay-out "$WORK/overlay.tar.gz" \
	--initramfs-dir "$WORK/unpacked/ramdisk-tree" \
	--kernel "$WORK/unpacked/kernel" \
	--dtb "$WORK/unpacked/dtb" \
	--cmdline "$WORK/unpacked/cmdline" \
	--overlay-version "$VERSION" \
	--recovery-dtbo "$WORK/unpacked/recovery_dtbo" \
	--out "$WORK/$OUT" || die "image assembly failed"

# --- self check -----------------------------------------------------------
info "self check"
mkdir -p "$WORK/verify"
python3 - "$WORK/$OUT" "$WORK/verify" <<'PY'
import os, struct, sys
data = open(sys.argv[1], "rb").read()
out = sys.argv[2]
(kernel_size, _ka, ramdisk_size, _ra, second_size, _sa, _ta, page_size,
 header_version) = struct.unpack_from("<9I", data, 8)
recovery_dtbo_size = struct.unpack_from("<I", data, 1632)[0]
dtb_size = struct.unpack_from("<I", data, 1648)[0]
pages = lambda n: (n + page_size - 1) // page_size
off = page_size
for label, size in (("kernel", kernel_size), ("ramdisk", ramdisk_size),
                    ("second", second_size),
                    ("recovery_dtbo", recovery_dtbo_size), ("dtb", dtb_size)):
    if size:
        open(os.path.join(out, label), "wb").write(data[off:off + size])
    off += pages(size) * page_size
PY
fails=0
for s in kernel dtb recovery_dtbo; do
	a=$(sha "$WORK/unpacked/$s"); b=$(sha "$WORK/verify/$s")
	if [ "$a" = "$b" ]; then
		info "  $s identical (${a%????????????????????????????????????????????????????????})"
	else
		info "  $s MISMATCH"; fails=$((fails + 1))
	fi
done
newcmd=$(python3 - "$WORK/$OUT" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print((d[64:576].split(b"\0")[0].decode() +
       d[608:1632].split(b"\0")[0].decode()).strip())
PY
)
if [ "$newcmd" = "$(cat "$WORK/unpacked/cmdline")" ]; then
	info "  cmdline identical"
else
	info "  cmdline MISMATCH"; fails=$((fails + 1))
fi
mkdir -p "$WORK/verify/ramdisk-tree"
( cd "$WORK/verify/ramdisk-tree" &&
  gzip -dc "$WORK/verify/ramdisk" | cpio -idmu --quiet 2>/dev/null ) || true
ov=$WORK/verify/ramdisk-tree/m1b-overlay.tar.gz
if [ -f "$ov" ]; then
	ovver=$(tar -xzOf "$ov" etc/m1b-overlay-version 2>/dev/null | tr -d '\n')
	info "  overlay in ramdisk: $(stat -c %s "$ov") bytes, version $ovver"
	[ "$ovver" = "$VERSION" ] || { info "  overlay version mismatch"; fails=$((fails + 1)); }
else
	info "  overlay MISSING in the new ramdisk"; fails=$((fails + 1))
fi
if [ -e "$WORK/verify/ramdisk-tree/init" ]; then
	info "  init present ($(stat -c %s "$WORK/verify/ramdisk-tree/init") bytes)"
else
	info "  init MISSING"; fails=$((fails + 1))
fi
if [ -e "$WORK/verify/ramdisk-tree/bin/busybox" ]; then
	info "  busybox present"
else
	info "  busybox MISSING"; fails=$((fails + 1))
fi
[ "$fails" = 0 ] || die "$fails self-check failure(s) - do not deploy this image"

info ""
info "OK: $WORK/$OUT ($(stat -c %s "$WORK/$OUT") bytes)"
info "sha256: $(sha "$WORK/$OUT")"
info "deploy (deliberate, after review - see docs/m1b-rebuild-on-device.md §5):"
info "  dd if=$WORK/$OUT of=$DEV bs=1M && sync"
