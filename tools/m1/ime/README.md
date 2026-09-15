# tools/m1/ime — Chinese (pinyin) input for the lmi OSK

The patched `weston-keyboard` (see `tools/m1/weston-patches/0007-keyboard-pinyin.patch`)
gets a **pinyin page with a candidate strip** on top of the key grid. It is a
single client: no extra daemon, no Qt, no changes to Weston or its protocols
(weston 14 only offers `zwp_input_method_v1`; one input method per seat).

Layout (pinyin page, 12 columns x 50 logical px rows, 540x250 logical total):

    [ candidate strip: pinyin buffer | 8 candidates | < > ]   (50 px)
    q w e r t y u i o p <--                                    (row 1)
    中/英 a s d f g h j k l 符                                 (row 2)
    123 z x c v b n m <-- Enter                                (row 3)
    ， 空格 。 、                                                (row 4)

* tapping a letter feeds the engine, the pinyin buffer is shown as
  `preedit_string` (and drawn in the strip for clients that do not render it)
* `空格`/`，`/`。`/`、` commit the first candidate first when a composition is
  active (Chinese punctuation rules)
* `Enter` commits the first candidate, or escapes the raw pinyin as ASCII
* `<--` deletes from the buffer first, then acts as Backspace in the client
* candidates are per-character (逐字): selecting one consumes only the syllables
  it covers, the rest of the pinyin stays active
* `中/英` toggles the latin layout (also reachable there as the last key of the
  bottom row); `符`/`123` open the latin symbol pages
* the latin layout is the stock weston one (with our earlier patches)

## Data pipeline

    tools/m1/ime/fetch-data.sh      # download sources into ./data (gitignored)
    tools/m1/ime/gen-dict.py        # -> pinyin.dict (221 KB)
    tools/m1/ime/check-dict.py      # spot checks (syllables, words)
    tools/m1/ime/dump-syl.py FILE syl...   # full candidate lists per syllable

Sources (see `fetch-data.sh` for URLs):

| source | license | use |
|---|---|---|
| mozillazg/pinyin-data | MIT | single character readings (all + 通用规范汉字表) |
| rime/rime-essay-simp | LGPL-3.0 | character/word frequencies (candidate order) |
| rime/rime-luna-pinyin | LGPL-3.0 | polyphone usage weights, explicit word pinyin |
| CC-CEDICT (mdbg) | CC BY-SA 4.0 | word pinyin (multi-syllable correctness, e.g. 银行) |

`pinyin.dict` (committed) is the only runtime artifact; it is installed at
`/usr/share/lmi/ime/pinyin.dict` (the client also honours `LMI_PINYIN_DICT`).
It contains 431 syllables, 19 631 character candidates and 18 130 words
(2/3/4 syllables); see `gen-dict.py` and `check-dict.py` for the binary layout
(little endian: header, syllable table, char table, w2/w3/w4 tables).

## Engine

`src/pinyin.c` + `src/pinyin.h` (linked into weston-keyboard by the patch):

* syllable segmentation over the syllable table: bounded DFS, scored
  (full-sequence words > longest-prefix words > first-syllable chars > fewer
  syllables > longer first syllable)
* candidate assembly takes the best 4 segmentations, so `xian` yields 先/线/…
  and `西安` (from `xi'an`) in the same list
* commit consumes exactly the covered syllables and re-segments
* `src/test-engine.c` (`cc ... -DPINYIN_DEBUG_SYLLABLE` with `src/debug-syl.c`)
  are dev tools for checking the engine without the UI

## Building

`tools/m1/build-weston-clients.sh` applies **all** patches in
`tools/m1/weston-patches/` (0001-0007) and builds `weston-keyboard` +
`weston-terminal` on the device. The patch was generated with
`tools/m1/ime/make-patch.sh` (rebuilds a clean 14.0.2 + 0001-0006 baseline,
applies `apply-keyboard-pinyin.py`, diffs).

## Pitfalls (device-verified 2026-09-15)

* The char table interleaves one `u16` count per syllable with the data, so the
  data index of syllable *n* is `sum(counts[0..n-1]) + n` — forgetting the `+n`
  silently returns another syllable's characters (this bug shipped once).
* Stock `input_method_activate()` resets the keyboard state to DEFAULT; the
  patch keeps PINYIN when the dictionary is loaded (otherwise every new text
  field would silently switch to the latin layout).
* **cairo's toy font API has no per-glyph fallback** on this system: a face
  without CJK glyphs (DejaVu) renders tofu even with fontconfig fallbacks
  configured. The keyboard requests `WenQuanYi Zen Hei`; weston-terminal gets
  `font=WenQuanYi Zen Hei Mono` from `weston.ini` (editor uses Pango and is
  fine). Any new cairo toy-API client that must show Chinese needs the same.
* Weston maps the input panel only while a seat has **keyboard focus**
  (`show_input_panel_surface()`); touch taps grant it, so the OSK appears once
  a text field is focused — this is normal.
* Screenshots can contain stale frames on this driver (msm/pixman): use
  `weston-debug scene-graph` for geometry (e.g. `tools/m1/dev/kbd-tap.py`) and
  check content in small crops.
* `weston-debug` pipes to `tail`/`grep` inside the proot build env lose output;
  write to a file instead.

## Dev tools

* `tools/m1/dev/lmi-inject.py` — uinput key/touch/pointer/taps injection
* `tools/m1/dev/kbd-tap.py` — tap OSK keys by name, geometry from the scene graph

## Known gaps / next steps

* no long-press alternates, no fuzzy pinyin (z/zh, n/l), no user dictionary
* word candidates exist only for exact multi-syllable matches (no partial
  word listing for a longer buffer)
* candidate strip shows 8 items per page; paging via `<`/`>` (or `，`/`。` as
  punctuation when no composition is active)
* 半/全角 and 简/繁 switches, emoji page, and any learning are future work;
  the engine can later be swapped for librime/fcitx5 behind the same UI

## Backspace behaviour (2026-09-15 fix)

* The keyboard **does not fabricate surrounding text** when the client never
  provided one (`keyboard_commit_text()`): weston-terminal therefore keeps
  taking the `XKB_KEY_BackSpace` keysym path, which deletes terminal content
  without limit.  Before this fix, committing text made the keyboard believe
  it owned the surrounding text and every later backspace went through
  `delete_surrounding_text`, which the terminal ignored (nothing deleted).
* Patch 0008 implements `delete_surrounding_text` in weston-terminal as a
  fallback for clients/keys that do use it (one character per request, byte
  length approximated), so both paths work.

## Build environment (important)

`weston-keyboard` / `weston-terminal` must be **built natively on the device**
(`tools/m1/build-weston-clients.sh`).  Binaries built in the WSL/alpine proot
hobble toward a different musl/userland and can SIGSEGV on the phone (the
terminal did exactly that on 2026-09-15); only device builds are shipped.
