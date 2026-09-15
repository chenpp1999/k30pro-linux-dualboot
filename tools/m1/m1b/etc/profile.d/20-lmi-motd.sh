# shellcheck shell=sh
# SPDX-License-Identifier: MIT
# 20-lmi-motd.sh - print the lmi cheat sheet for interactive SSH logins.
#
# Only for interactive sessions (a login shell on a tty); never for scp/sftp,
# cron or non-interactive `ssh host cmd`.  `-n`/--no-shell keeps it from
# dropping into a shell.
case "$-" in
*i*) ;;
*) return 0 2>/dev/null || exit 0 ;;
esac
[ -t 0 ] && [ -t 1 ] || return 0 2>/dev/null || exit 0
[ -x /usr/sbin/lmi-help ] || return 0 2>/dev/null || exit 0
# skip for tmux/multiplexers and when the user says so
[ -n "${LMI_NO_MOTD:-}" ] && return 0 2>/dev/null || true
/usr/sbin/lmi-help --no-shell
