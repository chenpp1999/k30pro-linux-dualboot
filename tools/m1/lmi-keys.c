// SPDX-License-Identifier: MIT
// lmi-keys - hardware key / idle handling for the lmi Alpine rootfs.
//
//  * volume up/down     -> panel backlight -/+ 10%  (no audio stack yet)
//  * power key (short)  -> toggle screen off/on
//  * idle timeout       -> backlight off; first touch/key restores it
//
// The daemon watches every /dev/input/event* device that advertises volume
// keys or touch input, rescans for hotplug, and drives
// /sys/class/backlight/*/brightness. Weston's own idle handling
// (m1-weston --idle-time) turns the CRTC off at the same timeout; this
// daemon covers the backlight, which the DRM backend does not touch.
//
// Build (static, musl):
//   cc -static -O2 -Wall -o lmi-keys lmi-keys.c
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_FDS 32
#define SCAN_MS 2000
#define ROLE_VOLUME 1
#define ROLE_TOUCH 2

static int fds[MAX_FDS];
static char *paths[MAX_FDS];
static int roles[MAX_FDS];
static int nfds;

static char backlight_dir[256] = "/sys/class/backlight/panel0-backlight";
static int step_pct = 10;
static int idle_secs = 300;
static int cur_brightness;
static int max_brightness;
static int min_brightness;
static int dimmed;
static int restore_brightness;
static double last_input;

static double
now_monotonic(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int
dev_has_key(int fd, unsigned int code)
{
	unsigned long bits[(KEY_MAX / (8 * sizeof(long))) + 1] = { 0 };

	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0)
		return 0;
	return (bits[code / (8 * sizeof(long))] >> (code % (8 * sizeof(long)))) & 1UL;
}

static void
write_brightness_raw(int value)
{
	char path[300];
	FILE *f;

	snprintf(path, sizeof(path), "%s/brightness", backlight_dir);
	f = fopen(path, "w");
	if (!f) {
		fprintf(stderr, "lmi-keys: open %s: %s\n", path, strerror(errno));
		return;
	}
	fprintf(f, "%d\n", value);
	fclose(f);
}

static void
apply_brightness(int value)
{
	if (value > max_brightness)
		value = max_brightness;
	if (value < min_brightness)
		value = min_brightness;
	if (value == cur_brightness)
		return;
	write_brightness_raw(value);
	cur_brightness = value;
	fprintf(stderr, "lmi-keys: brightness %d/%d\n", value, max_brightness);
}

static void
screen_dim(void)
{
	if (dimmed)
		return;
	restore_brightness = cur_brightness;
	dimmed = 1;
	write_brightness_raw(0);
	cur_brightness = 0;
	fprintf(stderr, "lmi-keys: screen off (idle)\n");
}

static void
screen_restore(void)
{
	if (!dimmed)
		return;
	dimmed = 0;
	apply_brightness(restore_brightness);
	fprintf(stderr, "lmi-keys: screen on\n");
}

static void
rescan(void)
{
	glob_t g;
	size_t i;

	if (glob("/dev/input/event*", 0, NULL, &g) != 0)
		return;
	for (i = 0; i < g.gl_pathc && nfds < MAX_FDS; i++) {
		int fd, j, known = 0, role = 0;

		for (j = 0; j < nfds; j++) {
			if (strcmp(paths[j], g.gl_pathv[i]) == 0) {
				known = 1;
				break;
			}
		}
		if (known)
			continue;
		fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		if (dev_has_key(fd, KEY_VOLUMEUP) || dev_has_key(fd, KEY_VOLUMEDOWN) ||
		    dev_has_key(fd, KEY_POWER))
			role |= ROLE_VOLUME;
		if (dev_has_key(fd, BTN_TOUCH))
			role |= ROLE_TOUCH;
		if (!role) {
			close(fd);
			continue;
		}
		paths[nfds] = strdup(g.gl_pathv[i]);
		fds[nfds] = fd;
		roles[nfds] = role;
		nfds++;
		fprintf(stderr, "lmi-keys: watching %s (%s%s)\n", g.gl_pathv[i],
			(role & ROLE_VOLUME) ? "keys" : "",
			(role & ROLE_TOUCH) ? ((role & ROLE_VOLUME) ? ",touch" : "touch") : "");
	}
	globfree(&g);
}

int
main(int argc, char *argv[])
{
	int opt;

	while ((opt = getopt(argc, argv, "b:s:t:h")) != -1) {
		switch (opt) {
		case 'b':
			snprintf(backlight_dir, sizeof(backlight_dir), "%s", optarg);
			break;
		case 's':
			step_pct = atoi(optarg);
			break;
		case 't':
			idle_secs = atoi(optarg);
			break;
		default:
			fprintf(stderr,
				"usage: %s [-b backlight_dir] [-s step_pct] [-t idle_secs]\n",
				argv[0]);
			return 1;
		}
	}

	{
		char path[300];
		FILE *f;

		snprintf(path, sizeof(path), "%s/max_brightness", backlight_dir);
		f = fopen(path, "r");
		if (!f) {
			fprintf(stderr, "lmi-keys: no backlight at %s\n", backlight_dir);
			return 1;
		}
		if (fscanf(f, "%d", &max_brightness) != 1)
			max_brightness = 2047;
		fclose(f);
		snprintf(path, sizeof(path), "%s/brightness", backlight_dir);
		f = fopen(path, "r");
		if (f) {
			if (fscanf(f, "%d", &cur_brightness) != 1)
				cur_brightness = max_brightness;
			fclose(f);
		}
		if (step_pct < 1)
			step_pct = 10;
		min_brightness = max_brightness / 100;
		if (min_brightness < 1)
			min_brightness = 1;
		fprintf(stderr, "lmi-keys: backlight %s cur=%d max=%d step=%d%% idle=%ds\n",
			backlight_dir, cur_brightness, max_brightness, step_pct, idle_secs);
	}

	last_input = now_monotonic();
	rescan();
	if (nfds == 0)
		fprintf(stderr, "lmi-keys: no suitable device yet, waiting\n");

	for (;;) {
		struct pollfd pfd[MAX_FDS];
		int i, ready;

		for (i = 0; i < nfds; i++) {
			pfd[i].fd = fds[i];
			pfd[i].events = POLLIN;
			pfd[i].revents = 0;
		}
		ready = poll(pfd, nfds, SCAN_MS);
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			return 1;
		}
		if (ready == 0) {
			rescan();
			if (idle_secs > 0 && !dimmed &&
			    now_monotonic() - last_input >= idle_secs)
				screen_dim();
			continue;
		}
		for (i = 0; i < nfds; i++) {
			struct input_event ev;
			ssize_t n;
			int drop = 0;

			if (!(pfd[i].revents & POLLIN) && !(pfd[i].revents & POLLERR) &&
			    !(pfd[i].revents & POLLHUP))
				continue;
			while ((n = read(pfd[i].fd, &ev, sizeof(ev))) == sizeof(ev)) {
				int delta = 0;

				if (ev.type == EV_SYN)
					continue;
				if (ev.type != EV_KEY && ev.type != EV_ABS &&
				    ev.type != EV_REL)
					continue;
				last_input = now_monotonic();
				if (roles[i] & ROLE_TOUCH) {
					/* Any touch activity brings the screen back. */
					screen_restore();
					continue;
				}
				if (ev.type != EV_KEY || ev.value != 1)
					continue;
				if (ev.code == KEY_VOLUMEUP)
					delta = max_brightness * step_pct / 100;
				else if (ev.code == KEY_VOLUMEDOWN)
					delta = -(max_brightness * step_pct / 100);
				else if (ev.code == KEY_POWER) {
					if (dimmed)
						screen_restore();
					else
						screen_dim();
					continue;
				} else
					continue;
				screen_restore();
				apply_brightness(cur_brightness + delta);
			}
			if (n < 0 && errno == ENODEV)
				drop = 1;
			if (drop) {
				fprintf(stderr, "lmi-keys: %s gone\n", paths[i]);
				close(fds[i]);
				free(paths[i]);
				nfds--;
				fds[i] = fds[nfds];
				paths[i] = paths[nfds];
				roles[i] = roles[nfds];
				break;
			}
			/* any event on a watched device is user activity */
			last_input = now_monotonic();
			if (idle_secs > 0 && !dimmed &&
			    now_monotonic() - last_input >= idle_secs)
				screen_dim();
		}
	}
	return 0;
}
