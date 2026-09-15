# k30pro-linux-dualboot

**Fail-safe dual boot for Xiaomi Redmi K30 Pro / POCO F2 Pro (`lmi`) — Android first, Linux sandboxed.**

为小米 Redmi K30 Pro / POCO F2 Pro（代号 `lmi`，Qualcomm SM8250）提供故障安全的
Android + 真 Linux（Alpine/OpenRC + Weston）双系统方案。

> ⚠️ **实验性项目，当前处于 M4（v1.0 发布）。** M0–M3 均已实机验收。涉及引导与分区修改，
> 操作不当可能丢失数据。请先读完文档并做好备份。

> ℹ️ **设备镜像是私有的**：引导镜像 / rootfs 内含按本机注入的 WiFi 凭据与设备序列号，
> **不随仓库或 Release 分发**；请按 [复现指南](docs/reproduce.md) 自行构建。

> ⚠️ **想一键安装？先读 [一键安装说明（含风险提示）](docs/install-guide.md)。**
> 会覆盖 `recovery`、写入 `super` 空闲区、可能需要解锁 Bootloader（清数据）；
> **尚未真机验证，请在测试机/已全量备份的设备上操作，风险自负。**

## 核心理念

1. **Android first**：`boot` 分区永不改动；正常重启、断电、强制重启永远回到 Android。
2. **Linux sandboxed**：Linux 引导镜像装在 `recovery` 分区，经一次性引导标记
   （misc/BCB）进入；Linux 根文件系统位于独立空间。Linux 崩溃、卡死、被玩坏，
   都只影响它自己。
3. **Recoverable by design**：一切破坏性操作必须有 dry-run、备份和回滚；
   按"零风险 → 低风险 → 可选高风险"三级推进，逐级验证。
4. **Upstream friendly**：复用并回馈 postmarketOS / mainline Linux 生态。

## 里程碑

| 阶段 | 交付 | 状态 |
|---|---|---|
| Phase 0 | 立项文档（Charter / 可行性 / 风险 / ADR / 测试计划） | ✅ 完成 |
| M0 | 非破坏 bring-up：`fastboot boot` RAM 启动 Linux | ✅ 2026-09-13 方式 A 验收 A1–A5 |
| M1 | 低风险持久化：super 空闲空间 + recovery 分区安装 | ✅ M1a/M1b 验收（持久 rootfs + WiFi 直连 + 3 轮持久化 + USB/LAN SSH） |
| M2 | 双向切换器 v0.1（BCB 一次性引导 + 自动回退） | ✅ 实机验收（往返 5 轮零失败 + 故障/救援/TWRP 演练；`recovery_dtbo` 缺陷已修） |
| Linux UX | 桌面可用性 + 中文输入法 + 快捷键栏 + 电源温控监控 | ✅ 实机验证（[UX 验收](docs/acceptance/ux-2026-09-15.md)、[温控充电](docs/m1b-thermal-charging.md)） |
| M3 | 可选扩容工具 `lmi-repart`（userdata 缩容 + `lnx` 新建） | ✅ **已在本机执行**：userdata 107→91 GiB + `lnx` 16 GiB，rootfs 迁入并启动（[M3 验收](docs/acceptance/m3-2026-09-15.md)） |
| M4 | v1.0 公开发布 | 🚧 进行中（[发布说明](docs/release-v1.0.0.md)、[复现指南](docs/reproduce.md)） |
| M5 | 一键安装（PC 脚本 + 通用镜像） | 🚧 PC 一键已实现（[安装说明](docs/install-guide.md)、[设计](docs/installer-design.md)）；离线模拟全绿，**真机端到端待验证** |

## 现在能做什么

> 日常怎么用（切系统、连 WiFi、看监测台、充电保护、中文输入…）见
> **[使用说明书 docs/usage.md](docs/usage.md)**。

- **Android 一键切 Linux**：Magisk 模块 `lmi-dualboot-switch`（[包与说明](packages/magisk-module/)），
  自动挑最新镜像、校验后写 BCB 重启；不一致时走带 attestation 门禁的完整流程。
- **Linux 正常桌面**：Weston 面板（时间 + 电量）、启动器、终端、WiFi 扫描/连接 CLI。
- **中文输入**：屏幕键盘拼音页 + 候选条（431 音节 / 19631 字 / 18130 词），终端可直接上屏。
- **快捷键栏**：Esc/Tab/Ctrl/Alt/方向/Home/End/PgUp/PgDn，Ctrl、Alt 支持一次锁定。
- **按键与息屏**：音量键调背光、电源键开关屏、空闲自动灭屏。
- **长期插电保护**：充电停在 80 %/恢复 70 %、42/38 °C 温度门限、卡死保护、24 h 安全阀；
  CPU governor 由 `performance` 改为 `schedutil` 降温。
- **可观测**：`lmi-status` 一屏摘要；`lmi-monitor` 60 s 采样 + CSV 落盘 + 内网面板 `:8080`。

## 构建依赖（G5 可复现性）

在 Linux/arm64 环境（本项目在**手机 Linux 侧原生**构建；内核相关镜像构建另需 Android 侧）需要：

| 工具 | 用途 | 备注 |
|---|---|---|
| `gcc` | 静态编译 eventdump/display、`lmi-keys`、weston 客户端补丁 | **weston 客户端必须在设备内原生编译**（WSL/proot 产物会 SIGSEGV） |
| `meson` + `ninja` | 编译打了补丁的 weston 客户端 | 必须 `-Dprefix=/usr`；补丁用 `-p0` |
| `busybox` | initramfs 基础 | 优先 `busybox-static` |
| `dropbear` | initramfs / rootfs SSH | 动态版随带库 |
| `cpio` + `gzip` | initramfs 打包 | 确定性处理（`sort` + `gzip -n`） |
| `mkbootimg` | boot 镜像合成 | **必须 LineageOS `lineage-19.1` 版**（A15 版 ImportError）；需 `--header_version 2` |
| `sgdisk` / `resize.f2fs` / `fsck.f2fs` | M3 扩容（可选、有风险） | 缩容**必须** `resize.f2fs -s` |
| `python3` + `curl` | 词典生成 / 上游产物获取（sha256 固定校验） | |

详细步骤见 [复现指南](docs/reproduce.md)。

## 文档

**总览**
- [立项书（Charter）](docs/charter.md) · [可行性研究](docs/feasibility.md) ·
  [系统架构](docs/architecture.md) · [风险台账](docs/risk-register.md) ·
  [测试计划](docs/test-plan.md) · [ADR-0001 启动切换机制](docs/adr/0001-boot-switch-mechanism.md)
- [开发交接（Handoff）](docs/handoff.md) ← **新会话从这里开始**
- [一键安装说明（含风险提示）](docs/install-guide.md) ← **要装系统先看这份**
- [使用说明书（日常操作）](docs/usage.md) ← **装好之后看这份**
- [复现指南（G5）](docs/reproduce.md) · [v1.0 发布说明](docs/release-v1.0.0.md) ·
  [AI 协作协议](docs/ai-protocol.md)

**分阶段手册**
- [M0 操作手册](docs/m0-runbook.md) · [M1a 复现手册](docs/m1a-ramboot.md) ·
  [M1b 持久化设计](docs/m1b-persistent.md) · [M1b WiFi 试飞](docs/m1b-wifi-runbook.md) ·
  [M2 切换器手册](docs/m2-runbook.md) · [M3 扩容方案](docs/m3-repart-plan.md) ·
  [M5 一键安装设计](docs/installer-design.md)
- [设备侧镜像重建（不需 Android/fastboot）](docs/m1b-rebuild-on-device.md) ·
  [温控/充电/长期监控](docs/m1b-thermal-charging.md)

**验收记录**
- [M0](docs/acceptance/m0-2026-09-13.md) · [M1a](docs/acceptance/m1a-2026-09-14.md) ·
  [M1b](docs/acceptance/m1b-2026-09-14.md) · [M2](docs/acceptance/m2-2026-09-14.md) ·
  [M3](docs/acceptance/m3-2026-09-15.md) · [UX/输入法/温控](docs/acceptance/ux-2026-09-15.md)

**调研/计划**
- [Linux 适配全面审查](docs/linux-ux-audit-2026-09-14.md) ·
  [UX 优化实施计划](docs/linux-ux-plan-2026-09-14.md) · `docs/research/`

## 许可证

- 工具链、脚本、App：MIT，见 [LICENSE](LICENSE)
- 内核相关补丁 / DTS：GPL-2.0-only（沿用 Linux 内核许可）
- 中文词典数据：拼音数据 MIT、`rime-essay-simp`/`rime-luna-pinyin` LGPL-3.0、
  CC-CEDICT CC BY-SA 4.0（见 `tools/m1/ime/README.md`）

## 免责声明

刷机有风险，请在生产使用前完整阅读文档并备份数据。项目不对任何数据丢失或
硬件损坏负责。
