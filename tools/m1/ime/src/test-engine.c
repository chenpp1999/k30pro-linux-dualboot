#include <stdio.h>
#include "pinyin.h"

int main(int argc, char **argv)
{
	struct pinyin_engine *e;
	const char *path = argc > 1 ? argv[1] : "pinyin.dict";
	const char *keys = argc > 2 ? argv[2] : "nihao";
	const char *p;
	int i;

	e = pinyin_engine_create(path);
	printf("loaded=%d\n", (int)pinyin_engine_loaded(e));
	if (!pinyin_engine_loaded(e))
		return 1;
	for (p = keys; *p; p++)
		pinyin_engine_input(e, *p);
	printf("buffer=%s candidates=%d pages=%d\n", pinyin_engine_buffer(e),
	       pinyin_engine_candidate_count(e), pinyin_engine_page_count(e));
	for (i = 0; i < pinyin_engine_candidate_count(e); i++) {
		const struct pinyin_candidate *c = pinyin_engine_candidates(e);

		printf("  %d: %s (syl=%d cut=%d)\n", i, c[i].text, c[i].syllables,
		       c[i].cut);
	}
	if (pinyin_engine_candidate_count(e) > 0) {
		const char *sel = pinyin_engine_select(e, 0);

		printf("select[0]=%s rest=%s cands=%d\n", sel,
		       pinyin_engine_buffer(e), pinyin_engine_candidate_count(e));
	}
	return 0;
}
