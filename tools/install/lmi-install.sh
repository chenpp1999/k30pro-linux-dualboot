#!/bin/sh
# SPDX-License-Identifier: MIT
# lmi-install.sh - one-command installer for the Linux dual boot (M5).
#
# Runs on a PC with adb + fastboot and a USB cable.  It never repartitions and
# never writes the Android `boot` partition; the Linux rootfs goes into the
# free space of `super` that the LP metadata describes, and the Linux boot
# image goes to `recovery` (ADR-0001).  The writes happen inside a RAM-booted
# TWRP (`fastboot boot`, nothing is flashed first), because the Android
# kernel's baseband_guard rejects writes to `super` (issue #13).
#
# For a first-time user (docs/installer-design.md):
#
#   tools/install/lmi-install.sh check    --recovery IMG --rootfs IMG --twrp IMG
#   tools/install/lmi-install.sh plan     --recovery IMG --rootfs IMG
#   tools/install/lmi-install.sh install  --recovery IMG --rootfs IMG --twrp IMG
#   tools/install/lmi-install.sh rollback --twrp IMG
#
# Options:
#   --serial S     adb/fastboot device serial (default: the only device)
#   --super IMG    use a local copy of `super` instead of reading the device
#                  (check/plan only; needed for the offline tests)
#   --work DIR     backup directory (default ./lmi-install-backup)
#   --yes          do not prompt
#   --dry-run      validate + print the exact steps, touch nothing
#
# Safety: backup first (recovery/boot/misc/super metadata), then write the
# rootfs, then recovery, then the BCB -- an interruption before the BCB leaves
# the device booting Android.  `boot` is backed up but never written.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ADB=${LMI_ADB:-adb}
FASTBOOT=${LMI_FASTBOOT:-fastboot}
PYTHON=${LMI_PYTHON:-python3}
PATCHER=$HERE/patch-cmdline.py
LP=$HERE/lp-metadata.py

BYNAME=/dev/block/by-name
# Must match tools/m1/m1b-init.sh: the rootfs region is a fixed 1.5 GiB slot and
# the mailbox lives right after it.
ROOTFS_BLOCKS=393216      # 1.5 GiB in 4096-byte blocks
MBOX_GAP_BLOCKS=256
MBOX_SECTION_BLOCKS=16
MBOX_SECTIONS=5
RESERVE_BLOCKS=$((ROOTFS_BLOCKS + MBOX_GAP_BLOCKS + MBOX_SECTIONS * MBOX_SECTION_BLOCKS))
MAX_ROOTFS_MB=1536
BCB_CMD=boot-recovery

DRY=0
YES=0
SERIAL=
SUPER_IMG=
WORK=$PWD/lmi-install-backup
RECOVERY=
ROOTFS=
TWRP=

die() { echo "FATAL: $*" >&2; exit 1; }
msg() { echo "$*"; }
run() {
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $*"
		return 0
	fi
	"$@"
}

CMD=
while [ $# -gt 0 ]; do
	case "$1" in
	check | plan | install | rollback) CMD=$1; shift ;;
	--recovery) RECOVERY=$2; shift 2 ;;
	--rootfs) ROOTFS=$2; shift 2 ;;
	--twrp) TWRP=$2; shift 2 ;;
	--serial) SERIAL=$2; shift 2 ;;
	--super) SUPER_IMG=$2; shift 2 ;;
	--work) WORK=$2; shift 2 ;;
	--yes) YES=1; shift ;;
	--dry-run) DRY=1; shift ;;
	-h | --help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done
[ -n "$CMD" ] || die "usage: lmi-install.sh {check|plan|install|rollback} [...] (try --help)"

ADB_ARGS=""
FB_ARGS=""
if [ -n "$SERIAL" ]; then
	ADB_ARGS="-s $SERIAL"
	FB_ARGS="-s $SERIAL"
fi

adb_() { # shellcheck disable=SC2086
	$ADB $ADB_ARGS "$@"
}
fb_() { # shellcheck disable=SC2086
	$FASTBOOT $FB_ARGS "$@"
}

need_file() { [ -f "$2" ] || die "$1 not found: $2"; }
need_tool() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

require_android_boot_image() {
	img=$1
	head=$(dd if="$img" bs=1 count=8 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
	# 414e44524f494421 == "ANDROID!"
	[ "$head" = "414e44524f494421" ] || die "$img is not an Android boot image (magic=$head)"
}

# --- LP free-space selection ------------------------------------------------
choose_region() { # $1 = super image (>= 320 KiB); prints "offset_sectors size_sectors"
	super=$1
	out=$($PYTHON "$LP" select "$super" --size "$((RESERVE_BLOCKS * 4096))" --align 4096) ||
		die "no LP free region in super fits the $((RESERVE_BLOCKS * 4096 / 1048576 + 1)) MiB rootfs slot"
	echo "$out" | sed -n 's/.*offset_sectors=\([0-9][0-9]*\) size_sectors=\([0-9][0-9]*\).*/\1 \2/p'
}

# --- device helpers ---------------------------------------------------------
acquire_super_head() { # $1 = destination file (320 KiB)
	dst=$1
	if [ -n "$SUPER_IMG" ]; then
		cp "$SUPER_IMG" "$dst"
		return 0
	fi
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB exec-out dd if=$BYNAME/super bs=4096 count=80 > $dst"
		: >"$dst"
		return 0
	fi
	adb_ exec-out "dd if=$BYNAME/super bs=4096 count=80 2>/dev/null" >"$dst"
	[ -s "$dst" ] || die "failed to read the super metadata (is adb connected?)"
}

wait_for_fastboot() {
	i=0
	while [ $i -lt 60 ]; do
		if [ -n "$(fb_ devices 2>/dev/null | grep -v '^$')" ]; then return 0; fi
		i=$((i + 1))
		sleep 2
	done
	return 1
}

in_twrp() { adb_ shell 'getprop ro.twrp.version' 2>/dev/null | tr -d '\r' | grep -q .; }

enter_twrp() {
	[ -n "$TWRP" ] || die "--twrp <twrp.img> required"
	need_file "--twrp" "$TWRP"
	require_android_boot_image "$TWRP"
	msg "== rebooting to the bootloader and RAM-booting TWRP =="
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB reboot bootloader"
		echo "DRY  : $FASTBOOT boot $TWRP"
		return 0
	fi
	adb_ reboot bootloader
	wait_for_fastboot || die "no fastboot device after 120 s"
	fb_ boot "$TWRP" || die "fastboot boot TWRP failed"
	msg "waiting for TWRP adb..."
	i=0
	while [ $i -lt 60 ]; do
		if in_twrp; then
			msg "TWRP is up"
			return 0
		fi
		i=$((i + 1))
		sleep 3
	done
	die "TWRP did not expose adb within 180 s"
}

backup_partition() { # $1 = by-name basename, $2 = local file
	name=$1
	out=$2
	msg "backing up $name -> $out"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB exec-out dd if=$BYNAME/$name > $out"
		return 0
	fi
	adb_ exec-out "dd if=$BYNAME/$name 2>/dev/null" >"$out" || die "backup of $name failed"
	[ -s "$out" ] || die "backup of $name produced an empty file"
	sha256_of "$out" >"$out.sha256"
}

write_region() { # $1 file  $2 by-name  $3 bs  $4 seek
	msg "writing $1 -> $2 (bs=$3 seek=$4)"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB shell 'dd of=$BYNAME/$2 bs=$3 seek=$4 conv=notrunc' < $1"
		return 0
	fi
	adb_ shell "dd of=$BYNAME/$2 bs=$3 seek=$4 conv=notrunc 2>/dev/null" <"$1" ||
		die "dd to $2 failed (out of space / unreadable partition?)"
	adb_ shell sync
}

verify_region() { # $1 file  $2 by-name  $3 bs  $4 skip
	size=$(file_size "$1")
	[ "$((size % $3))" = 0 ] || die "internal: $1 size is not a multiple of $3"
	count=$((size / $3))
	want=$(sha256_of "$1")
	msg "verifying $2 readback (sha256)"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB exec-out dd if=$BYNAME/$2 bs=$3 skip=$4 count=$count | sha256sum"
		echo "DRY  : expect $want"
		return 0
	fi
	got=$(adb_ exec-out "dd if=$BYNAME/$2 bs=$3 skip=$4 count=$count 2>/dev/null" | sha256sum | awk '{print $1}')
	[ "$got" = "$want" ] || die "readback mismatch for $2: want $want got $got"
	msg "  ok: $got"
}

write_bcb() { # $1 = command
	msg "setting one-shot BCB '$1'"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB shell 'dd if=/dev/zero of=$BYNAME/misc bs=32 count=1 conv=notrunc'"
		echo "DRY  : printf '$1' | $ADB shell 'dd of=$BYNAME/misc bs=1 conv=notrunc'"
		return 0
	fi
	adb_ shell "dd if=/dev/zero of=$BYNAME/misc bs=32 count=1 conv=notrunc 2>/dev/null"
	printf '%s' "$1" | adb_ shell "dd of=$BYNAME/misc bs=1 conv=notrunc 2>/dev/null"
	adb_ shell sync
	got=$(adb_ shell "dd if=$BYNAME/misc bs=1 count=32 2>/dev/null | od -An -v -tx1 | tr -d ' \n'")
	want=$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
	case "$got" in
	"$want"*) msg "  BCB verified" ;;
	*) die "BCB verify failed (want $want got $got)" ;;
	esac
}

clear_bcb() {
	msg "clearing the BCB"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB shell 'dd if=/dev/zero of=$BYNAME/misc bs=32 count=1 conv=notrunc'"
		return 0
	fi
	adb_ shell "dd if=/dev/zero of=$BYNAME/misc bs=32 count=1 conv=notrunc 2>/dev/null"
	adb_ shell sync
}

confirm() {
	[ "$YES" = 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r ans || ans=
	case "$ans" in y | Y | yes | YES) return 0 ;; *) die "aborted by the user" ;; esac
}

# --- commands ---------------------------------------------------------------
preflight_images() {
	need_file "--recovery" "$RECOVERY"
	need_file "--rootfs" "$ROOTFS"
	require_android_boot_image "$RECOVERY"
	rsize=$(file_size "$ROOTFS")
	[ "$((rsize % 4096))" = 0 ] || die "rootfs image size must be a multiple of 4096"
	[ "$rsize" -gt 0 ] || die "rootfs image is empty"
	[ "$rsize" -le $((MAX_ROOTFS_MB * 1048576)) ] ||
		die "rootfs is larger than ${MAX_ROOTFS_MB} MiB: the super slot is fixed, use a smaller image (or M3)"
	msg "images:"
	msg "  recovery: $RECOVERY ($(file_size "$RECOVERY") bytes) sha256 $(sha256_of "$RECOVERY")"
	msg "  rootfs  : $ROOTFS ($rsize bytes) sha256 $(sha256_of "$ROOTFS")"
}

resolve_region() { # $1 = tmp dir; sets OFFSET_SECTORS/OFFSET_BYTES/OFFSET_BLOCKS
	acquire_super_head "$1/super-head.img"
	region=$(choose_region "$1/super-head.img")
	# shellcheck disable=SC2086
	set -- $region
	[ $# = 2 ] || die "could not select a super free region"
	OFFSET_SECTORS=$1
	OFFSET_BYTES=$((OFFSET_SECTORS * 512))
	[ "$((OFFSET_BYTES % 4096))" = 0 ] || die "free region is not 4096-aligned"
	OFFSET_BLOCKS=$((OFFSET_BYTES / 4096))
}

cmd_check() {
	preflight_images
	need_tool "$PYTHON"
	[ -f "$LP" ] || die "missing $LP"
	[ -f "$PATCHER" ] || die "missing $PATCHER"
	if [ -z "$SUPER_IMG" ]; then
		need_tool "$ADB"
		need_tool "$FASTBOOT"
	fi
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM
	resolve_region "$tmp"
	msg "super free region: offset $OFFSET_SECTORS sectors ($OFFSET_BYTES B)"
	msg "rootfs slot: $((ROOTFS_BLOCKS * 4096 / 1048576)) MiB (+ mailbox)"
	msg "check passed"
}

cmd_plan() {
	preflight_images
	need_tool "$PYTHON"
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM
	resolve_region "$tmp"
	msg "== plan =="
	msg "rootfs offset : $OFFSET_BYTES B ($OFFSET_BLOCKS x 4096)"
	msg "cmdline       : lmi_root_off=$OFFSET_BLOCKS"
	msg "recovery image: $RECOVERY -> recovery partition"
	msg "BCB           : $BCB_CMD -> misc (one-shot; Linux init clears it)"
	msg "steps:"
	msg "  1. adb reboot bootloader; fastboot boot <twrp.img>"
	msg "  2. backup recovery / boot / misc / super metadata -> $WORK"
	msg "  3. patch '$RECOVERY' cmdline: lmi_root_off=$OFFSET_BLOCKS"
	msg "  4. write rootfs -> super @ offset $OFFSET_BYTES, verify sha256 readback"
	msg "  5. write recovery image -> recovery, verify sha256 readback"
	msg "  6. write BCB '$BCB_CMD' to misc, verify"
	msg "  7. reboot -> Linux (any later reboot returns to Android)"
}

cmd_install() {
	preflight_images
	need_tool "$PYTHON"
	need_file "--twrp" "$TWRP"
	msg "== lmi-install =="
	msg "work dir: $WORK"
	confirm "Install Linux into super free space and overwrite the recovery partition?"

	run mkdir -p "$WORK"
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	enter_twrp
	resolve_region "$tmp"
	msg "chosen rootfs offset: $OFFSET_BYTES B (block $OFFSET_BLOCKS)"

	# 1) backup -- mandatory, before any write
	backup_partition recovery "$WORK/recovery.img"
	backup_partition boot "$WORK/boot.img"
	backup_partition misc "$WORK/misc.img"
	run cp "$tmp/super-head.img" "$WORK/super-head.img"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : write $WORK/manifest.txt (offset, sha256s, timestamp)"
	else
		{
			echo "installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
			echo "rootfs_offset_bytes=$OFFSET_BYTES"
			echo "rootfs_sha256=$(sha256_of "$ROOTFS")"
			echo "recovery_sha256=$(sha256_of "$RECOVERY")"
		} >"$WORK/manifest.txt"
	fi
	msg "backup complete: $WORK"

	# 2) patch the cmdline to the device-specific offset
	msg "== patching cmdline =="
	run $PYTHON "$PATCHER" "$RECOVERY" --set "lmi_root_off=$OFFSET_BLOCKS" --out "$tmp/recovery-patched.img"
	if [ "$DRY" = 0 ]; then
		RECOVERY=$tmp/recovery-patched.img
		require_android_boot_image "$RECOVERY"
	fi

	# 3) rootfs -> super (long), 4) recovery, 5) BCB last
	write_region "$ROOTFS" super 4096 "$OFFSET_BLOCKS"
	verify_region "$ROOTFS" super 4096 "$OFFSET_BLOCKS"
	write_region "$RECOVERY" recovery 4096 0
	verify_region "$RECOVERY" recovery 4096 0
	write_bcb "$BCB_CMD"

	msg "== done; rebooting into Linux =="
	msg "if Linux never starts and the device loops into fastboot:"
	msg "  fastboot erase misc && fastboot reboot"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB reboot recovery"
	else
		adb_ reboot recovery
	fi
}

cmd_rollback() {
	[ -d "$WORK" ] || die "no backup directory: $WORK"
	need_file "$WORK/recovery.img" "$WORK/recovery.img"
	need_file "--twrp" "$TWRP"
	msg "== rollback from $WORK =="
	confirm "Restore recovery and clear the BCB? (boot is not written)"
	enter_twrp
	write_region "$WORK/recovery.img" recovery 4096 0
	verify_region "$WORK/recovery.img" recovery 4096 0
	clear_bcb
	msg "rollback complete; rebooting"
	if [ "$DRY" = 1 ]; then
		echo "DRY  : $ADB reboot"
	else
		adb_ reboot
	fi
}

case "$CMD" in
check) cmd_check ;;
plan) cmd_plan ;;
install) cmd_install ;;
rollback) cmd_rollback ;;
*) die "unknown command: $CMD" ;;
esac
