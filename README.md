# k30pro-linux-dualboot

**Fail-safe dual boot for Xiaomi Redmi K30 Pro / POCO F2 Pro (`lmi`) — Android first, Linux sandboxed.**

为小米 Redmi K30 Pro / POCO F2 Pro（代号 `lmi`，Qualcomm SM8250）提供故障安全的
Android + 真 Linux（postmarketOS / Mobian）双系统方案。

> ⚠️ **实验性项目，当前处于 Phase 0（立项）阶段。** 涉及引导与分区修改，
> 操作不当可能丢失数据。请先读完文档并做好备份。

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
| M0 | 非破坏 bring-up：`fastboot boot` RAM 启动 Linux | 🔄 产物已构建，待部署 |
| M1 | 低风险持久化：super 空闲空间 + recovery 分区安装 | ⬜ |
| M2 | 双向切换器 v0.1（BCB 一次性引导 + 自动回退） | ⬜ |
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

## 许可证

- 工具链、脚本、App：MIT，见 [LICENSE](LICENSE)
- 内核相关补丁 / DTS：GPL-2.0-only（沿用 Linux 内核许可）

## 免责声明

刷机有风险，请在生产使用前完整阅读文档并备份数据。项目不对任何数据丢失或
硬件损坏负责。
