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

> ⚠️ 下表两条要分清：**社区 mainline（postmarketOS）基线**支持面较广，而本项目实际
> 部署的是**下游 4.19 内核**（`yuweiyuan8/linux` 4.19-CIP + qcacld/cnss2），支持面更窄。
> 2026-09-16 实测差异见下。

- **社区 mainline 基线**可用：显示（60 Hz）、触屏、Adreno 650、WiFi、蓝牙、音频、
  电池/充电、UFS、USB OTG、NFC、闪光灯、红外、加速度/磁力/光线传感器、部分相机。
- **本项目下游 4.19 内核实测**：
  - 可用：显示、触屏、WiFi（QCA6390 / cnss2+qcacld）、USB-NCM、UFS、
    电池/充电、温控与监控。
  - **不可用（重点）**：
    - **蓝牙**：内核只编了 `CONFIG_BT=y` 核心 + `CONFIG_BT_SLIM_QCA6390`（SLIMbus
      BT/FM 音频路径），**`CONFIG_BT_HCIUART` / `CONFIG_BT_HCIVHCI` / `BT_HCIBTUSB`
      等所有用户态 HCI 传输全部未编**，DT 里也没有标准 BT 节点 → `bluez`/`btattach`
      无从接入（rfkill `bt_power` 存在但 `/sys/class/bluetooth` 始终为空）。
      要支持蓝牙必须：**重建内核**（启用 HCI-UART/VHCI 等）+ **DT BT 节点**
      （UART + `bt-en` GPIO + 稳压器）+ **QCA BT 固件** + 用户态 bluez。
    - **音频**：`/dev/snd` 仅有 timer，无声卡（未配置音频链路/UCM）。
  - 不可用/实验性（其他）：GPS、距离感应、震动（本机硬件已损坏）、SDX55 modem
    （本机无 SIM，影响可忽略）。

## 4. 平台限制

- A-only 单槽，无 A/B 双系统捷径；lk2nd 不支持 SM8250；U-Boot 上游止于 SDM845。
- userdata 位于磁盘末尾，尾部缩容在技术上可行（f2fs shrink，kernel ≥5.19 +
  f2fs-tools ≥1.15），但属于唯一的高影响操作，列为可选阶段。
- super 存在约 2.4 GiB 未分配空间，可用于低风险持久化试验。

## 5. 法律与许可

- 工具链 MIT；内核补丁/DTS 必须 GPL-2.0-only。
- 固件 blobs 来源为公开固件包，再分发前需确认来源许可（在 M1 前完成审查）。
