#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline tests for tools/install/firstboot/lmi-firstboot (M5 generic image).
#
# Runs the first-boot setup against a sandbox tree (`--root <dir>`), so nothing
# outside the mktemp dir is touched.  Requires openssl or python3 for the
# SHA-512 hash; skips cleanly if neither exists.  Runs in CI.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FB=$HERE/../install/firstboot/lmi-firstboot
[ -f "$FB" ] || { echo "script not found: $FB" >&2; exit 1; }

if ! command -v openssl >/dev/null 2>&1 && ! python3 -c 'import crypt' >/dev/null 2>&1 &&
	! command -v mkpasswd >/dev/null 2>&1; then
	echo "SKIP: no SHA-512 crypt tool (openssl/python3/mkpasswd)"
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

ROOT=$TMP/root
fails=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { sh "$FB" --root "$ROOT" "$@"; }

mkdir -p "$ROOT/etc/conf.d" "$ROOT/var/log" "$ROOT/root"
printf 'root:!:19000:0:99999:7:::\n' >"$ROOT/etc/shadow"
printf 'DROPBEAR_OPTS="-P /run/dropbear.pid"\n' >"$ROOT/etc/conf.d/dropbear"

echo "== T1: --dry-run changes nothing"
run --dry-run >"$TMP/dry.out" 2>&1 || fail "dry-run failed"
[ -e "$ROOT/etc/lmi-firstboot-done" ] && fail "dry-run wrote the done marker" || ok "dry-run wrote no marker"
grep -q '^root:!' "$ROOT/etc/shadow" && ok "dry-run left /etc/shadow locked" || fail "dry-run touched /etc/shadow"
sed 's/^/    /' "$TMP/dry.out"

echo "== T2: first run sets everything up"
run >"$TMP/run.out" 2>&1 || fail "first run failed: $(cat "$TMP/run.out")"
[ -e "$ROOT/etc/lmi-firstboot-done" ] && ok "done marker written" || fail "done marker missing"
[ -f "$ROOT/root/lmi-root-password.txt" ] && ok "root password file written" || fail "root password file missing"
[ "$(stat -c %a "$ROOT/root/lmi-root-password.txt" 2>/dev/null)" = 600 ] \
	&& ok "root password file is 0600" || fail "root password file mode is not 0600"
root_hash=$(awk -F: '$1=="root"{print $2}' "$ROOT/etc/shadow")
case "$root_hash" in
	'$6$'*) ok "root password hash uses SHA-512 crypt" ;;
	*) fail "root hash was not updated: $root_hash" ;;
esac
grep -q '^[0-9a-f]\{32\}$' "$ROOT/etc/machine-id" && ok "machine-id regenerated (32 hex)" || fail "machine-id not regenerated"
grep -q -- '-s' "$ROOT/etc/conf.d/dropbear" && ok "SSH password logins disabled" || fail "DROPBEAR_OPTS -s missing"
[ "$(stat -c %a "$ROOT/root/.ssh")" = 700 ] && ok "$ROOT/root/.ssh is 0700" || fail "/root/.ssh mode wrong"
[ -f "$ROOT/root/.ssh/authorized_keys" ] && [ ! -s "$ROOT/root/.ssh/authorized_keys" ] \
	&& ok "authorized_keys exists and is empty" || fail "authorized_keys state wrong"

echo "== T3: the second run is a no-op"
cp "$ROOT/etc/shadow" "$TMP/shadow.before"
run >"$TMP/run2.out" 2>&1 || fail "second run failed"
if diff -q "$ROOT/etc/shadow" "$TMP/shadow.before" >/dev/null 2>&1; then
	ok "password was not rotated again"
else
	fail "second run changed /etc/shadow"
fi
grep -q "already initialized" "$TMP/run2.out" && ok "second run reports it is initialized" || fail "no-op message missing"

echo "== T4: --force rotates the password"
run --force >"$TMP/run3.out" 2>&1 || fail "--force failed"
new_hash=$(awk -F: '$1=="root"{print $2}' "$ROOT/etc/shadow")
[ "$new_hash" != "$root_hash" ] && ok "--force produced a new hash" || fail "--force did not rotate"

echo "== T5: unknown option is rejected"
if run --bogus >/dev/null 2>&1; then
	fail "unknown option accepted"
else
	ok "unknown option rejected"
fi

if [ "$fails" -gt 0 ]; then
	echo "M5 firstboot tests: $fails failure(s)"
	exit 1
fi
echo "M5 firstboot tests: all passed"
