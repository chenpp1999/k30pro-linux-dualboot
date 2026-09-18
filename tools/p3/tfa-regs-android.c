/*
 * tfa-regs-android - read/write TFA98xx registers from a static aarch64 binary.
 *
 * Built for the Linux/Android live comparison of the speaker amp (TFA9874,
 * i2c addr 0x34).  Android has no i2c-tools and debugfs is disabled, so this
 * tool is cross-compiled static and pushed to /data/local/tmp.
 *
 * Two back ends:
 *   i2c <bus>    /dev/i2c-<bus> (I2C_SLAVE_FORCE first: the TFA driver owns
 *                the slave address, plain I2C_SLAVE returns EBUSY)
 *   misc <node>  the driver's own tfa_reg char device (write 1 byte = register
 *                address, read 2 bytes = big-endian value)
 *
 * Register protocol: 8-bit address, 16-bit big-endian value.
 *
 * usage:
 *   tfa-regs scan [maxbus]                    probe buses for addr 0x34
 *   tfa-regs i2c <bus> [REG[=VAL] ...]        read REG (0xNN), write REG=VAL
 *   tfa-regs misc <node> [REG[=VAL] ...]
 *   tfa-regs dump <bus> [start] [count]       read count regs from start
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define I2C_SLAVE 0x0703
#define I2C_SLAVE_FORCE 0x0706
#define TFA_ADDR 0x34

static int fd = -1;
static int addr_fd = -1;
static int is_misc = 0;

static int bus_open(int bus)
{
	char path[64];
	int forced = 0;

	snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (ioctl(fd, I2C_SLAVE_FORCE, TFA_ADDR) == 0) {
		forced = 1;
	} else if (ioctl(fd, I2C_SLAVE, TFA_ADDR) != 0) {
		fprintf(stderr, "%s: I2C_SLAVE_FORCE/EBUSY and I2C_SLAVE failed: %s\n",
			path, strerror(errno));
		close(fd);
		fd = -1;
		return -1;
	}
	printf("# %s addr=0x%02x forced=%d\n", path, TFA_ADDR, forced);
	return 0;
}

/*
 * The driver exposes the register address node separately from the data node:
 * write the 1-byte address to <regnode> (e.g. /dev/tfa_reg), then read/write
 * the value on <rwnode> (e.g. /dev/tfa_rw).
 */
static int misc_open(const char *regnode, const char *rwnode)
{
	addr_fd = open(regnode, O_WRONLY);
	if (addr_fd < 0) {
		fprintf(stderr, "open %s: %s\n", regnode, strerror(errno));
		return -1;
	}
	fd = open(rwnode, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", rwnode, strerror(errno));
		close(addr_fd);
		addr_fd = -1;
		return -1;
	}
	is_misc = 1;
	printf("# %s + %s (driver misc nodes)\n", regnode, rwnode);
	return 0;
}

static int reg_read(unsigned reg, uint16_t *val)
{
	uint8_t addr = (uint8_t)reg;
	uint8_t buf[2];
	ssize_t n;

	if (is_misc) {
		if (write(addr_fd, &addr, 1) != 1) {
			fprintf(stderr, "misc set addr 0x%02x: %s\n",
				reg, strerror(errno));
			return -1;
		}
		n = read(fd, buf, 2);
	} else {
		n = write(fd, &addr, 1);
		if (n != 1) {
			fprintf(stderr, "i2c write addr: %s\n", strerror(errno));
			return -1;
		}
		n = read(fd, buf, 2);
	}
	if (n != 2) {
		fprintf(stderr, "read reg 0x%02x: %s (n=%zd)\n", reg,
			n < 0 ? strerror(errno) : "short", n);
		return -1;
	}
	*val = (uint16_t)((buf[0] << 8) | buf[1]);
	return 0;
}

static int reg_write(unsigned reg, uint16_t val)
{
	uint8_t buf[3] = {(uint8_t)reg, (uint8_t)(val >> 8), (uint8_t)val};

	if (is_misc) {
		uint8_t addr = (uint8_t)reg;

		if (write(addr_fd, &addr, 1) != 1) {
			fprintf(stderr, "misc set addr 0x%02x: %s\n",
				reg, strerror(errno));
			return -1;
		}
		if (write(fd, &buf[1], 2) != 2) {
			fprintf(stderr, "misc write reg 0x%02x: %s\n",
				reg, strerror(errno));
			return -1;
		}
		return 0;
	}
	if (write(fd, buf, 3) != 3) {
		fprintf(stderr, "write reg 0x%02x: %s\n", reg, strerror(errno));
		return -1;
	}
	return 0;
}

static int do_regs(char **args, int n)
{
	int i;

	if (n == 0) {
		for (i = 0; i < 0x100; i++) {
			uint16_t v;

			if (reg_read(i, &v) != 0)
				return 1;
			printf("0x%02x=0x%04x\n", i, v);
		}
		return 0;
	}
	for (i = 0; i < n; i++) {
		char *eq = strchr(args[i], '=');
		unsigned reg;

		if (sscanf(args[i], "%x", &reg) != 1) {
			fprintf(stderr, "bad register '%s'\n", args[i]);
			return 2;
		}
		if (eq) {
			unsigned val;

			if (sscanf(eq + 1, "%x", &val) != 1) {
				fprintf(stderr, "bad value '%s'\n", args[i]);
				return 2;
			}
			if (reg_write(reg, (uint16_t)val) != 0)
				return 1;
		}
		{
			uint16_t v;

			if (reg_read(reg, &v) != 0)
				return 1;
			printf("0x%02x=0x%04x\n", reg, v);
		}
	}
	return 0;
}

static int scan_buses(int maxbus)
{
	int bus, found = 0;

	for (bus = 0; bus <= maxbus; bus++) {
		char path[64];
		int bfd, forced = 0;
		uint8_t addr = 0x00, buf[2];

		snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
		bfd = open(path, O_RDWR);
		if (bfd < 0)
			continue;
		if (ioctl(bfd, I2C_SLAVE_FORCE, TFA_ADDR) == 0)
			forced = 1;
		else if (ioctl(bfd, I2C_SLAVE, TFA_ADDR) != 0) {
			close(bfd);
			continue;
		}
		if (write(bfd, &addr, 1) == 1 && read(bfd, buf, 2) == 2) {
			printf("bus %d: addr 0x%02x responds reg0x00=0x%02x%02x forced=%d\n",
			       bus, TFA_ADDR, buf[0], buf[1], forced);
			found++;
		}
		close(bfd);
	}
	if (!found)
		printf("# no bus with a device at 0x%02x\n", TFA_ADDR);
	return found ? 0 : 1;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr,
			"usage: %s scan [maxbus]\n"
			"       %s i2c <bus> [REG[=VAL] ...]\n"
			"       %s misc <regnode> <rwnode> [REG[=VAL] ...]\n"
			"       %s dump <bus> [start] [count]\n",
			argv[0], argv[0], argv[0], argv[0]);
		return 2;
	}
	if (strcmp(argv[1], "scan") == 0) {
		int maxbus = (argc > 2) ? (int)strtol(argv[2], NULL, 0) : 16;

		return scan_buses(maxbus);
	}
	if (strcmp(argv[1], "i2c") == 0) {
		if (bus_open((int)strtol(argv[2], NULL, 0)) != 0)
			return 1;
	} else if (strcmp(argv[1], "misc") == 0) {
		if (argc < 4) {
			fprintf(stderr, "misc needs <regnode> <rwnode>\n");
			return 2;
		}
		if (misc_open(argv[2], argv[3]) != 0)
			return 1;
	} else if (strcmp(argv[1], "dump") == 0) {
		unsigned start = (argc > 3) ? (unsigned)strtoul(argv[3], NULL, 0) : 0;
		unsigned count = (argc > 4) ? (unsigned)strtoul(argv[4], NULL, 0) : 0x100;
		unsigned r;

		if (bus_open((int)strtol(argv[2], NULL, 0)) != 0)
			return 1;
		for (r = start; r < start + count && r < 0x100; r++) {
			uint16_t v;

			if (reg_read(r, &v) != 0)
				return 1;
			printf("0x%02x=0x%04x\n", r, v);
		}
		close(fd);
		return 0;
	} else {
		fprintf(stderr, "unknown mode '%s'\n", argv[1]);
		return 2;
	}
	{
		int first = (strcmp(argv[1], "misc") == 0) ? 4 : 3;
		int rc = do_regs(&argv[first], argc - first);

		close(fd);
		if (addr_fd >= 0)
			close(addr_fd);
		return rc;
	}
}
