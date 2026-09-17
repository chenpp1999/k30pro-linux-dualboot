# 硬件支持现状盘点（2026-09-16 实测）

> 在设备 Linux 侧逐项核对（`/proc`、`/sys`、`/dev`）。本表是**当前部署的下游 4.19 内核**
> 的实际情况；社区 mainline 的支持面不同（见 `docs/feasibility.md` §3）。
> 修复计划见 [`peripheral-bringup-plan.md`](peripheral-bringup-plan.md)。

## ✅ 可用（已实机验证或节点齐全）

| 模块 | 证据 |
|---|---|
| 显示 + 触摸 | Weston 桌面；`fts_ts`(event3) 触摸；`/dev/dri/{card0,renderD128}` |
| 音量/电源键 | `gpio-keys`/`qpnp_pon`(event1/4) + `lmi-keys`（背光/息屏/长按重启） |
| WiFi | QCA6390（cnss2 + qcacld）：`wlan0 up`，自动连已配置网络 |
| USB 网络 / SSH | NCM `usb0` = `172.16.42.1`，dropbear 正常 |
| 电池 / 充电 / 温控 | `lmi-chargectl`（70–80% 锯齿）、`lmi-monitor`；92 个 `thermal_zone*` |
| 存储 | UFS；rootfs 在 `/dev/sda35`（`lnx`） |
| RTC | `/dev/rtc0`（`rtc-pm8xxx`）；墙钟目前用 `swclock`+NTP |
| CPU 调频 | `schedutil`（`lmi-power`） |
| GPS 之外的 sensor ADC | PMIC `vadc`（3 个 iio device，电压/温度用） |

## ⚠️ 节点在、功能未接（多数很便宜）

| 模块 | 现状 | 证据 | 修复 | 成本 |
|---|---|---|---|---|
| ~~手电筒/闪光灯~~ | ✅ **已实现**（overlay v17） | 驱动 `qcom,qpnp-flash-led-v2`；`lmi-torch toggle` + 面板手电图标（`led:torch_*` 设电流、`led:switch_*` 使能） | — | 已完成 |
| **红外 IR** | 设备在，未使用 | `/dev/lirc0`、`/sys/class/rc/rc0`；DT 有 `qcom,ir` | 用户态 `ir-ctl`/lirc 发码 | **低** |
| **摄像头** | v4l 节点在，未验证 | `/dev/video{0,1,32,33}` + 33 个 `v4l-subdev*` | 需要 camss/驱动 + 用户态采集与调参 | 中 |
| 指纹（Goodix） | DT 有、无 Linux 指纹栈 | DTB 含 `goodix`；输入侧见 `uinput-goodix` | 需 libfprint 里匹配该型号的驱动（不确定） | 中 |

## ❌ 缺（需要内核重建 / 固件）

| 模块 | 现状 | 证据 | 修复路径 | 可行性 |
|---|---|---|---|---|
| **音频：扬声器/听筒/耳机 + 麦克风** | **无声卡**（录制同样无从谈起） | `/proc/asound/cards` 无卡；`/dev/snd` 仅 timer；`# CONFIG_SND_SOC_QCOM is not set`、`# CONFIG_QCOM_APR is not set` | 内核开 Qualcomm ASoC（WCD938x/LPASS/QDSP6/APR/SoundWire）+ ADSP 固件 + UCM；用户态 alsa-utils/pipewire | **中**（与蓝牙同一次内核重建） |
| **蓝牙** | 无 HCI 控制器 | `# CONFIG_BT_HCIUART is not set`；只有 `BT_SLIM_QCA6390`；`rfkill bt_power` 可 unblock 但 `/sys/class/bluetooth` 空；BT 串口 = `/dev/ttyHS0` | 内核 `BT_HCIUART(_QCA)/BT_QCA` + DT BT 节点 + `qca/*.tlv|*.bin` 固件 + bluez | **中** |
| 环境光 / 距离（LTR） | 无 iio 设备 | iio 只有 PMIC vadc；DT 含 `ltr` 节点 | 内核启用该 i2c 光感/距离驱动 | 低-中（同一次内核重建） |
| 磁力计（AKM） | 无 iio 设备 | DT 含 `akm0` | 同上 | 低-中 |
| NFC | 无节点 | 无 `/dev/nfc*`、无 `/sys/class/nfc`；DT 有 `nxp` 痕迹 | 驱动 + NFC 固件（原厂） | 中-高 |
| 加速度计 / 陀螺仪 | 无节点 | 无 iio/输入设备；怀疑挂在 **SLPI 传感器 DSP**（DT 无直接 i2c 节点） | 需 SLPI 固件 + Qualcomm sensor 栈（`sns`/SSC） | **高**（不建议） |
| GPS / GNSS | 无节点 | 无 `/dev/gnss*`、无 `/sys/class/gnss` | 驱动 + 固件（SDX55/集成） | 高（非目标） |
| modem | 无数据通路 | 无 `rmnet`/`qrtr`/`rmtfs`；有 `subsys_esoc0`/`subsys_spss`；本机无 SIM | SDX55 modem bring-up | 高（非目标） |

## ⛔ 不可修复 / 非目标

| 模块 | 说明 |
|---|---|
| 震动（AW8697） | **本机硬件损坏**：Linux 内核侧已在 DT 禁用；引导器（ABL，签名不可改）每次仍重试 i2c → 所以退出 Linux 必须走热复位（见 `docs/handoff.md` §六 第 11 条） |
| modem / GPS | 无 SIM、上游支持不足，`docs/charter.md` 非目标 |
| SD 卡 | 本机无卡槽 |

## 备注

- 本表只反映**当前部署的预编译内核**；如果在 `peripheral-bringup-plan.md` 的 P2 里重建
  内核，**音频/蓝牙/光感/磁力计**可以在同一次改动里一起开（成本主要是那次内核构建）。
- "便宜项"（手电筒、红外）**不需要内核改动**，可以作为独立小任务随时做。
