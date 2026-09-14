#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate the M1b rootfs overlay tarball (delta between two rootfs trees).

The overlay is applied by tools/m1/m1b-init.sh on the first boot after
switch_root, so the persistent rootfs (living inside the Android `super`
partition, which Android itself cannot write: issue #13) can be updated
without TWRP or a USB host.

Only additions and content changes are shipped (deletions are intentionally
not supported; the initramfs refuses to unlink data on the persistent rootfs).
"""

import argparse
import hashlib
import io
import os
import sys
import tarfile

EXCLUDE_PREFIXES = (
    "lost+found",
    "var/log/",
    "root/m1b-boot-count",
    "root/m1b-boots.log",
)

MANIFEST_PATH = "etc/m1b-overlay.manifest"
VERSION_PATH = "etc/m1b-overlay-version"


def excluded(rel):
    return any(rel == p.rstrip("/") or rel.startswith(p) for p in EXCLUDE_PREFIXES)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entry_key(root, rel):
    """(kind, detail, size) — detail is sha256 for files, target for symlinks."""
    path = os.path.join(root, rel)
    st = os.lstat(path)
    if os.path.islink(path):
        return ("symlink", os.readlink(path), 0)
    if os.path.isfile(path):
        return ("file", sha256_file(path), st.st_size)
    if os.path.isdir(path):
        return ("dir", "", 0)
    return ("special", "", 0)


def collect(root):
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if excluded(rel):
                continue
            entries[rel] = entry_key(root, rel)
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--old", required=True, help="baseline rootfs tree (as deployed)")
    ap.add_argument("--new", required=True, help="new rootfs tree")
    ap.add_argument("--out", required=True, help="output .tar.gz")
    ap.add_argument("--version", required=True, help="overlay version string")
    ap.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024,
                    help="fail if the overlay exceeds this size (default 64 MiB)")
    args = ap.parse_args()

    old = collect(args.old)
    new = collect(args.new)
    changed = sorted(rel for rel, key in new.items() if old.get(rel) != key)
    files = [rel for rel in changed if new[rel][0] != "dir"]
    # ship every directory so extraction can create parent dirs reliably
    dirs = [rel for rel in sorted(new) if new[rel][0] == "dir"]

    manifest = ["# M1b rootfs overlay manifest", "# version: %s" % args.version,
                "# changed files: %d (dirs: %d)" % (len(files), len(dirs)), ""]
    for rel in files:
        kind, detail, size = new[rel]
        manifest.append("%-7s %8d %s %s" % (kind, size, detail, rel))
    manifest.append("")

    if os.path.exists(os.path.join(args.new, MANIFEST_PATH)):
        print("WARN: %s exists in the new tree; it will be overwritten" % MANIFEST_PATH,
              file=sys.stderr)

    tmp = args.out + ".tmp"
    with tarfile.open(tmp, "w:gz") as tf:
        for rel in sorted(set(dirs) | set(files)):
            path = os.path.join(args.new, rel)
            ti = tf.gettarinfo(path, arcname=rel)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            if ti.isdir() or ti.issym() or ti.islnk():
                tf.addfile(ti)
            elif ti.isfile():
                with open(path, "rb") as fh:
                    tf.addfile(ti, fh)
            else:
                print("skip special file: %s" % rel, file=sys.stderr)

        for rel, text in ((MANIFEST_PATH, "\n".join(manifest)),
                          (VERSION_PATH, args.version + "\n")):
            data = text.encode()
            ti = tarfile.TarInfo(rel)
            ti.size = len(data)
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(data))

    size = os.path.getsize(tmp)
    if size > args.max_bytes:
        os.unlink(tmp)
        sys.exit("overlay is %d bytes > limit %d; refusing" % (size, args.max_bytes))
    os.replace(tmp, args.out)
    print("overlay: %s (%d bytes, %d files, %d dirs)" % (args.out, size, len(files), len(dirs)))


if __name__ == "__main__":
    main()
