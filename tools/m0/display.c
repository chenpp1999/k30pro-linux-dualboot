// SPDX-License-Identifier: MIT
// m0-display: minimal DRM/KMS bring-up for the M0 ramboot image (no libdrm).
//
// The device kernel sets CONFIG_DRM_FBDEV_EMULATION=n and CONFIG_FB=n, so there
// is no framebuffer console and nothing modesets the panel in userspace: the
// screen stays black even though the DSI panel binds successfully. This tool:
//   1. disables any inherited planes/crtc state (bootloader splash),
//   2. sets the first connected connector's preferred mode with a dumb buffer
//      of color bars,
//   3. sets connector DPMS=On and the panel backlight (bl_power=0 + brightness),
//   4. stays resident to hold DRM master: msm blanks the display on last close.
//
// Build: gcc -static -O2 -I/usr/include/libdrm -o display display.c
// Usage: display [--once] [/dev/dri/card0]
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__has_include)
#  if __has_include(<drm/drm.h>)
#    include <drm/drm.h>
#    include <drm/drm_mode.h>
#  else
#    include <drm.h>
#    include <drm_mode.h>
#  endif
#else
#  include <drm.h>
#  include <drm_mode.h>
#endif

static int fd = -1;

/* libdrm's uapi headers do not define the connection state names. */
#ifndef DRM_MODE_CONNECTED
#define DRM_MODE_CONNECTED 1
#endif
#ifndef DRM_MODE_DPMS_ON
#define DRM_MODE_DPMS_ON 0
#endif

static void fill_bars(uint8_t *p, uint32_t w, uint32_t h, uint32_t pitch)
{
    static const uint32_t bars[8] = {
        0xffffffff, 0xffffff00, 0xff00ffff, 0xff00ff00,
        0xffff00ff, 0xffff0000, 0xff0000ff, 0xff000000,
    };
    for (uint32_t y = 0; y < h; y++) {
        uint32_t *row = (uint32_t *)(p + (size_t)y * pitch);
        for (uint32_t x = 0; x < w; x++) {
            uint32_t b = (uint32_t)((uint64_t)x * 8 / w);
            row[x] = bars[b > 7 ? 7 : b];
        }
    }
}

static void backlight_on(void)
{
    DIR *d = opendir("/sys/class/backlight");
    if (!d) {
        printf("backlight: opendir failed: %s\n", strerror(errno));
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        char path[512];
        long mx = -1;
        if (e->d_name[0] == '.')
            continue;
        snprintf(path, sizeof(path), "/sys/class/backlight/%s/bl_power", e->d_name);
        FILE *f = fopen(path, "w");
        if (f) {
            fprintf(f, "0\n"); /* FB_BLANK_UNBLANK */
            fclose(f);
        }
        snprintf(path, sizeof(path), "/sys/class/backlight/%s/max_brightness", e->d_name);
        f = fopen(path, "r");
        if (f) {
            if (fscanf(f, "%ld", &mx) != 1)
                mx = -1;
            fclose(f);
        }
        if (mx <= 0)
            continue;
        snprintf(path, sizeof(path), "/sys/class/backlight/%s/brightness", e->d_name);
        f = fopen(path, "w");
        if (f) {
            fprintf(f, "%ld\n", mx * 3 / 4);
            fclose(f);
            printf("backlight: %s bl_power=0 brightness=%ld/%ld\n", e->d_name, mx * 3 / 4, mx);
        } else {
            printf("backlight: %s write failed: %s\n", e->d_name, strerror(errno));
        }
    }
    closedir(d);
}

static void disable_planes(const uint32_t *planes, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        struct drm_mode_set_plane sp;
        memset(&sp, 0, sizeof(sp));
        sp.plane_id = planes[i];
        if (ioctl(fd, DRM_IOCTL_MODE_SETPLANE, &sp) == 0)
            printf("display: plane %u disabled\n", planes[i]);
    }
}

static void connector_dpms_on(uint32_t conn_id)
{
    struct drm_mode_get_connector c;
    memset(&c, 0, sizeof(c));
    c.connector_id = conn_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0 || c.count_props == 0)
        return;
    uint32_t n = c.count_props;
    uint32_t *props = calloc(n, sizeof(uint32_t));
    uint64_t *vals = calloc(n, sizeof(uint64_t));
    if (!props || !vals) {
        free(props);
        free(vals);
        return;
    }
    memset(&c, 0, sizeof(c));
    c.connector_id = conn_id;
    c.props_ptr = (uint64_t)(uintptr_t)props;
    c.prop_values_ptr = (uint64_t)(uintptr_t)vals;
    c.count_props = n;
    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) {
        free(props);
        free(vals);
        return;
    }
    for (uint32_t i = 0; i < n; i++) {
        struct drm_mode_get_property p;
        memset(&p, 0, sizeof(p));
        p.prop_id = props[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &p) < 0)
            continue;
        if (strcmp(p.name, "DPMS") == 0) {
            struct drm_mode_connector_set_property sp;
            memset(&sp, 0, sizeof(sp));
            sp.value = DRM_MODE_DPMS_ON;
            sp.prop_id = props[i];
            sp.connector_id = conn_id;
            if (ioctl(fd, DRM_IOCTL_MODE_SETPROPERTY, &sp) == 0)
                printf("display: connector %u DPMS -> On\n", conn_id);
            else
                printf("display: connector %u DPMS set failed: %s\n",
                       conn_id, strerror(errno));
        }
    }
    free(props);
    free(vals);
}

int main(int argc, char **argv)
{
    const char *card = "/dev/dri/card0";
    int hold = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--once") == 0)
            hold = 0;
        else
            card = argv[i];
    }

    fd = open(card, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "%s: %s\n", card, strerror(errno));
        return 1;
    }
    printf("display: %s opened\n", card);

    struct drm_mode_card_res res;
    uint32_t crtcs[32], conns[32], encs[32], fbs[16], planes[64];
    memset(&res, 0, sizeof(res));
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        fprintf(stderr, "GETRESOURCES: %s\n", strerror(errno));
        return 1;
    }
    if (res.count_crtcs > 32 || res.count_connectors > 32 ||
        res.count_encoders > 32) {
        fprintf(stderr, "too many resources\n");
        return 1;
    }
    uint32_t n_crtcs = res.count_crtcs, n_conns = res.count_connectors;
    uint32_t n_encs = res.count_encoders;
    memset(&res, 0, sizeof(res));
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)encs;
    res.fb_id_ptr = (uint64_t)(uintptr_t)fbs;
    res.count_crtcs = n_crtcs;
    res.count_connectors = n_conns;
    res.count_encoders = n_encs;
    res.count_fbs = 16;
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        fprintf(stderr, "GETRESOURCES(2): %s\n", strerror(errno));
        return 1;
    }
    struct drm_mode_get_plane_res pres;
    memset(&pres, 0, sizeof(pres));
    pres.plane_id_ptr = (uint64_t)(uintptr_t)planes;
    pres.count_planes = 64;
    uint32_t n_planes = 0;
    if (ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pres) == 0)
        n_planes = pres.count_planes;
    printf("display: %u crtc(s), %u connector(s), %u encoder(s), %u plane(s)\n",
           n_crtcs, n_conns, n_encs, n_planes);

    uint32_t conn_id = 0, crtc_id = 0;
    struct drm_mode_modeinfo mode;
    memset(&mode, 0, sizeof(mode));
    int have_mode = 0;

    for (uint32_t i = 0; i < n_conns; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof(c));
        c.connector_id = conns[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0)
            continue;
        printf("display: connector %u: connection=%u modes=%u\n",
               conns[i], c.connection, c.count_modes);
        if (c.connection != DRM_MODE_CONNECTED || conn_id != 0)
            continue;
        uint32_t n_modes = c.count_modes;
        struct drm_mode_modeinfo *modes = calloc(n_modes ? n_modes : 1, sizeof(*modes));
        if (!modes)
            continue;
        memset(&c, 0, sizeof(c));
        c.connector_id = conns[i];
        c.modes_ptr = (uint64_t)(uintptr_t)modes;
        c.count_modes = n_modes;
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0 || n_modes == 0) {
            free(modes);
            continue;
        }
        uint32_t pick = 0;
        for (uint32_t m = 0; m < n_modes; m++) {
            if (modes[m].type & DRM_MODE_TYPE_PREFERRED)
                pick = m;
        }
        mode = modes[pick];
        have_mode = 1;
        conn_id = conns[i];
        printf("display: picked connector %u mode %ux%u@%u type=0x%x\n",
               conn_id, mode.hdisplay, mode.vdisplay, mode.vrefresh, mode.type);
        if (c.encoder_id) {
            struct drm_mode_get_encoder e;
            memset(&e, 0, sizeof(e));
            e.encoder_id = c.encoder_id;
            if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e) == 0 && e.crtc_id)
                crtc_id = e.crtc_id;
        }
        free(modes);
    }

    if (!have_mode || !conn_id) {
        fprintf(stderr, "no connected connector with modes\n");
        return 1;
    }
    if (!crtc_id) {
        if (n_crtcs == 0) {
            fprintf(stderr, "no crtc available\n");
            return 1;
        }
        crtc_id = crtcs[0];
        printf("display: encoder has no crtc, using first crtc %u\n", crtc_id);
    }

    /* Release inherited (bootloader splash) state. */
    disable_planes(planes, n_planes);
    struct drm_mode_crtc off;
    memset(&off, 0, sizeof(off));
    off.crtc_id = crtc_id;
    if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &off) == 0)
        printf("display: crtc %u released\n", crtc_id);
    sleep(1);

    struct drm_mode_create_dumb dumb;
    memset(&dumb, 0, sizeof(dumb));
    dumb.width = mode.hdisplay;
    dumb.height = mode.vdisplay;
    dumb.bpp = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb) < 0) {
        fprintf(stderr, "CREATE_DUMB: %s\n", strerror(errno));
        return 1;
    }
    struct drm_mode_map_dumb map;
    memset(&map, 0, sizeof(map));
    map.handle = dumb.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map) < 0) {
        fprintf(stderr, "MAP_DUMB: %s\n", strerror(errno));
        return 1;
    }
    uint8_t *buf = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map.offset);
    if (buf == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        return 1;
    }
    fill_bars(buf, mode.hdisplay, mode.vdisplay, dumb.pitch);
    printf("display: dumb buffer %ux%u pitch=%u size=%llu\n",
           dumb.width, dumb.height, dumb.pitch, (unsigned long long)dumb.size);

    struct drm_mode_fb_cmd fbc;
    memset(&fbc, 0, sizeof(fbc));
    fbc.width = dumb.width;
    fbc.height = dumb.height;
    fbc.pitch = dumb.pitch;
    fbc.bpp = 32;
    fbc.depth = 24;
    fbc.handle = dumb.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fbc) < 0) {
        fprintf(stderr, "ADDFB: %s\n", strerror(errno));
        return 1;
    }

    struct drm_mode_crtc set;
    memset(&set, 0, sizeof(set));
    set.crtc_id = crtc_id;
    set.fb_id = fbc.fb_id;
    set.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
    set.count_connectors = 1;
    set.mode = mode;
    set.mode_valid = 1;
    if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set) < 0) {
        fprintf(stderr, "SETCRTC: %s\n", strerror(errno));
        return 1;
    }
    printf("display: crtc %u -> fb %u, mode set\n", crtc_id, fbc.fb_id);

    connector_dpms_on(conn_id);
    backlight_on();

    if (hold) {
        printf("display: holding DRM master (msm blanks on last close)\n");
        for (;;)
            sleep(3600);
    }
    printf("display: done\n");
    return 0;
}
