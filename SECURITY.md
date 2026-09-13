# 安全与风险声明

本项目的"安全"主要指标是**数据安全与设备可恢复性**，其次才是传统信息安全。

## 使用前必读

- 本项目处于实验阶段。执行任何写分区操作前，必须完整备份（boot、recovery、
  分区表 / GPT、Android 用户数据）。
- 永远保留一条可回滚路径，并事先验证过它有效。
- 只在通过门禁评审的里程碑上执行对应风险级别的操作，见
  [docs/charter.md](docs/charter.md) 与 [docs/test-plan.md](docs/test-plan.md)。

## 报告问题

如发现可能导致数据丢失、无法开机、启动循环等问题：

1. 不要公开披露可利用细节，先发私密报告或直接联系仓库所有者；
2. 附上设备型号、ROM 版本、复现步骤、consequence（后果）与现场日志；
3. 若涉及上游组件（postmarketOS / mainline / pmOS 生态），同时通知对应上游。

## 支持范围

仅支持 Xiaomi Redmi K30 Pro / POCO F2 Pro（`lmi`），且仅支持文档中列明的
ROM 与版本组合。其他环境不在支持范围内。
