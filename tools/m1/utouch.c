// SPDX-License-Identifier: MIT
// utouch: inject touch taps through /dev/uinput for headless UI verification.
// Creates a virtual touchscreen with panel-pixel coordinates, taps once, and
// optionally keeps tapping periodically while holding the device open.
// Build: aarch64-linux-gnu-gcc -static -O2 -o utouch utouch.c
// Usage: utouch <x> <y> [hold_seconds [repeat_seconds]]
//        (screen coordinates, 1080x2400 panel; repeat needs hold)
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include <linux/input.h>
#include <linux/uinput.h>

static void emit(int fd, int type, int code, int val)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = val;
	if (write(fd, &ev, sizeof(ev)) < 0)
		perror("write");
}

static void tap(int fd, int x, int y)
{
	emit(fd, EV_ABS, ABS_MT_SLOT, 0);
	emit(fd, EV_ABS, ABS_MT_TRACKING_ID, 42);
	emit(fd, EV_ABS, ABS_X, x);
	emit(fd, EV_ABS, ABS_Y, y);
	emit(fd, EV_ABS, ABS_MT_POSITION_X, x);
	emit(fd, EV_ABS, ABS_MT_POSITION_Y, y);
	emit(fd, EV_KEY, BTN_TOUCH, 1);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	usleep(90000);
	emit(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
	emit(fd, EV_KEY, BTN_TOUCH, 0);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	usleep(150000);
}

int main(int argc, char **argv)
{
	int x, y, fd, hold = 0, repeat = 0;
	struct uinput_setup us;
	struct uinput_abs_setup ax, ay, amx, amy, aslot, atid;

	if (argc < 3 || argc > 5) {
		fprintf(stderr, "usage: %s <x> <y> [hold_seconds [repeat_seconds]]\n", argv[0]);
		return 2;
	}
	x = atoi(argv[1]);
	y = atoi(argv[2]);
	if (argc >= 4)
		hold = atoi(argv[3]);
	if (argc >= 5)
		repeat = atoi(argv[4]);

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) {
		perror("open /dev/uinput");
		return 1;
	}

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_ABSBIT, ABS_X);
	ioctl(fd, UI_SET_ABSBIT, ABS_Y);
	ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT);
	ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
	ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
	ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
	ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

	memset(&ax, 0, sizeof(ax));
	ax.code = ABS_X;
	ax.absinfo.maximum = 1079;
	memset(&ay, 0, sizeof(ay));
	ay.code = ABS_Y;
	ay.absinfo.maximum = 2399;
	memset(&amx, 0, sizeof(amx));
	amx.code = ABS_MT_POSITION_X;
	amx.absinfo.maximum = 1079;
	memset(&amy, 0, sizeof(amy));
	amy.code = ABS_MT_POSITION_Y;
	amy.absinfo.maximum = 2399;
	memset(&aslot, 0, sizeof(aslot));
	aslot.code = ABS_MT_SLOT;
	aslot.absinfo.maximum = 9;
	memset(&atid, 0, sizeof(atid));
	atid.code = ABS_MT_TRACKING_ID;
	atid.absinfo.maximum = 65535;
	ioctl(fd, UI_ABS_SETUP, &ax);
	ioctl(fd, UI_ABS_SETUP, &ay);
	ioctl(fd, UI_ABS_SETUP, &amx);
	ioctl(fd, UI_ABS_SETUP, &amy);
	ioctl(fd, UI_ABS_SETUP, &aslot);
	ioctl(fd, UI_ABS_SETUP, &atid);

	memset(&us, 0, sizeof(us));
	snprintf(us.name, sizeof(us.name), "utouch-inject");
	us.id.bustype = BUS_VIRTUAL;
	us.id.vendor = 0x1234;
	us.id.product = 0x5678;
	if (ioctl(fd, UI_DEV_SETUP, &us) < 0) {
		perror("UI_DEV_SETUP");
		return 1;
	}
	if (ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("UI_DEV_CREATE");
		return 1;
	}

	usleep(600000); /* let libinput pick up the new device */

	tap(fd, x, y);

	if (hold > 0) {
		int elapsed = 0;
		if (repeat > 0) {
			while (elapsed < hold) {
				sleep((unsigned)repeat);
				elapsed += repeat;
				if (elapsed <= hold)
					tap(fd, x, y);
			}
		} else {
			printf("holding device for %d s\n", hold);
			sleep((unsigned)hold);
		}
	}

	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	printf("tap %d %d done\n", x, y);
	return 0;
}

