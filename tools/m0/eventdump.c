// SPDX-License-Identifier: MIT
// eventdump: print input events from one or more /dev/input/eventN devices.
// Uses poll(2) so all given devices are monitored simultaneously (issue #5:
// the previous version blocked on the first device only).
// Build: gcc -static -O2 -o eventdump eventdump.c
// Usage: eventdump /dev/input/event0 [/dev/input/event3 ...]
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <linux/input.h>

int main(int argc, char **argv)
{
	int n, alive = 0;
	struct pollfd *pfds;

	if (argc < 2) {
		fprintf(stderr, "usage: eventdump /dev/input/eventX [...]\n");
		return 2;
	}
	n = argc - 1;
	pfds = calloc((size_t)n, sizeof(*pfds));
	if (!pfds) {
		perror("calloc");
		return 1;
	}

	for (int i = 0; i < n; i++) {
		pfds[i].fd = open(argv[i + 1], O_RDONLY | O_NONBLOCK);
		pfds[i].events = POLLIN;
		if (pfds[i].fd < 0) {
			fprintf(stderr, "%s: %s\n", argv[i + 1], strerror(errno));
			continue;
		}
		printf("listening on %s\n", argv[i + 1]);
		fflush(stdout);
		alive++;
	}
	if (!alive)
		return 1;

	for (;;) {
		int r = poll(pfds, (nfds_t)n, 1000);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			return 1;
		}
		if (r == 0)
			continue;
		for (int i = 0; i < n; i++) {
			struct input_event ev;
			if (pfds[i].fd < 0 || !(pfds[i].revents & POLLIN))
				continue;
			while (read(pfds[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				printf("%s %ld.%06ld type=%d code=%d value=%d\n",
				       argv[i + 1], (long)ev.time.tv_sec,
				       (long)ev.time.tv_usec, ev.type, ev.code,
				       ev.value);
			}
			fflush(stdout);
		}
	}
	return 0;
}
