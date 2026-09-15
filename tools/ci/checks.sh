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
tools/m1/m1b/usr/sbin/lmi-chargectl tools/m1/m1b/usr/sbin/m1-mailbox
#   lmi-netwatch : one-shot BCB write in the NETWATCH_REBOOT=1 last resort
tools/m1/m1b/usr/sbin/lmi-netwatch"
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
tools/m1/m1b/usr/sbin/lmi-wifi-start tools/m1/m1b/usr/sbin/lmi-netwatch"
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

echo "== 4. credential / identifier hygiene =="
# Generic patterns that must never enter the tree (see SECURITY.md).  The
# repository deliberately does NOT hard-code the author's own identifiers
# (device serial, SSID, ...): repeating them here would re-publish them.  Put
# yours in the untracked, gitignored tools/ci/forbidden-local.txt instead
# (one extended-regex per line) and they are enforced locally.
GEN='psk="[^"<$]|passphrase="[^"<$]|wpa_passphrase=[^"$]|BEGIN [A-Z ]*PRIVATE KEY|[A-Z]:\\Users\\|androidboot\.serialno=[0-9a-f]{6,}|androidboot\.cpuid=0x[0-9a-f]{4}|androidboot\.cert=[A-Z][0-9]{3}[A-Z0-9]{4}|ssid="[^"<$]'
PAT="$GEN"
if [ -r tools/ci/forbidden-local.txt ]; then
	local_extra=$(grep -vE '^[[:space:]]*(#|$)' tools/ci/forbidden-local.txt | tr '\n' '|' | sed 's/|$//')
	[ -n "$local_extra" ] && PAT="$PAT|$local_extra"
	echo "(local forbidden list: $(grep -cvE '^[[:space:]]*(#|$)' tools/ci/forbidden-local.txt) patterns)"
fi
hits=$(git grep -n -E "$PAT" -- . ':(exclude)tools/ci/checks.sh' ':(exclude)tools/ci/forbidden-local.txt' 2>/dev/null || true)
# Also scan not-yet-committed (untracked, non-ignored) files: a leak must be
# caught before the commit, not only by CI after the push.
for f in $(git ls-files --others --exclude-standard); do
	case "$f" in
	tools/ci/forbidden-local.txt|*.png|*.ttc|*.dict|*.zip|*.gz|*.img|*.bin) continue ;;
	esac
	if grep -a -q -E "$PAT" "$f" 2>/dev/null; then
		hits="$hits
$(grep -a -n -E "$PAT" "$f" 2>/dev/null | head -3 | sed "s|^|$f:|")"
	fi
done
if [ -n "$hits" ]; then
	echo "$hits"
	echo "FOUND credentials/identifiers"; status=1
else
	echo "clean"
fi

echo "== 5. payload integrity (exec bits + line endings) =="
# The overlay payload is copied into the rootfs verbatim and may also be exported
# with `git archive` / `tar`; scripts must be executable and text files must be
# LF in the index or the device ends up with a broken bring-up (2026-09-15:
# 0644 scripts + CRLF blobs each bit us).
pbad=0
for f in $(git ls-files 'tools/m1/m1b/usr/sbin/*' 'tools/m1/m1b/etc/init.d/*' \
	'tools/m1/m1b/usr/bin/*' 'tools/m1/m1b/usr/libexec/*'); do
	mode=$(git ls-files -s "$f" | awk '{print $1}')
	if [ "$mode" != "100755" ]; then
		echo "NOT EXECUTABLE ($mode): $f"; pbad=1
	fi
done
for f in $(git ls-files 'tools/m1/m1b/*'); do
	eol=$(git ls-files --eol "$f" | awk '{print $1}')
	case "$eol" in
	i/lf|i/-text|i/none) ;;
	*) echo "UNEXPECTED EOL ($eol): $f"; pbad=1 ;;
	esac
done
if [ "$pbad" = 0 ]; then echo "ok"; else status=1; fi

echo "== guard rails done (status=$status) =="
exit $status
