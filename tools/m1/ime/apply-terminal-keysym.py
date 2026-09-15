#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# apply-terminal-keysym.py - make weston-terminal honour the text-input v1
# keysym modifiers: parse the IM's modifiers_map, map it onto toytoolkit
# MOD_* masks (fixes a real Ctrl/Alt swap), and turn Ctrl+<key>/Alt+<key>
# into the expected pty bytes.  Emits patch 0010.
#
# Usage: apply-terminal-keysym.py <weston-tree>
import os
import sys


def replace_once(text, old, new, what):
    assert text.count(old) == 1, f"anchor not unique/found: {what}"
    return text.replace(old, new, 1)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = os.path.join(sys.argv[1], "clients", "terminal.c")
    s = open(path, encoding="utf-8").read()

    # 1. per-terminal modifier masks
    s = replace_once(
        s,
        """	struct zwp_text_input_v1 *text_input;
	struct wl_seat *text_input_seat;""",
        """	struct zwp_text_input_v1 *text_input;
	struct wl_seat *text_input_seat;
	xkb_mod_mask_t ti_shift_mask, ti_ctrl_mask, ti_alt_mask;""",
        "terminal struct")

    # 2. parse the IM's modifiers map
    s = replace_once(
        s,
        """text_input_modifiers_map(void *data, struct zwp_text_input_v1 *text_input,
			 struct wl_array *map)
{
}""",
        """text_input_modifiers_map(void *data, struct zwp_text_input_v1 *text_input,
			 struct wl_array *map)
{
	struct terminal *terminal = data;

	terminal->ti_shift_mask = keysym_modifiers_get_mask(map, "Shift");
	terminal->ti_ctrl_mask = keysym_modifiers_get_mask(map, "Control");
	terminal->ti_alt_mask = keysym_modifiers_get_mask(map, "Mod1");
}""",
        "modifiers map")

    # 3. text_input_keysym: convert the protocol mask, add Ctrl/Alt letters
    old_fn = """text_input_keysym(void *data, struct zwp_text_input_v1 *text_input,
		  uint32_t serial, uint32_t time, uint32_t sym,
		  uint32_t state, uint32_t modifiers)
{
	struct terminal *terminal = data;
	char buf[MAX_RESPONSE];
	size_t len = 0;

	if (state != WL_KEYBOARD_KEY_STATE_PRESSED)
		return;

	switch (sym) {"""
    new_fn = """text_input_keysym(void *data, struct zwp_text_input_v1 *text_input,
		  uint32_t serial, uint32_t time, uint32_t sym,
		  uint32_t state, uint32_t modifiers)
{
	struct terminal *terminal = data;
	char buf[MAX_RESPONSE];
	size_t len = 0;
	xkb_mod_mask_t mods = 0;

	if (state != WL_KEYBOARD_KEY_STATE_PRESSED)
		return;

	/* The protocol carries the IM's own modifiers_map bitmask; translate
	 * it into the toytoolkit masks the rest of this file expects. */
	if (modifiers & terminal->ti_shift_mask)
		mods |= MOD_SHIFT_MASK;
	if (modifiers & terminal->ti_ctrl_mask)
		mods |= MOD_CONTROL_MASK;
	if (modifiers & terminal->ti_alt_mask)
		mods |= MOD_ALT_MASK;

	switch (sym) {"""
    s = replace_once(s, old_fn, new_fn, "keysym head")

    # use the translated mask in the escape-sequence keys
    s = replace_once(
        s,
        """	case XKB_KEY_Delete:
		len = function_key_response('[', 3, modifiers, '~', buf);
		break;
	case XKB_KEY_Page_Up:
		len = function_key_response('[', 5, modifiers, '~', buf);
		break;
	case XKB_KEY_Page_Down:
		len = function_key_response('[', 6, modifiers, '~', buf);
		break;
	case XKB_KEY_Left:
		len = function_key_response('[', 1, modifiers, 'D', buf);
		break;
	case XKB_KEY_Up:
		len = function_key_response('[', 1, modifiers, 'A', buf);
		break;
	case XKB_KEY_Right:
		len = function_key_response('[', 1, modifiers, 'C', buf);
		break;
	case XKB_KEY_Down:
		len = function_key_response('[', 1, modifiers, 'B', buf);
		break;
	case XKB_KEY_Home:
		len = function_key_response('[', 1, modifiers, 'H', buf);
		break;
	case XKB_KEY_End:
		len = function_key_response('[', 1, modifiers, 'F', buf);
		break;
	default:
		return;
	}""",
        """	case XKB_KEY_Delete:
		len = function_key_response('[', 3, mods, '~', buf);
		break;
	case XKB_KEY_Page_Up:
		len = function_key_response('[', 5, mods, '~', buf);
		break;
	case XKB_KEY_Page_Down:
		len = function_key_response('[', 6, mods, '~', buf);
		break;
	case XKB_KEY_Left:
		len = function_key_response('[', 1, mods, 'D', buf);
		break;
	case XKB_KEY_Up:
		len = function_key_response('[', 1, mods, 'A', buf);
		break;
	case XKB_KEY_Right:
		len = function_key_response('[', 1, mods, 'C', buf);
		break;
	case XKB_KEY_Down:
		len = function_key_response('[', 1, mods, 'B', buf);
		break;
	case XKB_KEY_Home:
		len = function_key_response('[', 1, mods, 'H', buf);
		break;
	case XKB_KEY_End:
		len = function_key_response('[', 1, mods, 'F', buf);
		break;
	default:
		/* printable keys from the OSK with a latched modifier:
		 * Ctrl+<key> -> control bytes, Alt+<key> -> ESC prefix */
		if (sym >= 0x20 && sym < 0x7f && (mods & MOD_CONTROL_MASK)) {
			unsigned int c = sym;

			if (c >= 'a' && c <= 'z')
				c = c - 'a' + 1;
			else if (c >= 'A' && c <= 'Z')
				c = c - 'A' + 1;
			else if (c >= '@' && c <= '_')
				c = c - '@';
			else if (c == '?' || c == '8')
				c = 0x7f;
			else
				return;
			buf[len++] = (char)c;
		} else if (sym >= 0x20 && sym < 0x7f && (mods & MOD_ALT_MASK)) {
			if (terminal->mode & MODE_ALT_SENDS_ESC)
				buf[len++] = 0x1b;
			buf[len++] = (char)sym;
		} else {
			return;
		}
		break;
	}""",
        "keysym cases")

    open(path, "w", encoding="utf-8").write(s)
    print("terminal keysym modifiers applied to", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
