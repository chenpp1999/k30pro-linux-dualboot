#!/bin/sh
# SPDX-License-Identifier: MIT
# lmi-repart - M3 userdata-tail repartition planner (v0.1: dry-run only).
#
# Plan (docs/m3-repart-plan.md): shrink userdata's f2fs tail, move the userdata
# GPT entry's end, add an `lnx` partition at the disk tail, format it and
# migrate the Linux rootfs onto it.
#
# SAFETY: v0.1 never writes a partition table or a filesystem.  `plan` prints
# the exact reviewed command sequence, `backup` captures the GPT + the affected
# regions with a hash manifest, `verify` re-checks that manifest and
# `restore --yes` is the table rollback for an *applied* plan.  `apply` is
# intentionally not implemented (see docs/m3-repart-plan.md §5).
#
# Invariants (docs/architecture.md §1): boot/recovery/misc/super are never
# touched; only the userdata tail is reshaped.
#
# Usage (root; device unmounted - TWRP or a Linux boot):
#   lmi-repart.sh status
#   lmi-repart.sh plan [--lnx-size 16G] [--shrink 20G]
#   lmi-repart.sh backup
#   lmi-repart.sh verify
#   lmi-repart.sh restore --yes
#   lmi-repart.sh apply            # refused in v0.1
#
# Test/offline overrides: LMI_DISK (disk device or image file), LMI_DB_DIR
# (state dir), LMI_REPART_OFFLINE=1 (never call blockdev, work on files).
set -eu

DIR=${LMI_DB_DIR:-/data/local/lmi-dualboot/repart}
DISK=${LMI_DISK:-/dev/block/sda}
LOG=$DIR/repart.log
GPT_BACKUP=$DIR/gpt-backup.bin
GPT_TEXT=$DIR/gpt-table.txt
MANIFEST=$DIR/manifest.txt
PLAN_JSON=$DIR/plan.json
LOGICAL_SECTOR=512
ALIGN_SECTORS=2048            # 1 MiB

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "$*"; }
log() { mkdir -p "$DIR"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

need_sgdisk() {
	command -v sgdisk >/dev/null 2>&1 || die "sgdisk (gdisk) is required"
}

part_size() { # bytes
	if [ "${LMI_REPART_OFFLINE:-0}" = 1 ]; then
		stat -c %s "$DISK"
	else
		blockdev --getsize64 "$DISK" 2>/dev/null || stat -c %s "$DISK"
	fi
}

disk_sectors() {
	size=$(part_size)
	echo $((size / LOGICAL_SECTOR))
}

align_up() { # sectors -> aligned sectors (1 MiB)
	echo $(( (($1 + ALIGN_SECTORS - 1) / ALIGN_SECTORS) * ALIGN_SECTORS ))
}

parse_size() { # 16G/512M/123456 -> bytes
	case "$1" in
	*[gG]) echo $(( ${1%[gG]} * 1024 * 1024 * 1024 ));;
	*[mM]) echo $(( ${1%[mM]} * 1024 * 1024 ));;
	*[kK]) echo $(( ${1%[kK]} * 1024 ));;
	*)     echo "$1";;
	esac
}

gpt_table() { # sgdisk -p text on stdout
	need_sgdisk
	sgdisk -p "$DISK" 2>/dev/null || die "cannot read the GPT of $DISK"
}

# fields: index start end size+unit code (name must be userdata)
userdata_row() {
	gpt_table | awk '
		/^Number/ { in_table = 1; next }
		in_table && /^[ \t]*[0-9]+/ && $7 == "userdata" {
			print $1, $2, $3, $4$5, $6
		}'
}

userdata_fields() { # sets UP_INDEX UP_START UP_END UP_SIZE UP_TYPE
	row=$(userdata_row | head -n1)
	[ -n "$row" ] || die "no 'userdata' partition found on $DISK"
	set -- $row
	UP_INDEX=$1 UP_START=$2 UP_END=$3 UP_SIZE=$4 UP_TYPE=$5
	# sgdisk prints Start/End in sectors and Size like "107.4 GiB"
	case "$UP_START" in *[!0-9]*) die "unexpected userdata start: $UP_START";; esac
	case "$UP_END" in *[!0-9]*) die "unexpected userdata end: $UP_END";; esac
}

f2fs_magic_ok() { # check the f2fs superblock magic at userdata_start + 1024
	disk=$1 start=$2
	bytes=$(dd if="$disk" bs=1 skip=$((start * LOGICAL_SECTOR + 1024)) count=4 2>/dev/null |
		od -An -v -tx1 | tr -d ' \n')
	[ "$bytes" = "1020f5f2" ]
}

cmd_status() {
	need_sgdisk
	total=$(disk_sectors)
	info "disk: $DISK ($((total / 2048)) MiB, $total sectors)"
	gpt_table | sed 's/^/  /'
	userdata_fields
	info ""
	info "userdata: index=$UP_INDEX start=$UP_START end=$UP_END type=$UP_TYPE"
	info "tail gap: $((total - UP_END - 1 - 33)) sectors (minus the secondary GPT)"
	if [ "${LMI_REPART_OFFLINE:-0}" != 1 ]; then
		info "current size: $(( (UP_END - UP_START + 1) * LOGICAL_SECTOR / 1024 / 1024 )) MiB"
	fi
}

cmd_plan() {
	lnx_size=16G
	shrink=
	while [ $# -gt 0 ]; do
		case "$1" in
		--lnx-size) lnx_size=$2; shift 2;;
		--shrink)   shrink=$2; shift 2;;
		*) die "unknown option: $1";;
		esac
	done
	need_sgdisk
	[ -b "$DISK" ] || [ -f "$DISK" ] || die "no such disk: $DISK"
	userdata_fields
	f2fs_magic_ok "$DISK" "$UP_START" ||
		die "userdata does not start with an f2fs superblock (magic missing) - refusing"
	cur_sectors=$((UP_END - UP_START + 1))
	lnx_bytes=$(parse_size "$lnx_size")
	[ "$lnx_bytes" -ge 268435456 ] || die "--lnx-size must be >= 256M"
	lnx_sectors=$(( (lnx_bytes + LOGICAL_SECTOR - 1) / LOGICAL_SECTOR ))
	lnx_sectors=$(align_up "$lnx_sectors")

	if [ -n "$shrink" ]; then
		shrink_bytes=$(parse_size "$shrink")
		new_sectors=$((cur_sectors - (shrink_bytes + LOGICAL_SECTOR - 1) / LOGICAL_SECTOR))
		[ "$new_sectors" -ge "$lnx_sectors" ] ||
			die "shrink leaves fewer sectors than the lnx size"
	else
		new_sectors=$((cur_sectors - lnx_sectors))
		[ "$new_sectors" -gt 0 ] || die "lnx does not fit inside userdata"
		new_sectors=$(align_up "$new_sectors")
	fi

	new_end=$((UP_START + new_sectors - 1))
	lnx_start=$(align_up $((new_end + 1)))
	lnx_end=$((lnx_start + lnx_sectors - 1))
	total=$(disk_sectors)
	last_usable=$((total - 34))   # 33 secondary GPT sectors + 1
	[ "$lnx_end" -le "$last_usable" ] ||
		die "no room at the tail: lnx_end=$lnx_end > last usable=$last_usable"
	next_idx=$(gpt_table | awk '/^Number/{f=1;next} f && /^[ \t]*[0-9]+/{i=$1} END{print i+1}')
	new_userdata_gib=$(awk "BEGIN {printf \"%.2f\", $new_sectors * $LOGICAL_SECTOR / 1073741824}")
	lnx_gib=$(awk "BEGIN {printf \"%.2f\", $lnx_sectors * $LOGICAL_SECTOR / 1073741824}")

	info "=== lmi-repart plan (dry-run, nothing is written) ==="
	info "userdata: $UP_START..$UP_END -> $UP_START..$new_end (${new_userdata_gib} GiB)"
	info "lnx:      index $next_idx, $lnx_start..$lnx_end (${lnx_gib} GiB)"
	info ""
	info "reviewed manual steps (docs/m3-repart-plan.md §4):"
	info "  0. full TWRP backup of userdata + 'lmi-repart.sh backup'"
	info "  1. fsck.f2fs -f /dev/block/by-name/userdata"
	info "  2. resize.f2fs -s $new_sectors /dev/block/by-name/userdata"
	info "  3. sgdisk -d $UP_INDEX \\"
	info "       -n $UP_INDEX:$UP_START:$new_end -c $UP_INDEX:userdata \\"
	info "       -u $UP_INDEX:<uuid from gpt-table.txt> \\"
	info "       -t $UP_INDEX:<type from gpt-table.txt> $DISK"
	info "  4. sgdisk -n $next_idx:$lnx_start:$lnx_end -c $next_idx:lnx -t $next_idx:8300 $DISK"
	info "  5. sgdisk -v $DISK && blockdev --rereadpt $DISK"
	info "  6. mkfs.ext4 -L lnx /dev/block/by-name/lnx"
	info "  7. migrate the rootfs, update the Linux cmdline (by-name) and rebuild the image"
	info ""

	mkdir -p "$DIR"
	cat > "$PLAN_JSON" <<EOF
{
  "disk": "$DISK",
  "sector_size": $LOGICAL_SECTOR,
  "userdata": { "index": $UP_INDEX, "old_start": $UP_START, "old_end": $UP_END,
                "new_end": $new_end, "new_sectors": $new_sectors },
  "lnx": { "index": $next_idx, "start": $lnx_start, "end": $lnx_end,
           "sectors": $lnx_sectors },
  "gpt_sha256": "$(cmd_status_sha)"
}
EOF
	cat > "$DIR/plan.env" <<EOF
PLAN_DISK=$DISK
PLAN_UD_INDEX=$UP_INDEX
PLAN_UD_OLD_END=$UP_END
PLAN_UD_NEW_END=$new_end
PLAN_UD_NEW_SECTORS=$new_sectors
PLAN_LNX_INDEX=$next_idx
PLAN_LNX_START=$lnx_start
PLAN_LNX_END=$lnx_end
PLAN_LNX_SECTORS=$lnx_sectors
EOF
	log "plan written: userdata_end=$new_end lnx=$lnx_start..$lnx_end"
	info "plan written to $PLAN_JSON (and plan.env)"
	[ "${LMI_REPART_OFFLINE:-0}" = 1 ] || info "NOW: run 'lmi-repart.sh backup' and a full TWRP backup"
}

cmd_status_sha() { # sha256 of the current GPT text (for the plan lock)
	gpt_table | sha256sum | awk '{print $1}'
}

cmd_backup() {
	need_sgdisk
	mkdir -p "$DIR"
	userdata_fields
	# region dumps: 1 MiB at the userdata start (superblock) and 1 MiB at the
	# planned lnx start (the tail region that disappears after the shrink)
	lnx_start=
	[ -f "$DIR/plan.env" ] && . "$DIR/plan.env" && lnx_start=${PLAN_LNX_START:-}
	sgdisk --backup="$GPT_BACKUP" "$DISK" >/dev/null 2>&1 ||
		die "sgdisk --backup failed"
	gpt_table > "$GPT_TEXT"
	dd if="$DISK" of="$DIR/userdata-head.img" bs=1024k count=1 2>/dev/null
	: > "$MANIFEST"
	{
		printf 'disk=%s\n' "$DISK"
		printf 'gpt_backup_sha256=%s\n' "$(sha "$GPT_BACKUP")"
		printf 'gpt_text_sha256=%s\n' "$(sha "$GPT_TEXT")"
		printf 'userdata_head_sha256=%s\n' "$(sha "$DIR/userdata-head.img")"
		printf 'userdata_index=%s start=%s end=%s\n' "$UP_INDEX" "$UP_START" "$UP_END"
		[ -n "${lnx_start:-}" ] && printf 'planned_lnx_start=%s\n' "$lnx_start"
	} >> "$MANIFEST"
	log "backup done (gpt + head region) in $DIR"
	info "backup written:"
	sed 's/^/  /' "$MANIFEST"
	info "keep a full TWRP backup next to this manifest before applying anything"
}

cmd_verify() {
	[ -f "$MANIFEST" ] || die "no manifest in $DIR (run backup first)"
	[ -f "$GPT_BACKUP" ] || die "no GPT backup in $DIR"
	fails=0
	check() { # name expected actual
		if [ "$1" = "$2" ]; then info "ok   - $2"; else info "FAIL - $1 (got $2)"; fails=$((fails + 1)); fi
	}
	want=$(awk -F= '$1=="gpt_text_sha256"{print $2}' "$MANIFEST")
	gpt_table > "$DIR/gpt-now.txt"
	check "$want" "$(sha "$DIR/gpt-now.txt")"
	info "GPT backup present: $GPT_BACKUP ($(stat -c %s "$GPT_BACKUP") bytes)"
	[ "$fails" = 0 ] || die "$fails check(s) failed - the table changed since the backup"
	info "manifest verified against the current table"
}

cmd_restore() {
	[ "${1:-}" = "--yes" ] || die "restore is destructive: pass --yes (see docs/m3-repart-plan.md §6)"
	[ -f "$GPT_BACKUP" ] || die "no GPT backup in $DIR"
	need_sgdisk
	sgdisk --load-backup="$GPT_BACKUP" "$DISK" >/dev/null 2>&1 ||
		die "sgdisk --load-backup failed"
	sgdisk -v "$DISK" >/dev/null 2>&1 || die "GPT verification failed after restore"
	log "GPT restored from $GPT_BACKUP"
	info "GPT restored. Re-read the table (blockdev --rereadpt $DISK) or reboot;"
	info "re-grow userdata's f2fs with resize.f2fs and check Android before proceeding."
}

cmd_apply() {
	die "v0.1 is a planner: run 'plan', review docs/m3-repart-plan.md, take a full
TWRP backup and execute the steps manually on a TEST DEVICE first (charter M3)."
}

main() {
	cmd=${1:-}
	[ -n "$cmd" ] || { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
	shift || true
	case "$cmd" in
	status)  cmd_status "$@";;
	plan)    cmd_plan "$@";;
	backup)  cmd_backup "$@";;
	verify)  cmd_verify "$@";;
	restore) cmd_restore "$@";;
	apply)   cmd_apply "$@";;
	*) die "unknown command: $cmd";;
	esac
}

main "$@"
