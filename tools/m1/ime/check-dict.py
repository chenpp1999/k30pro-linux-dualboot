#!/usr/bin/env python3
"""spot-check the generated pinyin.dict"""
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "pinyin.dict"
data = open(path, "rb").read()
assert data[:4] == b"LMI1", "bad magic"
nsyl, total_chars, nw2, nw3, nw4 = struct.unpack_from("<5I", data, 4)
syl_len, char_len, _res = struct.unpack_from("<3I", data, 24)
print(f"nsyl={nsyl} chars={total_chars} w2={nw2} w3={nw3} w4={nw4} size={len(data)}")

off = 36
syls = []
for _ in range(nsyl):
    (n,) = struct.unpack_from("<B", data, off)
    off += 1
    syls.append(data[off:off + n].decode())
    off += n
assert off == 36 + syl_len, (off, 36 + syl_len)
sid = {s: i for i, s in enumerate(syls)}
print("syllable sample:", " ".join(syls[:12]), "... total", len(syls))

off_char = 36 + syl_len
char_lists = []
off = off_char
for _ in range(nsyl):
    (cnt,) = struct.unpack_from("<H", data, off)
    off += 2
    cps = struct.unpack_from("<%dH" % cnt, data, off) if cnt else ()
    off += 2 * cnt
    char_lists.append([chr(c) for c in cps])
assert off == off_char + char_len, (off, off_char + char_len)

off_w2 = off_char + char_len
off_w3 = off_w2 + nw2 * 8
off_w4 = off_w3 + nw3 * 12
assert off_w4 + nw4 * 16 == len(data), (off_w4 + nw4 * 16, len(data))

WORD = {2: (off_w2, nw2, 8), 3: (off_w3, nw3, 12), 4: (off_w4, nw4, 16)}


def find_words(sids, n):
    base, count, rec = WORD[n]
    key = tuple(sids)
    lo, hi = 0, count
    while lo < hi:
        mid = (lo + hi) // 2
        cur = struct.unpack_from("<%dH" % n, data, base + mid * rec)
        if cur < key:
            lo = mid + 1
        else:
            hi = mid
    res = []
    for idx in range(lo, count):
        cur = struct.unpack_from("<%dH" % n, data, base + idx * rec)
        if cur != key:
            break
        cps = struct.unpack_from("<%dH" % n, data, base + idx * rec + 2 * n)
        res.append("".join(chr(c) for c in cps))
    return res


for s in ("ni", "hao", "zhong", "guo", "xing", "hang", "yi", "shi", "shui", "lv", "nv"):
    lst = char_lists[sid[s]] if s in sid else []
    print(f"{s:>8}: {''.join(lst[:12])}")

for seq in ("nihao", "zhongguo", "beijing", "beijingdaxue", "xingzou",
            "yinhang", "nihaoshijie", "xuexi", "gongzuo"):
    pos, sids = 0, []
    while pos < len(seq):
        for ln in range(6, 0, -1):
            if seq[pos:pos + ln] in sid:
                sids.append(sid[seq[pos:pos + ln]])
                pos += ln
                break
        else:
            break
    n = len(sids)
    if n in (2, 3, 4):
        print(f"{seq} ({'+'.join(seq)}) -> {'/'.join(find_words(sids, n)[:6])}")
    else:
        print(f"{seq} -> split into {n} syllables")

for n in (2, 3, 4):
    base, count, rec = WORD[n]
    for idx in (0, 100, 1000):
        if idx < count:
            cps = struct.unpack_from("<%dH" % n, data, base + idx * rec + 2 * n)
            sids = struct.unpack_from("<%dH" % n, data, base + idx * rec)
            print(f"w{n}[{idx}] = {''.join(chr(c) for c in cps)} "
                  f"({'+'.join(syls[s] for s in sids)})")
