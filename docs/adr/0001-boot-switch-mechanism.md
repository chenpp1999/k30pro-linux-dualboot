# ADR-0001：启动切换机制 — recovery 分区 + BCB 一次性引导

- 状态：Accepted（待 M0 实测复核 BCB 清除行为）
- 日期：2026-09-13
- 决策人：chenpp1999

## 背景

需求：Android 必须永远是默认系统；Linux 侧的崩溃/被玩坏不能影响 Android；
支持"一键切换进入 Linux"，尽量不依赖电脑。

设备事实：A-only 单槽（无 A/B）；有独立 recovery 分区（128 MB）与 misc
分区（4 MB）；boot 分区 128 MB；BootLoader 已解锁（Magisk/TWRP 在用）。

## 决策

1. `boot` 分区**永不改动**，始终是 Android 引导镜像。
2. Linux 引导镜像放入 `recovery` 分区。
3. 切换方式：向 `misc` 写入 BCB `boot-recovery` 后重启，BootLoader 引导
   recovery 分区进入 Linux；Linux 启动早期清除 BCB，使之后所有重启回到 Android。
4. TWRP 与 Linux 引导镜像以文件形式双份备份，按需回刷 recovery 分区。

## 备选方案与否决理由

| 方案 | 否决理由 |
|---|---|
| boot 分区镜像互换（Poco F1 MultiBoot 型） | 切换后默认启动项即被改变；Linux 卡死时重启仍进 Linux，不满足"永远回 Android" |
| A/B 槽位双系统 | 本机为 A-only，无槽位可用 |
| U-Boot 二阶段引导器 | 上游仅支持到 SDM845，SM8250 需自研大量驱动，周期与风险不可接受 |
| lk2nd 引导器 | 官方设备列表确认不支持 SM8250 |
| kexec 从 Android 热切换 | 目标内核 kexec 支持未知且需自定义内核，失败模式不可控 |

## 后果

正面：
- Android 默认性由**架构**保证（boot 分区从未被改），不依赖脚本正确性；
- 切换失败/断电最多停留在 Linux 或 Android，不会"两边都进不去"；
- 无需电脑即可双向切换（Android root 写 BCB）。

负面 / 约束：
- recovery 分区被 Linux 占用期间，TWRP 需从文件回刷；
- 依赖 BCB 在 Linux 侧被正确清除，需要 M0/T1-03 实测验证；
- 若未来系统 OTA 覆盖 recovery，需要重刷安装（文档化恢复步骤）。
