#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# gen-dict.py - build the compact pinyin dictionary used by the patched
# weston-keyboard (lmi OSK). Run ./fetch-data.sh first (or in WSL).
#
# Inputs (tools/m1/ime/data/):
#   pinyin.txt              mozillazg/pinyin-data (MIT): char -> all readings (tone marks)
#   kMandarin_8105.txt      same (MIT): char -> most common reading
#   essay-zh-hans.txt       rime-essay-simp (LGPL-3.0): word -> frequency
#   luna_pinyin.dict.yaml   rime-luna-pinyin (LGPL-3.0): char/word -> pinyin (+ polyphone %)
#   cedict_ts.u8            CC-CEDICT (CC BY-SA 4.0): word -> pinyin (numbered tones)
#
# Output: pinyin.dict (little-endian binary, see tools/m1/ime/README.md)
import os
import re
import struct
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "pinyin.dict")

MAX_CHARS_PER_SYL = 60
MAX_CANDS_PER_TUPLE = 12
WORD_TOPS = {2: 40000, 3: 15000, 4: 6000}
MIN_WORD_FREQ = {2: 800, 3: 300, 4: 150}

ACCENT = {
    "ā": "a", "á": "a", "ǎ": "a", "à": "a",
    "ē": "e", "é": "e", "ě": "e", "è": "e", "ê": "e",
    "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
    "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
    "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
    "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
    "ń": "n", "ň": "n", "ǹ": "n", "ḿ": "m",
}


def norm_reading(s):
    """tone-marked or numbered pinyin -> plain ascii syllables, v for u-umlaut"""
    s = s.strip().lower()
    s = re.sub(r"[1-5]", "", s)
    s = s.replace("u:", "v").replace("ü", "v")
    out = []
    for ch in s:
        out.append(ACCENT.get(ch, ch))
    s = "".join(out)
    s = re.sub(r"[^a-z]", "", s)
    return s


def split_syllables(pinyin):
    """cedict/luna pinyin string -> list of ascii syllables"""
    parts = re.split(r"[\s']+", pinyin.strip())
    return [norm_reading(p) for p in parts if p.strip()]


def parse_pinyin_data(path):
    """U+4E00: yī, yì  # 一  -> {cp: [reading, ...]}"""
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line.startswith("U+"):
                continue
            cp_s, _, rest = line.partition(":")
            cp = int(cp_s[2:], 16)
            readings = [norm_reading(r) for r in rest.split(",")]
            readings = [r for r in readings if r]
            if readings:
                table[cp] = readings
    return table


def parse_essay(path):
    """word<TAB>freq"""
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            word, freq = line.split("\t", 1)
            try:
                table[word] = int(freq)
            except ValueError:
                continue
    return table


def parse_luna(path):
    """char/word -> list of (syllables, weight) ; weights are percentages"""
    char_r = defaultdict(list)
    word_r = {}
    with open(path, encoding="utf-8") as f:
        started = False
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("..."):
                started = True
                continue
            if not started or not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            word, py = parts[0], parts[1]
            weight = 1.0
            if len(parts) >= 3:
                m = re.match(r"([0-9.]+)%", parts[2])
                if m:
                    weight = float(m.group(1)) / 100.0
            sylls = split_syllables(py)
            if not sylls:
                continue
            if len(word) == 1:
                char_r[word].append((sylls[0], weight))
            elif len(word) <= 4:
                word_r[word] = sylls
    return char_r, word_r


def parse_cedict(path):
    """漢字 汉字 [han4 zi4] /def/ -> {simplified: [syllables]}"""
    table = {}
    line_re = re.compile(r"^\S+\s+(\S+)\s+\[([^\]]+)\]")
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = line_re.match(line)
            if not m:
                continue
            word, py = m.group(1), m.group(2)
            sylls = split_syllables(py)
            if sylls and word not in table:
                table[word] = sylls
    return table


def build():
    py_all = parse_pinyin_data(os.path.join(DATA, "pinyin.txt"))
    py_8105 = parse_pinyin_data(os.path.join(DATA, "kMandarin_8105.txt"))
    essay = parse_essay(os.path.join(DATA, "essay-zh-hans.txt"))
    luna_chars, luna_words = parse_luna(os.path.join(DATA, "luna_pinyin.dict.yaml"))
    cedict = parse_cedict(os.path.join(DATA, "cedict_ts.u8"))

    char_freq = {w: f for w, f in essay.items() if len(w) == 1}

    # char -> ordered [(syllable, score)] with polyphone weights
    char_readings = {}
    chars = set(py_all) | set(py_8105) | {ord(c) for c in luna_chars}
    for cp in chars:
        ch = chr(cp)
        weights = {}
        for syl, w in luna_chars.get(ch, []):
            weights[syl] = max(weights.get(syl, 0.0), w)
        primary = None
        if cp in py_8105 and py_8105[cp]:
            primary = py_8105[cp][0]
        elif ch in luna_chars and luna_chars[ch]:
            primary = luna_chars[ch][0][0]
        elif cp in py_all:
            primary = py_all[cp][0]
        readings = list(py_all.get(cp, []))
        for syl, _ in luna_chars.get(ch, []):
            if syl not in readings:
                readings.append(syl)
        if primary and primary not in readings:
            readings.insert(0, primary)
        base = float(char_freq.get(ch, 0))
        entries = []
        for idx, syl in enumerate(readings):
            if not syl:
                continue
            if syl in weights:
                score = base * max(weights[syl], 0.02) + (1.0 if idx == 0 else 0.0)
            else:
                score = base / (1 + idx) if idx else base
            if score <= 0:
                score = 1.0 / (1 + idx)
            entries.append((syl, score))
        if entries:
            char_readings[cp] = entries

    # syllable table: canonical set comes from single-character readings only
    # (word pinyin is validated against it below)
    syl_set = set()
    for entries in char_readings.values():
        syl_set.update(s for s, _ in entries)
    syl_list = sorted(syl_set)
    syl_id = {s: i for i, s in enumerate(syl_list)}
    sys.stderr.write(f"syllables: {len(syl_list)}\n")

    # char candidates per syllable (score desc, cap, deduped)
    per_syl = defaultdict(dict)
    for cp, entries in char_readings.items():
        if cp > 0xFFFF:
            continue
        for syl, score in entries:
            if cp not in per_syl[syl] or score > per_syl[syl][cp]:
                per_syl[syl][cp] = score
    char_section = {}
    for syl in syl_list:
        cands = sorted(per_syl.get(syl, {}).items(), key=lambda t: (-t[1], t[0]))
        char_section[syl] = [cp for cp, _ in cands[:MAX_CHARS_PER_SYL]]

    # word candidates: essay freq as score, pinyin from luna (explicit) else cedict
    words = []
    for word, freq in essay.items():
        n = len(word)
        if n not in (2, 3, 4):
            continue
        if freq < MIN_WORD_FREQ[n]:
            continue
        sylls = luna_words.get(word)
        if sylls is None:
            sylls = cedict.get(word)
        if not sylls or len(sylls) != n:
            continue
        if any(s not in syl_id for s in sylls):
            continue
        cps = [ord(c) for c in word]
        if any(cp > 0xFFFF for cp in cps):
            continue
        words.append((tuple(syl_id[s] for s in sylls), tuple(cps), freq))

    words.sort(key=lambda t: (t[0], -t[2]))
    buckets = defaultdict(list)
    for sids, cps, freq in words:
        if len(buckets[sids]) < MAX_CANDS_PER_TUPLE:
            buckets[sids].append((cps, freq))
    by_len = {2: [], 3: [], 4: []}
    for sids, cands in buckets.items():
        by_len[len(sids)].append((sids, cands))
    for n in (2, 3, 4):
        by_len[n].sort(key=lambda t: -t[1][0][1])
        by_len[n] = by_len[n][:WORD_TOPS[n]]
        # the binary format requires records sorted by syllable tuple
        by_len[n].sort(key=lambda t: t[0])

    # ---- write binary ----
    buf = bytearray()
    nsyl = len(syl_list)
    nw = {n: sum(len(c) for _, c in by_len[n]) for n in (2, 3, 4)}
    total_chars = sum(len(char_section[s]) for s in syl_list)
    buf += b"LMI1"
    buf += struct.pack("<5I", nsyl, total_chars, nw[2], nw[3], nw[4])

    syl_blob = bytearray()
    for s in syl_list:
        b = s.encode("ascii")
        syl_blob += struct.pack("<B", len(b)) + b
    char_blob = bytearray()
    for s in syl_list:
        cands = char_section[s]
        char_blob += struct.pack("<H", len(cands))
        for cp in cands:
            char_blob += struct.pack("<H", cp)

    def word_blob(n):
        blob = bytearray()
        for sids, cands in by_len[n]:
            for cps, _ in cands:
                blob += struct.pack("<%dH" % n, *sids)
                blob += struct.pack("<%dH" % n, *cps)
        return blob

    buf += struct.pack("<3I", len(syl_blob), len(char_blob), 0)
    buf += syl_blob
    buf += char_blob
    buf += word_blob(2)
    buf += word_blob(3)
    buf += word_blob(4)

    with open(OUT, "wb") as f:
        f.write(buf)
    sys.stderr.write(
        f"chars={total_chars} w2={nw[2]} w3={nw[3]} w4={nw[4]} "
        f"size={len(buf)} B -> {OUT}\n")


if __name__ == "__main__":
    build()
