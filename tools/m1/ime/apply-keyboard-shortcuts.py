#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# apply-keyboard-shortcuts.py - add the shortcut bar (Esc/Tab/Ctrl/Alt/arrows/
# Home/End/PgUp/PgDn) with one-shot + locked modifiers to weston-keyboard.
# Expects patch 0007 (pinyin page) already applied.  Emits patch 0009.
#
# Usage: apply-keyboard-shortcuts.py <weston-tree>
import os
import sys


def replace_once(text, old, new, what):
    assert text.count(old) == 1, f"anchor not unique/found: {what}"
    return text.replace(old, new, 1)


SHORTCUT_BLOCK = '''
/* ---- shortcut bar (one extra row at the bottom of every layout) ----
 * Esc / Tab / Ctrl / Alt / arrows / Home / End / PgUp / PgDn.
 * Ctrl and Alt latch for the next key (one-shot); tapping them twice within
 * MOD_LATCH_MS locks them (highlighted), tapping again releases. */
struct shortcut_key {
	const char *label;
	xkb_keysym_t sym; /* 0 for modifier latches */
	int modifier;     /* 1 = Control, 2 = Mod1/Alt */
};

static const struct shortcut_key shortcut_keys[] = {
	{ "Esc", XKB_KEY_Escape, 0 },
	{ "Tab", XKB_KEY_Tab, 0 },
	{ "Ctrl", 0, 1 },
	{ "Alt", 0, 2 },
	{ "\\u2190", XKB_KEY_Left, 0 },
	{ "\\u2191", XKB_KEY_Up, 0 },
	{ "\\u2193", XKB_KEY_Down, 0 },
	{ "\\u2192", XKB_KEY_Right, 0 },
	{ "Home", XKB_KEY_Home, 0 },
	{ "End", XKB_KEY_End, 0 },
	{ "PgUp", XKB_KEY_Prior, 0 },
	{ "PgDn", XKB_KEY_Next, 0 },
};

#define SHORTCUT_COUNT ((int)(sizeof(shortcut_keys) / sizeof(*shortcut_keys)))
#define MOD_LATCH_MS 300

static xkb_mod_mask_t
shortcut_mod_mask(const struct keyboard *keyboard, int modifier)
{
	if (modifier == 1)
		return keyboard->ctrl_mask;
	if (modifier == 2)
		return keyboard->alt_mask;
	return 0;
}

static void
keyboard_send_keysym(struct keyboard *keyboard, xkb_keysym_t sym, uint32_t time,
		     xkb_mod_mask_t mods)
{
	struct virtual_keyboard *vk = keyboard->keyboard;

	if (!vk->context)
		return;
	zwp_input_method_context_v1_keysym(vk->context, vk->serial, time, sym,
					   WL_KEYBOARD_KEY_STATE_PRESSED, mods);
	zwp_input_method_context_v1_keysym(vk->context, vk->serial, time, sym,
					   WL_KEYBOARD_KEY_STATE_RELEASED, mods);
}

static void
keyboard_handle_shortcut(struct keyboard *keyboard, double x,
			 enum wl_pointer_button_state state, uint32_t time)
{
	xkb_mod_mask_t bit, mods;
	const struct shortcut_key *sk;
	int idx;

	if (state != WL_POINTER_BUTTON_STATE_PRESSED || x < 0)
		return;
	idx = (int)(x / key_width);
	if (idx >= SHORTCUT_COUNT)
		return;
	sk = &shortcut_keys[idx];

	if (sk->modifier) {
		bit = shortcut_mod_mask(keyboard, sk->modifier);
		if (!bit)
			return;
		if (keyboard->locked_mods & bit) {
			keyboard->locked_mods &= ~bit;
		} else if ((keyboard->latched_mods & bit) &&
			   time - keyboard->last_mod_tap < MOD_LATCH_MS) {
			keyboard->latched_mods &= ~bit;
			keyboard->locked_mods |= bit;
		} else if (keyboard->latched_mods & bit) {
			keyboard->latched_mods &= ~bit;
		} else {
			keyboard->latched_mods |= bit;
		}
		keyboard->last_mod_tap = time;
		return;
	}

	mods = keyboard->latched_mods | keyboard->locked_mods;
	keyboard_send_keysym(keyboard, sk->sym, time, mods);
	keyboard->latched_mods = 0;
}

static void
draw_shortcut_bar(struct keyboard *keyboard, cairo_t *cr, double y)
{
	int i;

	for (i = 0; i < SHORTCUT_COUNT; i++) {
		const struct shortcut_key *sk = &shortcut_keys[i];
		xkb_mod_mask_t bit = shortcut_mod_mask(keyboard, sk->modifier);
		int lit = bit && ((keyboard->latched_mods |
				   keyboard->locked_mods) & bit);
		int locked = bit && (keyboard->locked_mods & bit);

		cairo_save(cr);
		cairo_rectangle(cr, i * key_width, y, key_width, key_height);
		if (locked) {
			cairo_set_source_rgb(cr, 0.29, 0.53, 0.78);
			cairo_fill_preserve(cr);
		} else if (lit) {
			cairo_set_source_rgb(cr, 0.75, 0.85, 0.95);
			cairo_fill_preserve(cr);
		}
		cairo_set_source_rgb(cr, 0, 0, 0);
		cairo_set_line_width(cr, 3);
		cairo_stroke(cr);
		cairo_restore(cr);

		if (locked)
			cairo_set_source_rgb(cr, 1, 1, 1);
		else
			cairo_set_source_rgb(cr, 0, 0, 0);
		draw_boxed_text(cr, sk->label, i * key_width, y, key_width,
				key_height, 15);
	}
}
'''


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = os.path.join(sys.argv[1], "clients", "keyboard.c")
    s = open(path, encoding="utf-8").read()

    # 1. shortcut table + helpers (after draw_boxed_text, before the strip)
    anchor = """	cairo_move_to(cr, x + (w - extents.x_advance) / 2,
		      y + (h - (fe.ascent + fe.descent)) / 2 + fe.ascent);
	cairo_show_text(cr, text);
}

static void
draw_candidate_strip"""
    s = replace_once(
        s,
        anchor,
        """	cairo_move_to(cr, x + (w - extents.x_advance) / 2,
		      y + (h - (fe.ascent + fe.descent)) / 2 + fe.ascent);
	cairo_show_text(cr, text);
}
""" + SHORTCUT_BLOCK + """
static void
draw_candidate_strip""",
        "shortcut block")

    # 2. keyboard struct fields
    s = replace_once(
        s,
        "\tstruct pinyin_engine *pinyin;\n};",
        """	struct pinyin_engine *pinyin;

	/* shortcut bar modifiers */
	xkb_mod_mask_t ctrl_mask, alt_mask;
	xkb_mod_mask_t latched_mods, locked_mods;
	uint32_t last_mod_tap;
};""",
        "keyboard struct")

    # 3. masks from the modifiers map (input_method_activate)
    s = replace_once(
        s,
        """	keyboard->keysym.shift_mask = keysym_modifiers_get_mask(&modifiers_map, "Shift");
	wl_array_release(&modifiers_map);""",
        """	keyboard->keysym.shift_mask = keysym_modifiers_get_mask(&modifiers_map, "Shift");
	keyboard->keyboard->ctrl_mask =
		keysym_modifiers_get_mask(&modifiers_map, "Control");
	keyboard->keyboard->alt_mask =
		keysym_modifiers_get_mask(&modifiers_map, "Mod1");
	wl_array_release(&modifiers_map);""",
        "modifier masks")

    # 4. surface height includes the bar
    s = replace_once(
        s,
        """	const struct layout *layout = get_current_layout(keyboard);
	double h = layout->rows * key_height;

	if (layout_has_strip(layout))
		h += strip_height;""",
        """	const struct layout *layout = get_current_layout(keyboard);
	double h = (layout->rows + 1) * key_height; /* + shortcut bar */

	if (layout_has_strip(layout))
		h += strip_height;""",
        "update size")

    # 5. draw the bar in redraw_handler
    s = replace_once(
        s,
        """		if (col >= layout->columns) {
			row += 1;
			col = 0;
		}
	}

	cairo_destroy(cr);""",
        """		if (col >= layout->columns) {
			row += 1;
			col = 0;
		}
	}

	draw_shortcut_bar(keyboard, cr, layout->rows * key_height);

	cairo_destroy(cr);""",
        "draw bar")

    # 6. button_handler hit test
    s = replace_once(
        s,
        """	if (layout_has_strip(layout))
		y -= strip_height;

	row = y / key_height;""",
        """	if (layout_has_strip(layout))
		y -= strip_height;

	if (y >= layout->rows * key_height) {
		keyboard_handle_shortcut(keyboard, x, state, time);
		widget_schedule_redraw(widget);
		return;
	}

	row = y / key_height;""",
        "button bar")

    # 7. touch_handler hit test
    s = replace_once(
        s,
        """	if (layout_has_strip(layout))
		y -= strip_height;

	row = (int)y / key_height;""",
        """	if (layout_has_strip(layout))
		y -= strip_height;

	if (y >= layout->rows * key_height) {
		keyboard_handle_shortcut(keyboard, x, state, time);
		widget_schedule_redraw(keyboard->widget);
		return;
	}

	row = (int)y / key_height;""",
        "touch bar")

    # 8. latin letters with a latched modifier -> keysym with modifiers
    s = replace_once(
        s,
        """		case keytype_default:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;

			/* Commit immediately (no preedit buffering): terminals
			 * echo each key as it is pressed. */
			zwp_input_method_context_v1_commit_string(
				keyboard->keyboard->context,
				keyboard->keyboard->serial,
				label);
			break;""",
        """		case keytype_default:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;

			if ((keyboard->latched_mods | keyboard->locked_mods) &&
			    label && (unsigned char)label[0] >= 0x20 &&
			    (unsigned char)label[0] < 0x7f) {
				keyboard_send_keysym(keyboard,
						     (xkb_keysym_t)label[0], time,
						     keyboard->latched_mods |
						     keyboard->locked_mods);
				keyboard->latched_mods = 0;
				break;
			}

			/* Commit immediately (no preedit buffering): terminals
			 * echo each key as it is pressed. */
			zwp_input_method_context_v1_commit_string(
				keyboard->keyboard->context,
				keyboard->keyboard->serial,
				label);
			break;""",
        "latin mods")

    # 9. pinyin letters with a latched modifier -> keysym (bypass the engine)
    s = replace_once(
        s,
        """		case keytype_pinyin_letter:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (!label || !label[0])
				break;
			pinyin_engine_input(keyboard->pinyin, label[0]);""",
        """		case keytype_pinyin_letter:
			if (state != WL_POINTER_BUTTON_STATE_PRESSED)
				break;
			if (!label || !label[0])
				break;
			if (keyboard->latched_mods | keyboard->locked_mods) {
				keyboard_send_keysym(keyboard,
						     (xkb_keysym_t)label[0], time,
						     keyboard->latched_mods |
						     keyboard->locked_mods);
				keyboard->latched_mods = 0;
				break;
			}
			pinyin_engine_input(keyboard->pinyin, label[0]);""",
        "pinyin mods")

    open(path, "w", encoding="utf-8").write(s)
    print("shortcut bar applied to", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
