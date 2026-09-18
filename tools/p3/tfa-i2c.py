import fcntl
import os
import sys

I2C_SLAVE = 0x0706  # I2C_SLAVE_FORCE: the TFA driver owns 0x34
ADDR = 0x34
bus = int(sys.argv[1]) if len(sys.argv) > 1 else 1

path = "/dev/i2c-%d" % bus
fd = os.open(path, os.O_RDWR)
fcntl.ioctl(fd, I2C_SLAVE, ADDR)


def rd(reg):
    os.write(fd, bytes([reg]))
    return os.read(fd, 2)


def wr(reg, val):
    os.write(fd, bytes([reg, (val >> 8) & 0xFF, val & 0xFF]))


print("bus %d (%s) addr 0x%02x" % (bus, path, ADDR))
for r in (0x00, 0x11, 0x13, 0x20, 0x21):
    d = rd(r)
    be = (d[0] << 8) | d[1]
    le = (d[1] << 8) | d[0]
    print("reg 0x%02x bytes=%s be=0x%04x le=0x%04x" % (r, d.hex(), be, le))

# round-trip test on a benign field: keep the value identical
d = rd(0x20)
wr(0x20, (d[0] << 8) | d[1])
d2 = rd(0x20)
print("write-back 0x20: %s -> %s" % (d.hex(), d2.hex()))
