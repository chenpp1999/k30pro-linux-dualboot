#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# kbd-tap.py - tap keys on the lmi OSK via uinput, using the live scene-graph
# geometry of the input panel surface (dev/test tool, run as root on device).
#
# usage: kbd-tap.py <key> [<key> ...]
#   letters: a-z            keys on the pinyin page
#   back, enter, space, dot, comma, dun, lang, sym, num, cand0..cand7,
#   prev, next
import importlib.util
import os
import re
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("lmi_inject", "/usr/lib/lmi/lmi-inject.py")
try:
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
except FileNotFoundError:
    spec = importlib.util.spec_from_file_location("lmi_inject", "/root/lmi-inject.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)

# logical coordinates inside the 540-wide keyboard, per key
ROWS = {
    "q": (0, 0.5), "w": (0, 1.5), "e": (0, 2.5), "r": (0, 3.5), "t": (0, 4.5),
    "y": (0, 5.5), "u": (0, 6.5), "i": (0, 7.5), "o": (0, 8.5), "p": (0, 9.5),
    "a": (1, 1.5), "s": (1, 2.5), "d": (1, 3.5), "f": (1, 4.5), "g": (1, 5.5),
    "h": (1, 6.5), "j": (1, 7.5), "k": (1, 8.5), "l": (1, 9.5),
    "z": (2, 1.5), "x": (2, 2.5), "c": (2, 3.5), "v": (2, 4.5), "b": (2, 5.5),
    "n": (2, 6.5), "m": (2, 7.5),
    "lang": (1, 0.5), "sym": (1, 10.5),
    "num": (2, 0.5), "back": (2, 8.5), "enter": (2, 10.5),
    "comma": (3, 0.5), "space": (3, 4.5), "dot": (3, 8.5), "dun": (3, 10.5),
    # shortcut bar (row 4 = below the key grid, one key per column)
    "esc": (4, 0.5), "tab": (4, 1.5), "ctrl": (4, 2.5), "alt": (4, 3.5),
    "left": (4, 4.5), "up": (4, 5.5), "down": (4, 6.5), "right": (4, 7.5),
    "home": (4, 8.5), "end": (4, 9.5), "pgup": (4, 10.5), "pgdn": (4, 11.5),
}

# the stock latin layout has a different grid (tab/Enter on the a-row,
# symbols/space/arrows/language on the last row, ABC switch keys)
ROWS_LATIN = {
    "q": (0, 0.5), "w": (0, 1.5), "e": (0, 2.5), "r": (0, 3.5), "t": (0, 4.5),
    "y": (0, 5.5), "u": (0, 6.5), "i": (0, 7.5), "o": (0, 8.5), "p": (0, 9.5),
    "back": (0, 10.5),
    "tab": (1, 0.5),
    "a": (1, 1.5), "s": (1, 2.5), "d": (1, 3.5), "f": (1, 4.5), "g": (1, 5.5),
    "h": (1, 6.5), "j": (1, 7.5), "k": (1, 8.5), "l": (1, 9.5),
    "enter": (1, 10.5),
    "z": (2, 2.5), "x": (2, 3.5), "c": (2, 4.5), "v": (2, 5.5), "b": (2, 6.5),
    "n": (2, 7.5), "m": (2, 8.5), "comma": (2, 9.5), "dot": (2, 10.5),
    "sym": (3, 0.5), "space": (3, 3.5),
    "al": (3, 6.5), "au": (3, 7.5), "ar": (3, 8.5), "ad": (3, 9.5),
    "lang": (3, 10.5),
    # the shortcut bar is identical in every layout
    "esc": (4, 0.5), "tab": (4, 1.5), "ctrl": (4, 2.5), "alt": (4, 3.5),
    "left": (4, 4.5), "up": (4, 5.5), "down": (4, 6.5), "right": (4, 7.5),
    "home": (4, 8.5), "end": (4, 9.5), "pgup": (4, 10.5), "pgdn": (4, 11.5),
}
STRIP_Y = 0.5
OUTPUT_SCALE = 2.0  # lmi panel: 540x1200 logical at scale 2


def scene_geometry():
    env = dict(os.environ, XDG_RUNTIME_DIR="/run/lmi-weston",
               WAYLAND_DISPLAY="wayland-0")
    out = subprocess.run(["weston-debug", "scene-graph"], capture_output=True,
                         text=True, env=env).stdout
    for block in out.split("View "):
        if "input panel" not in block:
            continue
        mm = re.search(r"position: \((-?\d+), (-?\d+)\) -> \((-?\d+), (-?\d+)\)", block)
        if mm:
            x1, y1, x2, y2 = map(int, mm.groups())
            return x1, y1, x2 - x1, y2 - y1
    return None


def main():
    keys = sys.argv[1:]
    rows = ROWS
    if keys and keys[0] in ("--latin", "--pinyin"):
        if keys[0] == "--latin":
            rows = ROWS_LATIN
        keys = keys[1:]
    if not keys:
        print(__doc__)
        return 2
    geom = scene_geometry()
    if not geom:
        print("kbd-tap: input panel not mapped (focus a text field first)")
        return 1
    x1, y1, w_logical, h_logical = geom
    if w_logical != 540:
        print(f"kbd-tap: unexpected panel width {w_logical}")
    # pinyin page = 300 (50 strip + 5 rows), latin page = 250 (5 rows)
    strip = 50 if h_logical >= 290 else 0
    taps = []
    for key in keys:
        if key.startswith("cand"):
            idx = int(key[4:])
            lx, ly = 96 + 48 * idx + 24, STRIP_Y
        elif key == "prev":
            lx, ly = 495, STRIP_Y
        elif key == "next":
            lx, ly = 525, STRIP_Y
        elif key in rows:
            row, col = rows[key]
            lx, ly = col * 45, strip + (row + 0.5) * 50
        else:
            print(f"kbd-tap: unknown key {key}")
            return 2
        taps.append((int((x1 + lx) * OUTPUT_SCALE),
                     int((y1 + ly) * OUTPUT_SCALE)))
    dev = m.UInput("lmi-kbd-tap", touch=True)
    time.sleep(2.5)
    for px, py in taps:
        dev.emit(m.EV_ABS, m.ABS_MT_SLOT, 0)
        dev.emit(m.EV_ABS, m.ABS_MT_TRACKING_ID, 42)
        dev.emit(m.EV_ABS, m.ABS_MT_POSITION_X, px)
        dev.emit(m.EV_ABS, m.ABS_MT_POSITION_Y, py)
        dev.emit(m.EV_KEY, m.BTN_TOUCH, 1)
        dev.sync()
        time.sleep(0.08)
        dev.emit(m.EV_ABS, m.ABS_MT_TRACKING_ID, -1)
        dev.emit(m.EV_KEY, m.BTN_TOUCH, 0)
        dev.sync()
        time.sleep(0.25)
    dev.close()
    print(f"tapped {len(taps)} keys: {keys}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
