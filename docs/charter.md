# 立项书 — k30pro-linux-dualboot

| 项目 | 内容 |
|---|---|
| 项目代号 | k30pro-linux-dualboot |
| 目标设备 | Xiaomi Redmi K30 Pro / POCO F2 Pro（`lmi`，SM8250） |
| 负责人 | chenpp1999 |
| 立项日期 | 2026-09-13 |
| 状态 | Draft（待负责人批准） |

## 1. 背景与问题

- 现有 lmi 已作为 7×24 手机服务器运行（Termux + proot Debian），但 proot
  环境无法运行 Docker、完整 systemd 等，需要"真 Linux"。
- lmi 已有成熟的社区 mainline 移植（显示 / 触屏 / WiFi / 蓝牙 / 音频 / GPU /
  传感器可用，见 [feasibility.md](feasibility.md)），但官方 postmarketOS
  尚无 `device-xiaomi-lmi` 设备包，也没有任何双系统方案。
- 直接刷单系统（pmOS 安装到 userdata）会摧毁现有 Android、手机功能与服务器
  环境，不可接受。

## 2. 目标（可度量）

- **G1 Android 永远可回退**：所有交付版本中，正常重启 / 断电强制重启 100%
  回到 Android（验收：连续 100 次重启 + 断电演练）。
- **G2 一键切换**：Android 端一次操作进入 Linux；Linux 端重启自动回 Android
  （验收：双向各 20 次切换无失败）。
- **G3 Linux 可用性**：显示、触屏、WiFi、USB 网络、SSH 可用（验收：M0 清单全过）。
- **G4 数据安全**：全流程不损坏 Android 用户数据（验收：全量备份 + 恢复演练）。
- **G5 开源交付**：文档可复现，至少 1 名外部用户成功复现。

## 3. 非目标（Non-goals）

- 不做 U-Boot / lk2nd 引导器移植（SM8250 上游支持不足，见 ADR-0001）。
- 不追求 Linux 侧 modem / GPS / 震动等本机型不完整的硬件功能。
- 不做 Windows on ARM。
- 不修改 Android 既有分区内容；扩容阶段（M3）也仅动 userdata 尾部。
- 不提供图形化 Windows/macOS 工具（本期）。

## 4. 成功标准

按第 2 节 G1–G5 全部通过，且 M0–M4 门禁评审全部通过。

## 5. 关键决策（已锁定）

| 决策项 | 结论 |
|---|---|
| 项目名 / 仓库名 | `k30pro-linux-dualboot` |
| 许可证 | MIT（工具/脚本/App）+ GPL-2.0-only（内核补丁/DTS） |
| 仓库策略 | 公开开发（Public from day 1） |
| 启动切换机制 | recovery 分区 + BCB 一次性引导（ADR-0001） |
| Android 侧默认 | `boot` 分区永不改动 |

## 6. 里程碑与门禁

| 里程碑 | 交付物 | Exit Criteria（通过标准） |
|---|---|---|
| M0 | `fastboot boot` RAM 启动 Linux；USB 网络/SSH | 清单全过；方式 A 未写任何分区；方式 B（可选）仅允许同一镜像先经方式 A 实机启动并生成 attestation 后写入（门禁与 BCB 救援流程见 runbook §4/§5） |
| M1 | super 空闲空间逻辑分区 + recovery 分区安装 Linux | 30 次重启稳定；TWRP 可恢复；boot 镜像双备份 |
| M2 | 切换器 v0.1（脚本 + Magisk 模块） | BCB 行为验证；断电/卡死场景验证；双向 20 次 |
| M3 | `lmi-repart`（dry-run/备份/回滚） | 测试机演练 + 全量备份恢复演练通过 |
| M4 | v1.0 Release + 完整文档 + CI | G1–G5 全过；外部复现 ≥1 |

任何里程碑进入下一阶段前必须 Go/No-Go 评审。

## 7. 资源与预算

- 开发：chenpp1999 + AI 辅助（opencode）。
- 测试：主力机承担 M0–M2（低风险）；M3 起建议二手测试机（预算 ~300–500 元，
  在 M2 结束后决策）。
- 基础设施：GitHub 仓库 + Actions（免费额度）。

## 8. 范围变更控制

任何新增破坏性操作必须依次完成：更新风险台账 → 更新测试计划 →
负责人批准 → 先在测试机验证 → 才能在主力机执行。
