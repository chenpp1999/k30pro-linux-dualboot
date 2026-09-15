#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# build.py - assemble the Magisk module zip.
#
# The zip carries the module files at its root (classic layout).  Entries are
# deflated, dated, and tagged with unix modes and a unix create_system so
# Magisk's installer treats them like a normal module zip; shell scripts are
# normalised to LF (Android's sh would choke on CR in the shebang line).
#
#   python3 packages/magisk-module/build.py [out.zip]
import os
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "lmi-dualboot-switch.zip")

SHELL_FILES = ("action.sh", "recovery-swap.sh")
COPY = (
    (os.path.join(HERE, "module.prop"), "module.prop"),
    (os.path.join(HERE, "action.sh"), "action.sh"),
    (os.path.join(HERE, "README.md"), "README.md"),
    (os.path.join(REPO, "tools", "m1", "recovery-swap.sh"), "recovery-swap.sh"),
)

now = time.localtime(time.time())[:6]

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for src, arc in COPY:
        if not os.path.isfile(src):
            sys.exit(f"missing: {src}")
        with open(src, "rb") as fh:
            data = fh.read()
        if arc in SHELL_FILES:
            data = data.replace(b"\r\n", b"\n")
        info = zipfile.ZipInfo(arc, date_time=now)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3                      # unix
        info.external_attr = (0o100755 if arc.endswith(".sh") else 0o100644) << 16
        zf.writestr(info, data)
        print(f"  + {arc} ({len(data)} bytes)")

print(f"built: {OUT} ({os.path.getsize(OUT)} bytes)")

with zipfile.ZipFile(OUT) as zf:
    for i in zf.infolist():
        print(f"    {i.filename} size={i.file_size} comp={i.compress_size} "
              f"mode={oct(i.external_attr >> 16)}")
