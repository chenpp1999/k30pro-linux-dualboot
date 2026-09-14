# tools/m1/m1b — persistent-rootfs WiFi bring-up files

These files are copied into the M1b persistent rootfs tree
(Alpine 3.23 + OpenRC, living inside the Android `super` free space) and are
shipped to the device through the one-shot overlay applied by
`tools/m1/m1b-init.sh` on the first boot after switch_root.

## Layout

| path | role |
|---|---|
| `etc/conf.d/lmi-wifi` | super extents, CNSS2 timing, DHCP budgets (device specific) |
| `etc/init.d/lmi-wifi` | OpenRC service (background runner of `lmi-wifi-start`) |
| `etc/wpa_supplicant/wpa_supplicant.conf.template` | network template (PSKs injected at build time, never committed) |
| `usr/sbin/lmi-wifi-start` | linear bring-up: firmware links -> qrtr-ns -> cnss-daemon -> WLAN on -> wpa_supplicant -> DHCP, with mailbox reporting |
| `usr/sbin/m1-mailbox` | writes reports into the super mailbox (readable from Android) |
| `usr/sbin/lmi-cnss-daemon-wrapper` | runs the vendor daemon with the Android-property shim |

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
