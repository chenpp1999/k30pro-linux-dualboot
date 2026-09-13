#!/bin/sh
# Fetch and verify upstream build inputs for M0 ramboot.
# Everything here is public, provenance-pinned data from:
#   https://github.com/jian45154/redmi-k30-pro-postmarketos
# Output: $WORKDIR/{vmlinuz,kona-v2.1-lmi.dtb,lmi-sm8250-overlay.dtbo}
set -eu

WORKDIR="${WORKDIR:-$(pwd)/out}"
mkdir -p "$WORKDIR"

TAG=d80-minimal-gui-osk-20260712
URL="https://github.com/jian45154/redmi-k30-pro-postmarketos/releases/download/${TAG}/d80-minimal-gui-osk-20260712.tar.gz"
SHA=f380eb275ef4ba8854dd3bc389f7113a701a29ab3fd302684b729e6ad64286ca

BUNDLE="$WORKDIR/d80.tar.gz"
if [ ! -f "$BUNDLE" ] || ! echo "$SHA  $BUNDLE" | sha256sum -c - >/dev/null 2>&1; then
  echo "downloading $URL"
  curl -L --fail --retry 5 --retry-delay 2 --retry-all-errors -C - -o "$BUNDLE" "$URL"
fi
echo "$SHA  $BUNDLE" | sha256sum -c -

EXTRACT="$WORKDIR/d80"
if [ ! -d "$EXTRACT" ]; then
  mkdir -p "$EXTRACT"
  tar xzf "$BUNDLE" -C "$EXTRACT"
fi

python3 - "$EXTRACT" "$WORKDIR" <<'EOF'
import sys, tarfile, os, pathlib
extract, workdir = sys.argv[1], sys.argv[2]
src = pathlib.Path(extract) / "d80-minimal-gui-osk-20260712"
apk = src / "linux-xiaomi-lmi-4.19.325-r9.apk"
want = [
    ("boot/vmlinuz", "vmlinuz"),
    ("boot/dtbs/qcom/kona-v2.1-lmi.dtb", "kona-v2.1-lmi.dtb"),
    ("boot/dtbs/qcom/lmi-sm8250-overlay.dtbo", "lmi-sm8250-overlay.dtbo"),
]
t = tarfile.open(apk, "r:gz")
for member, out in want:
    dst = pathlib.Path(workdir) / out
    data = t.extractfile(t.getmember(member)).read()
    dst.write_bytes(data)
    print(f"extracted {out} ({len(data)} bytes)")
EOF

ls -l "$WORKDIR"
