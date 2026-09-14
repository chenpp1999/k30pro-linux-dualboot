# 开发交接（Handoff）— 2026-09-14

> 给接手本项目的 AI 会话/开发者：按 `AGENTS.md` → `docs/ai-protocol.md` → 本文 的顺序阅读，
> 再按需深入 `docs/` 其他文档。所有结论以仓库与 `/root/SERVER_NOTES.md`（第 14、15 节）为准，
> 不依赖任何会话记忆。

## 一、当前状态

| 里程碑 | 状态 | 备注 |
|---|---|---|
| M0 | ✅ 已验收（2026-09-13，方式 A） | A1–A5 全过；证据 `docs/acceptance/m0-2026-09-13/` |
| M1a | ✅ 完成 | Alpine+Weston RAM 全量 bring-up（触摸+虚拟键盘）；`docs/m1a-ramboot.md`、证据 `docs/acceptance/m1a-2026-09-14/` |
| M1b | 🔄 收尾中 | 持久 rootfs 已写入 super 空闲区并可引导（OpenRC+Weston 真机运行）；剩 SSH/持久化测试 |
| M2 | ⬜ 未开始 | 双向切换器 v0.1 |
| M3/M4 | ⬜ | 见 `docs/charter.md` |

## 二、M1b 现状（收尾项的起点）

- **存储**：1.5 GiB ext4 rootfs 镜像写入 `super`（`/dev/block/sda32`）空闲区：
  - 偏移 6,540,705,792 B（= 4K 单元 1,596,852，cmdline `lmi_root_off=1596852`）
  - **不修改 super 元数据**；Android 完全无感、可回滚
- **引导链**：`boot-m1b.img`（小 RAM initramfs）→ 清 BCB → NCM gadget →
  `losetup -o <offset>` 挂载 super 内 ext4 → switch_root → OpenRC（udev/seatd/dropbear/weston）
- **产物**：`/sdcard/Download/phone-server/lmi-m1b/rootfs.img`、`boot-m1b.img`（含 .sha256）
- **设备限制（issue #13）**：Android 用户态写 super 被内核 `baseband_guard` 拒绝；
  写入必须走 **TWRP**（电脑 adb）或 **Linux 环境**
- **回滚**：不再引导即可；或在 TWRP 中将该区域清零（见 `docs/m1b-persistent.md`）；
  super 元数据备份 `/sdcard/Download/phone-server/backup/super-metadata.bin`
- **待办（建议顺序）**：
  1. **WiFi 直连**：给 rootfs 增加 ath11k/qca6391 固件与 wpa_supplicant 配置，
     Linux 启动即连路由器 → 摆脱"必须有 USB 主机"的限制
  2. 持久化读写测试（写入 → 重启 → 校验，≥3 轮）
  3. SSH 验收（WiFi 后从局域网 OPPO 直连）
  4. 更新 `docs/m1b-persistent.md` 与 README 状态

## 三、M2 设计要点（照 `docs/adr/0001-boot-switch-mechanism.md`）

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
- **关机冷启动会卡 Redmi logo 4–5 分钟**：ABL 开机震动反馈在坏芯片上重试（硬件问题，
  不可软件修复）；日常用"重启"（SERVER_NOTES 第 15 节）
- Magisk 覆盖 init `.rc` 无效（init 解析早于 Magisk 挂载）——勿再尝试
- FIFO rootbridge 的引号/括号坑；`am` / `pm grant` 类命令会杀 Termux
- 开工前检查 open issues（`[VFY]` 开头为独立验证者产出），按 `docs/ai-protocol.md` 回应

## 六、与"开机优化"的关系

开机优化（dtbo 禁用 aw8697、关闭 traced、keymaster sleep 调查）已完成并记录于
`/root/SERVER_NOTES.md` 第 15 节与 `/sdcard/Download/phone-server/lmi-bootdiag/`。
与双系统项目相互独立，**勿重做**。
