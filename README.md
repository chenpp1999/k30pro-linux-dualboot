# k30pro-linux-dualboot

**Fail-safe dual boot for Xiaomi Redmi K30 Pro / POCO F2 Pro (`lmi`) — Android first, Linux sandboxed.**

为小米 Redmi K30 Pro / POCO F2 Pro（代号 `lmi`，Qualcomm SM8250）提供故障安全的
Android + 真 Linux（postmarketOS / Mobian）双系统方案。

> ⚠️ **实验性项目，当前处于 M2 阶段（M0/M1 已实机验收）。** 涉及引导与分区修改，
> 操作不当可能丢失数据。请先读完文档并做好备份。

## 构建依赖（G5 可复现性）

在 Linux/arm64 环境（本项目在手机 Termux + proot Debian 内构建）需要：

| 工具 | 用途 | 备注 |
|---|---|---|
| `gcc` | 静态编译 eventdump/display | 需 `libdrm-dev` 头（display） |
| `busybox` | initramfs 基础 | 优先 `busybox-static`；动态版会自动随带库（#8） |
| `dropbear` | initramfs SSH | 动态版随带库 |
| `cpio` + `gzip` | initramfs 打包 | 打包已做确定性处理（`sort` + `gzip -n`） |
| `mkbootimg` | boot 镜像合成 | 需支持 `--header_version 2`；路径/大小记录在构建日志 |
| `curl` | 上游产物获取 | sha256 固定校验 |

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
| M0 | 非破坏 bring-up：`fastboot boot` RAM 启动 Linux | ✅ 2026-09-13 方式 A 实机验收 A1–A5 全过（显示为色条接管；完整 UI 属 M1） |
| M1 | 低风险持久化：super 空闲空间 + recovery 分区安装 | ✅ M1a 完成；**M1b 已验收**（持久 rootfs + WiFi 直连 + 持久化 3 轮 + USB/局域网 SSH；证据 [M1b 验收记录](docs/acceptance/m1b-2026-09-14.md)） |
| M2 | 双向切换器 v0.1（BCB 一次性引导 + 自动回退） | 🚧 v0.1 已实现（离线测试通过），实机验收待做；手册 [M2 切换器](docs/m2-runbook.md) |
| M3 | 可选扩容工具 `lmi-repart`（userdata 尾部缩容） | ⬜ |
| M4 | v1.0 公开发布 | ⬜ |

## 文档

- [立项书](docs/charter.md)
- [可行性研究](docs/feasibility.md)
- [系统架构](docs/architecture.md)
- [风险台账](docs/risk-register.md)
- [测试计划](docs/test-plan.md)
- [ADR-0001 启动切换机制](docs/adr/0001-boot-switch-mechanism.md)
- [M0 操作手册](docs/m0-runbook.md)
- [M0 验收记录（2026-09-13）](docs/acceptance/m0-2026-09-13.md)
- [M1a 复现手册（RAM 全量 Linux + Weston）](docs/m1a-ramboot.md)
- [M1a 验收记录（2026-09-14）](docs/acceptance/m1a-2026-09-14.md)
- [M1b 持久化 rootfs 设计与实录](docs/m1b-persistent.md)
- [M1b WiFi 试飞手册（boot-m1b-v5/v6）](docs/m1b-wifi-runbook.md)
- [M1b 验收记录（2026-09-14）](docs/acceptance/m1b-2026-09-14.md)
- [M2 双向切换器手册与验收流程](docs/m2-runbook.md)
- [开发交接（handoff）](docs/handoff.md)

## 许可证

- 工具链、脚本、App：MIT，见 [LICENSE](LICENSE)
- 内核相关补丁 / DTS：GPL-2.0-only（沿用 Linux 内核许可）

## 免责声明

刷机有风险，请在生产使用前完整阅读文档并备份数据。项目不对任何数据丢失或
硬件损坏负责。
