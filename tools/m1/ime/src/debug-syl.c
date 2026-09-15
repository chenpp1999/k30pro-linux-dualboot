/* SPDX-License-Identifier: MIT
 * debug-syl.c - dev tool: print stored char candidates per syllable
 * (compile with -DPINYIN_DEBUG_SYLLABLE) */
#include <stdio.h>
#include "pinyin.h"

int pinyin_engine_debug_syllable(const struct pinyin_engine *e, const char *syl,
				 unsigned int *base, unsigned int *count);
unsigned int pinyin_engine_debug_cp(const struct pinyin_engine *e,
				    unsigned int idx);
unsigned long pinyin_engine_debug_char_offset(const struct pinyin_engine *e);
int pinyin_engine_debug_sylname(const struct pinyin_engine *e, unsigned int id,
				char *buf, unsigned int len);

int
main(int argc, char **argv)
{
	const char *syls[] = { "a", "ai", "ba", "ni", "nai", "nan", "hao",
			       "zhong", NULL };
	struct pinyin_engine *e;
	int i;

	e = pinyin_engine_create(argc > 1 ? argv[1] : "pinyin.dict");
	if (!pinyin_engine_loaded(e)) {
		printf("load failed\n");
		return 1;
	}
	printf("char_data file offset = %lu\n",
	       pinyin_engine_debug_char_offset(e));
	for (i = 0; syls[i]; i++) {
		unsigned int base = 0, count = 0, j;
		int id = pinyin_engine_debug_syllable(e, syls[i], &base, &count);

		printf("%-6s id=%-4d base=%-6u count=%-3u first:", syls[i], id,
		       base, count);
		for (j = 0; j < 6 && j < count; j++)
			printf(" %04X", pinyin_engine_debug_cp(e, base + j));
		printf("\n");
	}
	for (i = 0; i < 8; i++) {
		char name[16];

		pinyin_engine_debug_sylname(e, (unsigned int)i, name, sizeof(name));
		printf("syl[%d] = '%s'\n", i, name);
	}
	pinyin_engine_destroy(e);
	return 0;
}
