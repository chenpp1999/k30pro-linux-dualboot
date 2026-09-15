#!/usr/bin/env python3
"""dump full candidate lists for given syllables from pinyin.dict"""
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "pinyin.dict"
data = open(path, "rb").read()
assert data[:4] == b"LMI1"
nsyl, total_chars, nw2, nw3, nw4 = struct.unpack_from("<5I", data, 4)
syl_len, char_len, _ = struct.unpack_from("<3I", data, 24)
off = 36
syls = []
for _ in range(nsyl):
    (n,) = struct.unpack_from("<B", data, off)
    off += 1
    syls.append(data[off:off + n].decode())
    off += n
assert off == 36 + syl_len
sid = {s: i for i, s in enumerate(syls)}
off_char = 36 + syl_len
off = off_char
char_lists = []
for _ in range(nsyl):
    (cnt,) = struct.unpack_from("<H", data, off)
    off += 2
    cps = struct.unpack_from("<%dH" % cnt, data, off) if cnt else ()
    off += 2 * cnt
    char_lists.append([chr(c) for c in cps])
print("syllable ids 0..20:", " ".join(f"{i}:{s}" for i, s in enumerate(syls[:20])))
for s in sys.argv[2:]:
    if s not in sid:
        print(f"{s}: NOT IN TABLE")
        continue
    lst = char_lists[sid[s]]
    print(f"{s} (id {sid[s]}, {len(lst)} cands): {''.join(lst)}")
print("char section size:", char_len, "total chars:", total_chars)
print("sum of list sizes:", sum(len(l) for l in char_lists))
