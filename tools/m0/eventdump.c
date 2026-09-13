// SPDX-License-Identifier: MIT
// eventdump: print input events from /dev/input/eventN (for touch validation).
// Build: gcc -static -O2 -o eventdump eventdump.c
#include <linux/input.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: eventdump /dev/input/eventX [...]\n");
    return 2;
  }
  for (int i = 1; i < argc; i++) {
    int fd = open(argv[i], O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
      fprintf(stderr, "%s: %s\n", argv[i], strerror(errno));
      continue;
    }
    printf("listening on %s (type/time/code/value)\n", argv[i]);
    fflush(stdout);
    for (;;) {
      struct input_event ev;
      ssize_t n = read(fd, &ev, sizeof(ev));
      if (n == sizeof(ev)) {
        printf("%s %ld.%06ld type=%d code=%d value=%d\n",
               argv[i], (long)ev.time.tv_sec, (long)ev.time.tv_usec,
               ev.type, ev.code, ev.value);
        fflush(stdout);
      } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
        fprintf(stderr, "%s: %s\n", argv[i], strerror(errno));
        break;
      } else {
        usleep(20000);
      }
    }
    close(fd);
  }
  return 0;
}
