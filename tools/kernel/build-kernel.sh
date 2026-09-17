#!/bin/sh
# SPDX-License-Identifier: MIT
# build-kernel.sh - reproduce the xiaomi-lmi downstream kernel (4.19 / SM8250).
#
# This is the P1/P2 tool of docs/peripheral-bringup-plan.md: it fetches the
# exact LineageOS source commit the deployed kernel came from, applies the
# committed config, and builds Image + dtbs with Clang/LLD.  It writes only
# into its work dir; flashing/RAM-booting is a separate, deliberate step.
#
# usage:
#   tools/kernel/build-kernel.sh [--work DIR] [--config FILE] [--jobs N]
#                               [--fetch-only] [--dry-run]
#
#   --config FILE  kernel config to use (default
#                  tools/kernel/config-xiaomi-lmi.aarch64).  Use a copy for P2
#                  experiments: scripts/config or a fragment + olddefconfig.
#   --jobs N       parallel build jobs (default 4; the reference machine has
#                  12 CPUs but only ~5.8 GB RAM, and the kernel build OOMs with
#                  too many clang jobs)
#
# Requires (Debian/Ubuntu): git clang lld llvm device-tree-compiler bc flex
# bison libssl-dev libelf-dev.  On the reference machine they were installed
# with `wsl -u root -e sh ...` because the WSL user's sudo needs a password.
#
# Outputs (in the work dir):
#   out/arch/arm64/boot/Image        uncompressed kernel (this is what the
#                                    deployed boot image carries)
#   out/arch/arm64/boot/dts/vendor/qcom/*.dtb
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

SHA=a5b3099017ae581aae8bf597b2f9c8c765026af1
URL=https://github.com/LineageOS/android_kernel_xiaomi_sm8250
WORK=${LMI_KERNEL_WORK:-$HOME/kbuild}
CONFIG=${LMI_KERNEL_CONFIG:-$HERE/config-xiaomi-lmi.aarch64}
JOBS=${LMI_KERNEL_JOBS:-4}
FETCH_ONLY=0
DRY=0

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--work) WORK=$2; shift 2 ;;
	--config) CONFIG=$2; shift 2 ;;
	--jobs) JOBS=$2; shift 2 ;;
	--fetch-only) FETCH_ONLY=1; shift ;;
	--dry-run) DRY=1; shift ;;
	-h | --help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

SRC=$WORK/linux-sm8250
OUT=$WORK/out
[ -f "$CONFIG" ] || die "config not found: $CONFIG"

for t in git clang ld.lld llvm-ar make; do
	command -v "$t" >/dev/null 2>&1 || die "$t not found (see the dependency list in the header)"
done

echo "work:   $WORK"
echo "source: $URL @ $SHA"
echo "config: $CONFIG ($(wc -l <"$CONFIG") lines)"
echo "jobs:   $JOBS"
if [ "$DRY" = 1 ]; then
	echo "DRY-RUN: would clone/fetch, seed .config, olddefconfig, build Image + dtbs"
	exit 0
fi

# --- source (shallow fetch of the single commit; retried, the link is flaky) --
if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$SRC"
	( cd "$SRC" && git init -q && git remote add origin "$URL" )
fi
if ! ( cd "$SRC" && git cat-file -e "$SHA^{commit}" 2>/dev/null ); then
	i=1
	ok=0
	while [ "$i" -le 8 ]; do
		if ( cd "$SRC" && timeout 1200 git fetch --depth 1 origin "$SHA" ); then ok=1; break; fi
		echo "fetch attempt $i failed, retrying"
		i=$((i + 1))
		sleep 5
	done
	[ "$ok" = 1 ] || die "could not fetch $SHA"
	( cd "$SRC" && git checkout -q FETCH_HEAD )
fi
echo "source: $(cd "$SRC" && git log --oneline -1)"

# --- config ------------------------------------------------------------------
mkdir -p "$OUT"
cp -f "$CONFIG" "$OUT/.config"
( cd "$SRC" && make O="$OUT" ARCH=arm64 olddefconfig >/dev/null )

[ "$FETCH_ONLY" = 0 ] || { echo "fetch-only: done"; exit 0; }

# --- build -------------------------------------------------------------------
export ARCH=arm64 LLVM=1
( cd "$SRC" && make O="$OUT" -j"$JOBS" Image )
( cd "$SRC" && make O="$OUT" -j"$JOBS" dtbs )

echo "Image: $OUT/arch/arm64/boot/Image ($(stat -c %s "$OUT/arch/arm64/boot/Image") bytes)"
find "$OUT/arch/arm64/boot/dts" -name '*.dtb' 2>/dev/null | head -10
echo "done. remember: RAM-boot it first (fastboot boot), never flash blind."
