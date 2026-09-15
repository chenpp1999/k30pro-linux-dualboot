/*
 * SPDX-License-Identifier: MIT
 * pinyin.c - compact pinyin engine for the lmi OSK (weston-keyboard).
 *
 * Data: see tools/m1/ime/ (generator + sources, MIT/LGPL/CC-BY-SA data).
 * Design: segmentation over the syllable table (bounded DFS, scored), then
 * candidates = words matching the longest prefix of the best segmentation
 * followed by single characters of its first syllable; other segmentations
 * contribute afterwards (e.g. "xian" -> 先… plus 西安 from xi'an).
 *
 * Commit semantics are per-character (逐字): selecting a candidate consumes
 * only the syllables it covers, the rest stays in the buffer.
 */
#include "pinyin.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define WORD_REC(n) (4 * (n))
#define MAX_DFS_NODES 20000

static void __attribute__ ((format (printf, 1, 2)))
dbg(const char *fmt, ...)
{
	va_list argp;

	va_start(argp, fmt);
	fprintf(stderr, "lmi-ime: ");
	vfprintf(stderr, fmt, argp);
	va_end(argp);
}

static unsigned int
rd_u32(const unsigned char *p)
{
	return (unsigned int)p[0] | ((unsigned int)p[1] << 8) |
	       ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}

static unsigned int
rd_u16(const unsigned char *p)
{
	return (unsigned int)p[0] | ((unsigned int)p[1] << 8);
}

/* ---- dictionary access ---- */

static const unsigned char *
syl_at(const struct pinyin_engine *e, unsigned int id)
{
	const unsigned char *p = e->dict + 36;
	unsigned int i;

	if (id >= e->nsyl)
		return NULL;
	for (i = 0; i < id; i++)
		p += 1 + p[0];
	return p;
}

static int
syl_lookup(const struct pinyin_engine *e, const char *s, int len)
{
	int lo = 0, hi = (int)e->nsyl - 1;

	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		const unsigned char *p = syl_at(e, mid);
		int plen = p[0];
		int cmp = memcmp(s, p + 1, (size_t)(len < plen ? len : plen));

		if (cmp == 0 && len == plen)
			return mid;
		if (cmp == 0 ? len < plen : cmp < 0)
			hi = mid - 1;
		else
			lo = mid + 1;
	}
	return -1;
}

static unsigned int
char_count(const struct pinyin_engine *e, unsigned int syl)
{
	return rd_u16(e->char_counts + 2 * syl);
}

static const unsigned char *
word_rec(const struct pinyin_engine *e, int n, unsigned long idx)
{
	const unsigned char *base;

	if (n == 2)
		base = e->w2;
	else if (n == 3)
		base = e->w3;
	else
		base = e->w4;
	return base + WORD_REC(n) * idx;
}

static unsigned long
word_count_n(const struct pinyin_engine *e, int n)
{
	return n == 2 ? e->nw2 : (n == 3 ? e->nw3 : e->nw4);
}

static int
tuple_cmp(const unsigned char *rec, const int *ids, int n)
{
	int i, cmp = 0;

	for (i = 0; i < n && cmp == 0; i++)
		cmp = ids[i] - (int)rd_u16(rec + 2 * i);
	return cmp;
}

static unsigned long
word_lower_bound(const struct pinyin_engine *e, const int *ids, int n)
{
	unsigned long lo = 0, hi = word_count_n(e, n);

	while (lo < hi) {
		unsigned long mid = (lo + hi) / 2;
		const unsigned char *rec = word_rec(e, n, mid);

		if (tuple_cmp(rec, ids, n) <= 0)
			hi = mid;
		else
			lo = mid + 1;
	}
	return lo;
}

/* count words whose syllable tuple equals ids[0..n-1] */
static int
word_matches(const struct pinyin_engine *e, const int *ids, int n)
{
	unsigned long count, k;
	int cnt = 0;

	if (n < 2 || n > 4)
		return 0;
	count = word_count_n(e, n);
	k = word_lower_bound(e, ids, n);
	while (k < count) {
		const unsigned char *rec = word_rec(e, n, k);

		if (tuple_cmp(rec, ids, n) != 0)
			break;
		cnt++;
		k++;
	}
	return cnt;
}

static const unsigned char *
word_at(const struct pinyin_engine *e, const int *ids, int n, int idx)
{
	unsigned long count = word_count_n(e, n), k;

	k = word_lower_bound(e, ids, n);
	while (k < count && idx > 0) {
		const unsigned char *rec = word_rec(e, n, k);

		if (tuple_cmp(rec, ids, n) != 0)
			return NULL;
		k++;
		idx--;
	}
	if (k >= count)
		return NULL;
	if (tuple_cmp(word_rec(e, n, k), ids, n) != 0)
		return NULL;
	return word_rec(e, n, k);
}

/* ---- utf-8 helpers ---- */

static size_t
utf8_put(char *dst, unsigned int cp)
{
	if (cp < 0x80) {
		dst[0] = (char)cp;
		return 1;
	}
	if (cp < 0x800) {
		dst[0] = (char)(0xc0 | (cp >> 6));
		dst[1] = (char)(0x80 | (cp & 0x3f));
		return 2;
	}
	dst[0] = (char)(0xe0 | (cp >> 12));
	dst[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
	dst[2] = (char)(0x80 | (cp & 0x3f));
	return 3;
}

static void
cps_to_utf8(char *dst, size_t dstlen, const unsigned int *cps, int n)
{
	size_t used = 0;
	int i;

	for (i = 0; i < n && used + 4 < dstlen; i++)
		used += utf8_put(dst + used, cps[i]);
	dst[used] = '\0';
}

/* ---- candidates ---- */

static void
add_candidate(struct pinyin_engine *e, const unsigned int *cps, int nchars,
	      int syllables, int cut)
{
	int i;

	if (e->ncands >= PINYIN_MAX_CANDIDATES)
		return;
	cps_to_utf8(e->cands[e->ncands].text, sizeof(e->cands[e->ncands].text),
		    cps, nchars);
	e->cands[e->ncands].syllables = syllables;
	e->cands[e->ncands].cut = cut;
	for (i = 0; i < e->ncands; i++) {
		if (strcmp(e->cands[i].text, e->cands[e->ncands].text) == 0)
			return;
	}
	e->ncands++;
}

static int
seg_score(const struct pinyin_engine *e, const struct pinyin_segmentation *s)
{
	int sc = 0, k;

	if (s->n == 0)
		return -1000000;
	if (word_matches(e, s->ids, s->n))
		sc += 1000000;
	for (k = s->n; k >= 2; k--) {
		if (word_matches(e, s->ids, k)) {
			sc += 100000 + k * 1000;
			break;
		}
	}
	if (char_count(e, s->ids[0]))
		sc += 10000;
	sc -= s->n;                              /* fewer syllables preferred */
	sc += (s->n > 0 ? s->ends[0] : 0) * 10;  /* longer first syllable */
	return sc;
}

static void
seg_dfs(struct pinyin_engine *e, int pos, struct pinyin_segmentation *cur,
	int *nodes)
{
	int len;

	if (*nodes > MAX_DFS_NODES)
		return;
	(*nodes)++;
	if (pos == e->raw_len) {
		int sc = seg_score(e, cur);

		if (e->nsegs < PINYIN_MAX_SEGMENTATIONS) {
			cur->score = sc;
			e->segs[e->nsegs++] = *cur;
		} else {
			int worst = 0, i;

			for (i = 1; i < e->nsegs; i++)
				if (e->segs[i].score < e->segs[worst].score)
					worst = i;
			if (sc > e->segs[worst].score) {
				cur->score = sc;
				e->segs[worst] = *cur;
			}
		}
		return;
	}
	if (cur->n >= PINYIN_MAX_SYLLABLES)
		return;
	for (len = 6; len >= 1; len--) {
		int id;

		if (pos + len > e->raw_len)
			continue;
		id = syl_lookup(e, e->raw + pos, len);
		if (id < 0)
			continue;
		cur->ids[cur->n] = id;
		cur->ends[cur->n] = pos + len;
		cur->n++;
		seg_dfs(e, pos + len, cur, nodes);
		cur->n--;
	}
}

static int
seg_cmp(const void *a, const void *b)
{
	const struct pinyin_segmentation *sa = a, *sb = b;

	return sb->score - sa->score;
}

static unsigned int
char_base(const struct pinyin_engine *e, unsigned int syl)
{
	unsigned int i, base = 0;

	for (i = 0; i < syl; i++)
		base += char_count(e, i);
	return base;
}

static void
engine_resegment(struct pinyin_engine *e)
{
	struct pinyin_segmentation cur = { {0}, {0}, 0, 0 };
	int nodes = 0;
	int i;

	e->nsegs = 0;
	e->page = 0;
	e->ncands = 0;
	memset(e->cands, 0, sizeof(e->cands));

	if (e->raw_len == 0)
		return;

	seg_dfs(e, 0, &cur, &nodes);
	if (e->nsegs == 0)
		return;
	qsort(e->segs, e->nsegs, sizeof(e->segs[0]), seg_cmp);

	for (i = 0; i < e->nsegs && e->ncands < PINYIN_MAX_CANDIDATES; i++) {
		const struct pinyin_segmentation *s = &e->segs[i];
		int k, j;

		/* longest prefix that has word candidates */
		for (k = s->n; k >= 2; k--) {
			int cnt = word_matches(e, s->ids, k);

			if (cnt == 0)
				continue;
			for (j = 0; j < cnt && e->ncands < PINYIN_MAX_CANDIDATES; j++) {
				const unsigned char *rec = word_at(e, s->ids, k, j);
				unsigned int cps[4];
				int m;

				if (!rec)
					break;
				for (m = 0; m < k; m++)
					cps[m] = rd_u16(rec + 2 * k + 2 * m);
				add_candidate(e, cps, k, k, s->ends[k - 1]);
			}
			break;
		}
		/* single characters of the first syllable.  The char section
		 * interleaves one u16 count per syllable with the data, so the
		 * data offset of syllable n is (cumulative entries) + n. */
		{
			unsigned int cnt = char_count(e, s->ids[0]);
			unsigned int base = char_base(e, s->ids[0]) + s->ids[0];
			unsigned int j;

			for (j = 0; j < cnt && e->ncands < PINYIN_MAX_CANDIDATES; j++) {
				unsigned int cp = rd_u16(e->char_data + 2 * (base + j));

				add_candidate(e, &cp, 1, 1, s->ends[0]);
			}
		}
		if (i >= 3) /* keep the list sane: best 4 segmentations only */
			break;
	}
}

/* ---- public API ---- */

struct pinyin_engine *
pinyin_engine_create(const char *dict_path)
{
	struct pinyin_engine *e;
	int fd;
	struct stat st;
	ssize_t got;
	const unsigned char *syl_tbl, *char_tbl, *p;
	unsigned char *counts;
	unsigned int i;
	unsigned long char_total = 0;

	fd = open(dict_path, O_RDONLY);
	if (fd < 0) {
		dbg("pinyin: cannot open %s: %s\n", dict_path, strerror(errno));
		return NULL;
	}
	if (fstat(fd, &st) != 0 || st.st_size < 40) {
		close(fd);
		return NULL;
	}
	e = calloc(1, sizeof(*e));
	if (!e) {
		close(fd);
		return NULL;
	}
	e->dict = malloc((size_t)st.st_size);
	if (!e->dict) {
		close(fd);
		free(e);
		return NULL;
	}
	got = read(fd, e->dict, (size_t)st.st_size);
	close(fd);
	if (got != st.st_size || memcmp(e->dict, "LMI1", 4) != 0) {
		free(e->dict);
		free(e);
		return NULL;
	}
	e->dict_size = (unsigned long)st.st_size;
	e->nsyl = rd_u32(e->dict + 4);
	e->total_chars = rd_u32(e->dict + 8);
	e->nw2 = rd_u32(e->dict + 12);
	e->nw3 = rd_u32(e->dict + 16);
	e->nw4 = rd_u32(e->dict + 20);

	syl_tbl = e->dict + 36;
	char_tbl = syl_tbl;
	for (i = 0; i < e->nsyl; i++)
		char_tbl += 1 + char_tbl[0];
	if (rd_u32(e->dict + 24) != (unsigned int)(char_tbl - syl_tbl)) {
		dbg("pinyin: bad syllable table length\n");
		free(e->dict);
		free(e);
		return NULL;
	}
	counts = malloc(2 * e->nsyl + 4);
	if (!counts) {
		free(e->dict);
		free(e);
		return NULL;
	}
	p = char_tbl;
	for (i = 0; i < e->nsyl; i++) {
		unsigned int cnt = rd_u16(p);

		counts[2 * i] = cnt & 0xff;
		counts[2 * i + 1] = (cnt >> 8) & 0xff;
		char_total += cnt;
		p += 2 + 2 * cnt;
	}
	if (char_total != e->total_chars) {
		dbg("pinyin: char table mismatch (%lu != %u)\n", char_total,
		    e->total_chars);
		free(counts);
		free(e->dict);
		free(e);
		return NULL;
	}
	e->char_counts = counts;
	e->char_data = char_tbl + 2; /* first count is at char_tbl */
	e->w2 = p;
	e->w3 = e->w2 + (unsigned long)e->nw2 * WORD_REC(2);
	e->w4 = e->w3 + (unsigned long)e->nw3 * WORD_REC(3);
	if ((unsigned long)(e->w4 - e->dict) +
	    (unsigned long)e->nw4 * WORD_REC(4) > e->dict_size) {
		dbg("pinyin: truncated dictionary\n");
		free(counts);
		free(e->dict);
		free(e);
		return NULL;
	}
	dbg("pinyin: loaded %s (%u syllables, %u chars, %u/%u/%u words)\n",
	    dict_path, e->nsyl, e->total_chars, e->nw2, e->nw3, e->nw4);
	return e;
}

void
pinyin_engine_destroy(struct pinyin_engine *e)
{
	if (!e)
		return;
	free((void *)e->char_counts);
	free(e->dict);
	free(e);
}

bool
pinyin_engine_loaded(const struct pinyin_engine *e)
{
	return e && e->dict != NULL;
}

void
pinyin_engine_input(struct pinyin_engine *e, char c)
{
	if (!pinyin_engine_loaded(e))
		return;
	if (c < 'a' || c > 'z')
		return;
	if (e->raw_len >= PINYIN_MAX_INPUT)
		return;
	e->raw[e->raw_len++] = c;
	e->raw[e->raw_len] = '\0';
	engine_resegment(e);
}

void
pinyin_engine_backspace(struct pinyin_engine *e)
{
	if (!pinyin_engine_loaded(e) || e->raw_len == 0)
		return;
	e->raw[--e->raw_len] = '\0';
	engine_resegment(e);
}

void
pinyin_engine_reset(struct pinyin_engine *e)
{
	if (!e)
		return;
	e->raw_len = 0;
	e->raw[0] = '\0';
	engine_resegment(e);
}

const char *
pinyin_engine_buffer(const struct pinyin_engine *e)
{
	return e ? e->raw : "";
}

int
pinyin_engine_candidate_count(const struct pinyin_engine *e)
{
	return e ? e->ncands : 0;
}

const struct pinyin_candidate *
pinyin_engine_candidates(const struct pinyin_engine *e)
{
	return e ? e->cands : NULL;
}

int
pinyin_engine_page_count(const struct pinyin_engine *e)
{
	if (!e || e->ncands == 0)
		return 1;
	return (e->ncands + 7) / 8;
}

int
pinyin_engine_page(const struct pinyin_engine *e)
{
	return e ? e->page : 0;
}

void
pinyin_engine_page_next(struct pinyin_engine *e)
{
	if (e && e->page + 1 < pinyin_engine_page_count(e))
		e->page++;
}

void
pinyin_engine_page_prev(struct pinyin_engine *e)
{
	if (e && e->page > 0)
		e->page--;
}

const char *
pinyin_engine_select(struct pinyin_engine *e, int idx)
{
	static char out[PINYIN_CANDIDATE_TEXT];
	const struct pinyin_candidate *c;
	int i, cut, rest;

	if (!pinyin_engine_loaded(e) || e->ncands == 0)
		return NULL;
	i = e->page * 8 + idx;
	if (i < 0 || i >= e->ncands)
		return NULL;
	c = &e->cands[i];
	cut = c->cut;
	if (cut <= 0 || cut > e->raw_len)
		cut = e->raw_len;
	rest = e->raw_len - cut;
	memmove(e->raw, e->raw + cut, (size_t)rest);
	e->raw_len = rest;
	e->raw[rest] = '\0';
	snprintf(out, sizeof(out), "%s", c->text);
	engine_resegment(e);
	return out;
}

#ifdef PINYIN_DEBUG_SYLLABLE
/* dev helper: dump one syllable's stored candidates (see dump-syl test) */
int
pinyin_engine_debug_syllable(const struct pinyin_engine *e, const char *syl,
			     unsigned int *base, unsigned int *count)
{
	int id = syl_lookup(e, syl, (int)strlen(syl));

	if (id < 0)
		return -1;
	*base = char_base(e, (unsigned int)id);
	*count = char_count(e, (unsigned int)id);
	return id;
}

unsigned int
pinyin_engine_debug_cp(const struct pinyin_engine *e, unsigned int idx)
{
	return rd_u16(e->char_data + 2 * idx);
}

unsigned long
pinyin_engine_debug_char_offset(const struct pinyin_engine *e)
{
	return (unsigned long)(e->char_data - e->dict);
}

int
pinyin_engine_debug_sylname(const struct pinyin_engine *e, unsigned int id,
			    char *buf, unsigned int len)
{
	const unsigned char *p = syl_at(e, id);
	unsigned int i, n;

	if (!p)
		return -1;
	n = p[0];
	if (n >= len)
		n = len - 1;
	for (i = 0; i < n; i++)
		buf[i] = (char)p[1 + i];
	buf[n] = '\0';
	return (int)n;
}
#endif

