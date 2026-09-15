#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# apply-terminal-delete.py - give weston-terminal a working
# delete_surrounding_text (patch 0008): terminals delete whole characters,
# the protocol carries byte lengths (see weston-editor).
#
# Usage: apply-terminal-delete.py <weston-tree>
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
    s = replace_once(
        s,
        """static void
text_input_delete_surrounding_text(void *data,
				   struct zwp_text_input_v1 *text_input,
				   int32_t index, uint32_t length)
{
}""",
        """static void
text_input_delete_surrounding_text(void *data,
				   struct zwp_text_input_v1 *text_input,
				   int32_t index, uint32_t length)
{
	struct terminal *terminal = data;
	uint32_t n, i;

	(void)index;
	/* The protocol carries byte lengths (cf. weston-editor); a terminal
	 * deletes whole characters.  The OSK sends one character per request,
	 * so map up to three bytes to one character and scale beyond. */
	n = length <= 3 ? 1 : (length + 2) / 3;
	if (n > 64)
		n = 64;
	for (i = 0; i < n; i++)
		terminal_write(terminal, "\\x7f", 1);
	if (n)
		window_schedule_redraw(terminal->window);
}""",
        "terminal delete_surrounding_text")
    open(path, "w", encoding="utf-8").write(s)
    print("terminal delete patch applied to", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
