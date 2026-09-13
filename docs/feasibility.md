# 可行性研究

## 1. 结论

**可行。** lmi 已有可用的社区 mainline Linux 移植；"Android 永不改动、Linux
放沙盒"的架构在本机硬件条件下可实现（recovery 分区 128 MB、misc 4 MB、
super 有 ~2.4 GiB 空闲空间）。主要风险集中在"扩容"这一可选阶段，已通过
三级渐进路径与测试计划隔离。

## 2. 可复用资产（上游 / 社区）

| 组件 | 来源 | 状态 |
|---|---|---|
| mainline 内核 + lmi DTS | `yuweiyuan8/linux`（v6.19 分支） | 可用；个人 fork，需镜像与跟进 |
| 固件包 | `yuweiyuan8/firmware-xiaomi-lmi` | 可用 |
| 设备包 | `macosmojave2-alt/postmarket-xiaomi-lmi` | 显示/触屏/GPU/WiFi/BT/音频/UFS/USB OTG/NFC/传感器可用 |
| Mobian/Phosh 验证 | `electropica/xiaomi-lmi-linux-port` | Debian trixie + Phosh 已跑通 |
| recovery 安装法 | `jian45154/redmi-k30-pro-postmarketos` | 持久化安装先例（覆盖式） |
| 双系统方法论 | Poco F1 MultiBoot / ivonblog / XDA | 分区 + boot 镜像切换先例 |
| 安装工具 | pmbootstrap（`--partition`） | 官方支持装到自定义分区 |

## 3. 硬件支持现状（Linux 侧）

- 可用：显示（60 Hz）、触屏、Adreno 650、WiFi、蓝牙、音频、电池/充电、
  UFS、USB OTG、NFC、闪光灯、红外、加速度/磁力/光线传感器、部分相机。
- 不可用/实验性：GPS、距离感应、震动（本机硬件已损坏）、SDX55 modem
  （本机无 SIM，影响可忽略）。

## 4. 平台限制

- A-only 单槽，无 A/B 双系统捷径；lk2nd 不支持 SM8250；U-Boot 上游止于 SDM845。
- userdata 位于磁盘末尾，尾部缩容在技术上可行（f2fs shrink，kernel ≥5.19 +
  f2fs-tools ≥1.15），但属于唯一的高影响操作，列为可选阶段。
- super 存在约 2.4 GiB 未分配空间，可用于低风险持久化试验。

## 5. 法律与许可

- 工具链 MIT；内核补丁/DTS 必须 GPL-2.0-only。
- 固件 blobs 来源为公开固件包，再分发前需确认来源许可（在 M1 前完成审查）。
