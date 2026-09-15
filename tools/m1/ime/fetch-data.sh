#!/bin/sh
# SPDX-License-Identifier: MIT
# fetch-data.sh - fetch the pinyin/IME data sources into ./data (WSL/Linux host).
#
# Sources and licenses (all freely redistributable; attribution kept in
# docs/research/ux-ime-2026-09-15.md and tools/m1/ime/README.md):
#   - mozillazg/pinyin-data        MIT            char readings (all + 通用规范汉字表)
#   - rime/rime-essay-simp         LGPL-3.0       word/char frequency corpus
#   - rime/rime-luna-pinyin        LGPL-3.0       polyphone usage weights
#   - CC-CEDICT via mdbg           CC BY-SA 4.0   word pinyin (multi-syllable correctness)
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"
mkdir -p data
cd data

fetch() { # $1=url $2=file
	if [ -s "$2" ]; then
		echo "have $2"
		return 0
	fi
	echo "fetch $2"
	curl -sSL -o "$2.part" "$1"
	mv "$2.part" "$2"
}

P=https://raw.githubusercontent.com/mozillazg/pinyin-data/master
fetch "$P/pinyin.txt" pinyin.txt
fetch "$P/kMandarin_8105.txt" kMandarin_8105.txt
fetch "https://raw.githubusercontent.com/rime/rime-essay-simp/master/essay-zh-hans.txt" essay-zh-hans.txt
fetch "https://raw.githubusercontent.com/rime/rime-luna-pinyin/master/luna_pinyin.dict.yaml" luna_pinyin.dict.yaml
fetch "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip" cedict.zip
[ -f cedict_ts.u8 ] || python3 -c "import zipfile; zipfile.ZipFile('cedict.zip').extractall('.')"

ls -l
