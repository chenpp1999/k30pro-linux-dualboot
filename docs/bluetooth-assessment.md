# 蓝牙可行性评估（2026-09-16）

> 结论：**蓝牙不是配置项，需要重建内核 + 设备树 + 固件 + bluez，属于独立里程碑。**
> 本项目当前部署的内核里**没有编入任何用户态 HCI 传输**，所以 `bluez`/`btattach`
> 无从接入。本文记录实测证据、可行路径、工作量与建议；**本期不做**，仅评估。

## 1. 实测证据（设备 Linux 侧，2026-09-16）

| 事实 | 证据 |
|---|---|
| BT 核心在，但**没有用户态 HCI 传输** | `/proc/config.gz`：`CONFIG_BT=y`、`CONFIG_BT_LE/BREDR/HS=y`；`# CONFIG_BT_HCIUART is not set`、`# CONFIG_BT_HCIVHCI is not set`、`# CONFIG_BT_HCIBTUSB is not set` |
| 只有 SLIMbus 的 BT/FM **音频**路径 | `CONFIG_BT_SLIM_QCA6390=y`、`CONFIG_BTFM_SLIM=y`（BTFM = BT SCO/FM 音频 over SLIMbus，不是 HCI） |
| BT 供电/复位节点存在且生效 | DT `/vendor/bt_qca6390`（`compatible="qca,qca6390"`，`qca,bt-reset-gpio`/`sw-ctrl-gpio` + 多路 `qca,bt-vdd-*-supply`）；dmesg `bt_power vendor:bt_qca6390: Linked as a consumer to regulator.*` |
| **BT 串口就是 `/dev/ttyHS0`** | `/sys/class/tty/ttyHS0/device → 998000.qcom,qup_uart`；dmesg `998000.qcom,qup_uart: ttyHS0 at MMIO 0x998000 (irq 292) is a MSM`；DT 里它是唯一启用的 `qcom,msm-geni-serial-hs` |
| 没有 HCI 设备 | `/sys/class/bluetooth` 为空；`rfkill` 只有 `bt_power`（可 unblock，但 unblock 后仍无 hci0） |
| **没有 BT 固件** | `/lib/firmware` 只有 WLAN 的 `qca6390/amss20.bin` 等；Android `vendor`/`system` 里搜不到任何 `*.tlv`/`crnv*`/`btfw*`/`btnv*`；`/vendor/bt_firmware` 为空 |
| 上游（内核提供方）同样没做 | `jian45154/redmi-k30-pro-postmarketos`：`bluetooth` 服务不存在、BT 列为 P2 待办且**排在最后**（先 QRTR/服务基础、再音频内核配置），验收标准是"hci0 出现并能扫描" |

## 2. 为什么会这样（架构差异）

- 本项目用的是**下游 LineageOS 4.19 内核**（`LineageOS/android_kernel_xiaomi_sm8250`
  @ `a5b3099`，config = `kona-perf_defconfig` + `debugfs.config` +
  `xiaomi/sm8250-common.config` + `xiaomi/lmi.config` 合并，LLVM=1），由第三方预编译成
  `linux-xiaomi-lmi-4.19.325-r9.apk`。
- 该编译**关掉了** BT 的 HCI 传输（`BT_HCIUART`/`BT_HCIBTUSB`/`BT_HCIVHCI`），只留
  `BT_SLIM_QCA6390`（音频）——所以 Android 能用的蓝牙在 Linux 侧整个缺失。
- 社区 **mainline** 移植里蓝牙是通的：DTS 在 `&uart6` 下挂
  `bluetooth { compatible = "qcom,qca6390-bt"; ... }`，由 `hci_qca` 驱动，固件取
  `qca/*.tlv`（rampatch）+ `qca/*.bin`（NVM）。**若换 mainline，WiFi（cnss2/qcacld）
  会失去支持**，代价更大——这也是本项目留在下游内核的原因。

## 3. 可行路径（按顺序，每步都有验证标准）

**Step 0（便宜，先做）：确认 BT 固件拿得到。**
从**原厂 MIUI 固件包**（fastboot 包里的 `bt_firmware`/`bluetooth` 分区，或 `vendor`）
提取 QCA6390 BT 的 rampatch/NVM（形如 `crbtfw21.tlv`+`crnv21.bin`，或高通新命名
`hpbtfw21.tlv`+`hpnv21.bin`）。上游清点确认 **LineageOS OTA 分区里没有**这些文件，
所以必须来自原厂包/其它可信来源。**拿不到固件，后面全白做。**

**Step 1：重建内核**（用上游同一份源码 + 同一套 config 片段）
- 代码：`LineageOS/android_kernel_xiaomi_sm8250` @ `a5b3099`；
- 追加配置：`CONFIG_BT_HCIUART=y`、`CONFIG_BT_HCIUART_QCA=y`、`CONFIG_BT_QCA=y`
  （若树里有 `CONFIG_BT_HCIUART_SERDEV` 一并开；为诊断可临时开 `BT_HCIVHCI`）；
- 设备树：在 `998000.qcom,qup_uart`（= `ttyHS0`）下加 BT 子节点，复用现有
  `/vendor/bt_qca6390` 的稳压器与 `bt-en`/`reset`/`sw_ctrl` GPIO；
- 构建环境：上游用 **WSL2(Ubuntu) + pmbootstrap 3.10 + Clang/LLD（`LLVM=1`）**
  交叉编译（`kernel-config-2026-05-28.md` 有完整配方）；
- 验证：内核能启动、`hci0` 出现、`bluetoothctl list` 有控制器、
  `rfkill list` 的 `bt_power` 可 unblock 且不再是"无 HCI"。

**Step 2：装固件**：把 Step 0 的文件放进 `/lib/firmware/qca/`（名字按启动日志里
`QCA Downloading qca/xxx` 的请求来；版本字节不匹配时按 WCN3990 的经验做 symlink）。

**Step 3：用户态**：`apk add bluez bluez-deprecated`，启用 `bluetooth` OpenRC 服务，
`rfkill unblock bluetooth`，配对耳机/键盘。

**Step 4（可选，上游排在 BT 之前）音频**：ADSP/音频固件（`adsp.mdt` 等，同样不在
LineageOS 分区里）+ 内核音频配置 + UCM；`/dev/snd` 目前只有 timer。

## 4. 工作量与风险

| 项 | 评估 |
|---|---|
| 内核构建环境 + 首次自编译内核成功启动 | **主要成本**（上游在 WSL2 下完成；数小时级，含排错） |
| 设备树 BT 节点 + 固件命名/board-id | 中等，通常要几轮迭代 |
| 固件获取 | **不确定**：依赖原厂固件包；上游在自己的分区里没找到 |
| 回归风险 | 重建内核会同时改动 DT（WiFi/显示都依赖它）→ 必须保留当前预编译内核做回滚，且逐项回归 WiFi/显示/USB |
| 维护成本 | 一旦自编译，就**自己维护内核**，不再"用现成 APK" |

## 5. 建议

1. **本期不做**，按 §1 的结论在文档中标注为已知限制（已做：`docs/feasibility.md` §3、
   `docs/linux-ux-audit-2026-09-14.md` B6、`docs/handoff.md` §六 第 19 条）。
2. 若要做，按 **Step 0 → 1 → 2 → 3** 推进，**先花 30 分钟确认固件是否存在**；
   固件拿不到就直接停。
3. 音频（Step 4）与 BT 共享大部分前置条件（固件 + 内核），可以合在一个"内核外设
   bring-up"里程碑里做。
4. 另一条更省事但代价大的路：换 **mainline 内核**（BT 现成）——但会失去当前
   WiFi（cnss2/qcacld），不建议。

## 6. 参考

- 内核来源与配置：`jian45154/redmi-k30-pro-postmarketos` →
  `notes/kernel-config-2026-05-28.md`、`docs/porting-sm8250-downstream-to-postmarketos.md`
- 固件清点（确认 BT 固件缺失）：同仓库 `notes/firmware-inventory-2026-06-23.md`
- BT 现状与排序：同仓库 `notes/current-state.md`、`notes/hardware-enablement-queue-2026-06-23.md`
- mainline BT 路径：`hci_qca` + `qcom,qca6390-bt`（`&uart6`），固件 `qca/*.tlv`+`qca/*.bin`
- 本机证据：`docs/acceptance/m0-2026-09-13/dmesg*.txt`（`Bluetooth: Core ver 2.22` 等）
