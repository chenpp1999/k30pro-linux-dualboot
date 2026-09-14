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
| M2 | 🚧 v0.1 实机验收完成（部分标准） | 双向切换器；T1-03 完成并修复 recovery 引导缺陷（v7）；T2-02 5 轮零失败（负责人决定提前结束）；`docs/acceptance/m2-2026-09-14.md` |
| M3/M4 | ⬜ | 见 `docs/charter.md` |

## 二、M1b 现状（收尾项的起点）

> **2026-09-14 验收完成**：M1b 收尾项全部通过——WiFi 直连（<SSID>，
> `wpa_state=COMPLETED`，DHCP `192.168.1.x/24`，WiFi6/HE）、持久化三轮
> （boot=4→6）、USB 与局域网 SSH。当前部署 = `boot-m1b-v5.img`
> （sha256 `7658da6a…b937`）+ super 内 rootfs（修补后 sha256 `0734a5de…`）。
> 验收记录 `docs/acceptance/m1b-2026-09-14.md`；试飞手册
> `docs/m1b-wifi-runbook.md`（§0.1 结果摘要）。
>
> **收工快照（2026-09-14）**：手机已重启回 Android（adb `REDACTED` 正常，已解锁授权）；
> super 空闲区内容 = 修补后 rootfs（`0734a5de…`）；sdcard `lmi-m1b/` 新增
> `rootfs-fixed2.img`（= 当前部署）与 `rootfs-live2.img`（boot=3 现场，含运行日志）；
> 测试网：<SSID>（手机 `192.168.1.x`、电脑 `192.168.1.x`，均 DHCP）；
> Linux 登录：root / `<your-password>`（USB 侧固定 `172.16.42.1`）。

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
- **M1b 收官完成（2026-09-14 会话）**：
  1. ✅ overlay v2 / `boot-m1b-v6` 重建完成并校验：镜像 sha256 `346343b3…`
     （54,546,432 B）、overlay v2 `db760fec…`（5,991,807 B）；产物在 sdcard
     `lmi-m1b/` 与 `/data/local/lmi-dualboot/`。构建要点：`tools/m1/m1b-init.sh`
     版本常量 → `m1b-wifi-v2`；staged 树 `m1b2` 带入三个修补文件；overlay 用
     `--base-tree /root/work/m1b-old` 生成（勿用 `--base-image`，见 §五）。
  2. ✅ M2 v0.1 已实现：`tools/m1/recovery-swap.sh`（显式 BCB、全量回读校验、
     中断安全顺序、`bcb` 子命令、`switch.log`）、离线测试
     `tools/tests/m2-switch-test.sh`（CI 运行）、`docs/m2-runbook.md`、
     Magisk 骨架 `packages/magisk-module/`。
- **M2 实机验收完成（2026-09-14 会话）**：
  1. ✅ **T1-03 完成**：recovery 引导失败根因 = 镜像缺 `recovery_dtbo`
     （ABL 从该字段读 DTBO 表，读到 `ANDR` → 无 DTB → fastboot）。修复：
     `build-m1b-image.sh --recovery-dtbo`（内容=本机 dtbo 表 `32e9ba4f…`，
     487,424 B），产物升级为 **`boot-m1b-v7.img`**（sha256 `754b63b4…`，
     55,029,760 B）；ABL 日志确认 `Apply Overlay`、无 Dtbo/DTB 报错。
     BCB 结论：**ABL 不清 BCB，由 Linux init 清除**（ledger 记录 `bcb=boot-recovery`）。
  2. ✅ T2-04 中断电（写镜像阶段 SIGKILL）→ BCB 空 → 回 Android；
     ✅ T2-03 自愈（Linux 设 BCB → 重启仍进 Linux → init 清除）；
     ✅ 救援演练（损坏 v6 + BCB → fastboot → `fastboot erase misc` → Android）；
     ✅ TWRP 恢复演练（`restore-twrp` → `reboot recovery` → TWRP 3.7.1）。
  3. ⚠️ T2-02 往返：**5 轮零失败**（boot=10…14，~188 s/轮），负责人决定提前
     结束（时间成本），未跑满 20 轮；标准修订待定。证据
     `docs/acceptance/m2-2026-09-14.md`。
  4. 最终状态：手机在 Android（默认）；`recovery` = `boot-m1b-v7.img`（回读
     校验通过）；BCB 空；`boot` 分区 sha256 `8d441fc5…` 全程未变。
- **下一步（建议）**：标准修订（G2/T2-02 轮数）→ M2 Go/No-Go → M3 评估；
  遗留：T2-01（30 次重启）、T1-04（100 次重启回归）、Magisk 模块实机安装、
  Linux 启动耗时波动观察。

## 三、M2 设计要点（照 `docs/adr/0001-boot-switch-mechanism.md`；追踪 issue #15）

- Android 侧一键切换：Linux boot 镜像写入 `recovery` + 写 `misc`/BCB `boot-recovery` + reboot
- Linux 侧：启动早期清 BCB（M1b init 已实现，直接复用）→ 任意重启回 Android
- 工具基础：`tools/m1/recovery-swap.sh`（backup/to-linux/restore-twrp），M2 在其上演进
- 验收（见 `docs/test-plan.md` T2）：双向各 20 次；切换中断电；Linux 卡死强制重启；
  TWRP 恢复演练；boot 分区全程未被修改
- **v0.1 实现（2026-09-14）**：`recovery-swap.sh` 已演进——写 recovery → 全量
  sha256 回读校验 → 写 BCB（校验）→ 重启（先镜像后 BCB，缩小中断窗口）；
  `--no-reboot` 只准备不重启；`bcb show|clear|boot-recovery`；`switch.log` 证据。
  离线测试 `tools/tests/m2-switch-test.sh`（8 组，CI 运行）；手册
  `docs/m2-runbook.md`；Magisk 一键骨架 `packages/magisk-module/`。
- **实机验收（2026-09-14 完成，见 `docs/acceptance/m2-2026-09-14.md`）**：
  T1-03 完成（recovery 引导需 `recovery_dtbo`，修复产物 = `boot-m1b-v7.img`）；
  T2-04/T2-03/救援/TWRP 演练全过；T2-02 5 轮零失败（负责人决定提前结束）。

## 四、开发环境与约定

- **主环境 = 手机本机 opencode**（Debian proot 内）；**电脑 opencode 仅当 USB 工具**：
  `fastboot boot`（方法 A）、TWRP adb 写 super、大编译。
  电脑开工前 `git pull`、收工 `git push`，严禁两边并行修改同一文件
- 电脑→手机通道（2026-09-14 实测可用，手机在 Android 时）：
  `adb shell run-as com.termux <prefix>/bin/sshd` + `adb forward tcp:18022 tcp:8022`
  → `ssh -p 18022 u0_a289@localhost`；复杂命令写成脚本 scp 过去，
  用 `proot-distro login debian -- /bin/bash /root/work/<script>.sh` 执行。
  ⚠️ proot 内不要用相对 `bash`（会命中 Termux 的 bash），脚本里自带
  `PATH=/usr/sbin:/usr/bin:/sbin:/bin`。手机 GitHub 不稳时，仓库同步可用
  电脑侧 `git bundle` + scp + `git -C <repo> pull <bundle> main`。
  root 命令（rootbridge 未运行时）：`/debug_ramdisk/su -c 'sh <script>'`。
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
- **overlay 重建的 base 是树不是镜像**：v5 用的是 `--base-tree /root/work/m1b-old`；
  若用 `--base-image m1b-rootfs.img` 会得到 ~119 MB 超限 delta（镜像内容与
  `m1b2` 树差异大，64 MiB 上限直接拒绝）
- `m1b-out/vmlinuz`、`m1b-out/kona-v2.1-lmi.dtb` 符号链接已失效；内核/DTB 实际在
  `/root/work/lmi-m0/kernel/`（sha256 与 v5 buildinfo 一致）
- proot 的 fake root **不能**绕过真实文件权限：root 属主的
  `m1b-out/initramfs-root` 读不了，构建用已 chown 的 `m1b-v5-initramfs` 作基底
- `od` 会把重复行缩写成 `*`：读 BCB 等定长数据必须 `od -An -v -tx1`
  （M2 脚本已处理，勿回退）
- FIFO rootbridge 无 worker 时 `echo > .rootbridge.fifo` 会**阻塞**（写端等读者）；
  先确认 `ps | grep rootbridge` 再写
- **部署到 recovery 的镜像必须带 `recovery_dtbo`**（T1-03，2026-09-14）：ABL 的
  recovery 路径从 boot header 的该字段读 DTBO 表，缺了会读到 `ANDROID!` 魔数
  → "Dtbo hdr magic mismatch" → "Device Tree blob not found" → 落 fastboot。
  构建加 `--recovery-dtbo /root/work/dtbo-new.img`（本机 dtbo 表，487,424 B，
  sha `32e9ba4f…`）；RAM 引导（方法 A）不需要。
- **Debian 版 `mkbootimg` 真除 bug**：`get_number_of_pages` 用了 `/` 产生 float，
  带 `--recovery_dtbo` 时 `pack('Q')` 报 struct.error；需
  `sed -i 's|) / page_size|) // page_size|' /usr/bin/mkbootimg`（环境修复，
  不入仓；build 脚本已加 `--recovery-dtbo` 透传）。
- **adb forward 到 run-as 启动的 Termux sshd 会被拒**（SELinux/上下文）；
  用 WiFi `ssh -p 8022`（需 Termux 本体启动 sshd）或 `adb shell run-as com.termux
  <cmd>` 直跑；root 用 `run-as com.termux /debug_ramdisk/su -c '<cmd>'`。
- fastboot/TWRP 之后 **USB 常需重新插拔**才会重新枚举（电脑侧 adb/fastboot 都看不到时先重插）。
- Linux 启动到 SSH 可达的耗时偶发变长（最长 ~6–10 分钟，NCM 宿主侧枚举慢为主因），
  自动化轮询超时给足（≥5 分钟）。
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

## 七、新会话开工清单（换会话时照此交接）

本仓库刻意不依赖会话记忆：新会话拿到仓库 + 下列三步即可完整接手。

1. **同步**：电脑侧 `git pull --ff-only`；手机侧仓库（`/root/work/k30pro-linux-dualboot/`）
   同样先 pull（GitHub 不稳时用 `git bundle` + scp，见 §四）。当前 tip ≥ `3701751`
   （T1-03 修复；本次验收文档提交在其后，以 `git log` 为准）。
2. **阅读顺序**：`AGENTS.md` → `docs/ai-protocol.md` → 本文 → 按任务进
   `docs/acceptance/m2-2026-09-14.md` / `docs/m2-runbook.md` /
   `docs/m1b-persistent.md` / `docs/m1b-wifi-runbook.md`。
3. **开工前检查**：open issues（`[VFY]` 开头 = 独立验证者产出，按协议评论
   `Resolved-by:`）；`git log --oneline -10` 对照本文"下一步"。

可直接粘贴给新会话的交接提示词：

> 你在开发仓库 `k30pro-linux-dualboot`（Redmi K30 Pro 双系统）。
> 先读 `AGENTS.md` → `docs/ai-protocol.md` → `docs/handoff.md`，然后 `git pull`
> 并确认 HEAD 与 `origin/main` 一致（≥ `3701751`）。
> 当前状态：M0/M1（含 M1b）已实机验收；M2 v0.1 已实机验收（T1-03 完成，修复
> recovery 引导缺陷 → `boot-m1b-v7.img` 部署在 recovery；T2-02 5 轮零失败；
> 故障场景/TWRP 演练全过；见 `docs/acceptance/m2-2026-09-14.md`）。手机当前在
> Android（默认）；BCB 空；`boot` 分区未动。
> 任务：先读验收记录与 handoff §二/§三 的遗留项（标准修订、T2-01/T1-04、Magisk
> 模块实机、Linux 启动耗时观察），与负责人确认 M2 Go/No-Go 后再进入 M3。
> 收到后先复述计划再动手。
