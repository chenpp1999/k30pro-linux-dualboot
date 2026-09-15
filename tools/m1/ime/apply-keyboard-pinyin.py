#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# apply-keyboard-pinyin.py - apply the Chinese/pinyin OSK changes to a
# weston 14.0.2 tree (expects tools/m1/weston-patches/0001-0006 applied).
#
# Usage: apply-keyboard-pinyin.py <weston-tree>
# It rewrites clients/keyboard.c + clients/meson.build and installs
# clients/pinyin.c / clients/pinyin.h from tools/m1/ime/src/.
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")


def replace_once(text, old, new, what):
    assert text.count(old) == 1, f"anchor not unique/found: {what}"
    return text.replace(old, new, 1)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    tree = sys.argv[1]
    kbd_path = os.path.join(tree, "clients", "keyboard.c")
    meson_path = os.path.join(tree, "clients", "meson.build")
    s = open(kbd_path, encoding="utf-8").read()

    # 1. include
    s = replace_once(
        s,
        '#include "shared/xalloc.h"',
        '#include "shared/xalloc.h"\n#include "pinyin.h"',
        "include")

    # 2. key types
    s = replace_once(
        s,
        "\tkeytype_arrow_down,\n\tkeytype_style\n};",
        "\tkeytype_arrow_down,\n\tkeytype_style,\n\tkeytype_language,\n"
        "\tkeytype_pinyin_letter,\n\tkeytype_pinyin_punct\n};",
        "key_type enum")

    # 3. the useless preedit-style key becomes the 中/英 toggle in the latin layout
    s = replace_once(
        s,
        '\t{ keytype_style, "", "", "", 2}\n};\n\nstatic const struct key numeric_keys[] = {',
        '\t{ keytype_language, "\u4e2d/\u82f1", "\u4e2d/\u82f1", "\u4e2d/\u82f1", 2}\n};\n\nstatic const struct key numeric_keys[] = {',
        "style key -> language key")

    # 4. pinyin layout
    pinyin_layout = '''
/* Chinese (pinyin) layout: 12 columns, rows are
 *   [candidate strip drawn on top]
 *   q w e r t y u i o p <--
 *   中/英 a s d f g h j k l 符
 *   123 z x c v b n m <-- Enter
 *   ， 空格 。 、
 */
static const struct key pinyin_keys[] = {
\t{ keytype_pinyin_letter, "q", "q", "q", 1},
\t{ keytype_pinyin_letter, "w", "w", "w", 1},
\t{ keytype_pinyin_letter, "e", "e", "e", 1},
\t{ keytype_pinyin_letter, "r", "r", "r", 1},
\t{ keytype_pinyin_letter, "t", "t", "t", 1},
\t{ keytype_pinyin_letter, "y", "y", "y", 1},
\t{ keytype_pinyin_letter, "u", "u", "u", 1},
\t{ keytype_pinyin_letter, "i", "i", "i", 1},
\t{ keytype_pinyin_letter, "o", "o", "o", 1},
\t{ keytype_pinyin_letter, "p", "p", "p", 1},
\t{ keytype_backspace, "<--", "<--", "<--", 2},

\t{ keytype_language, "\u4e2d/\u82f1", "\u4e2d/\u82f1", "\u4e2d/\u82f1", 1},
\t{ keytype_pinyin_letter, "a", "a", "a", 1},
\t{ keytype_pinyin_letter, "s", "s", "s", 1},
\t{ keytype_pinyin_letter, "d", "d", "d", 1},
\t{ keytype_pinyin_letter, "f", "f", "f", 1},
\t{ keytype_pinyin_letter, "g", "g", "g", 1},
\t{ keytype_pinyin_letter, "h", "h", "h", 1},
\t{ keytype_pinyin_letter, "j", "j", "j", 1},
\t{ keytype_pinyin_letter, "k", "k", "k", 1},
\t{ keytype_pinyin_letter, "l", "l", "l", 1},
\t{ keytype_symbols, "\u7b26", "\u7b26", "\u7b26", 2},

\t{ keytype_symbols, "123", "123", "123", 1},
\t{ keytype_pinyin_letter, "z", "z", "z", 1},
\t{ keytype_pinyin_letter, "x", "x", "x", 1},
\t{ keytype_pinyin_letter, "c", "c", "c", 1},
\t{ keytype_pinyin_letter, "v", "v", "v", 1},
\t{ keytype_pinyin_letter, "b", "b", "b", 1},
\t{ keytype_pinyin_letter, "n", "n", "n", 1},
\t{ keytype_pinyin_letter, "m", "m", "m", 1},
\t{ keytype_backspace, "<--", "<--", "<--", 2},
\t{ keytype_enter, "Enter", "Enter", "Enter", 2},

\t{ keytype_pinyin_punct, "\uff0c", "\uff0c", "\uff0c", 2},
\t{ keytype_space, "", "", "", 6},
\t{ keytype_pinyin_punct, "\u3002", "\u3002", "\u3002", 2},
\t{ keytype_pinyin_punct, "\u3001", "\u3001", "\u3001", 2}
};

static const struct layout pinyin_layout = {
\tpinyin_keys,
\tsizeof(pinyin_keys) / sizeof(*pinyin_keys),
\t12,
\t4,
\t"zh",
\tZWP_TEXT_INPUT_V1_TEXT_DIRECTION_LTR
};

'''
    s = replace_once(s, "static const char *style_labels[] = {", pinyin_layout + "static const char *style_labels[] = {", "pinyin layout insert")

    # 5. state enum
    s = replace_once(
        s,
        "enum keyboard_state {\n\tKEYBOARD_STATE_DEFAULT,\n\tKEYBOARD_STATE_UPPERCASE,\n\tKEYBOARD_STATE_SYMBOLS\n};",
        "enum keyboard_state {\n\tKEYBOARD_STATE_DEFAULT,\n\tKEYBOARD_STATE_UPPERCASE,\n\tKEYBOARD_STATE_SYMBOLS,\n\tKEYBOARD_STATE_PINYIN\n};",
        "state enum")

    # 6. struct field
    s = replace_once(
        s,
        "\tstruct widget *widget;\n\n\tenum keyboard_state state;\n};",
        "\tstruct widget *widget;\n\n\tenum keyboard_state state;\n\n\tstruct pinyin_engine *pinyin;\n};",
        "keyboard struct")

    # 7. label_from_key
    s = replace_once(
        s,
        "\tcase KEYBOARD_STATE_SYMBOLS:\n\t\treturn key->symbol;\n\t}\n\n\treturn \"\";",
        "\tcase KEYBOARD_STATE_SYMBOLS:\n\t\treturn key->symbol;\n\tcase KEYBOARD_STATE_PINYIN:\n\t\treturn key->label;\n\t}\n\n\treturn \"\";",
        "label_from_key")

    # 8. layout selection + strip helpers
    s = replace_once(
        s,
        """static const struct layout *
get_current_layout(struct virtual_keyboard *keyboard)
{
	switch (keyboard->content_purpose) {
		case ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_DIGITS:
		case ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_NUMBER:
			return &numeric_layout;
		default:
			if (keyboard->preferred_language &&
			    strcmp(keyboard->preferred_language, "ar") == 0)
				return &arabic_layout;
			else
				return &normal_layout;
	}
}""",
        """static const struct layout *
get_current_layout(struct keyboard *keyboard)
{
	struct virtual_keyboard *vk = keyboard->keyboard;

	if (keyboard->state == KEYBOARD_STATE_PINYIN &&
	    pinyin_engine_loaded(keyboard->pinyin))
		return &pinyin_layout;

	switch (vk->content_purpose) {
		case ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_DIGITS:
		case ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_NUMBER:
			return &numeric_layout;
		default:
			if (vk->preferred_language &&
			    strcmp(vk->preferred_language, "ar") == 0)
				return &arabic_layout;
			else
				return &normal_layout;
	}
}

/* candidate strip (Chinese layout only), 50 logical px on top */
static const double strip_height = 50;
static const double cand_text_width = 96;
static const double cand_cell_width = 48;
static const int cand_per_page = 8;

static bool
layout_has_strip(const struct layout *layout)
{
	return layout == &pinyin_layout;
}

static void
draw_boxed_text(cairo_t *cr, const char *text, double x, double y,
		double w, double h, double font_size)
{
	cairo_text_extents_t extents;
	cairo_font_extents_t fe;
	double size = font_size;

	cairo_set_font_size(cr, size);
	cairo_text_extents(cr, text, &extents);
	while (extents.x_advance > w - 6 && size > 9) {
		size -= 1;
		cairo_set_font_size(cr, size);
		cairo_text_extents(cr, text, &extents);
	}
	cairo_font_extents(cr, &fe);
	cairo_move_to(cr, x + (w - extents.x_advance) / 2,
		      y + (h - (fe.ascent + fe.descent)) / 2 + fe.ascent);
	cairo_show_text(cr, text);
}

static void
draw_candidate_strip(struct keyboard *keyboard, cairo_t *cr)
{
	const struct pinyin_candidate *cands;
	const char *buf;
	double width = 12 * key_width;
	int n, page, npages, i;

	cairo_set_source_rgb(cr, 0.88, 0.88, 0.88);
	cairo_rectangle(cr, 0, 0, width, strip_height);
	cairo_fill(cr);

	/* pinyin buffer, right aligned in the left box */
	buf = pinyin_engine_buffer(keyboard->pinyin);
	if (buf[0]) {
		cairo_text_extents_t extents;

		cairo_set_source_rgb(cr, 0.15, 0.15, 0.55);
		cairo_set_font_size(cr, 15);
		cairo_text_extents(cr, buf, &extents);
		cairo_move_to(cr, cand_text_width - 6 - extents.x_advance,
			      (strip_height - extents.height) / 2 + extents.y_bearing);
		cairo_show_text(cr, buf);
	}

	cands = pinyin_engine_candidates(keyboard->pinyin);
	n = pinyin_engine_candidate_count(keyboard->pinyin);
	page = pinyin_engine_page(keyboard->pinyin);
	npages = pinyin_engine_page_count(keyboard->pinyin);

	for (i = 0; i < cand_per_page; i++) {
		int idx = page * cand_per_page + i;
		double x = cand_text_width + i * cand_cell_width;

		if (idx >= n)
			break;
		if (i == 0) {
			cairo_set_source_rgb(cr, 0.29, 0.53, 0.78);
			cairo_rectangle(cr, x + 1, 2, cand_cell_width - 2,
					strip_height - 4);
			cairo_fill(cr);
			cairo_set_source_rgb(cr, 1, 1, 1);
		} else {
			cairo_set_source_rgb(cr, 0, 0, 0);
		}
		draw_boxed_text(cr, cands[idx].text, x, 0, cand_cell_width,
				strip_height, 18);
	}

	/* paging */
	cairo_set_source_rgb(cr, 0.2, 0.2, 0.2);
	draw_boxed_text(cr, "\u2039", width - 60, 0, 30, strip_height, 20);
	draw_boxed_text(cr, "\u203a", width - 30, 0, 30, strip_height, 20);
	if (npages > 1) {
		char label[16];
		snprintf(label, sizeof(label), "%d/%d", page + 1, npages);
		cairo_set_font_size(cr, 10);
		cairo_move_to(cr, width - 58, 11);
		cairo_show_text(cr, label);
	}
}""",
        "layout selection")

    # 9. redraw with strip (whole function)
    old_redraw = """static void
redraw_handler(struct widget *widget, void *data)
{
	struct keyboard *keyboard = data;
	cairo_surface_t *surface;
	struct rectangle allocation;
	cairo_t *cr;
	unsigned int i;
	unsigned int row = 0, col = 0;
	const struct layout *layout;

	layout = get_current_layout(keyboard->keyboard);

	surface = window_get_surface(keyboard->window);
	widget_get_allocation(keyboard->widget, &allocation);

	cr = cairo_create(surface);
	cairo_rectangle(cr, allocation.x, allocation.y, allocation.width, allocation.height);
	cairo_clip(cr);

	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, 16);

	cairo_translate(cr, allocation.x, allocation.y);

	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(cr, 1, 1, 1, 0.75);
	cairo_rectangle(cr, 0, 0, layout->columns * key_width, layout->rows * key_height);
	cairo_paint(cr);

	cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

	for (i = 0; i < layout->count; ++i) {
		cairo_set_source_rgb(cr, 0, 0, 0);
		draw_key(keyboard, &layout->keys[i], cr, row, col);
		col += layout->keys[i].width;
		if (col >= layout->columns) {
			row += 1;
			col = 0;
		}
	}

	cairo_destroy(cr);
	cairo_surface_destroy(surface);
}"""
    new_redraw = """static void
redraw_handler(struct widget *widget, void *data)
{
	struct keyboard *keyboard = data;
	cairo_surface_t *surface;
	struct rectangle allocation;
	cairo_t *cr;
	unsigned int i;
	unsigned int row = 0, col = 0;
	double strip;
	const struct layout *layout;

	layout = get_current_layout(keyboard);
	strip = layout_has_strip(layout) ? strip_height : 0;

	surface = window_get_surface(keyboard->window);
	widget_get_allocation(keyboard->widget, &allocation);

	cr = cairo_create(surface);
	cairo_rectangle(cr, allocation.x, allocation.y, allocation.width, allocation.height);
	cairo_clip(cr);

	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, 16);

	cairo_translate(cr, allocation.x, allocation.y);

	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(cr, 1, 1, 1, 0.75);
	cairo_rectangle(cr, 0, 0, layout->columns * key_width,
			strip + layout->rows * key_height);
	cairo_paint(cr);

	cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

	if (strip) {
		cairo_save(cr);
		draw_candidate_strip(keyboard, cr);
		cairo_restore(cr);
	}

	cairo_translate(cr, 0, strip);

	for (i = 0; i < layout->count; ++i) {
		cairo_set_source_rgb(cr, 0, 0, 0);
		draw_key(keyboard, &layout->keys[i], cr, row, col);
		col += layout->keys[i].width;
		if (col >= layout->columns) {
			row += 1;
			col = 0;
		}
	}

	cairo_destroy(cr);
	cairo_surface_destroy(surface);
}"""
    s = replace_once(s, old_redraw, new_redraw, "redraw_handler")

    # 10. update size helper + candidate commit helpers
    s = replace_once(
        s,
        "static void\nkeyboard_handle_key(",
        """static void
keyboard_update_size(struct keyboard *keyboard)
{
	const struct layout *layout = get_current_layout(keyboard);
	double h = layout->rows * key_height;

	if (layout_has_strip(layout))
		h += strip_height;
	window_schedule_resize(keyboard->window,
			       layout->columns * key_width, (int)h);
}

static void
keyboard_send_preedit(struct keyboard *keyboard)
{
	struct virtual_keyboard *vk = keyboard->keyboard;
	const char *buf = pinyin_engine_buffer(keyboard->pinyin);

	if (!vk->context)
		return;
	zwp_input_method_context_v1_preedit_cursor(vk->context,
						   (uint32_t)strlen(buf));
	zwp_input_method_context_v1_preedit_string(vk->context, vk->serial,
						   buf, buf);
}

static void
keyboard_commit_text(struct keyboard *keyboard, const char *text)
{
	struct virtual_keyboard *vk = keyboard->keyboard;
	char *surrounding_text;

	if (!vk->context || !text || !text[0])
		return;
	zwp_input_method_context_v1_commit_string(vk->context, vk->serial, text);
	zwp_input_method_context_v1_preedit_string(vk->context, vk->serial,
						   "", "");
	if (vk->surrounding_text) {
		surrounding_text = insert_text(vk->surrounding_text,
					       vk->surrounding_cursor, text);
		free(vk->surrounding_text);
		vk->surrounding_text = surrounding_text;
		vk->surrounding_cursor += strlen(text);
	}
	/* Don't fabricate surrounding text when the client never provided
	 * one (weston-terminal): leave it NULL so Backspace keeps using the
	 * keysym path, which works for unbounded terminal edits. */
}

static void
keyboard_commit_candidate(struct keyboard *keyboard, int idx)
{
	const char *text;

	if (!keyboard->pinyin)
		return;
	text = pinyin_engine_select(keyboard->pinyin, idx);
	if (!text)
		return;
	keyboard_commit_text(keyboard, text);
	keyboard_send_preedit(keyboard);
}

static void
keyboard_handle_strip(struct keyboard *keyboard, double x, double y)
{
	double width = 12 * key_width;

	if (x >= width - 30) {
		pinyin_engine_page_next(keyboard->pinyin);
	} else if (x >= width - 60) {
		pinyin_engine_page_prev(keyboard->pinyin);
	} else if (x >= cand_text_width) {
		int cell = (int)((x - cand_text_width) / cand_cell_width);

		keyboard_commit_candidate(keyboard, cell);
	}
	(void)y;
}

static void
keyboard_handle_key(""",
        "update size + commit helpers")

    # 11. handle_key: labels + new cases
    s = replace_once(
        s,
        """	case KEYBOARD_STATE_SYMBOLS :
		label = key->symbol;
		break;
	}""",
        """	case KEYBOARD_STATE_SYMBOLS :
		label = key->symbol;
		break;
	case KEYBOARD_STATE_PINYIN :
		label = key->label;
		break;
	}""",
        "handle_key labels")

    # space: pinyin commit
    s = replace_once(
        s,
        """		case keytype_space:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			keyboard->keyboard->preedit_string =
				append(keyboard->keyboard->preedit_string, " ");
			virtual_keyboard_commit_preedit(keyboard->keyboard);
			break;""",
        """		case keytype_space:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (keyboard->state == KEYBOARD_STATE_PINYIN) {
				if (pinyin_engine_candidate_count(keyboard->pinyin) > 0) {
					keyboard_commit_candidate(keyboard, 0);
					break;
				}
				keyboard_commit_text(keyboard, " ");
				break;
			}
			keyboard->keyboard->preedit_string =
				append(keyboard->keyboard->preedit_string, " ");
			virtual_keyboard_commit_preedit(keyboard->keyboard);
			break;
		case keytype_pinyin_letter:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (!label || !label[0])
				break;
			pinyin_engine_input(keyboard->pinyin, label[0]);
			keyboard_send_preedit(keyboard);
			break;
		case keytype_pinyin_punct:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (pinyin_engine_candidate_count(keyboard->pinyin) > 0)
				keyboard_commit_candidate(keyboard, 0);
			keyboard_commit_text(keyboard, label);
			break;
		case keytype_language:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (!pinyin_engine_loaded(keyboard->pinyin))
				break;
			if (keyboard->state == KEYBOARD_STATE_PINYIN) {
				pinyin_engine_reset(keyboard->pinyin);
				if (keyboard->keyboard->context)
					zwp_input_method_context_v1_preedit_string(
						keyboard->keyboard->context,
						keyboard->keyboard->serial, "", "");
				keyboard->state = KEYBOARD_STATE_DEFAULT;
			} else {
				keyboard->state = KEYBOARD_STATE_PINYIN;
			}
			keyboard_update_size(keyboard);
			break;""",
        "space + new key types")

    # backspace: pinyin buffer first
    s = replace_once(
        s,
        """		case keytype_backspace:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;

			if (keyboard->keyboard->surrounding_text == NULL) {""",
        """		case keytype_backspace:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;

			if (keyboard->state == KEYBOARD_STATE_PINYIN &&
			    keyboard->pinyin &&
			    pinyin_engine_buffer(keyboard->pinyin)[0]) {
				pinyin_engine_backspace(keyboard->pinyin);
				keyboard_send_preedit(keyboard);
				break;
			}

			if (keyboard->keyboard->surrounding_text == NULL) {""",
        "backspace pinyin")

    # enter: commit candidate / escape raw pinyin first
    s = replace_once(
        s,
        """		case keytype_enter:
			virtual_keyboard_commit_preedit(keyboard->keyboard);""",
        """		case keytype_enter:
			if (keyboard->state == KEYBOARD_STATE_PINYIN &&
			    keyboard->pinyin) {
				if (pinyin_engine_candidate_count(keyboard->pinyin) > 0) {
					keyboard_commit_candidate(keyboard, 0);
				} else if (pinyin_engine_buffer(keyboard->pinyin)[0]) {
					char raw[PINYIN_MAX_INPUT + 1];

					snprintf(raw, sizeof(raw), "%s",
						 pinyin_engine_buffer(keyboard->pinyin));
					pinyin_engine_reset(keyboard->pinyin);
					keyboard_commit_text(keyboard, raw);
				}
			}
			virtual_keyboard_commit_preedit(keyboard->keyboard);""",
        "enter pinyin")

    # symbols switch: keep the layout in sync
    s = replace_once(
        s,
        """			case KEYBOARD_STATE_SYMBOLS:
				keyboard->state = KEYBOARD_STATE_DEFAULT;
				break;
			}
			break;""",
        """			case KEYBOARD_STATE_SYMBOLS:
				keyboard->state = KEYBOARD_STATE_DEFAULT;
				break;
			case KEYBOARD_STATE_PINYIN:
				keyboard->state = KEYBOARD_STATE_SYMBOLS;
				break;
			}
			keyboard_update_size(keyboard);
			break;""",
        "symbols switch pinyin")

    # 12. hit tests use the new layout accessor + strip
    s = s.replace("get_current_layout(keyboard->keyboard);",
                  "get_current_layout(keyboard);")

    s = replace_once(
        s,
        """	layout = get_current_layout(keyboard);

	if (keyboard->surrounding_text)
		dbg("Surrounding text updated: %s\\n", keyboard->surrounding_text);

	window_schedule_resize(keyboard->keyboard->window,
			       layout->columns * key_width,
			       layout->rows * key_height);""",
        """	layout = get_current_layout(keyboard->keyboard);

	if (keyboard->surrounding_text)
		dbg("Surrounding text updated: %s\\n", keyboard->surrounding_text);

	keyboard_update_size(keyboard->keyboard);""",
        "handle_commit_state layout")

    s = replace_once(
        s,
        """	layout = get_current_layout(keyboard);

	window_schedule_resize(keyboard->keyboard->window,
			       layout->columns * key_width,
			       layout->rows * key_height);

	zwp_input_method_context_v1_language(context,""",
        """	layout = get_current_layout(keyboard->keyboard);

	keyboard_update_size(keyboard->keyboard);

	zwp_input_method_context_v1_language(context,""",
        "input_method_activate layout")

    # 12b. silence -Wswitch in the latin switch key handler
    s = replace_once(
        s,
        """			case KEYBOARD_STATE_SYMBOLS:
				keyboard->state = KEYBOARD_STATE_UPPERCASE;
				break;
			}
			break;""",
        """			case KEYBOARD_STATE_SYMBOLS:
				keyboard->state = KEYBOARD_STATE_UPPERCASE;
				break;
			case KEYBOARD_STATE_PINYIN:
				keyboard->state = KEYBOARD_STATE_DEFAULT;
				break;
			}
			break;""",
        "switch key pinyin case")

    s = replace_once(
        s,
        """	input_get_position(input, &x, &y);

	widget_get_allocation(keyboard->widget, &allocation);
	x -= allocation.x;
	y -= allocation.y;

	row = y / key_height;""",
        """	input_get_position(input, &x, &y);

	widget_get_allocation(keyboard->widget, &allocation);
	x -= allocation.x;
	y -= allocation.y;

	if (layout_has_strip(layout) && y < strip_height) {
		keyboard_handle_strip(keyboard, x, y);
		widget_schedule_redraw(widget);
		return;
	}
	if (layout_has_strip(layout))
		y -= strip_height;

	row = y / key_height;""",
        "button strip")

    s = replace_once(
        s,
        """	widget_get_allocation(keyboard->widget, &allocation);

	x -= allocation.x;
	y -= allocation.y;

	row = (int)y / key_height;""",
        """	widget_get_allocation(keyboard->widget, &allocation);

	x -= allocation.x;
	y -= allocation.y;

	if (layout_has_strip(layout) && y < strip_height) {
		keyboard_handle_strip(keyboard, x, y);
		widget_schedule_redraw(keyboard->widget);
		return;
	}
	if (layout_has_strip(layout))
		y -= strip_height;

	row = (int)y / key_height;""",
        "touch strip")

    # 13. create: engine + state + size
    s = replace_once(
        s,
        """	struct keyboard *keyboard;
	const struct layout *layout;

	layout = get_current_layout(virtual_keyboard);

	keyboard = xzalloc(sizeof *keyboard);
	keyboard->keyboard = virtual_keyboard;""",
        """	struct keyboard *keyboard;
	const char *dict;

	keyboard = xzalloc(sizeof *keyboard);
	keyboard->keyboard = virtual_keyboard;
	dict = getenv("LMI_PINYIN_DICT");
	if (!dict)
		dict = "/usr/share/lmi/ime/pinyin.dict";
	keyboard->pinyin = pinyin_engine_create(dict);
	if (pinyin_engine_loaded(keyboard->pinyin))
		keyboard->state = KEYBOARD_STATE_PINYIN;
	else
		keyboard->state = KEYBOARD_STATE_DEFAULT;""",
        "create engine")

    s = replace_once(
        s,
        """	window_schedule_resize(keyboard->window,
			       layout->columns * key_width,
			       layout->rows * key_height);""",
        """	keyboard_update_size(keyboard);""",
        "create size")

    # 14. destroy engine
    s = replace_once(
        s,
        """	widget_destroy(virtual_keyboard->keyboard->widget);
	window_destroy(virtual_keyboard->keyboard->window);
	free(virtual_keyboard->keyboard);""",
        """	widget_destroy(virtual_keyboard->keyboard->widget);
	window_destroy(virtual_keyboard->keyboard->window);
	pinyin_engine_destroy(virtual_keyboard->keyboard->pinyin);
	free(virtual_keyboard->keyboard);""",
        "destroy engine")

    # 15. input context activation must not force the latin layout when the
    # pinyin dictionary is available (stock: state = DEFAULT)
    s = replace_once(
        s,
        "\tkeyboard->keyboard->state = KEYBOARD_STATE_DEFAULT;\n",
        """	if (pinyin_engine_loaded(keyboard->keyboard->pinyin)) {
		keyboard->keyboard->state = KEYBOARD_STATE_PINYIN;
		pinyin_engine_reset(keyboard->keyboard->pinyin);
	} else {
		keyboard->keyboard->state = KEYBOARD_STATE_DEFAULT;
	}
""",
        "activate state reset")

    # 16. wider page label buffer (silences -Wformat-truncation)
    s = replace_once(
        s,
        "\t\tchar label[16];\n",
        "\t\tchar label[32];\n",
        "page label buffer")

    # 17. cairo's toy font API does not do per-glyph fallback: request a
    # CJK-capable family directly so the Chinese key labels/candidates render
    # (the system ships WenQuanYi Zen Hei; see audit 6.5)
    s = replace_once(
        s,
        '\tcairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);',
        '\tcairo_select_font_face(cr, "WenQuanYi Zen Hei", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);',
        "keyboard font")

    open(kbd_path, "w", encoding="utf-8").write(s)

    # meson.build
    m = open(meson_path, encoding="utf-8").read()
    m = replace_once(
        m,
        "'weston-keyboard',\n\t\t'keyboard.c',",
        "'weston-keyboard',\n\t\t'keyboard.c',\n\t\t'pinyin.c',\n\t\t'pinyin.h',",
        "meson keyboard")

    open(meson_path, "w", encoding="utf-8").write(m)

    shutil.copy(os.path.join(SRC, "pinyin.c"), os.path.join(tree, "clients", "pinyin.c"))
    shutil.copy(os.path.join(SRC, "pinyin.h"), os.path.join(tree, "clients", "pinyin.h"))
    print("keyboard pinyin changes applied to", tree)
    return 0


if __name__ == "__main__":
    sys.exit(main())
