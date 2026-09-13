# M1a 复现手册 — 全量 Alpine + Weston RAM 引导

> 状态：2026-09-14 实机验证通过（截图见 `docs/acceptance/m1a-2026-09-14/`）。
> 目标：在**不写任何分区**的前提下，把"完整 Linux 用户态 + 触摸 + 虚拟键盘"
> 通过 `fastboot boot` 跑起来（M1b 持久化前置验证）。

## 1. 产物

| 产物 | 字节数 | SHA-256 |
|---|---|---|
| `boot-m1a.img` | 162,238,464 | `ed2962222254606f34de771b9c6ee00ea9253e5e73fe8b1edb74bedf71739400` |
| `initramfs-m1.cpio.gz` | 118,098,634 | `59ec5ce704727acfc338794e0823a74f790bf287301fc17cb76c6902d23009c8` |
| `libweston-14.so.0.0.2`（补丁版） | 396,728 | `8c00072656212e5f988c57f4938bc5a74e737b776722a6836d6c9b7f9a4b2b31` |

## 2. rootfs 组成

- 基座：Alpine minirootfs **3.23.5**（清华镜像）
- weston 栈（v3.23 = 14.0.2-r4）：`weston`、`weston-backend-drm`、
  `weston-shell-desktop`、`weston-clients`、`weston-terminal`、**`libweston`**
- 运行依赖：`seatd`、`dropbear`、`iproute2`、`xkeyboard-config`、`font-dejavu`、
  `libdrm-tests`（modetest）
- **eudev**（`eudev` + `kmod-libs` + `udev-init-scripts`）：libinput 的 udev
  后端必须运行 udevd 才能枚举输入设备
- **D80 归档的 pmOS weston r10** 覆盖：`weston-14.0.2-r10.apk`、
  `weston-backend-drm`、`weston-shell-desktop`、`weston-clients`、
  `weston-terminal`（含手机布局补丁：10 列键盘适配 1080 宽屏）
- 设备配置：`etc/xdg/weston/weston.ini`（DSI-1 preferred / scale=2 /
  Virtual-1 off），来自 `device-xiaomi-lmi-1-r139.apk`
- 本项目脚本：`/init`（`tools/m1/m1-init.sh`）、`/usr/sbin/m1-weston`
  （`tools/m1/m1-weston.sh`）

## 3. 关键修补

1. **libweston 重复格式断言**：msm 驱动的 IN_FORMATS 含重复项，上游
   `weston_drm_format_array_add_format`（drm-formats.c:131）直接 `assert`，
   weston 启动即 abort。用 `tools/m1/patch-libweston.sh` 把该函数的
   `bl __assert_fail` 补丁为 NOP（与 pmOS 补丁版行为一致）。
2. **udev 缺失**：Alpine 基座没有 udevd；不启动它，weston 日志会出现
   `no input devices found`（触摸/键盘全部不可用）。init 中先启动
   `/sbin/udevd --daemon` 并 `udevadm trigger`。
3. **Weston 截图**：`weston-screenshooter` 仅在 weston 以 `--debug` 启动时
   被授权（上游策略）；headless 验证即基于此（配合 `tools/m1/utouch.c`
   经 `/dev/uinput` 注入触摸）。

## 4. 构建步骤（在手机 Termux + Debian proot 中）

```sh
# 1) 基座
curl -O https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.23/releases/aarch64/alpine-minirootfs-3.23.5-aarch64.tar.gz
mkdir rootfs && tar xzf alpine-minirootfs-3.23.5-aarch64.tar.gz -C rootfs
printf 'nameserver 223.5.5.5\n' > rootfs/etc/resolv.conf
printf 'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.23/main\nhttps://mirrors.tuna.tsinghua.edu.cn/alpine/v3.23/community\n' > rootfs/etc/apk/repositories

# 2) proot 进入 rootfs 安装
apk update
apk add dropbear seatd iproute2 xkeyboard-config font-dejavu libdrm-tests
apk add libweston weston weston-backend-drm weston-shell-desktop weston-clients weston-terminal
apk add --allow-untrusted --no-scripts --force-non-repository /path/eudev-*.apk /path/kmod-libs-*.apk /path/udev-init-scripts-*.apk

# 3) 覆盖 D80 pmOS weston r10（手机布局版）
for p in weston weston-backend-drm weston-shell-desktop weston-clients weston-terminal; do
  tar xzf /path/$p-14.0.2-r10.apk -C rootfs --overwrite
done

# 4) 补丁 libweston
tools/m1/patch-libweston.sh rootfs/usr/lib/libweston-14.so.0.0.2

# 5) 安装设备配置与本项目脚本
cp rootfs-from-device/etc/xdg/weston/weston.ini rootfs/etc/xdg/weston/weston.ini
cp tools/m1/m1-init.sh rootfs/init
cp tools/m1/m1-weston.sh rootfs/usr/sbin/m1-weston
chmod 755 rootfs/init rootfs/usr/sbin/m1-weston

# 6) 打包并合成 boot 镜像（Debian 内）
( cd rootfs && find . | cpio -o -H newc | gzip -9 ) > initramfs-m1.cpio.gz
mkbootimg --header_version 2 --pagesize 4096 \
  --kernel vmlinuz --ramdisk initramfs-m1.cpio.gz --dtb kona-v2.1-lmi.dtb \
  --cmdline "$(cat tools/m0/kernel-cmdline.txt)" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --second_offset 0x00000000 --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
  -o boot-m1a.img
```

引导：`fastboot boot boot-m1a.img`（零写入）。

## 5. 运行与验证

- 网络：NCM（172.16.42.1/24）+ `ssh root@172.16.42.1`；宿主无静态 IP 时可用
  **IPv6 链路本地**（`ping -6 ff02::1%<ifindex>` 邻居发现在线设备）。
- 屏幕验证：`XDG_RUNTIME_DIR=/run/lmi-weston weston-screenshooter`
  （weston 带 `--debug` 时才授权）。
- 交互验证（无头）：`tools/m1/utouch.c` 编译后注入触摸（点击输入框 → OSK
  弹出；点按键 → 字符插入）。

## 6. 已知问题

- weston 光标主题缺失（`could not load cursor 'dnd-*'`，触屏 UI 无影响）。
- OSK 仅在 text-input 客户端（weston-editor）聚焦时弹出；weston-terminal
  不触发（上游行为）。
- libweston 采用二进制补丁：建议后续跟随上游修复（msm 重复 IN_FORMATS）。
