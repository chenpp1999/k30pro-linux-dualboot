# 在设备上重建 M1b 引导镜像（不依赖 Android/fastboot/USB 主机）

> 2026-09-15 首次落地并实机验证（v9 由本流程生成，自检全绿）。
> 适用：只需更新 overlay/initramfs 内容（例如换键盘/字体/配置），**内核、DTB、
> cmdline、DTBO 表沿用当前部署版本**的场合。需要改内核/DTB 时仍走原 Debian 侧
> 构建链（`tools/m1/build-m1b-image.sh` + 上游产物）。

## 1. 原理

当前部署在 `recovery` 分区里的该镜像**本身就是全部输入**：

| 输入 | 从当前镜像取得 |
|---|---|
| kernel / DTB / cmdline / recovery_dtbo | `unpack`（按 boot header v2 解析，见脚本内嵌 Python） |
| initramfs 底座（busybox、目录骨架） | ramdisk 解包（`gzip -dc | cpio -idmu`） |
| overlay 内容 | 仓库 `tools/m1/m1b/`（**空基线**→全量 payload，见 §3） |
| 打包 | `mkbootimg`（AOSP/LineageOS 的 `mkbootimg.py`，设备侧只用于打包） |

流程：读取 `recovery` 分区首部的 boot header 算出镜像长度 → `dd` 出镜像 →
解包 → 用当前 initramfs 底座 + 新 overlay 重新生成 ramdisk → `mkbootimg` 打包 →
**自检**（解包新镜像，比对 kernel/DTB/DTBO/cmdline 与源镜像逐字节一致、overlay
版本正确、init/busybox 存在）。

## 2. 前置条件（全部在手机 Linux rootfs 内）

- `tools/m1/rebuild-image-from-device.sh`（本流程）、`build-m1b-image.sh`、
  `mk-overlay.py`、`m1b-init.sh`、`tools/m1/m1b/**`（payload）
- `mkbootimg.py`：设备无外网时从电脑 push（`lcp.py`）；**注意取 Android 11/12 时代
  的单文件版本**（LineageOS `lineage-19.1` 可用；A15 版会 `from gki...` 依赖缺失）
- `cpio`（**GNU cpio**，rootfs 自带 `/usr/bin/cpio`）、`gzip`、`python3`、`dd`
- root 权限、`recovery` 分区节点（Linux 侧为 `/dev/sda28`，128 MB）

## 3. overlay 是全量 payload（不是 delta）

`build-m1b-image.sh` 在没有 `--base-image/--base-tree` 时会**删除** initramfs 里
已有的 `m1b-overlay.tar.gz` 且不重建——必须显式给基线：

```
--tree tools/m1/m1b --base-tree <空目录> --overlay-out <输出>
```

空基线使 `mk-overlay.py` 把 payload 全量打包（本次 ≈ 9.8 MB / 33 文件），这样
**任何**旧版本（v1/v2/…）的设备应用 `m1b-ux-v5` 都能一次拿到全部 UX 资产。
（overlay 版本是"一次性应用"标记，跨版本跳跃不会被中间的 overlay 补齐。）

## 4. 使用

```
# 在手机 Linux（root）：
cd <repo>
sh tools/m1/rebuild-image-from-device.sh --mkbootimg /root/mkbootimg.py
#   --dev /dev/sda28        源分区（默认）
#   --image <file>          改用镜像文件
#   --version m1b-ux-v5     overlay 版本（默认）
#   --out boot-m1b-v9.img   输出名
#   --work /root/m1b-rebuild
#   --no-roundtrip          跳过"重打包体积一致性"检查
#   --dry-run               只校验源镜像并打印长度
```

产物：`<work>/boot-m1b-v9.img` + `.sha256` + `.buildinfo`（记 kernel/dtb/dtbo
sha256、overlay 版本、各段字节数）。

自检项（任一失败即拒绝出产）：
1. kernel / DTB / recovery_dtbo 与源镜像同名段 sha256 一致；
2. cmdline 一致；
3. 新 ramdisk 内 `m1b-overlay.tar.gz` 存在且 `etc/m1b-overlay-version` == 期望版本；
4. `init`、`bin/busybox` 存在。

## 5. 部署（单独、可审阅的一步）

```
# 手机 Linux（root）：
dd if=<work>/boot-m1b-v9.img of=/dev/sda28 bs=1M && sync
```

- **协议差异**：M1b/M2 部署流程要求先 `fastboot boot`（方式 A）验证；设备侧
  `dd` 跳过该门禁。可接受的理由：本流程产物的 kernel/DTB/DTBO/cmdline 与**已在
  实机验证过的当前镜像逐字节一致**，差异只在 ramdisk（overlay 内容已在设备上
  live 验证）。是否跳过由负责人决定；不做则镜像仅作为产物保留。
- **回滚**：`dd` 之前先 `dd if=/dev/sda28 of=old.img bs=1M count=58`（或直接用
  流程里的 `--work/source.img`，它就是当前镜像）；回滚即 `dd if=source.img of=/dev/sda28`。
- 部署后从 Linux 重启即可再次进入 Linux（`reboot`）；要验证新 overlay：
  Linux rootfs 的 `etc/m1b-overlay-version` 应为新版本，且
  `etc/m1b-overlay.manifest` 记录了文件清单。
- 注意：设备**已在运行**的 rootfs 不会因重刷 recovery 变化（overlay 在启动时按
  版本一次性应用）；recovery 镜像只影响"下一次从 recovery 引导/全新部署"。

## 6. 本次结果（2026-09-15）

| 项 | 值 |
|---|---|
| 产物 | `boot-m1b-v9.img`，58,634,240 B |
| sha256 | `f7fb31670dea491e31e0ea5615fa127428e257ef0c606bd3dccfa6716a52ed8d` |
| overlay | `m1b-ux-v5`（9,822,534 B，33 文件/19 目录，全量 payload） |
| kernel / dtb | `4583ada3…` / `aee89cc1…`（与 v8 相同） |
| recovery_dtbo | `32e9ba4f…`（487,424 B，与 v8 相同） |
| initramfs | 14,007,318 B（含 overlay、init、busybox） |
| 源镜像 | recovery 分区（v8，`4b2ce34b…`，58,064,896 B） |
| 位置 | 手机 `/root/m1b-rebuild/boot-m1b-v9.img`（未部署） |

## 7. 已知坑

- `build-m1b-image.sh` 用 `command -v mkbootimg` 找命令 → 本流程会生成一个
  `$WORK/bin/mkbootimg` shim（转发到 `python3 mkbootimg.py`）并加到 PATH。
- A15 版 `mkbootimg.py` 顶层 `from gki.generate_gki_certificate import ...` 会
  直接 ImportError（缺同目录模块）→ 用 lineage-19.1 版，或补 `gki/` 目录。
- busybox/GNU cpio 的成员名不带 `./` 前缀；自检改为**整包解出**再检查，避免
  模式匹配差异（曾误报 overlay/busybox 缺失）。
- 设备侧没有 `fastboot`，方式 A（RAM 引导验证）无法在本流程内完成；不要把它当作
  已通过方式 A。
