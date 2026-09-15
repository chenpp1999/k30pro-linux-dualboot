#!/bin/sh
# SPDX-License-Identifier: MIT
# build-generic-image.sh - assemble a *generic*, credential-free M5 boot image.
#
# The generic image is the artifact a first-time user installs (docs/installer-
# design.md).  Unlike the personalised images this project deployed on its own
# phone, it must not contain a single secret or device identity:
#
#   * no WiFi network / PSK                     -> build fails if one is present
#   * no usable root password in the rootfs     -> root entry must be locked (!)
#   * no pre-seeded SSH host keys or authorized_keys
#   * no fixed machine-id
#
# Per-device secrets are created on first boot by tools/install/firstboot/
# lmi-firstboot (installed into the payload here).
#
# This script never writes to a device; it only assembles an image file.
#
# usage:
#   tools/install/build-generic-image.sh \
#     --tree <rootfs-tree> --initramfs-dir <dir> \
#     --kernel <vmlinuz> --dtb <dtb> --cmdline <file> \
#     --overlay-version <ver> --out <boot-m1b-generic.img> \
#     [--recovery-dtbo <dtbo.img>] [--no-firstboot] [--dry-run]
#
#   --allow-credentials  skip the zero-credential gate (only for a *private*
#                        image you build for your own device; never publish)
#   --dry-run            validate + print the plan, build nothing
#
# The actual assembly is delegated to tools/m1/build-m1b-image.sh so the two
# paths cannot drift.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/../.." && pwd)

TREE=
INITRAMFS_DIR=
KERNEL=
DTB=
CMDLINE=
OVERLAY_VERSION=
OUT=
RECOVERY_DTBO=
DRY=0
FIRSTBOOT=1
ALLOW=0

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--tree) TREE=$2; shift 2 ;;
	--initramfs-dir) INITRAMFS_DIR=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	--cmdline) CMDLINE=$2; shift 2 ;;
	--overlay-version) OVERLAY_VERSION=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--recovery-dtbo) RECOVERY_DTBO=$2; shift 2 ;;
	--no-firstboot) FIRSTBOOT=0; shift ;;
	--allow-credentials) ALLOW=1; shift ;;
	--dry-run) DRY=1; shift ;;
	-h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

[ -n "$TREE" ] && [ -d "$TREE" ] || die "--tree <rootfs-tree> required"
[ -n "$INITRAMFS_DIR" ] && [ -d "$INITRAMFS_DIR" ] || die "--initramfs-dir required"
for f in "$KERNEL" "$DTB" "$CMDLINE"; do
	[ -n "$f" ] && [ -f "$f" ] || die "missing input: ${f:-<empty>}"
done
[ -n "$OVERLAY_VERSION" ] || die "--overlay-version required"
[ -n "$OUT" ] || die "--out required"
[ "$ALLOW" = 0 ] || echo "WARNING: --allow-credentials: the zero-credential gate is OFF; do not publish this image"

FB_SRC=$HERE/firstboot
[ "$FIRSTBOOT" = 0 ] || [ -f "$FB_SRC/lmi-firstboot" ] || die "firstboot payload missing: $FB_SRC/lmi-firstboot"

# --- zero-credential gate ----------------------------------------------------
check_credentials() {
	tree=$1
	bad=0
	warn() { echo "  - $1"; }

	if [ -e "$tree/etc/wpa_supplicant/wpa_supplicant.conf" ]; then
		warn "WiFi config with a network is present: etc/wpa_supplicant/wpa_supplicant.conf"
		bad=1
	fi

	if [ -f "$tree/etc/shadow" ]; then
		root_hash=$(awk -F: '$1=="root"{print $2}' "$tree/etc/shadow")
		case "$root_hash" in
		'' | '!'* | '*'*) : ;;
		*) warn "root has a usable password hash in etc/shadow (must be locked: !/*)"; bad=1 ;;
		esac
	fi

	if [ -f "$tree/etc/machine-id" ] && [ -s "$tree/etc/machine-id" ]; then
		warn "etc/machine-id is not empty (must be regenerated on first boot)"; bad=1
	fi

	for d in "$tree/etc/dropbear" "$tree/root/.ssh"; do
		[ -d "$d" ] || continue
		if ls "$d"/dropbear_*_host_key >/dev/null 2>&1; then
			warn "SSH host keys are pre-seeded in $d"; bad=1
		fi
		if [ -s "$d/authorized_keys" ]; then
			warn "authorized_keys is not empty in $d"; bad=1
		fi
	done

	# Credential patterns from tools/ci/checks.sh (kept in sync deliberately).
	# ${dq} keeps this script itself from looking like a leak to checks.sh
	# rule 4 while still matching the real-world strings.
	dq='"'
	pattern="psk=${dq}[^${dq}<\$]|passphrase=${dq}[^${dq}<\$]|BEGIN [A-Z ]*PRIVATE KEY|androidboot\.serialno="
	if grep -rIlE "$pattern" "$tree" >/dev/null 2>&1; then
		warn "a credential pattern was found under $tree"
		grep -rInE "$pattern" "$tree" 2>/dev/null | head -5 | sed 's/^/      /'
		bad=1
	fi

	return $bad
}

if [ "$ALLOW" = 0 ]; then
	echo "== zero-credential gate =="
	if check_credentials "$TREE"; then
		echo "gate OK: no credentials/identities found in $TREE"
	else
		die "zero-credential gate failed (use --allow-credentials only for private images)"
	fi
else
	echo "== zero-credential gate skipped (--allow-credentials) =="
fi

if [ "$DRY" = 1 ]; then
	echo "DRY-RUN: tree=$TREE"
	echo "DRY-RUN: firstboot payload=$([ "$FIRSTBOOT" = 1 ] && echo yes || echo no)"
	echo "DRY-RUN: overlay version=$OVERLAY_VERSION out=$OUT"
	if [ -n "$RECOVERY_DTBO" ]; then echo "DRY-RUN: recovery_dtbo=$RECOVERY_DTBO"; fi
	echo "DRY-RUN: would stage the payload, install firstboot, and call build-m1b-image.sh"
	exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lmi-generic-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "== staging payload =="
mkdir -p "$WORK/payload" "$WORK/empty"
( cd "$TREE" && tar -cf - . ) | ( cd "$WORK/payload" && tar -xf - )

# Normalise CRLF (Windows checkouts) the same way rebuild-image-from-device.sh
# does: a CR in an OpenRC script or conf.d breaks the device side.
python3 - "$WORK/payload" <<'PY'
import os, sys
root = sys.argv[1]
n = 0
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        data = open(path, "rb").read()
        if b"\0" in data or b"\r" not in data:
            continue
        open(path, "wb").write(data.replace(b"\r\n", b"\n"))
        n += 1
print("payload normalized: %d CRLF text file(s) fixed" % n)
PY

if [ "$FIRSTBOOT" = 1 ]; then
	echo "== installing firstboot payload =="
	mkdir -p "$WORK/payload/usr/sbin" "$WORK/payload/etc/init.d"
	cp "$FB_SRC/lmi-firstboot" "$WORK/payload/usr/sbin/lmi-firstboot"
	cp "$FB_SRC/lmi-firstboot.initd" "$WORK/payload/etc/init.d/lmi-firstboot"
	chmod 755 "$WORK/payload/usr/sbin/lmi-firstboot" "$WORK/payload/etc/init.d/lmi-firstboot"
fi

echo "== assembling =="
set -- --tree "$WORK/payload" \
	--base-tree "$WORK/empty" \
	--initramfs-dir "$INITRAMFS_DIR" \
	--kernel "$KERNEL" \
	--dtb "$DTB" \
	--cmdline "$CMDLINE" \
	--overlay-version "$OVERLAY_VERSION" \
	--out "$OUT"
if [ -n "$RECOVERY_DTBO" ]; then
	set -- "$@" --recovery-dtbo "$RECOVERY_DTBO"
fi
sh "$ROOT/tools/m1/build-m1b-image.sh" "$@"

echo ""
echo "generic image ready: $OUT"
ls -l "$OUT"
echo "the first boot will generate the root password, SSH host keys and machine-id (firstboot)"
