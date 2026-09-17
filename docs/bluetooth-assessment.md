# 蓝牙 / 音频（声卡）可行性评估（2026-09-16）

> 结论：**蓝牙和声卡都不是配置项，需要重建内核 + 固件（+ 设备树/用户态），属于独立
> 里程碑。** 本项目当前部署的下游 4.19 内核**没编任何用户态 HCI 传输**（蓝牙），也
> **没编高通音频驱动**（`CONFIG_SND_SOC_QCOM` 关闭 → 无声卡）；两者都还缺固件。
> 本文记录实测证据、可行路径、工作量与建议；**本期不做**，仅评估。
> 音频见 §6。

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

## 6. 附：音频（声卡）

**现状实测（2026-09-16）**：

| 事实 | 证据 |
|---|---|
| 没有声卡 | `/proc/asound/cards` → `--- no soundcards ---`；`/dev/snd` 只有 `timer` |
| 框架在、**高通音频驱动全关** | `CONFIG_SND_SOC=y`、`CONFIG_SND_PCM=y`，但 `# CONFIG_SND_SOC_QCOM is not set`（WCD938x 编解码 / LPASS / 音频机器驱动全无） |
| DSP 通路也关着 | `# CONFIG_QCOM_APR is not set`、`# CONFIG_SLIMBUS_MSM_CTRL is not set`；`CONFIG_SND_SOC_HDMI_CODEC=y` 但无真实卡 |
| 设备树/平台设备已就位 | `/sys/bus/platform/devices` 有 `soc:qcom,msm-audio-apr`、`qcom,msm-adsp-loader`、`17300000.qcom,lpass`、`qcom,msm-dai-*`；`/dev/subsys_adsp`、`/dev/subsys_slpi` 存在 |
| **没有 ADSP 固件** | `/lib/firmware` 里没有 `adsp.mdt` 及其分段；`/vendor/rfs/msm/adsp` 只有空目录（`hlos`/`shared`/…），`/vendor/dsp` 为空 —— 固件在 Android 单独分区，Linux 侧看不到 |
| 没有用户态音频栈 | `aplay`/`amixer`/`pipewire`/`wireplumber` 全未安装 |

**结论与路径**：与蓝牙同源（内核配置 + 固件），但上游把音频排在蓝牙**之前**，通常更
容易：
1. 重建内核时**同时**打开音频（与本文件 §3 Step 1 一次编译即可）：
   `CONFIG_SND_SOC_QCOM=y`（含 WCD938x codec、LPASS、SM8250 机器驱动）、
   `CONFIG_QCOM_APR=y`、`CONFIG_SND_SOC_SOUNDWIRE*`/`SLIMBUS_MSM_CTRL` 视该树而定；
2. 装 **ADSP 固件**（`adsp.mdt` + `adsp.b*` 分段，来自原厂固件包/对应分区）到
   `/lib/firmware/`（可能还需 `adsp*` 的子目录布局）；
3. 用户态：`apk add alsa-utils`（先用 `aplay` 打通），再考虑 pipewire/wireplumber +
   设备 **UCM**（`/usr/share/alsa/ucm*`，可从原厂 `acdbdata`/UCM 配置移植）。

**验证标准**：`/proc/asound/cards` 出现声卡、`aplay` 能播放、`alsactl store` 后
扬声器/听筒出声（需要有人现场听）。风险同样在**内核重建 + 固件获取**，且与蓝牙共用
同一次内核改动 —— 建议合并为一个"外设 bring-up"里程碑一起做。

## 6b. P2 实测复验（2026-09-17）——结论：本内核上不可行

按 §3 Step 1 试了"标准 Linux 路径"，结果**否定了该路径**，并查明了原因：

1. 打开 `SERIAL_DEV_BUS`（`BT_HCIUART_SERDEV` 的硬依赖）+ `BT_HCIUART` +
   `BT_HCIUART_QCA` + `BT_QCA`，编出内核并 `fastboot boot`（`Image` sha256 `b0f57baf…`）。
   → `hci0` **出现了**并绑定 `ttyHS0`，`bt_power` 也把 5 路稳压器依次上电
   （`bt_vreg_enable: … successful`）；但**一打开就内核崩溃**：
   ```
   Workqueue: hci0 hci_power_on
   pc : qca_setup+0x3c/0x6c0   lr : hci_uart_setup → hci_dev_do_open → hci_power_on
   ```
   源码原因（`drivers/bluetooth/hci_qca.c:1151`）：
   ```c
   qcadev = serdev_device_get_drvdata(hu->serdev);   /* tty/btattach 路径下 hu->serdev == NULL */
   ```
   即**这个下游 `hci_qca` 只支持 serdev 路径**，`btattach`（tty/N_HCI）会空指针。
2. 而且树里的 `btqca` **根本没有 QCA6390**（`enum qca_btsoc_type` 只到 `QCA_WCN3990`），
   `hci_qca` 的 DT 匹配也只有 `qcom,qca6174-bt`/`qcom,wcn3990-bt` → 即使走 serdev 也没有
   QCA6390 的初始化/固件下载实现。
3. **决定性证据**：本机 **Android 自己的 `kona-perf_defconfig` 里 BT 只有**
   `CONFIG_BT=y` + `CONFIG_BT_SLIM_QCA6390=y`（没有 UART/USB HCI）。也就是说该平台的
   QCA6390 蓝牙走高通**私有 SLIMbus BT/FM**（`btfm_slim`/`btfm_slim_slave`）路径，与
   标准 Linux 的 `hci_qca` 完全不是一回事；`btfm_slim*.c` 里也没有 `hci_register_dev`
   （它是 SLIM slave/codec，不是 HCI 传输）。

**结论**：在这套下游 4.19 内核上，蓝牙**不是配置能解决的**，要复刻高通私有 SLIM-HCI
（或换 mainline 内核——但会失去 cnss2 WiFi）。**P2 的 BT 分支就此关闭**（保留本节证据，
避免后人重复）。曾经打开 BT 的尝试也让 `btattach` 卡在 D 状态、`hci0` 卡死，需一次重启清除。

## 7. 参考

- 内核来源与配置：`jian45154/redmi-k30-pro-postmarketos` →
  `notes/kernel-config-2026-05-28.md`、`docs/porting-sm8250-downstream-to-postmarketos.md`
- 固件清点（确认 BT 固件缺失）：同仓库 `notes/firmware-inventory-2026-06-23.md`
- BT 现状与排序：同仓库 `notes/current-state.md`、`notes/hardware-enablement-queue-2026-06-23.md`
- mainline BT 路径：`hci_qca` + `qcom,qca6390-bt`（`&uart6`），固件 `qca/*.tlv`+`qca/*.bin`
- 本机证据：`docs/acceptance/m0-2026-09-13/dmesg*.txt`（`Bluetooth: Core ver 2.22` 等）
