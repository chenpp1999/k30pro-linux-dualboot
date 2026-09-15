#!/bin/sh
# SPDX-License-Identifier: MIT
# build.sh - assemble the Magisk module zip for the Android -> Linux switch.
#
#   packages/magisk-module/build.sh [out.zip]
#
# Contents: module.prop, action.sh, recovery-swap.sh (bundled from tools/m1),
# README.md.  No META-INF needed on Magisk 20.4+.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/../.." && pwd)
OUT=${1:-$HERE/lmi-dualboot-switch.zip}
STAGE=$(mktemp -d /tmp/lmi-magisk.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM

cp "$HERE/module.prop" "$HERE/action.sh" "$HERE/README.md" "$STAGE/"
cp "$REPO/tools/m1/recovery-swap.sh" "$STAGE/recovery-swap.sh"
chmod 755 "$STAGE/action.sh" "$STAGE/recovery-swap.sh"

# normalise line endings (the zip is consumed by Android's sh)
for f in "$STAGE"/*.sh; do
	sed -i 's/\r$//' "$f"
done

( cd "$STAGE" && zip -q -r "$OUT" . )
echo "built: $OUT"
unzip -l "$OUT"
