#!/bin/sh
# SPDX-License-Identifier: MIT
# P3: read-only audio bring-up probe (run on the device Linux side).
#
# Prints one report that covers the whole P3 chain documented in
# docs/bluetooth-assessment.md 6c, so a session can see *which* link is missing:
#   firmware -> ADSP boot -> QRTR/APR -> servreg locator (pd-mapper) -> sound card.
#
# usage: tools/p3/audio-probe.sh [--manifest <file>]
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MANIFEST=${MANIFEST:-$HERE/adsp-firmware.sha256}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST=$2; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# /sys/bus/platform/devices/ names contain commas and colons: avoid `ls | grep`.
have_dev() {
  for d in /sys/bus/platform/devices/*"$1"*; do [ -e "$d" ] && return 0; done
  return 1
}
list_audio_devs() {
  for d in /sys/bus/platform/devices/*q6core* /sys/bus/platform/devices/*sound* \
           /sys/bus/platform/devices/*bolero* /sys/bus/platform/devices/*wcd938*; do
    [ -e "$d" ] && basename "$d"
  done
}

echo "=== 1. firmware (/lib/firmware) ==="
if [ -r "$MANIFEST" ]; then
  ( cd /lib/firmware 2>/dev/null && sha256sum -c "$MANIFEST" 2>&1 | tail -3 )
else
  ls /lib/firmware/adsp.* 2>/dev/null | wc -l
fi

echo
echo "=== 2. adsp-loader sysfs ==="
ls -la /sys/kernel/boot_adsp/ 2>&1

echo
echo "=== 3. ADSP / APR dmesg ==="
dmesg 2>/dev/null | grep -iE 'adsp|apr|q6|lpass|svc|servreg|locator' | tail -25

echo
echo "=== 4. QRTR services ==="
if have qrtr-lookup; then
  timeout 10 qrtr-lookup 2>/dev/null > /tmp/p3-qrtr.$$ || true
  echo "--- service registry (notif 0x42 / locator 0x40) ---"
  grep -iE 'registry' /tmp/p3-qrtr.$$ || echo "  (no registry service)"
  echo "--- audio / TFTP ---"
  grep -iE 'avs|audio|TFTP' /tmp/p3-qrtr.$$ || echo "  (none)"
  echo "--- total advertised services: $(($(wc -l < /tmp/p3-qrtr.$$) - 1)) ---"
  rm -f /tmp/p3-qrtr.$$
else
  echo "(qrtr-lookup missing: apk add qrtr)"
fi

echo
echo "=== 5. APR/q6core audio platform devices ==="
for d in soc:qcom,msm-audio-apr soc:qcom,msm-pcm-routing soc:qcom,msm-dai-q6; do
  printf '%-32s -> ' "$d"
  readlink -f "/sys/bus/platform/devices/$d/driver" 2>/dev/null || echo "(no driver)"
done
echo "--- q6core-audio / sound / codecs (these are created only on ADSP 'up') ---"
found=$(list_audio_devs)
if [ -n "$found" ]; then
  printf '%s\n' "$found"
else
  echo "  ABSENT -> the ADSP 'up' notification chain has not run (see docs 6c.2)"
fi

echo
echo "=== 6. sound cards ==="
cat /proc/asound/cards 2>/dev/null || echo "(no /proc/asound)"

echo
echo "=== 7. userspace ==="
for b in aplay arecord amixer rmtfs pd-mapper tqftpserv qrtr-lookup; do
  p=$(command -v "$b" 2>/dev/null || true)
  [ -n "$p" ] && echo "  $b: $p"
done
for s in rmtfs pd-mapper tqftpserv; do
  printf '  %s service: ' "$s"
  rc-service "$s" status 2>/dev/null | tail -1 || echo "(not installed)"
done
echo "  /dev/qcom_rmtfs_mem*: $(ls /dev/qcom_rmtfs_mem* 2>/dev/null | tr '\n' ' ')"

echo
echo "=== 8. verdict ==="
if [ -s /proc/asound/cards ] && ! grep -q 'no soundcards' /proc/asound/cards; then
  echo "sound card present -> run: aplay -l ; arecord -l"
else
  if have_dev q6core; then
    echo "q6core exists but no card: inspect the machine driver (kona-asoc-snd) probe"
  else
    echo "no card: the ADSP-up chain (servreg locator / pd-mapper) is still the blocker"
  fi
fi
