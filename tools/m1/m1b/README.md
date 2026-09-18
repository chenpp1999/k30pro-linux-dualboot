# tools/m1/m1b — persistent-rootfs payloads (WiFi + UX)

These files are copied into the M1b persistent rootfs tree
(Alpine 3.23 + OpenRC, living inside the Android `super` free space) and are
shipped to the device through the one-shot overlay applied by
`tools/m1/m1b-init.sh` on the first boot after switch_root.

## Layout

### WiFi bring-up (overlay v1/v2)

| path | role |
|---|---|
| `etc/conf.d/lmi-wifi` | super extents, CNSS2 timing, DHCP budgets (device specific) |
| `etc/init.d/lmi-wifi` | OpenRC service (background runner of `lmi-wifi-start`) |
| `etc/init.d/dropbear` | **override** of Alpine stock: `use net` (the rootfs has no `networking` service; `need net` blocks dropbear) |
| `etc/conf.d/dropbear` | **override** of Alpine stock: `DROPBEAR_OPTS="-P /run/dropbear.pid"` (working stop/status) |
| `etc/wpa_supplicant/wpa_supplicant.conf.template` | network template (PSKs injected at build time, never committed) |
| `usr/sbin/lmi-wifi-start` | linear bring-up: firmware links -> qrtr-ns -> cnss-daemon -> WLAN on -> wpa_supplicant -> DHCP, with mailbox reporting |
| `usr/sbin/m1-mailbox` | writes reports into the super mailbox (readable from Android) |
| `usr/sbin/lmi-cnss-daemon-wrapper` | runs the vendor daemon with the Android-property shim |

### UX batch (overlay `m1b-ux-v3`, 2026-09-14; plan: docs/linux-ux-plan-2026-09-14.md)

| path | role |
|---|---|
| `etc/xdg/weston/weston.ini` | panel + 24h clock + launchers (terminal/editor). **Do not add `background-color`/`panel-color`/`background-image`**: they stall the msm/pixman repaint (black screen, `repaint status: awaiting completion`; audit §6.1) |
| `etc/xdg/weston/weston.ini.fallback` | minimal known-good config (wrapper retry / manual rescue) |
| `usr/share/lmi/term-icon.png`, `editor-icon.png` | generated launcher icons (small, committed) |
| `usr/sbin/m1-weston` | **rewritten**: owns all children, bounded cleanup, retry + fallback (UX audit A4) |
| `etc/init.d/m1-weston` | **new**: `command_background` start, escalating `stop()` (TERM -> KILL + orphan sweep) |
| `etc/conf.d/m1-weston` | tunables (RETRIES/BACKOFF/SEAT_WAIT) |
| `etc/init.d/ntpd` | **override**: `use net` + `after lmi-wifi` (no `networking` service); runs as root for the `-S` callback |
| `etc/conf.d/ntpd` | CN NTP pools + `-S /usr/sbin/lmi-time-save` |
| `usr/sbin/lmi-time-save` | ntpd callback: try RTC write, else touch swclock's timestamp (lmi RTC is read-only from the AP) |
| `etc/conf.d/hwclock` | RTC kept in UTC (stock; hwclock service is disabled, swclock used instead) |
| `etc/localtime`, `etc/timezone` | Asia/Shanghai (TZif v2, musl-compatible) |
| `etc/profile.d/00-lmi-locale.sh` | `LANG=C.UTF-8` (musl >= 1.2.4) |
| `etc/fonts/conf.{avail,d}/4[34]-wqy-zenhei.conf`, `91-wqy-zenhei.conf` | WQY fontconfig rules (shipped as regular files, not symlinks) |
| `usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc` | CJK font, from `font-wqy-zenhei-0.9.46-r0.apk` (sha256 `59b2fe2c…`); TTC sha256 `38ed4249…` |
| `usr/bin/weston-terminal` | **patched build** (weston 14.0.2 + `tools/m1/weston-patches/`): text-input v1 → the OSK can type into the terminal |
| `usr/libexec/weston-keyboard` | **patched build**: symbols `_ . ,` in the `?123` layer, key width 45 (fits 540 logical px), immediate commit (no preedit buffering), Backspace via `XKB_KEY_BackSpace` keysym when the client provides no surrounding text |
| `usr/sbin/lmi-keys` | **new**: static musl daemon (`tools/m1/lmi-keys.c`) — volume keys → backlight ±10%, power key toggles screen, idle (`-t 300`) turns the backlight off (Weston's `--idle-time` only drops the CRTC) |
| `etc/init.d/lmi-keys` | OpenRC service for the daemon (`command_args="-t 300"`) |

### Audio chain (2026-09-18, see docs/bluetooth-assessment.md §6c.10)

| path | role |
|---|---|
| `etc/init.d/lmi-qrtr-ns` | **new**: userspace QRTR name service. **Required**: this downstream kernel has no in-kernel QRTR NS, so without it QMI service registration/lookup fails → `pd-mapper`'s SERVREG_LOC is invisible → the kernel `servloc` never initializes → no `q6core`/`sound`, i.e. **no sound card at all**. `command_args="-f"` (the daemon forks by default; supervise-daemon needs foreground), `before pd-mapper rmtfs tqftpserv`, `respawn_max=0` |
| `etc/init.d/rmtfs` | **override** of the pmOS package service: drop the `-s` argument (the package adds it unless the qipcrtr preload shim exists; this kernel has no `/sys/class/remoteproc`, so `-s` makes rmtfs exit immediately and the ADSP never gets its PD maps) |
| `etc/init.d/lmi-adsp` | ordering updated: `after udev-settle lmi-qrtr-ns pd-mapper rmtfs tqftpserv` |

Both `lmi-qrtr-ns` and `rmtfs`/`tqftpserv` must be in the `default` runlevel
(`rc-update add … default`); the overlay post-step adds them.

The patched clients are built by `tools/m1/build-weston-clients.sh` (on device;
meson must use `-Dprefix=/usr`, see the script header and the audit §6).

`m1b-init.sh` bumps `OVERLAY_VERSION` to `m1b-ux-v5` and, only when the overlay
was applied, runs a `chroot /newroot` post-step: `rc-update add ntpd default`,
`rc-update add hwclock boot`, `fc-cache --system-only`.

## Pitfalls (device-verified 2026-09-14)

- **Images deployed to `recovery` must be built with `--recovery-dtbo`**
  (`tools/m1/build-m1b-image.sh`): lmi's ABL reads the DTBO table from the boot
  image header's `recovery_dtbo` field; when empty it reads the `ANDROID!`
  magic instead (`Dtbo hdr magic mismatch 52444E41`), finds no DTB and falls
  back to fastboot (T1-03; v6 defect, fixed in v7). Content: the device's
  current dtbo table (`dtbo-new.img`, 487,424 B, sha `32e9ba4f…`).
- The Debian-packaged `mkbootimg` has a true-division bug in
  `get_number_of_pages` (`/` instead of `//`): with `--recovery_dtbo` the
  offset becomes a float and `pack('Q')` raises struct.error. Patch:
  `sed -i 's|) / page_size|) // page_size|' /usr/bin/mkbootimg`.
- `usr/sbin/lmi-wifi-start`: Alpine's `wpa_supplicant` is built without
  `CONFIG_DEBUG_FILE`, so `-f <log>` prints usage and exits (WiFi fails with
  `status=failed`). Log via `2>>/var/log/wpa_supplicant.log` instead — do not
  reintroduce `-f`.
- `etc/init.d/dropbear`: keep `use net`, not `need net` — the rootfs does not
  run the `networking` service, so `need net` makes OpenRC refuse to start
  dropbear (`cannot start dropbear as networking would not start`).
- When patching a dumped rootfs image offline, replay the ext4 journal first
  (`tools/m1/patch-rootfs-image.sh`): debugfs writes followed by `e2fsck -fy`
  get silently reverted by journal replay otherwise.

## Files taken from the device (not committed)

Extracted from `device-xiaomi-lmi-1-r139.apk`
(sha256 `ac00f227…`, the D80 release bundle kept on the phone in
`/root/work/lmi-m0/d80-minimal-gui-osk-20260712/`):

| file | source in the apk | sha256 (2026-09-14) |
|---|---|---|
| `usr/sbin/lmi-qrtr-ns` | `usr/sbin/lmi-qrtr-ns` | `3a10b971…` (static aarch64) |
| `usr/lib/lmi/liblmi_android_prop_shim.so` | same path | `2a6b5319…` |

Firmware is bundled from the device's modem partition
(`/vendor/firmware_mnt/image/qca6390/`, read via Android root):
`amss20.bin`, `m3.bin`, `bdwlan.elf` (+ `bd_*.elf`, `bdwlan.e0x` variants),
`regdb.bin`, plus `/vendor/etc/wifi/qca6390/WCNSS_qcom_cfg.ini` and
`/mnt/vendor/persist/wlan_mac.bin` (linked to the paths the downstream
qcacld driver expects under `/lib/firmware/`).

## Overlay application and rollback

- The overlay is applied exactly once per version, marked by
  `etc/m1b-overlay-version`.
- Rollback: ship a new overlay version that restores old files; or rewrite the
  whole rootfs image from TWRP (the master copy lives in
  `/sdcard/Download/phone-server/lmi-m1b/rootfs.img`).
- The overlay never deletes files and refuses to apply on failure, so a broken
  overlay cannot make the rootfs unbootable.
