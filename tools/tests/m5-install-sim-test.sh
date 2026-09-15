#!/bin/sh
# SPDX-License-Identifier: MIT
# End-to-end *simulation* of the M5 PC installer with no device.
#
# A fake adb/fastboot pair maps /dev/block/by-name/* to files in a sandbox, so
# the real (non-dry-run) code path of tools/install/lmi-install.sh runs:
# enter "TWRP", back up, patch the cmdline, stream the rootfs into the sandbox
# super, write recovery, set the BCB -- and then we assert the sandbox state.
# Runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INSTALL=$HERE/../install/lmi-install.sh
[ -f "$INSTALL" ] || { echo "script not found: $INSTALL" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
SB=$TMP/sandbox
BIN=$TMP/bin
mkdir -p "$SB" "$BIN" "$TMP/work"

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# --- sandbox "partitions" ---------------------------------------------------
python3 - "$SB" "$TMP" <<'PY'
import hashlib, os, struct, sys
sb, tmp = sys.argv[1], sys.argv[2]
GM, HM, MS, SL = 0x616C4467, 0x414C5030, 4096, 1
DB = 3 * 1024 * 1024 * 1024
g = struct.pack("<II32sIII", GM, 52, b"\0" * 32, MS, SL, 4096)
g = struct.pack("<II32sIII", GM, 52, hashlib.sha256(g).digest(), MS, SL, 4096)
tables = struct.pack("<36sIIII", b"system", 0, 0, 1, 0) + \
         struct.pack("<QIQI", 8192, 0, 4096, 0) + \
         struct.pack("<36sIQ", b"grp", 0, 0) + \
         struct.pack("<QIIQ36sI", 2048, 1048576, 0, DB, b"super", 0)
descs = struct.pack("<III", 0, 1, 52) + struct.pack("<III", 52, 1, 24) + \
        struct.pack("<III", 76, 1, 48) + struct.pack("<III", 124, 1, 64)
h = struct.pack("<IHHI32sI32s", HM, 10, 0, 128, b"\0" * 32, len(tables),
                hashlib.sha256(tables).digest()) + descs
h = h[:12] + hashlib.sha256(h).digest() + h[44:]
with open(os.path.join(sb, "super"), "wb") as f:
    f.truncate(DB)
    f.seek(0x1000); f.write(g)
    f.seek(0x2000); f.write(g)
    f.seek(0x3000); f.write(h)
    f.seek(0x3000 + 128); f.write(tables)

def boot(path, cmdline):
    b = bytearray(4096)
    b[0:8] = b"ANDROID!"
    struct.pack_into("<9I", b, 8, 0, 0, 0, 0, 0, 0, 0, 4096, 2)
    b[64:64 + len(cmdline)] = cmdline
    open(path, "wb").write(bytes(b))

boot(os.path.join(sb, "recovery"), b"androidboot.hardware=qcom")
boot(os.path.join(sb, "boot"), b"androidboot.hardware=qcom boot")
with open(os.path.join(sb, "misc"), "wb") as f:
    f.write(b"\0" * 4096)
boot(os.path.join(tmp, "rec-generic.img"), b"console=tty0 lmi_root_off=1596852")
boot(os.path.join(tmp, "twrp.img"), b"androidboot.hardware=qcom twrp")
with open(os.path.join(tmp, "rootfs.img"), "wb") as f:
    f.truncate(1024 * 1024)
    f.seek(0)
    f.write(b"LMI-ROOTFS-CONTENT" * 64)
PY

# --- fake adb / fastboot ----------------------------------------------------
cat >"$BIN/adb" <<'EOF'
#!/bin/sh
SB=${FAKE_SB:?}
map() { case "$1" in /dev/zero) echo /dev/zero ;; /dev/block/by-name/*) echo "$SB/${1##*/}" ;; *) echo "$1" ;; esac; }
sub=$1; shift
case "$sub" in
exec-out)
	# only `dd ...` is used
	set -- $1
	in=/dev/null; bs=4096; skip=0; count=
	for w in "$@"; do case $w in if=*) in=${w#if=} ;; bs=*) bs=${w#bs=} ;; skip=*) skip=${w#skip=} ;; count=*) count=${w#count=} ;; esac; done
	in=$(map "$in")
	if [ "$skip" = 0 ] && [ -z "$count" ]; then
		cat "$in"
	else
		dd if="$in" bs="$bs" skip="$skip" ${count:+count=$count} 2>/dev/null
	fi
	;;
shell)
	cmd=$1
	case "$cmd" in
	"getprop ro.twrp.version"*) echo "3.7.0-fake" ;;
	sync) : ;;
	"dd if="*od*)
		set -- $cmd
		in=/dev/null; bs=1; skip=0; count=
		for w in "$@"; do case $w in if=*) in=${w#if=} ;; bs=*) bs=${w#bs=} ;; skip=*) skip=${w#skip=} ;; count=*) count=${w#count=} ;; esac; done
		dd if="$(map "$in")" bs="$bs" skip="$skip" ${count:+count=$count} 2>/dev/null | od -An -v -tx1 | tr -d ' \n'
		;;
	"dd "*)
		set -- $cmd
		in=/dev/stdin; of=; bs=512; seek=0; count=
		for w in "$@"; do case $w in if=*) in=${w#if=} ;; of=*) of=${w#of=} ;; bs=*) bs=${w#bs=} ;; seek=*) seek=${w#seek=} ;; count=*) count=${w#count=} ;; esac; done
		[ -n "$of" ] || { echo "fake adb: no of=" >&2; exit 1; }
		if [ "$in" = /dev/stdin ]; then
			dd of="$(map "$of")" bs="$bs" seek="$seek" ${count:+count=$count} conv=notrunc 2>/dev/null
		else
			dd if="$(map "$in")" of="$(map "$of")" bs="$bs" seek="$seek" ${count:+count=$count} conv=notrunc 2>/dev/null
		fi
		;;
	*) echo "fake adb: unhandled shell: $cmd" >&2; exit 1 ;;
	esac
	;;
reboot) echo "fake adb: reboot $*" ;;
*) echo "fake adb: unhandled: $sub $*" >&2; exit 1 ;;
esac
EOF
cat >"$BIN/fastboot" <<'EOF'
#!/bin/sh
case "$1" in
devices) echo "FAKESERIAL	fastboot" ;;
boot) echo "fake fastboot: boot $2" ;;
*) echo "fake fastboot: $*" ;;
esac
EOF
chmod 755 "$BIN/adb" "$BIN/fastboot"

echo "== simulated install (real code path, fake adb/fastboot) =="
if FAKE_SB="$SB" LMI_ADB="$BIN/adb" LMI_FASTBOOT="$BIN/fastboot" LMI_PYTHON=python3 \
	sh "$INSTALL" install \
	--recovery "$TMP/rec-generic.img" --rootfs "$TMP/rootfs.img" --twrp "$TMP/twrp.img" \
	--work "$TMP/work" --yes >"$TMP/install.log" 2>&1; then
	ok "install completed against the fake device"
else
	fail "install failed: $(cat "$TMP/install.log")"
fi
sed 's/^/    /' "$TMP/install.log"

echo "== assertions =="
for f in recovery.img boot.img misc.img super-head.img manifest.txt; do
	[ -f "$TMP/work/$f" ] && ok "backup written: $f" || fail "missing backup: $f"
done

# rootfs content landed at sector 12288 (block 1536) of the sandbox super
want=$(sha256sum "$TMP/rootfs.img" | awk '{print $1}')
got=$(dd if="$SB/super" bs=4096 skip=1536 count=256 2>/dev/null | sha256sum | awk '{print $1}')
[ "$want" = "$got" ] && ok "rootfs is byte-identical in the super free region" \
	|| fail "rootfs readback mismatch ($want != $got)"

# recovery now holds the Linux image with the device-specific cmdline
if python3 - "$SB/recovery" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
cmd = (d[64:576].split(b"\0")[0] + b" " + d[608:1632].split(b"\0")[0]).decode()
print(cmd)
assert "lmi_root_off=1536" in cmd, cmd
PY
then
	ok "recovery image was written with lmi_root_off=1536"
else
	fail "recovery image cmdline not patched"
fi

# BCB is 'boot-recovery'
bcb=$(dd if="$SB/misc" bs=1 count=32 2>/dev/null | tr -d '\000')
[ "$bcb" = "boot-recovery" ] && ok "BCB set to boot-recovery" || fail "BCB is '$bcb'"

# boot partition was backed up but not written (same as original)
bsha=$(sha256sum "$SB/boot" | awk '{print $1}')
bback=$(sha256sum "$TMP/work/boot.img" | awk '{print $1}')
[ "$bsha" = "$bback" ] && ok "boot partition untouched (sha256 matches the backup)" \
	|| fail "boot partition changed"

echo "== simulated rollback =="
if FAKE_SB="$SB" LMI_ADB="$BIN/adb" LMI_FASTBOOT="$BIN/fastboot" LMI_PYTHON=python3 \
	sh "$INSTALL" rollback --twrp "$TMP/twrp.img" --work "$TMP/work" --yes \
	>"$TMP/rollback.log" 2>&1; then
	ok "rollback completed"
else
	fail "rollback failed: $(cat "$TMP/rollback.log")"
fi
rback=$(sha256sum "$TMP/work/recovery.img" | awk '{print $1}')
rnow=$(sha256sum "$SB/recovery" | awk '{print $1}')
[ "$rback" = "$rnow" ] && ok "recovery restored from the backup" || fail "recovery not restored"
bcb2=$(dd if="$SB/misc" bs=1 count=32 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
allzero=$(printf '%064d' 0)
[ "$bcb2" = "$allzero" ] && ok "BCB cleared" || fail "BCB not cleared ($bcb2)"

if [ "$fails" -gt 0 ]; then
	echo "M5 install simulation: $fails failure(s)"
	exit 1
fi
echo "M5 install simulation: all passed"
