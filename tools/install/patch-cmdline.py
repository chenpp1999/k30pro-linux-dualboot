#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch the kernel cmdline inside an Android boot image, in place.

The generic M5 boot image (tools/install/build-generic-image.sh) is built with
a placeholder `lmi_root_off=`, but the *actual* offset of the rootfs inside
`super` depends on the device's LP metadata (docs/installer-design.md §4).
Rewriting the string field is the only device-specific step an install needs,
and it can be done without mkbootimg:

  boot header v2:  magic[8]  ...  page_size @36  header_version @40
                   name[16] @48   cmdline[512] @64   id[32] @576
                   extra_cmdline[1024] @608

The kernel concatenates cmdline + extra_cmdline, so the combined string may
span both fields (the 32-byte `id` sits between them and is left untouched).

usage:
  patch-cmdline.py <boot.img> --set lmi_root_off=1596852 [--out <file>]
  patch-cmdline.py <boot.img> --show

Reads and (unless --out/--show) rewrites the file.  No device access.
"""
import argparse
import struct
import sys

MAGIC = b"ANDROID!"
PAGE_SIZE_OFF = 36
HEADER_VERSION_OFF = 40
CMDLINE_OFF = 64
CMDLINE_LEN = 512
EXTRA_CMDLINE_OFF = 608
EXTRA_CMDLINE_LEN = 1024


def die(msg):
    print("patch-cmdline: %s" % msg, file=sys.stderr)
    return 1


def read_cmdline(data):
    version = struct.unpack_from("<I", data, HEADER_VERSION_OFF)[0]
    if version < 2:
        raise ValueError("unsupported boot header version %d (need v2)" % version)
    cmd = data[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN].split(b"\0", 1)[0].decode("utf-8", "replace")
    extra = data[EXTRA_CMDLINE_OFF:EXTRA_CMDLINE_OFF + EXTRA_CMDLINE_LEN].split(b"\0", 1)[0].decode("utf-8", "replace")
    return (cmd + " " + extra).strip()


def write_cmdline(data, combined):
    raw = combined.encode("utf-8")
    capacity = CMDLINE_LEN + EXTRA_CMDLINE_LEN
    if len(raw) > capacity - 1:
        raise ValueError("cmdline too long (%d > %d bytes)" % (len(raw), capacity - 1))
    first = raw[:CMDLINE_LEN - 1]
    rest = raw[len(first):]
    # cmdline field
    data[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = first + b"\0" * (CMDLINE_LEN - len(first))
    # extra_cmdline field (the 32-byte id between the two is preserved)
    data[EXTRA_CMDLINE_OFF:EXTRA_CMDLINE_OFF + EXTRA_CMDLINE_LEN] = \
        rest + b"\0" * (EXTRA_CMDLINE_LEN - len(rest))
    return data


def set_key(cmdline, key, value):
    prefix = key + "="
    words = cmdline.split()
    out = []
    replaced = False
    for w in words:
        if w.startswith(prefix):
            out.append(prefix + value)
            replaced = True
        else:
            out.append(w)
    if not replaced:
        out.append(prefix + value)
    return " ".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="patch an Android boot image cmdline")
    ap.add_argument("image")
    ap.add_argument("--set", dest="assign", metavar="KEY=VALUE", action="append", default=[])
    ap.add_argument("--out", default=None, help="write here instead of in place")
    ap.add_argument("--show", action="store_true", help="print the cmdline and exit")
    args = ap.parse_args(argv)

    with open(args.image, "rb") as fh:
        data = bytearray(fh.read())
    if data[:8] != MAGIC:
        return die("%s is not an Android boot image" % args.image)
    if args.show:
        print(read_cmdline(data))
        return 0
    if not args.assign:
        return die("nothing to do: pass --set KEY=VALUE, --show, or --out")

    try:
        combined = read_cmdline(data)
        for item in args.assign:
            if "=" not in item:
                return die("bad --set %r (want KEY=VALUE)" % item)
            key, value = item.split("=", 1)
            combined = set_key(combined, key, value)
        data = write_cmdline(data, combined)
    except ValueError as exc:
        return die(str(exc))

    out = args.out or args.image
    with open(out, "wb") as fh:
        fh.write(data)
    print("patched cmdline in %s: %s" % (out, combined))
    return 0


if __name__ == "__main__":
    sys.exit(main())
