#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# lmi-inject - inject synthetic input events via /dev/uinput (dev/test tool).
#
# Used to verify lmi-keys and weston DPMS wake without touching the device:
#   lmi-inject key KEY_VOLUMEUP      # press+release a key
#   lmi-inject touch                 # a short touch tap (wakes weston)
#   lmi-inject pointer X Y           # absolute pointer click (focuses windows;
#                                    # weston grants keyboard focus on clicks)
#   lmi-inject taps X Y X Y ...      # several touch taps on one device
import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
UI_SET_ABSBIT = 0x40045567
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN, EV_KEY, EV_ABS, EV_REL = 0x00, 0x01, 0x03, 0x02
SYN_REPORT = 0x00
BTN_TOUCH = 0x14A
BTN_LEFT = 0x110
REL_X, REL_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0x2F, 0x39
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36

KEY = {
    "KEY_VOLUMEUP": 115,
    "KEY_VOLUMEDOWN": 114,
    "KEY_POWER": 116,
    "KEY_ENTER": 28,
    "KEY_BACKSPACE": 14,
}

UI_DEV_SETUP = 0x405c5503
UI_ABS_SETUP = 0x401c5504


class UInput:
    def __init__(self, name, keys=(), touch=False, rel=False):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
        if keys:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
            for k in keys:
                fcntl.ioctl(self.fd, UI_SET_KEYBIT, k)
        if rel:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_REL)
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, BTN_LEFT)
            fcntl.ioctl(self.fd, UI_SET_RELBIT, REL_X)
            fcntl.ioctl(self.fd, UI_SET_RELBIT, REL_Y)
        if touch:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_ABS)
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, BTN_TOUCH)
            for code in (ABS_MT_SLOT, ABS_MT_TRACKING_ID,
                         ABS_MT_POSITION_X, ABS_MT_POSITION_Y):
                fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)

        # struct uinput_setup { input_id id; char name[80]; __u32 ff_effects_max; }
        # input_id { __u16 bustype, vendor, product, version; }
        setup = struct.pack("4H80sI", 0x03, 0x1, 0x1, 0x1, name.encode()[:79], 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        if touch:
            for code, (lo, hi) in ((ABS_MT_POSITION_X, (0, 1079)),
                                   (ABS_MT_POSITION_Y, (0, 2399))):
                # struct uinput_abs_setup { __u16 code; __u16 pad; input_absinfo absinfo; }
                # input_absinfo { __s32 value, minimum, maximum, fuzz, flat, resolution }
                aw = struct.pack("2H6i", code, 0, 0, lo, hi, 0, 0, 0)
                fcntl.ioctl(self.fd, UI_ABS_SETUP, aw)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        self.events = []

    def emit(self, etype, code, value):
        self.events.append((etype, code, value))

    def sync(self):
        self.events.append((EV_SYN, SYN_REPORT, 0))
        now = time.time()
        sec, usec = int(now), int((now % 1) * 1_000_000)
        for etype, code, value in self.events:
            buf = struct.pack("qqHHi", sec, usec, etype, code, value)
            os.write(self.fd, buf)
        self.events = []

    def close(self):
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("key", "touch", "pointer", "taps"):
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == "taps":
        coords = [(int(sys.argv[i]), int(sys.argv[i + 1]))
                  for i in range(2, len(sys.argv) - 1, 2)]
        dev = UInput("lmi-inject-taps", touch=True)
        time.sleep(2.5)
        for x, y in coords:
            dev.emit(EV_ABS, ABS_MT_SLOT, 0)
            dev.emit(EV_ABS, ABS_MT_TRACKING_ID, 42)
            dev.emit(EV_ABS, ABS_MT_POSITION_X, x)
            dev.emit(EV_ABS, ABS_MT_POSITION_Y, y)
            dev.emit(EV_KEY, BTN_TOUCH, 1)
            dev.sync()
            time.sleep(0.08)
            dev.emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
            dev.emit(EV_KEY, BTN_TOUCH, 0)
            dev.sync()
            time.sleep(0.25)
        dev.close()
        print(f"injected {len(coords)} taps")
    elif mode == "pointer":
        x, y = int(sys.argv[2]), int(sys.argv[3])
        dev = UInput("lmi-inject-pointer", rel=True)
        time.sleep(2.5)
        dev.emit(EV_REL, REL_X, -4000)
        dev.emit(EV_REL, REL_Y, -4000)
        dev.sync()
        time.sleep(0.2)
        dev.emit(EV_REL, REL_X, x)
        dev.emit(EV_REL, REL_Y, y)
        dev.sync()
        time.sleep(0.2)
        dev.emit(EV_KEY, BTN_LEFT, 1)
        dev.sync()
        time.sleep(0.1)
        dev.emit(EV_KEY, BTN_LEFT, 0)
        dev.sync()
        time.sleep(0.2)
        dev.close()
        print(f"injected pointer click at {x},{y}")
    elif mode == "key":
        name = sys.argv[2]
        code = KEY.get(name, int(name) if name.isdigit() else None)
        if code is None:
            print(f"unknown key: {name}", file=sys.stderr)
            return 2
        dev = UInput("lmi-inject-key", keys=[code])
        time.sleep(2.5)
        dev.emit(EV_KEY, code, 1)
        dev.sync()
        time.sleep(0.1)
        dev.emit(EV_KEY, code, 0)
        dev.sync()
        time.sleep(0.2)
        dev.close()
        print(f"injected {name} ({code})")
    else:
        dev = UInput("lmi-inject-touch", touch=True)
        time.sleep(2.5)
        x, y = 270, 600
        dev.emit(EV_ABS, ABS_MT_SLOT, 0)
        dev.emit(EV_ABS, ABS_MT_TRACKING_ID, 42)
        dev.emit(EV_ABS, ABS_MT_POSITION_X, x)
        dev.emit(EV_ABS, ABS_MT_POSITION_Y, y)
        dev.emit(EV_KEY, BTN_TOUCH, 1)
        dev.sync()
        time.sleep(0.15)
        dev.emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
        dev.emit(EV_KEY, BTN_TOUCH, 0)
        dev.sync()
        time.sleep(0.2)
        dev.close()
        print(f"injected touch tap at {x},{y}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
