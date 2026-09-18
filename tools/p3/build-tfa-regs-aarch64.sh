#!/bin/sh
# Build the static aarch64 TFA98xx register tool (tools/p3/tfa-regs-android.c).
#
# Used for the Linux/Android live comparison of the speaker amp registers:
# Android has no i2c-tools and debugfs is disabled, so this static binary is
# pushed to /data/local/tmp and run as root (Magisk).
#
# usage: tools/p3/build-tfa-regs-aarch64.sh [output]
#   CROSS  cross compiler (default aarch64-linux-gnu-gcc)
set -eu

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
src="$dir/tfa-regs-android.c"
out=${1:-tfa-regs-android}
cross=${CROSS:-aarch64-linux-gnu-gcc}

"$cross" -O2 -static -Wall -Wextra -o "$out" "$src"
"$cross" -dumpmachine
ls -l "$out"
