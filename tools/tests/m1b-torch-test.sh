#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for tools/m1/m1b/usr/sbin/lmi-torch (flashlight control).
#
# Uses a fake sysfs leds tree through LMI_TORCH_SYS: nothing on the real device
# is touched and no LED is lit.  Runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TORCH=$HERE/../m1/m1b/usr/sbin/lmi-torch
[ -f "$TORCH" ] || { echo "script not found: $TORCH" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
LEDS=$TMP/leds
mkdir -p "$LEDS"/led:torch_0 "$LEDS"/led:torch_1 "$LEDS"/led:switch_0 "$LEDS"/led:switch_1
for n in 0 1; do
	echo 500 >"$LEDS/led:torch_$n/max_brightness"
	echo 0 >"$LEDS/led:torch_$n/brightness"
	echo 0 >"$LEDS/led:switch_$n/brightness"
done

fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { LMI_TORCH_SYS=$LEDS sh "$TORCH" "$@"; }
val() { cat "$LEDS/$1/brightness"; }

echo "== T1: default action is toggle (off -> on)"
run >/dev/null
[ "$(val led:switch_0)" = 1 ] && [ "$(val led:torch_0)" = 100 ] \
	&& ok "toggle turned the torch on (switch=1, level=100)" \
	|| fail "toggle on failed (switch=$(val led:switch_0) torch=$(val led:torch_0))"

echo "== T2: toggle again turns it off (switch first, then level)"
run >/dev/null
[ "$(val led:switch_0)" = 0 ] && [ "$(val led:torch_0)" = 0 ] \
	&& ok "toggle turned the torch off" \
	|| fail "toggle off failed (switch=$(val led:switch_0) torch=$(val led:torch_0))"

echo "== T3: explicit on/off and status"
run on >/dev/null
out=$(run status)
case "$out" in *"state: on"*) ok "status reports on" ;; *) fail "status wrong: $out" ;; esac
run off >/dev/null
out=$(run status)
case "$out" in *"state: off"*) ok "status reports off" ;; *) fail "status wrong: $out" ;; esac

echo "== T4: --level is clamped to max_brightness"
run on --level 9999 >/dev/null
[ "$(val led:torch_0)" = 500 ] && ok "level clamped to max (500)" \
	|| fail "level not clamped: $(val led:torch_0)"
run off >/dev/null

echo "== T5: --dry-run changes nothing"
run on --dry-run >"$TMP/dry.out" 2>&1
[ "$(val led:switch_0)" = 0 ] && [ "$(val led:torch_0)" = 0 ] \
	&& ok "dry-run left the LEDs untouched" || fail "dry-run wrote something"
grep -q "DRY" "$TMP/dry.out" && ok "dry-run prints the planned writes" || fail "no DRY output"

echo "== T6: unknown option is rejected"
if run --bogus >/dev/null 2>&1; then fail "unknown option accepted"; else ok "unknown option rejected"; fi

echo "== T7: missing LED nodes -> clear error, exit != 0"
if LMI_TORCH_SYS=$TMP/empty sh "$TORCH" on >/dev/null 2>&1; then
	fail "accepted a missing sysfs tree"
else
	ok "refuses when the flash LED nodes are absent"
fi

if [ "$fails" -gt 0 ]; then
	echo "m1b torch tests: $fails failure(s)"
	exit 1
fi
echo "m1b torch tests: all passed"
