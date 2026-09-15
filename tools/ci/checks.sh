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
# Exemptions (each with a written justification):
#   ramboot init scripts : only write is the one-shot BCB clear (ADR-0001)
#   tools/m3/lmi-repart.sh : default action IS the dry-run planner; `apply` refuses
DRY_EXEMPT="tools/m0/init tools/m1/m1-init.sh tools/m1/m1b-init.sh tools/m3/lmi-repart.sh"
for f in $(git ls-files '*.sh' 'tools/m0/init'); do
  case "$f" in
    tools/tests/*) continue ;;   # test harnesses write only into mktemp dirs
  esac
  if grep -qE 'dd .*of=' "$f" 2>/dev/null; then
    case " $DRY_EXEMPT " in
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
# partition nodes are only allowed in the documented whitelist files.
# rebuild-image-from-device.sh: device-side tool, /dev/sda28 default with --dev override.
NODE_ALLOWED="tools/m0/init tools/m1/m1-init.sh tools/m1/m1b-init.sh tools/m1/rebuild-image-from-device.sh"
for f in $(git ls-files '*.sh' 'tools/m0/init'); do
  if grep -qE '/dev/sd[a-z][0-9]*' "$f" 2>/dev/null; then
    case " $NODE_ALLOWED " in
      *" $f "*) echo "whitelisted: $f" ;;
      *) echo "NEW hardcoded device node: $f"; status=1 ;;
    esac
  fi
done

echo "== guard rails done (status=$status) =="
exit $status
