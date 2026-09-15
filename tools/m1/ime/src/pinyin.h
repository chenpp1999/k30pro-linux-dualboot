/*
 * SPDX-License-Identifier: MIT
 * pinyin.h - compact pinyin engine for the lmi OSK (weston-keyboard).
 *
 * Dictionary format (little-endian, produced by tools/m1/ime/gen-dict.py):
 *   0   char[4]  "LMI1"
 *   4   u32 nsyl, total_chars, nw2, nw3, nw4
 *   24  u32 syl_len, char_len, reserved
 *   36  syllable table: nsyl * (u8 len + ascii bytes), sorted
 *       char table:     nsyl * (u16 count + count * u16 codepoint)
 *       w2: nw2 * (u16 syl[2] + u16 cp[2])   sorted by syl tuple
 *       w3: nw3 * (u16 syl[3] + u16 cp[3])
 *       w4: nw4 * (u16 syl[4] + u16 cp[4])
 */
#ifndef LMI_PINYIN_H
#define LMI_PINYIN_H

#include <stdbool.h>

#define PINYIN_MAX_INPUT 48
#define PINYIN_MAX_SYLLABLES 20
#define PINYIN_MAX_CANDIDATES 32
#define PINYIN_MAX_SEGMENTATIONS 64
#define PINYIN_CANDIDATE_TEXT 32

struct pinyin_candidate {
	char text[PINYIN_CANDIDATE_TEXT]; /* UTF-8 */
	int syllables;                    /* syllables consumed when committed */
	int cut;                          /* raw buffer offset consumed */
};

struct pinyin_segmentation {
	int ids[PINYIN_MAX_SYLLABLES];
	int ends[PINYIN_MAX_SYLLABLES];
	int n;
	int score;
};

struct pinyin_engine {
	unsigned char *dict;
	unsigned long dict_size;

	unsigned int nsyl;
	unsigned int total_chars;
	unsigned int nw2, nw3, nw4;

	const unsigned char *char_counts; /* u16 per syllable */
	const unsigned char *char_data;   /* u16 per candidate */
	const unsigned char *w2, *w3, *w4;

	char raw[PINYIN_MAX_INPUT + 1];
	int raw_len;

	/* segmentation */
	struct pinyin_segmentation segs[PINYIN_MAX_SEGMENTATIONS];
	int nsegs;

	struct pinyin_candidate cands[PINYIN_MAX_CANDIDATES];
	int ncands;
	int page;
};

struct pinyin_engine *pinyin_engine_create(const char *dict_path);
void pinyin_engine_destroy(struct pinyin_engine *engine);
bool pinyin_engine_loaded(const struct pinyin_engine *engine);

void pinyin_engine_input(struct pinyin_engine *engine, char c);
void pinyin_engine_backspace(struct pinyin_engine *engine);
void pinyin_engine_reset(struct pinyin_engine *engine);
const char *pinyin_engine_buffer(const struct pinyin_engine *engine);

int pinyin_engine_candidate_count(const struct pinyin_engine *engine);
const struct pinyin_candidate *pinyin_engine_candidates(const struct pinyin_engine *engine);
int pinyin_engine_page_count(const struct pinyin_engine *engine);
int pinyin_engine_page(const struct pinyin_engine *engine);
void pinyin_engine_page_next(struct pinyin_engine *engine);
void pinyin_engine_page_prev(struct pinyin_engine *engine);

/* commit candidate idx (of the current page): returns UTF-8 text (engine owned),
 * consumes its syllables and re-segments the remaining buffer. */
const char *pinyin_engine_select(struct pinyin_engine *engine, int idx);

#endif /* LMI_PINYIN_H */
