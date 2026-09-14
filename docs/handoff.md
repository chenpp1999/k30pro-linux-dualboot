# 开发交接（Handoff）— 2026-09-14

> 给接手本项目的 AI 会话/开发者：按 `AGENTS.md` → `docs/ai-protocol.md` → 本文 的顺序阅读，
> 再按需深入 `docs/` 其他文档。所有结论以仓库与 `/root/SERVER_NOTES.md`（第 14、15 节）为准，
> 不依赖任何会话记忆。

## 一、当前状态

| 里程碑 | 状态 | 备注 |
|---|---|---|
| M0 | ✅ 已验收（2026-09-13，方式 A） | A1–A5 全过；证据 `docs/acceptance/m0-2026-09-13/` |
| M1a | ✅ 完成 | Alpine+Weston RAM 全量 bring-up（触摸+虚拟键盘）；`docs/m1a-ramboot.md`、证据 `docs/acceptance/m1a-2026-09-14/` |
| M1b | ✅ 已验收（2026-09-14） | 持久 rootfs（super 空闲区）+ WiFi 直连 + 持久化 3 轮 + USB/局域网 SSH；`docs/acceptance/m1b-2026-09-14.md` |
| M2 | ⬜ 未开始 | 双向切换器 v0.1；接手先做"overlay v2 / boot-m1b-v6 重建"（见 §二末） |
| M3/M4 | ⬜ | 见 `docs/charter.md` |

## 二、M1b 现状（收尾项的起点）

> **2026-09-14 验收完成**：M1b 收尾项全部通过——WiFi 直连（<SSID>，
> `wpa_state=COMPLETED`，DHCP `192.168.1.x/24`，WiFi6/HE）、持久化三轮
> （boot=4→6）、USB 与局域网 SSH。当前部署 = `boot-m1b-v5.img`
> （sha256 `7658da6a…b937`）+ super 内 rootfs（修补后 sha256 `0734a5de…`）。
> 验收记录 `docs/acceptance/m1b-2026-09-14.md`；试飞手册
> `docs/m1b-wifi-runbook.md`（§0.1 结果摘要）。

- **存储**：1.5 GiB ext4 rootfs 镜像写入 `super`（`/dev/block/sda32`）空闲区：
  - 偏移 6,540,705,792 B（= 4K 单元 1,596,852，cmdline `lmi_root_off=1596852`）
  - **不修改 super 元数据**；Android 完全无感、可回滚
  - mailbox 上报区：rootfs 后 1 MiB 起（super 4K 块 1,990,324 起），
    仅供 initramfs/rootfs 写、Android 只读（`dd` + `strings`）
- **引导链**：`boot-m1b.img`（小 RAM initramfs）→ 清 BCB → NCM gadget →
  `losetup -o <offset>` 挂载 super 内 ext4 → 应用 overlay（一次性）→ switch_root
  → OpenRC（udev/seatd/dropbear/weston/lmi-wifi）
- **产物**：`/sdcard/Download/phone-server/lmi-m1b/rootfs.img`、`boot-m1b.img`、
  `boot-m1b-v5.img`（含 .sha256/.buildinfo）、`m1b-overlay-v1.tar.gz`
- **设备限制（issue #13）**：Android 用户态写 super 被内核 `baseband_guard` 拒绝；
  写入必须走 **TWRP**（电脑 adb）或 **Linux 环境**
- **回滚**：不再引导即可；或在 TWRP 中将该区域清零（见 `docs/m1b-persistent.md`）；
  super 元数据备份 `/sdcard/Download/phone-server/backup/super-metadata.bin`
- **M1b 已完成（issue #14，2026-09-14）**：
  1. WiFi 直连：下游 CNSS2 + qcacld（本内核无 ath11k）+ qrtr-ns +
     vendor cnss-daemon + wpa_supplicant + udhcpc；实测 `wpa_state=COMPLETED`、
     DHCP 与 WiFi6/HE 速率
  2. 持久化读写 3 轮：`/root/m1b-persist.log`（boot=4→5→6）与引导账本
     `/root/m1b-boots.log`
  3. SSH 验收：USB（`172.16.42.1`）与局域网（`192.168.1.x`）均通过
  4. 修复入仓：dropbear 依赖链 `need net`→`use net`、wpa `-f`→`2>>` 重定向；
     新增 `tools/m1/patch-rootfs-image.sh`（离线修补，含 journal 回放）
- **下一步（M1b 收官 → M2 准备，建议顺序）**：
  1. 重建 overlay v2 / `boot-m1b-v6`：把修补后的三个文件放入 overlay 树，
     使"镜像 + overlay"链路与仓库一致（v5 内嵌 overlay v1 仍含旧
     `lmi-wifi-start`，仅首启应用、不影响已部署设备）
  2. M2 双向切换器 v0.1（见 §三）

## 三、M2 设计要点（照 `docs/adr/0001-boot-switch-mechanism.md`；追踪 issue #15）

- Android 侧一键切换：Linux boot 镜像写入 `recovery` + 写 `misc`/BCB `boot-recovery` + reboot
- Linux 侧：启动早期清 BCB（M1b init 已实现，直接复用）→ 任意重启回 Android
- 工具基础：`tools/m1/recovery-swap.sh`（backup/to-linux/restore-twrp），M2 在其上演进
- 验收（见 `docs/test-plan.md` T2）：双向各 20 次；切换中断电；Linux 卡死强制重启；
  TWRP 恢复演练；boot 分区全程未被修改

## 四、开发环境与约定

- **主环境 = 手机本机 opencode**（Debian proot 内）；**电脑 opencode 仅当 USB 工具**：
  `fastboot boot`（方法 A）、TWRP adb 写 super、大编译。
  电脑开工前 `git pull`、收工 `git push`，严禁两边并行修改同一文件
- root 通道：
  `echo '命令' > /data/data/com.termux/files/home/.rootbridge.fifo`，结果读 `~/.rootbridge.log`
  ⚠️ 命令勿含英文括号、勿过长；复杂命令写成脚本文件再执行（SERVER_NOTES 第 3 节）
- 部署工具：`/data/data/com.termux/files/home/recovery-swap.sh`
- 构建工具（Debian 内）：`mkbootimg`、`gcc`、`dtc`（`LD_LIBRARY_PATH=/tmp/opencode/libs`）、`cpio`
- 开机诊断钩子：`/data/adb/post-fs-data.d/00-capture.sh`、`service.d/00-boot-capture.sh`
  → 每次开机导出 dmesg/boottime 到 `/data/local/tmp/boot-capture-early.txt`
- 备份：`/sdcard/Download/phone-server/`（boot/recovery/TWRP/dtbo/super 元数据均在内）

## 五、已知坑（不要重复踩）

- `baseband_guard` 禁止 Android 写 super（issue #13）
- **离线修补 rootfs 镜像必须先回放 journal**：从分区 dump 的 ext4 若带未回放
  journal，debugfs 直写后任何 `e2fsck -fy` 会先回放 journal、**静默回滚**修补
  （实测 `conf.d/dropbear` 被截断成 190 B）；正确顺序见
  `docs/m1b-persistent.md` §6，工具 `tools/m1/patch-rootfs-image.sh`
- **关机冷启动会卡 Redmi logo 4–5 分钟**：ABL 开机震动反馈在坏芯片上重试（硬件问题，
  不可软件修复）；日常用"重启"（SERVER_NOTES 第 15 节）
- Magisk 覆盖 init `.rc` 无效（init 解析早于 Magisk 挂载）——勿再尝试
- FIFO rootbridge 的引号/括号坑；`am` / `pm grant` 类命令会杀 Termux
- 开工前检查 open issues（`[VFY]` 开头为独立验证者产出），按 `docs/ai-protocol.md` 回应

## 六、与"开机优化"的关系

开机优化（dtbo 禁用 aw8697、关闭 traced、keymaster sleep 调查）已完成并记录于
`/root/SERVER_NOTES.md` 第 15 节与 `/sdcard/Download/phone-server/lmi-bootdiag/`。
与双系统项目相互独立，**勿重做**。
