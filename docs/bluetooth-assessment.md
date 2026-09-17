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

## 6c. P3 音频实测（2026-09-17）——ADSP 已通，卡在 apps 侧 servreg locator

`docs/peripheral-bringup-plan.md` **P3** 的实机结果。**注意：§6b 的结论只针对蓝牙；
音频与它无关**（P2 已证明音频不需要改内核 config）。本节全部是实机证据。

### 6c.0 一句话结论

**声卡出不来的直接原因是：`audio_apr` 的 DT 子节点（含 `q6core-audio` → `sound`）只在
ADSP "up" 通知时由 `of_platform_populate()` 创建；而这个通知链要求 apps 侧存在
`SERVREG_LOC`（QMI 0x40）服务 —— 它只能由 `pd-mapper` 提供。本下游内核没有
`/sys/class/remoteproc`，linux-msm 版 `pd-mapper` 因此拒绝启动。既有 ADSP 固件、
ADSP 能启动、QRTR/APR 都通，只差这一个 locator。**

### 6c.1 已完成（每步都有证据）

1. **ADSP 固件**：本机自带，见 [`firmware-inventory.md`](firmware-inventory.md)
   （`/vendor/firmware_mnt/image/{adsp.mdt,adsp.b00..b18}`，22 文件 20,356,050 B，
   sha256 已记录）→ 放 `/lib/firmware/`（rootfs 持久）。
2. **ADSP 能加载并启动**（`/sys/kernel/boot_adsp/boot` 写 `1`，即 `adsp-loader`
   的 `subsystem_get("adsp")`）：
   ```
   subsys-pil-tz 17300000.qcom,lpass: adsp: loading from 0x000000008bb00000 to 0x000000008e000000
   subsys-pil-tz 17300000.qcom,lpass: adsp: Brought out of reset
   subsys-pil-tz 17300000.qcom,lpass: adsp: Power/Clock ready interrupt received
   subsys-pil-tz 17300000.qcom,lpass: Subsystem error monitoring/handling services are up
   adsprpc: fastrpc_restart_notifier_cb: adsp subsystem is up
   qcom_smd_qrtr_probe: SMD QRTR driver probed
   apr_tal_rpmsg qcom,glink:adsp.apr_audio_svc.-1.-1: apr_tal_rpmsg_probe: Channel[apr_audio_svc] state[Up]
   sysmon-qmi: ssctl_new_server: Connection established between QMI handle and adsp's SSCTL service
   ```
   → **APR 音频通道已 Up**；`qrtr-lookup` 能看到 ADSP(node 5) 的服务
   （servreg-notif 0x42/inst 74、SLIMbus 控制、Subsystem control、Thermal…）。
3. **内核音频栈是完整的、且已绑定**（推翻"缺驱动"的猜测）：
   `/sys/bus/platform/drivers/` 有 `adsp-loader`、`audio_apr`、`q6core_audio`、
   `kona-asoc-snd`、`wcd938x_codec`、`bolero-codec`、`bolero-clk-rsc-mngr`、`swr-wcd`、
   `wcd-dsp-mgr`、`msm-lsm-client`、`msm-pcm-*`、`msm-dai-*`、`msm-stub-codec`；
   `/sys/bus/platform/drivers/audio_apr` 已绑定 `soc:qcom,msm-audio-apr`，
   `msm-pcm-routing`/`msm-dai-q6` 也都绑定；TFA9874 功放在 probe 时注册了 DAI。
   DT（`/sys/firmware/fdt` 反编译核对）里 `qcom,q6core-audio`、`sound`
   (`compatible = "qcom,kona-asoc-snd"`)、`bolero-cdc`、`wcd938x-codec`、各 SWR macro
   全都在且使能；`qcom,firmware-name = "adsp"`。**唯一的缺口是没有对应 platform device**：
   `soc:qcom,msm-audio-apr` 名下**没有任何子设备**，`kona-asoc-snd`/`q6core_audio`/
   `wcd938x_codec`/`bolero-codec` 四个驱动目录里只有 `uevent`（无设备可绑）。
4. **用户态就位**：`alsa-utils`/`alsa-ucm-conf`（Alpine v3.23 main）已装；pmOS v25.06 的
   `rmtfs`/`pd-mapper`/`tqftpserv`（+openrc）可正常装进 Alpine 3.23 rootfs；
   `tqftpserv` 正常（`qrtr-lookup` 里有 `4096 ... TFTP`）；`rmtfs` 所需的
   `/dev/qcom_rmtfs_mem1` 存在（DT 的 `qcom,rmtfs-mem` 补丁在部署内核里）。

### 6c.2 根因链（源码级）

```
boot: audio_pdr module_init → get_service_location("audio_pdr_adsp","avs/audio")
        → pd_locator_work → init_service_locator()（service-locator.c:236）
        → qmi_add_lookup(SERVREG_LOC_SERVICE_ID_V01=0x40, ver 1, instance)
        → 等待 apps 侧 0x40 服务出现（超时 3,000,000 ms）
                    ↑ 只能由 pd-mapper 提供
        → LOCATOR_UP → audio_pdr_locator_callback 填 domain_list（name/instance）
        → NOTIFY(FRAMEWORK_UP) → audio_notifier_pdr_callback
        → audio_notifer_reg_all_clients()  ← 注册 apr 的 adsp_service_nb
        → service_notifier 向 ADSP 的 servreg-notif(0x42) 订阅 "avs/audio"/inst 74
        → ADSP 报 state UP → audio_notifer_service_cb → AUDIO_NOTIFIER_SERVICE_UP
        → apr_notifier_service_cb → apr_adsp_up()（apr.c:306）
        → schedule_work(apr_add_child_devices) → of_platform_populate(msm-audio-apr)
        → 创建 q6core-audio → sound 等设备 → kona-asoc-snd probe → snd_soc_register_card
```

关键源码位置（`LineageOS/android_kernel_xiaomi_sm8250 @ a5b3099`）：
- `techpack/audio/ipc/apr.c:306` `apr_adsp_up()` → `:294 apr_add_child_devices()`
  （**子设备只在这里创建**；`apr_probe` 不 populate）；
- `techpack/audio/dsp/audio_pdr.c:154` `get_service_location(...)`（module_init 调用一次）；
- `drivers/soc/qcom/service-locator.c:236/297`、`drivers/soc/qcom/service-notifier.c`；
- `techpack/audio/dsp/audio_notifier.c:399` `audio_notifer_pdr_callback`
  （**FRAMEWORK_UP 时会 `audio_notifer_reg_all_clients()`**，所以只要 locator 起来，
  顺序问题会自愈）。

### 6c.3 为什么 `pd-mapper` 起不来

| | linux-msm 版（Alpine/pmOS 包） | Android 的 `/vendor/bin/pd-mapper` |
|---|---|---|
| 发现 PD 地图 | 扫 `/sys/class/remoteproc`（取每个 rproc 的固件路径） | 扫固件目录里的 **`*.jsn`**（`strings`：`/vendor/firmware/image`、`.jsn`、`sr_domain`、`sr_service`、`qmi_instance_id`） |
| 本机结果 | **失败**：`pd-mapper: failed to open remoteproc class: No such file or directory` → `no pd maps available` → 进程退出 | 不适用（bionic：`/system/bin/linker64` + `liblog.so`，不能直接跑在 musl rootfs 上） |

部署内核的 `/proc/config.gz`：`# CONFIG_REMOTEPROC is not set`（用的是下游 `MSM_PIL`/
`subsys-pil-tz`）→ **没有 `/sys/class/remoteproc`**，linux-msm 版 `pd-mapper` 直接放弃。

### 6c.4 下一步（已收敛，工具已实现）

1. **补丁并原生编译 `pd-mapper`** —— 已实现：`tools/p3/pd-mapper-downstream.patch`
   针对上游 `linux-msm/pd-mapper@5ecd2fe…` 打两处：
   - `/sys/class/remoteproc` 打不开时**直接扫 `PD_MAPPER_FIRMWARE_DIR`（默认 `/lib/firmware`）
     里的 `*.jsn`**（我们要的就是 `adspr.jsn` + `adspua.jsn`，格式一致），其余
     （QMI locator 服务、JSON 解析）照用；先例：Android 自己的 `/vendor/bin/pd-mapper`
     也是扫固件目录的 `*.jsn`（`strings` 证据见 §6c.3），无需 remoteproc；
   - 发布元组改成 **`(service 0x40, version 0x01, instance 1)`**（上游是 `0x101/0`）——
     内核 `service-locator.c` 的查找是 `SERVREG_LOC_SERVICE_VERS_V01=0x01` +
     `SERVREG_LOC_SERVICE_INSTANCE_ID=1`，必须一致（`service-locator.c:23,271`）。
   编译/安装：`tools/p3/build-pd-mapper.sh`（**设备内原生 musl**，装 `/usr/bin/pd-mapper`
   + OpenRC 服务 `pd-mapper`）；地图内容：`avs/audio` →
   `domain=adsp / subdomain=audio_pd / qmi_instance_id=74`。
2. 让 `pd-mapper`/`rmtfs`/`tqftpserv` **随 boot 起**（OpenRC；`pd-mapper` 的 unit 由
   `tools/p3/` 提供，`rmtfs`/`tqftpserv` 可先用 pmOS v25.06 的包），
   `service_locator.enable=1` **已在** `tools/m1/kernel-cmdline-m1b.txt` 里（无需改）。
3. 复验：`qrtr-lookup` 出现 **service 0x40**；`dmesg` 出现
   `Service locator initialized` → `adv/audio` UP → `q6core-audio`/`sound` 设备出现 →
   `/proc/asound/cards` 有声卡（期望 `kona-mtp-snd-card`/`Xiaomi lmi`）→ `aplay -l`/
   `arecord -l` → 出声/录音。
4. 若声卡仍不出：按 §6c.2 的每一环打断点（`pr_debug` 需 `CONFIG_DYNAMIC_DEBUG`，本内核没开）。

### 6c.5 踩坑记录（避免重复）

- **不要用 `dmesg -c` 清日志**再起 ADSP —— 会清掉 module_init 阶段的
  `service_locator`/`audio_pdr` 报错，正是最需要的那几条。
- `service_locator.c` 的 `service_timedout` 是**一次性粘滞标志**：若在超时窗口内没等到
  locator 服务，本次开机内**不再重试**（`init_service_locator()` 直接 `-ETIME`）。
  所以改完 pd-mapper 必须**重启**才能验证，不能指望热插拔。
- **ADSP 起来 ≠ 声卡起来**：`apr_adsp_up()` 只在收到 notifier "up" 时跑；手动
  `echo 1 > /sys/kernel/boot_adsp/ssr` 重启 ADSP 也不会补建子设备（除非 locator 已通）。
- busybox `find` 在 `/proc/device-tree` 上不可靠（返回空）；要核对 DT 请
  `cp /sys/firmware/fdt` 出来后用 `dtc -I dtb -O dts` 反编译。
- 设备 `sde*`/`sdf*` 这些 UFS LUN 在 Linux 侧**也是** `/dev/sde*`、`/dev/sdf*`
  （`/dev/sda`…`/dev/sdf` 都在）；`fw_dev` 的 `firmware_mnt` = **`/dev/sde51`**，
  `dsp` = `sde49`，`bluetooth` = `sde35`。
- `lssh.py` 会把设备 stdout 原样写进 Windows 控制台（gbk）——**含二进制/非 UTF-8 的输出
  会让它抛 `UnicodeEncodeError`**。对策：设备侧 `... > /root/out.txt`，再用 `lcp.py get` 取回。

### 6c.7 P3 第三轮（2026-09-17 续）：SWR pinctrl 的 -110 已解决，音量卡在 LPI vote

**根因（两条，都已修/已定位）**

1. **`-110` 不是 pinctrl 的问题，是 deferred-probe 超时**：`drivers/base/dd.c` 在
   `CONFIG_MODULES` 下默认 **`deferred_probe_timeout = 30s`**，超时后任何 `-EPROBE_DEFER`
   都被强制忽略（`deferred probe timeout, ignoring dependency`）且不再重试。音频设备要到
   t≈89s 才创建（固件在 rootfs + 用户态 `lmi-adsp`/`pd-mapper`）→ 同批里**最后**创建的
   provider 还没就绪就被强制 probe。
   **修复**：`tools/m1/kernel-cmdline-m1b.txt` 加 `deferred_probe_timeout=300`
   （设备内重建镜像用 `tools/m1/rebuild-image-from-device.sh --extra-cmdline ...`）。
   实测：`tx_swr_clk_data_pinctrl` 绑定、`tx/rx/va-macro` 绑定、`swr-wcd` 控制器绑定、
   SoundWire 总线与 `wcd938x-slave` 设备都出现。

2. **LPI pinctrl 吞掉了 clock 的 `-EPROBE_DEFER`**（决定性，已用插桩内核证实）：
   ```
   LMI_DBG devm_clk_get lpass_core_hw_vote ret=-517      (-517 = -EPROBE_DEFER)
   LMI_DBG lpi probe: core_hw_vote=0 audio_hw_vote=0
   LMI_DBG hw_vote_enable ret=0 ... 然后 lpi_gpio_read: core hw vote clk is not enabled
   ```
   provider 是同一批 `of_platform_populate` 里**后**创建的 `vote_lpass_core_hw`/
   `vote_lpass_audio_hw`（`qcom,audio-ref-clk`，DT 里就在 `lpi_pinctrl@33c0000` 之后）。
   `techpack/audio/soc/pinctrl-lpi.c` 把 `IS_ERR()` 一律当成"没有这个 clk"，置 NULL 且
   `ret = 0`，于是 vote 永远开不了 → SWR master 读不到 codec 逻辑地址（-22）→
   `wcd938x-slave` 绑不上 → `sound` 不绑 → 无声卡。
   **修复**：`tools/kernel/patches/lmi-lpi-pinctrl-defer-hw-vote.patch`（`-EPROBE_DEFER`
   走 `err_defer` 正常延迟重试）。
   实测（插桩内核）：`core_hw_vote=1 audio_hw_vote=1`、`hw_vote_enable ret=0`、
   `core hw vote clk not enabled` 计数 **0**、**两个** `wcd938x-slave.*` 都绑定成功、
   `wcd938x_codec: bound wcd938x-slave.d0117022{3,4}`、`tx/rx_macro: register macro successful`。

**状态**：`sound` 设备仍**未绑定** `kona-asoc-snd`（`driver` 符号链接是悬空的），
`/proc/asound/cards` 仍为空；机器驱动的 probe 跑到了
`msm_init_aux_dev: found 1 AUX codecs registered with ALSA core` 之后失败，
**但没有任何报错** —— 因为 `kona.c` 的 `devm_snd_soc_register_card()` 返回
`-EPROBE_DEFER` 且 `codec_reg_done` 为真时会被改写成 `-EINVAL` 且**不打日志**。

**下一步**：用**诊断内核**（`kona.c` 里加了三处 printk：register_card 的返回值、
defer 分支、hard fail 分支）拿到确切的 `ret`，就知道还缺哪个 component。
镜像已在 PC 备好：`%TEMP%\opencode\p3\boot-m1b-v27diag.img`
（= 部署镜像的 ramdisk/dtb/dtbo + 诊断内核 + 含 `deferred_probe_timeout=300` 的 cmdline）。

> **插桩经验**：该内核**没编 `CONFIG_DYNAMIC_DEBUG`**，动态调试不可用；改动用
> `tools/kernel/build-kernel.sh` 同一棵树（`/root/kbuild/linux-sm8250`）增量
> `make O=/root/kbuild/out ARCH=arm64 LLVM=1 -j4 Image` 只需 1–2 分钟。
> 编辑源码时**别用正则替换里的 `\\n`/`\t` 去拼 C 字符串**（会把 `\n` 写成真换行，
> 编译器报 `missing terminating '"'`）；用整段精确文本替换并断言只有 1 处匹配。

### 6c.6 P3 第二轮（2026-09-17 续）：locator 已通，卡在 SWR pinctrl（-110）

按 §6c.4 实现并实机跑通，**上一轮的阻塞（apps 侧 locator）已解决**，并暴露出下一环：

**已通（本次实机，boot=35/36）**
1. `pd-mapper` 补丁 + **设备内原生编译**成功（`tools/p3/build-pd-mapper.sh`，musl/aarch64），
   以 `(0x40, 0x01, 0x01)` 发布 → `qrtr-lookup` 出现
   **`64 1 1 1 ... Service registry locator service`**。
2. **内核 locator 链完成**：
   ```
   [ 89.690338] servloc: service_locator_new_server: Connection established with the Service locator
   [ 89.690356] servloc: init_service_locator: Service locator initialized
   [ 89.798616]  q6core_probe+0x84/0x120      <- Workqueue: events apr_add_child_devices
   [ 89.790524] kona-asoc-snd ...:sound: populate_snd_card_dailinks: Using pri_mi2s_rx_tfa9874_dai_links
   ```
   → `apr_adsp_up() → of_platform_populate()` 真的跑了，`q6core-audio`/`sound`/`bolero-cdc`/
   `wcd938x-codec`/各 SWR pinctrl 子设备**都被创建**，机器驱动也 probe 了。
3. **ADSP 必须由用户态触发加载**（重要）：`adsp-loader` 只在写
   `/sys/kernel/boot_adsp/boot` 时才 `subsystem_get("adsp")`（Android 是 vendor init 写的）。
   已加 OpenRC 服务 `lmi-adsp`（payload：`tools/m1/m1b/etc/init.d/lmi-adsp`，`
   before pd-mapper`，并加进 `m1b-init.sh` 的 `rc-update` 列表）→ 实测开机
   `t=48.8s adsp: Brought out of reset` → `t=89.7s Service locator initialized`。
   启动顺序：**ADSP → pd-mapper（locator）→ 内核链**。
4. `pd-mapper` 的 OpenRC unit 修了一个真坑：`supervise-daemon` 默认 `respawn-max=5`，
   开机时若短暂失败会**永久退出** → 现在 `respawn_max=0`（实测复现过）。

**剩余阻塞的根因已定位（2026-09-17 续）—— 是 deferred-probe 超时，不是 DT/驱动缺失**：

`drivers/base/dd.c`：`CONFIG_MODULES` 打开时内核默认 **`deferred_probe_timeout = 30`（秒）**，
超时后 `deferred_probe_timeout = 0`，此后**任何 `-EPROBE_DEFER` 都被强制忽略**并打
`deferred probe timeout, ignoring dependency`（`driver_deferred_probe_check_state()`），
被强制的 probe 一旦失败就**不再重试**。

我们的音频链要等 rootfs 里的固件 + 用户态的 `lmi-adsp`/`pd-mapper`，**最早 t≈89s**才
`of_platform_populate` 出 `q6core-audio` 的那批子设备 —— 早已过了 t=30s 的超时窗口。
于是同一批里**最后创建**的 provider（`lpi_pinctrl@33c0000` → `qcom-lpi-pinctrl`，实测它
**绑定成功**）还没就绪，前面 4 个消费者（`tx/rx_swr_clk_data_pinctrl`、`cdc_dmic01/23_pinctrl`）
就被强制 probe → `devm_pinctrl_get()` 返回 **-110** → `tx/rx_macro: failed to get swr pin state`
→ `sound` 不绑 `kona-asoc-snd` → 无声卡。

**修复（一行 cmdline，已入库）**：在 `tools/m1/kernel-cmdline-m1b.txt` 加
**`deferred_probe_timeout=300`**（给链 300s；`0`/负数 = 永不超时，即等于无 modules 内核的
默认语义）。改用新 cmdline 的镜像后用 `fastboot boot`（零写入）即可验证：
`sound` 绑定 → `/proc/asound/cards` → `aplay -l`/`arecord -l` → 出声/录音。

> 注：provider 绑定成功但 `/sys/class/pinctrl/` 不存在 —— 该 LPI pinctrl 走的是
> Qualcomm 私有路径（`techpack/audio/soc/pinctrl-lpi.c` 自己 `devm_pinctrl_register`），
> 与 mainline 的 pinctrl 类不同，别据此误判。消费者 `-110` 也**不是** pinctrl core 的
> 错误码（core 只会给 `-EPROBE_DEFER`），是被强制 probe 后 provider 侧的连锁失败码。

### 6c.8 P3 第四轮（2026-09-17 续）：**声卡出来了**；还差 userspace 混音/UCM 路由

第三个根因（上一轮的 `register_card -110`）是 **TFA9874 功放的调音容器缺失**：
`tfa98xx` 用 `request_firmware("tfa98xx.cnt")` 加载扬声器保护调音，文件不在 `/lib/firmware/`
时内核走 sysfs fallback 等 60s 超时 → `[TFA9874] tfa98xx_probe(): Container loading requested: -110`
→ 组件 probe 失败 → `ASoC: failed to instantiate card -110` → 机器驱动 probe 失败。
**文件在 Android 的 `/vendor/firmware/tfa98xx.cnt`**（`firmware_mnt` = `/dev/sde51`，510 B，
sha256 `07abfca1…`）—— 从 Android 取出后放进设备 `/lib/firmware/`（**专有固件，不入仓**；
`docs/firmware-inventory.md` 已登记）→ **重启后可复现**：

```
[TFA9874] tfa98xx_container_loaded(): 1 nprof / Firmware init complete / codec registered (TFA)
kona-asoc-snd ...: Sound card kona-mtp-snd-card registered
/proc/asound/cards -> 0 [konamtpsndcard ]: kona-mtp-snd-card
aplay -l / arecord -l  -> MultiMedia1/2、VoiceMMode1、VoIP… 全部列出；/dev/snd 里 100+ 个 PCM
```
**内核侧到此结束**：ADSP→locator→APR→q6core→机器驱动→编解码→声卡，全链打通。

**剩下的（userspace）**：`aplay`/`arecord` 现在能打开 FE PCM 并「成功」返回，
但**没有数据流动**（`arecord` 5s 得到 0 帧、无 wav；`aplay` 无声）——这是下游 QTI 老问题：
FE PCM 只是前端，**必须先用混音器把路由配好**（Android 的 audio HAL 做的就是这件事）。
下一步：为 `kona-mtp-snd-card` 提供 **UCM 配置**（`/usr/share/alsa/ucm*/…`，
用 `amixer`/`alsactl` 设置 `msm-pcm-routing` 的 `MM_DL* → PRI_MI2S_RX` 与 TFA98xx/WCD938x
通路），或先写个把必需 mixer 控件设好的脚本 —— 之后再 `aplay` 出声、`arecord` 录 5s
验证麦克风。

## 7. 参考

- 内核来源与配置：`jian45154/redmi-k30-pro-postmarketos` →
  `notes/kernel-config-2026-05-28.md`、`docs/porting-sm8250-downstream-to-postmarketos.md`
- 固件清点（确认 BT 固件缺失）：同仓库 `notes/firmware-inventory-2026-06-23.md`
- BT 现状与排序：同仓库 `notes/current-state.md`、`notes/hardware-enablement-queue-2026-06-23.md`
- mainline BT 路径：`hci_qca` + `qcom,qca6390-bt`（`&uart6`），固件 `qca/*.tlv`+`qca/*.bin`
- 本机证据：`docs/acceptance/m0-2026-09-13/dmesg*.txt`（`Bluetooth: Core ver 2.22` 等）
