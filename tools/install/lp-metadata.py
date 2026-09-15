#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Parse Android dynamic-partition (liblp) metadata and find free space.

The M5 installer needs to place the Linux rootfs image into the *unallocated*
space of the Android `super` partition (docs/installer-design.md).  That space
is not described by GPT, only by the LP metadata that `super` carries at its
start, so this tool reads that metadata and computes the gaps between the
LP bookkeeping area and the extents of the allocated logical partitions.

Layout on `lmi` (observed, `super` = /dev/sda32, 512-byte sectors):

    offset 0        : reserved (4096 bytes)
    offset 4096     : primary geometry   (LP_METADATA_GEOMETRY_SIZE)
    offset 8192     : backup geometry
    offset 12288    : primary metadata slot 0..N-1 (metadata_max_size each)
    ...             : backup  metadata slot 0..N-1

The geometry is located by scanning for LP_METADATA_GEOMETRY_MAGIC instead of
hard-coding 4096, so a device with a different reservation still works.

Read-only: the tool never writes anywhere.  Works on a copy of `super`
(`dd if=/dev/block/by-name/super of=super.img`) or directly on the device.

usage:
  lp-metadata.py info   <source>
  lp-metadata.py json   <source> [--size SIZE]
  lp-metadata.py free   <source> [--min-size SIZE] [--align SIZE]
  lp-metadata.py select <source> --size SIZE [--align SIZE]

SIZE accepts plain bytes or KiB/MiB/GiB suffixes.  Exit codes: 0 ok, 1 error,
2 no free region large enough (for `select`).
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys

LP_METADATA_GEOMETRY_MAGIC = 0x616C4467
LP_METADATA_GEOMETRY_SIZE = 4096
LP_METADATA_HEADER_MAGIC = 0x414C5030
LP_PARTITION_RESERVED_BYTES = 4096

# LpMetadataExtent.target_type
TARGET_TYPE_LINEAR = 0
TARGET_TYPE_ZERO = 1

GEOM_STRUCT = struct.Struct("<II32sIII")
HEADER_STRUCT = struct.Struct("<IHHI32sI32s")
TABLE_DESC_STRUCT = struct.Struct("<III")
PARTITION_STRUCT = struct.Struct("<36sIIII")
EXTENT_STRUCT = struct.Struct("<QIQI")
GROUP_STRUCT = struct.Struct("<36sIQ")
BLOCK_DEVICE_STRUCT = struct.Struct("<QIIQ36sI")

SIZE_RE = re.compile(r"^(\d+)\s*([KMGTP]i?B?|B)?$", re.IGNORECASE)


def die(msg):
    print("lp-metadata: %s" % msg, file=sys.stderr)
    return 1


def parse_size(text):
    m = SIZE_RE.match(text.strip())
    if not m:
        raise ValueError("bad size: %r" % text)
    value = int(m.group(1))
    unit = (m.group(2) or "").upper()
    factors = {"": 1, "B": 1,
               "K": 1024, "KB": 1024, "KIB": 1024,
               "M": 1024 ** 2, "MB": 1024 ** 2, "MIB": 1024 ** 2,
               "G": 1024 ** 3, "GB": 1024 ** 3, "GIB": 1024 ** 3,
               "T": 1024 ** 4, "TB": 1024 ** 4, "TIB": 1024 ** 4,
               "P": 1024 ** 5, "PB": 1024 ** 5, "PIB": 1024 ** 5}
    if unit not in factors:
        raise ValueError("bad size unit: %r" % text)
    return value * factors[unit]


def cstr(raw):
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


class Source:
    """Random-access read of a super image / block device (no full load)."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        try:
            self.size = os.fstat(self.f.fileno()).st_size
        except OSError:
            self.size = 0
        if self.size == 0:  # block device: st_size is 0 on Linux
            self.size = self._block_device_size()

    def _block_device_size(self):
        try:
            with open("/sys/class/block/%s/size" % os.path.basename(self.path)) as fh:
                return int(fh.read().strip()) * 512
        except (OSError, ValueError):
            return 0

    def read(self, offset, length):
        self.f.seek(offset)
        return self.f.read(length)

    def close(self):
        self.f.close()


def find_geometry(src, warnings):
    probe = min(1 << 20, src.size) if src.size else (1 << 20)
    data = src.read(0, probe)
    for off in range(0, max(0, len(data) - LP_METADATA_GEOMETRY_SIZE + 1), 512):
        if struct.unpack_from("<I", data, off)[0] != LP_METADATA_GEOMETRY_MAGIC:
            continue
        magic, struct_size, checksum, max_size, slots, block = GEOM_STRUCT.unpack_from(data, off)
        if not (LP_METADATA_GEOMETRY_STRUCT_MIN <= struct_size <= LP_METADATA_GEOMETRY_SIZE):
            continue
        if not (0 < max_size <= (64 << 20)) or not (1 <= slots <= 4):
            continue
        if block not in (512, 4096):
            continue
        # AOSP checksum: SHA-256 of the whole geometry struct with the checksum
        # field zeroed.
        zeroed = bytearray(data[off:off + struct_size])
        zeroed[8:40] = b"\0" * 32
        if hashlib.sha256(bytes(zeroed)).digest() != checksum:
            warnings.append("geometry @%d: checksum mismatch" % off)
        return off, struct_size, max_size, slots, block
    return None


LP_METADATA_GEOMETRY_STRUCT_MIN = 52


def parse(path):
    warnings = []
    src = Source(path)
    try:
        found = find_geometry(src, warnings)
        if not found:
            raise ValueError("no LP metadata geometry found in %s (not a super image?)" % path)
        geom_off, struct_size, max_size, slots, block = found

        # Metadata region: reserved -> primary geom -> backup geom -> slots...
        meta_start = geom_off + 2 * LP_METADATA_GEOMETRY_SIZE
        header_off = meta_start
        header_bytes = src.read(header_off, 4096)
        if len(header_bytes) < 128:
            raise ValueError("short read at metadata header")
        (magic, major, minor, header_size, header_checksum,
         tables_size, tables_checksum) = HEADER_STRUCT.unpack_from(header_bytes, 0)
        if magic != LP_METADATA_HEADER_MAGIC:
            raise ValueError("metadata header magic mismatch at offset %d" % header_off)

        # Table descriptors follow the 80-byte fixed header.
        descs = {}
        for idx, name in enumerate(("partitions", "extents", "groups", "block_devices")):
            off, num, esz = TABLE_DESC_STRUCT.unpack_from(header_bytes, 80 + idx * 12)
            descs[name] = {"offset": off, "num_entries": num, "entry_size": esz}

        tables = src.read(header_off + 128, tables_size)
        if len(tables) < tables_size:
            raise ValueError("short read of metadata tables")

        # Checksum verification (AOSP scheme): header checksum covers the header
        # with the header_checksum field zeroed; tables checksum covers tables.
        hdr = bytearray(header_bytes[:header_size])
        if len(hdr) >= 44:
            hdr[12:44] = b"\0" * 32
            if hashlib.sha256(bytes(hdr)).digest() != header_checksum:
                warnings.append("metadata header checksum mismatch")
        if hashlib.sha256(tables).digest() != tables_checksum:
            warnings.append("metadata tables checksum mismatch")

        def entries(name, struct_fmt, count=None):
            d = descs[name]
            n = d["num_entries"] if count is None else count
            out = []
            for i in range(n):
                if d["entry_size"] < struct_fmt.size:
                    break
                out.append(struct_fmt.unpack_from(tables, d["offset"] + i * d["entry_size"]))
            return out

        partitions = []
        for (name, attributes, first_extent, num_extents, group_index) in \
                entries("partitions", PARTITION_STRUCT):
            pname = cstr(name)
            plist = []
            for j in range(num_extents):
                idx = first_extent + j
                ex = entries("extents", EXTENT_STRUCT)
                if idx >= len(ex):
                    warnings.append("partition %s: extent index %d out of range" % (pname, idx))
                    break
                num_sectors, target_type, target_data, target_source = ex[idx]
                plist.append({"num_sectors": num_sectors,
                              "target_type": "linear" if target_type == 0 else
                                             ("zero" if target_type == 1 else str(target_type)),
                              "target_data": target_data,
                              "target_source": target_source})
            partitions.append({"name": pname, "attributes": attributes,
                               "group_index": group_index, "extents": plist})

        groups = []
        for (name, flags, maximum_size) in entries("groups", GROUP_STRUCT):
            groups.append({"name": cstr(name), "flags": flags, "maximum_size": maximum_size})

        block_devices = []
        for (first_logical, alignment, alignment_offset, size, name, flags) in \
                entries("block_devices", BLOCK_DEVICE_STRUCT):
            block_devices.append({"name": cstr(name), "first_logical_sector": first_logical,
                                  "alignment": alignment, "alignment_offset": alignment_offset,
                                  "size": size, "flags": flags})

        # Reserved prefix: geometry area (primary + backup) + all primary
        # metadata slots + all backup metadata slots (they follow the primary).
        reserved_end = meta_start + 2 * slots * max_size

        # LpMetadataBlockDevice.size is the device size in *bytes* (verified
        # against lmi: 9,126,805,504 == the real size of /dev/sda32).
        total_bytes = src.size
        if block_devices:
            total_bytes = max(total_bytes, block_devices[0]["size"])
        total_sectors = total_bytes // 512

        used = []
        if reserved_end:
            used.append((0, reserved_end // 512))
        for p in partitions:
            for e in p["extents"]:
                if e["target_type"] != "linear":
                    continue
                start = e["target_data"]
                used.append((start, start + e["num_sectors"]))
        used = _merge(used)

        free = []
        cursor = 0
        for start, end in used:
            if start > cursor:
                free.append((cursor, start))
            cursor = max(cursor, end)
        if total_sectors > cursor:
            free.append((cursor, total_sectors))
        free = [{"offset_sectors": s, "size_sectors": e - s,
                 "offset_bytes": s * 512, "size_bytes": (e - s) * 512}
                for s, e in free if e > s]

        return {
            "source": path,
            "geometry": {"offset": geom_off, "struct_size": struct_size,
                         "metadata_max_size": max_size, "metadata_slot_count": slots,
                         "logical_block_size": block,
                         "metadata_region_bytes": reserved_end},
            "header": {"major": major, "minor": minor, "header_size": header_size,
                       "tables_size": tables_size},
            "partitions": partitions,
            "groups": groups,
            "block_devices": block_devices,
            "used_sectors": [[s, e] for s, e in used],
            "free": free,
            "total_sectors": total_sectors,
            "warnings": warnings,
        }
    finally:
        src.close()


def _merge(ranges):
    out = []
    for start, end in sorted(ranges):
        if end <= start:
            continue
        if out and start <= out[-1][1]:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return [tuple(x) for x in out]


def human_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def cmd_info(args):
    md = parse(args.source)
    g = md["geometry"]
    print("source              : %s" % md["source"])
    print("geometry            : @%d struct=%d max=%d slots=%d block=%d" %
          (g["offset"], g["struct_size"], g["metadata_max_size"],
           g["metadata_slot_count"], g["logical_block_size"]))
    print("metadata region     : %d bytes (%s)" % (g["metadata_region_bytes"],
                                                   human_bytes(g["metadata_region_bytes"])))
    print("header              : v%d.%d header_size=%d tables=%d bytes" %
          (md["header"]["major"], md["header"]["minor"],
           md["header"]["header_size"], md["header"]["tables_size"]))
    print("super size          : %s" % human_bytes(md["total_sectors"] * 512))
    print("partitions (%d):" % len(md["partitions"]))
    for p in md["partitions"]:
        secs = sum(e["num_sectors"] for e in p["extents"] if e["target_type"] == "linear")
        print("  %-14s %10s  %d extent(s)" % (p["name"], human_bytes(secs * 512), len(p["extents"])))
    print("groups (%d): %s" % (len(md["groups"]), ", ".join(x["name"] or "(unnamed)" for x in md["groups"])))
    print("free regions (%d):" % len(md["free"]))
    for r in sorted(md["free"], key=lambda x: -x["size_bytes"]):
        print("  offset %10d sectors (%12d B, %10s) size %10d sectors (%s)" %
              (r["offset_sectors"], r["offset_bytes"], human_bytes(r["offset_bytes"]),
               r["size_sectors"], human_bytes(r["size_bytes"])))
    for w in md["warnings"]:
        print("WARNING: %s" % w)
    return 0


def cmd_json(args):
    md = parse(args.source)
    if args.size:
        md["total_sectors"] = parse_size(args.size) // 512
    print(json.dumps(md, indent=2, sort_keys=True))
    return 0


def _pick_free(md, want_bytes, align, warnings):
    best = None
    for r in md["free"]:
        start = r["offset_bytes"]
        size = r["size_bytes"]
        aligned = start if align <= 1 else (start + align - 1) // align * align
        avail = size - (aligned - start)
        if avail >= want_bytes:
            candidate = {"offset_bytes": aligned, "size_bytes": avail}
            if best is None or candidate["size_bytes"] > best["size_bytes"]:
                best = candidate
    if best is None:
        warnings.append("no free region >= %s" % human_bytes(want_bytes))
    return best


def cmd_free(args):
    md = parse(args.source)
    minimum = parse_size(args.min_size) if args.min_size else 0
    align = parse_size(args.align) if args.align else 0
    rows = sorted(md["free"], key=lambda x: -x["size_bytes"])
    for r in rows:
        start = r["offset_bytes"]
        aligned = start if align <= 1 else (start + align - 1) // align * align
        avail = r["size_bytes"] - (aligned - start)
        if avail < minimum:
            continue
        print("offset=%d (%s) usable=%s aligned=%d" %
              (aligned, human_bytes(aligned), human_bytes(avail), align))
    for w in md["warnings"]:
        print("WARNING: %s" % w, file=sys.stderr)
    return 0


def cmd_select(args):
    want = parse_size(args.size)
    align = parse_size(args.align) if args.align else 0
    md = parse(args.source)
    best = _pick_free(md, want, align, md["warnings"])
    for w in md["warnings"]:
        print("WARNING: %s" % w, file=sys.stderr)
    if not best:
        return 2
    print("offset=%d size=%d offset_sectors=%d size_sectors=%d" %
          (best["offset_bytes"], best["size_bytes"],
           best["offset_bytes"] // 512, best["size_bytes"] // 512))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Parse LP (liblp) super metadata")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("info", cmd_info), ("json", cmd_json), ("free", cmd_free), ("select", cmd_select)):
        p = sub.add_parser(name)
        p.add_argument("source")
        if name in ("json", "select"):
            p.add_argument("--size", help="required for select; overrides super size for json")
        else:
            p.add_argument("--min-size", default=None)
        p.add_argument("--align", default=None)
        p.set_defaults(func=fn)
    args = ap.parse_args(argv)
    if args.cmd == "select" and not args.size:
        return die("select requires --size")
    try:
        return args.func(args)
    except (OSError, ValueError, struct.error) as exc:
        return die(str(exc))


if __name__ == "__main__":
    sys.exit(main())
