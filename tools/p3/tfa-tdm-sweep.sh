#!/bin/sh
# one long playback + one long recording; several TDM register edits are applied
# at fixed times; the analysis prints the 1 kHz energy per time window.
C="amixer -c 0"
if [ ! -f /root/audio/t90.wav ]; then
	python3 - <<'PY'
import math, struct, wave
w = wave.open('/root/audio/t90.wav','w'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
fr = [struct.pack('<h', int(0.5*32767*math.sin(2*math.pi*1000*i/48000))) for i in range(48000*90)]
w.writeframes(b''.join(fr)); w.close()
PY
fi
pkill -x aplay 2>/dev/null; pkill -x arecord 2>/dev/null; sleep 1
/usr/sbin/lmi-audio-route >/dev/null 2>&1
V=$(amixer -c 0 controls | sed -n "s/numid=\([0-9]*\),.*Playback 0 Volume.*/\1/p" | head -1)
setsid arecord -D plughw:0,0 -f S16_LE -r 48000 -c 2 -d 85 /root/audio/sweep.wav </dev/null >/dev/null 2>&1 &
sleep 1
setsid aplay -D plughw:0,0 /root/audio/t90.wav </dev/null >/dev/null 2>&1 &
sleep 2
$C cset numid="$V" 8192 >/dev/null 2>&1

# t=0 baseline; then apply edits at 12/26/40/54/68 s
python3 - <<'PY'
import fcntl, os, time
fd = os.open("/dev/i2c-1", os.O_RDWR)
fcntl.ioctl(fd, 0x0706, 0x34)
def rd(reg):
    os.write(fd, bytes([reg])); d = os.read(fd, 2); return (d[0] << 8) | d[1]
def wr(reg, v):
    os.write(fd, bytes([reg, (v >> 8) & 0xFF, v & 0xFF]))
def setbf(reg, off, ln, val, tag):
    v = rd(reg); nv = (v & ~(((1 << ln) - 1) << off)) | ((val & ((1 << ln) - 1)) << off)
    wr(reg, nv)
    print("t=%2ds %-22s reg0x%02x 0x%04x->0x%04x" % (int(time.time()) % 1000, tag, reg, v, nv))
t0 = time.time()
plan = [
    (12, 0x20, 6, 1, 1, "TDMCLINV=1"),
    (26, 0x20, 5, 1, 1, "TDMMODE=1"),
    (40, 0x20, 12, 4, 1, "TDMNBCK=1"),
    (54, 0x21, 4, 5, 15, "TDMSLLN=15"),
    (68, 0x21, 4, 5, 7, "TDMSLLN=7"),
]
for at, reg, off, ln, val, tag in plan:
    while time.time() - t0 < at:
        time.sleep(0.2)
    setbf(reg, off, ln, val, tag)
PY
wait
python3 - <<'PY'
import wave, struct, math
w = wave.open('/root/audio/sweep.wav'); fs = w.getframerate(); ch = w.getnchannels()
d = w.readframes(w.getnframes()); s = struct.unpack('<%dh' % (len(d)//2), d); x = s[0::ch]
def energy(a, b):
    seg = x[int(a*fs):int(b*fs)]
    if len(seg) < 1000: return 0.0
    k = 2.0*math.cos(2.0*math.pi*1000.0/fs); s1=s2=0.0
    for v in seg:
        s0 = v + k*s1 - s2; s2 = s1; s1 = s0
    return (s1*s1+s2*s2-k*s1*s2)/(len(seg)**2)
print("peak=%d" % max(abs(v) for v in x))
for tag, a, b in [("baseline", 2, 12), ("TDMCLINV=1", 16, 26), ("TDMMODE=1", 30, 40),
                  ("TDMNBCK=1", 44, 54), ("TDMSLLN=15", 58, 68), ("TDMSLLN=7", 72, 82)]:
    print("  %-12s 1kHz=%.1f" % (tag, energy(a, b)))
PY
