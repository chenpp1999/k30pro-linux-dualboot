#!/bin/sh
# SPDX-License-Identifier: MIT
# Repository guard rails from docs/test-plan.md T0 (run by CI, issue #7):
#   1. Markdown local link check
#   2. Destructive scripts (dd ... of=) must offer --dry-run
#   3. Hardcoded /dev/sd* nodes only allowed in the documented whitelist
#
# The whitelists are heuristics: any new tool must either satisfy the rule or
# be added here WITH a written justification (issue #18).
set -u

status=0

echo "== 1. markdown local links =="
broken=$(mktemp)
for f in $(git ls-files '*.md'); do
  dir=$(dirname "$f")
  grep -oE '\[[^]]*\]\([^)]+\)' "$f" 2>/dev/null |
    sed -E 's/^.*\]\(([^)]+)\)$/\1/' |
    while read -r link; do
      case "$link" in
        http://*|https://*|mailto:*) continue ;;
      esac
      target=${link%%#*}
      target=${target#/}
      [ -n "$target" ] || continue
      [ -e "$dir/$target" ] || echo "BROKEN: $f -> $link"
    done >> "$broken"
done
if [ -s "$broken" ]; then
  echo "broken links:"; cat "$broken"; status=1
else
  echo "links OK"
fi
rm -f "$broken"

echo "== 2. destructive scripts must offer --dry-run =="
# Scanned set: every *.sh plus every extension-less shell/openrc script under
# tools/ (the payload scripts live in tools/m1/m1b/{usr/sbin,etc/init.d}).
# etc/conf.d/* are sourced config fragments and are not scripts.
scanned_scripts() {
  git ls-files '*.sh'
  for f in $(git ls-files tools); do
    case "$f" in
      *.sh) continue ;;
      */etc/conf.d/*) continue ;;
    esac
    head -n1 "$f" 2>/dev/null |
      grep -qE '^#!.*(/sh$|/sh |/ash|openrc-run|env sh|busybox sh)' && echo "$f"
  done
}
# Exemptions (each with a written justification):
#   ramboot init scripts : only write is the one-shot BCB clear (ADR-0001)
#   tools/m3/lmi-repart.sh : default action IS the dry-run planner; `apply` refuses
#   lmi-chargectl : the only write is the one-shot BCB in the stuck-charge
#                   recovery path (same class as the init scripts)
#   m1-mailbox    : device-side mailbox writer (super read/write region)
DRY_EXEMPT="tools/m0/init tools/m1/m1-init.sh tools/m1/m1b-init.sh tools/m3/lmi-repart.sh
tools/m1/m1b/usr/sbin/lmi-chargectl tools/m1/m1b/usr/sbin/m1-mailbox"
for f in $(scanned_scripts); do
  case "$f" in
    tools/ci/checks.sh) continue ;;   # the scanner itself contains these patterns
    tools/tests/*) continue ;;        # test harnesses write only into mktemp dirs
  esac
  if grep -qE 'dd .*of=' "$f" 2>/dev/null; then
    case " $(echo $DRY_EXEMPT) " in
      *" $f "*) echo "exempt: $f" ;;
      *)
        if grep -q -- '--dry-run' "$f"; then
          echo "ok: $f"
        else
          echo "MISSING --dry-run: $f"; status=1
        fi
        ;;
    esac
  fi
done

echo "== 3. hardcoded device nodes =="
# by-name symlinks (/dev/block/by-name/...) are stable and allowed; raw /dev/sd*
# partition nodes are only allowed in the documented whitelist files (the Linux
# side has no /dev/block/by-name, so /dev/sdXN with an env override is the
# legitimate form there).
#   rebuild-image-from-device.sh : device-side tool, /dev/sda28 default, --dev override
#   lmi-repart.sh                : planner for the disk it is asked to plan; prints commands
#   lmi-chargectl / m1-mailbox / lmi-wifi-start : misc/super defaults, overridable
NODE_ALLOWED="tools/m0/init tools/m1/m1-init.sh tools/m1/m1b-init.sh
tools/m1/rebuild-image-from-device.sh tools/m3/lmi-repart.sh
tools/m1/m1b/usr/sbin/lmi-chargectl tools/m1/m1b/usr/sbin/m1-mailbox
tools/m1/m1b/usr/sbin/lmi-wifi-start"
for f in $(scanned_scripts); do
  case "$f" in
    tools/ci/checks.sh) continue ;;   # the scanner itself contains this pattern
  esac
  if grep -qE '/dev/sd[a-z][0-9]*' "$f" 2>/dev/null; then
    case " $(echo $NODE_ALLOWED) " in
      *" $f "*) echo "whitelisted: $f" ;;
      *) echo "NEW hardcoded device node: $f"; status=1 ;;
    esac
  fi
done

echo "== 4. personal identifiers / credentials =="
# The tree must never contain the author's device identifiers, network names or
# credentials (SECURITY.md "凭据与隐私").  These patterns are the regression
# guard for the 2026-09-15 scrub: extend the list instead of deleting entries.
#   <your-password> is a *directory* name in some paths (phone-server/lmi-m0/), so it is
#   only flagged when it appears as a credential (password context).
FORBIDDEN='REDACTED|REDACTED|REDACTED|CMCC-[0-9]|(密码|口令|password)[^:]{0,12}<your-password>'
hits=$(git grep -n -E "$FORBIDDEN" -- . ':(exclude)tools/ci/checks.sh' 2>/dev/null || true)
if [ -n "$hits" ]; then
	echo "$hits"
	echo "FOUND personal identifiers/credentials"; status=1
else
	echo "clean"
fi

echo "== guard rails done (status=$status) =="
exit $status
