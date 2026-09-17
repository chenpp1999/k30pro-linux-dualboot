# 外设 bring-up 计划：蓝牙 + 音频（扬声器/麦克风）（2026-09-16 规划）

> 目标：把 Linux 侧缺失的**蓝牙**与**音频**（**扬声器/听筒/耳机输出 + 麦克风录音**）补上。
> 两者根因相同（下游 4.19 内核没编对应驱动 + 缺专有固件），**共用同一次内核重建**，
> 所以合并为一个里程碑做。整机硬件盘点见
> [`hardware-status.md`](hardware-status.md)（含光感/磁力计/NFC/摄像头/红外/手电筒等）。
> 现状与证据见 [`bluetooth-assessment.md`](bluetooth-assessment.md)；
> 上游（内核提供方）的同类分析见 `jian45154/redmi-k30-pro-postmarketos`
> `notes/{audio-bringup-analysis,hardware-enablement-queue}-2026-06-23.md`。

## 0. 非目标

- modem（本机无 SIM）/ GPS / 距离感应 / 震动（本机硬件损坏）——不在本期。
- 不换 mainline 内核（会失去当前 WiFi cnss2/qcacld）。
- 不追求 Hi-Fi 调音；先做到"有声卡、能出声、能配对"。

## 1. 现状（2026-09-16 实测，详见评估文档）

| | 蓝牙 | 音频（输出 + **麦克风**） |
|---|---|---|
| 内核驱动 | `# CONFIG_BT_HCIUART/BT_HCIVHCI/BT_HCIBTUSB is not set`；只有 `BT_SLIM_QCA6390`（SLIMbus 音频） | `# CONFIG_SND_SOC_QCOM is not set`、`# CONFIG_QCOM_APR is not set`；框架 `SND_SOC/SND_PCM` 在 |
| 设备树/平台 | `/vendor/bt_qca6390` 供电节点 + `bt-en`/reset/sw_ctrl GPIO **已就位并生效**；BT 串口 = `/dev/ttyHS0`（`998000.qcom,qup_uart`） | DT/平台设备齐全（`msm-audio-apr`、`msm-adsp-loader`、`lpass@17300000`、`msm-dai-*`、`/dev/subsys_adsp`） |
| 固件 | 无（`/lib/firmware` 无 `qca/*.tlv|*.bin`） | 无（无 ADSP 固件；`/vendor/dsp`、`/vendor/rfs/msm/adsp` 在 Linux 侧为空） |
| 用户态 | 无 bluez | 无 alsa-utils/pipewire |
| 固件来源 | **本机 GPT 没有 modem/dsp/bt_firmware 分区** → 必须从原厂 MIUI 固件包取 | 同左 |

## 2. 总体路线

```
P0 固件侦察  →  P1 内核构建环境  →  P2 配置/DT 开关  →  P3 固件+用户态
（只读，拿不到就停）   （先复现"原样"内核）    （音频+蓝牙一起开）    （声卡/hci0 出现）
                                                        ↓
                                    P5 验收/回馈上游  ←  P4 持久化（payload/overlay/镜像 + 回滚）
```

**贯穿原则**（沿用项目不变式）：
- 每一步**先 RAM 引导验证**（`fastboot boot`，零写入），通过后才谈持久化；
- `boot` 分区**永不动**；部署只写 `recovery`（并保留当前预编译内核镜像做回滚）；
- **专有固件不入仓**：本地暂存 + 在文档里记来源/路径/sha256/许可，发布物不含固件；
- 每个 Gate 有明确通过标准，不通过就停并记录。

## 3. 里程碑与交付物

### P0 固件侦察与清单（只读，~0.5 天）

**要做**：找到并确认两类固件：
1. **QCA6390 蓝牙**：`qca/*.tlv`（rampatch）+ `qca/*.bin`（NVM）；名字按内核探测到的
   ROM/SOC 版本决定（启动日志会打印 `QCA Downloading qca/xxx`）。
2. **ADSP/音频**：ADSP 镜像与分段。上游记的路径是 `qcom/sm8250/adsp.mbn`；本内核是
   下游风格（`adsp.mdt` + `adsp.b*` 分段 + `adsp-loader`），以实际内核请求为准。

**来源（按优先级，2026-09-16 调研结论：可行）**：
1. **公开 `linux-firmware`（首选，体积小、可分发）**：
   - ADSP/音频：`qcom/sm8250/{adsp.mbn, adspr.jsn, adspua.jsn}`（另有 `cdsp.mbn`、
     `a650_zap.mbn` 等同一目录）；
   - 蓝牙（QCA6390 走 UART/`hci_qca`）：`qca/*.tlv`（rampatch）+ `qca/*.bin`（NVM），
     具体名字由芯片回报的 ROM/SOC 版本决定（启动日志会打印 `QCA Downloading qca/xxx`；
     QCA6390 常见 `hpbtfw*/hpnv*`，WCN3990 常见 `crbtfw*/crnv*`）。
2. **原厂 MIUI 包（兜底，保证与本机匹配）**：`mifirm.net` 的 lmi fastboot 包或
   upmiui 的 vendor firmware（含 modem/dsp/bluetooth）；提取方法参考 pmOS 设备的
   `firmware-extraction` 文档（`/vendor/firmware/{adsp,cdsp,slpi,venus}.mbn` +
   传感器 `hexagonfs/` JSON）。
3. 设备自身 Android 分区：本机 GPT **无** `modem`/`dsp`/`bt_firmware` 分区，Linux 侧
   `/vendor/firmware` 只有触觉 `.bin`，故不作为主来源（可在 Android 侧复核）。

**交付物**：`docs/firmware-inventory.md`（文件→目标路径→大小→sha256→**来源/许可**，
固件本体放本地/设备，不入仓）。

**Gate G1**：两类固件都拿到且 sha256 记录在案；**拿不到 → 停止本计划**（记录结论）。

### P1 内核构建环境复现（~0.5–1 天）

**要做**：在 **WSL2(Ubuntu)** 里按上游配方复现一个**原样**内核（不改配置），证明工具链
与产物可用：
- 源码：`LineageOS/android_kernel_xiaomi_sm8250` @ `a5b3099`；
- 配置：`arch/arm64/configs/vendor/kona-perf_defconfig` + `debuggerfs.config`（实际为
  `debugfs.config`）+ `xiaomi/sm8250-common.config` + `xiaomi/lmi.config` 合并；
- 工具链：**Clang/LLD（`LLVM=1`）**，`pmbootstrap` 3.10 或手工 `make`；
- 产出：`vmlinuz` + `kona-v2.1-lmi.dtb`（本次还需 dtb，见 P2）。

**交付物**：可复现的构建脚本 `tools/kernel/build-kernel.sh`（或文档化的命令序列）+
构建产物 sha256 + 一次成功的构建日志（**脚本/配置入仓，内核二进制不入仓**）。

**Gate G2**：用**自编译但未改配置**的内核 + 现有 initramfs 做一次
`fastboot boot`（方式 A），确认**显示/触摸/WiFi/USB-NCM/SSH 全不回归**。
不通过就停（说明工具链/配置复现有问题）。

**P1 进展（2026-09-17）**：工具链装好（clang 18.1.3 + ld.lld），源码按 SHA
浅取到 `a5b3099`（1.3 GB），**12 分钟**编出 `Image`（43,251,728 B）+ dtbs；配方与产物
存进 [`tools/kernel/`](../tools/kernel/README.md)。两个关键发现：

1. **上游 4 个 config 片段不够**（与设备 `/proc/config.gz` 差 49 行，含 SELinux 关闭、
   VT/console、DEVTMPFS、USB RNDIS、`QCOM_RMTFS_MEM=y`、IKHEADERS 等）→ 改用**设备
   实测 config**（`tools/kernel/config-xiaomi-lmi.aarch64`）。
2. **还必须打两个补丁**（上游 `linux-xiaomi-lmi` 的 `source=` 里有）：其中
   `lmi-vfs-mount-diagnostic.patch` 含 `do_new_mount()` 的 **`fc->source` 兜底修复**，
   没有它 `mount -t ext4 /dev/...` 返回 **ENOENT** → rootfs 挂不上。

**G2 结果（2026-09-17）＝ ✅ 通过（带补丁内核）**：
- 第一次用"无补丁"内核：`fastboot boot` 后内核启动（NCM 起、可 ping），但 SSH 只认
  **救援口令** ⇒ rootfs 挂载失败（根因＝缺上游补丁，见 `tools/kernel/README.md`）。
  该次失败还暴露 initramfs **缺 `/bin/sh`**（救援 SSH 无法起 shell）。
- 修正后（补丁 + `bin/sh` 软链）用 `boot-g2b.img` 重试：
  - `~30 s` 拿到 rootfs SSH；`/proc/version` = `4.19.325-cip128-st12-perf-ga5b3099017ae-dirty`
    **Ubuntu clang 18.1.3 / LLD 18.1.3**（设备原内核是 Alpine clang 22.1.8 ⇒ 证明跑的是自编内核）；
  - 显示/weston（`socket ready after 7s`）、触摸（`fts_ts`）、USB-NCM（`usb0` `172.16.42.1`）、
    SSH、电量/温控监控、`lmi-keys` 均正常；**WiFi 自动连上 502（`192.168.5.27`）**；
  - 日志里可见 `LMI_VFS_DIAG ... fc_source=/dev/loop2`，正是补丁生效的证据。
- **副作用（已处理）**：运行中 `seatd` 卡死（进程/socket 都在但连接被拒）→ weston 无限
  重试、**屏幕灭/亮循环**；`rc-service seatd restart` 恢复。已给 `m1-weston` 加自愈：
  失败日志命中 `libseat/could not open seat/seatd.sock` 时自动重启 seatd。
- 此后设备可继续留在 Linux；**P2（音频+蓝牙配置/DT）在 G2 基础上开工**。

### P2 打开音频 + 蓝牙（配置 + DT）（~0.5 天）

**P2 实测（2026-09-17）：音频其实不需要改 config** —— 这套下游内核的音频在
`techpack/audio/`，由 `ARCH_KONA=y` 经 `konaauto.conf` **无条件导出并编译**
（`out/techpack/audio/**/*.o` 已在），机器驱动 `asoc/kona.c`、编解码 `wcd938x`/`bolero`、
SLIM/SoundWire 都在，且 `lmi-audio-overlay.dtsi` 里已有完整 routing。所以**音频卡不起来是
运行时问题**：ADSP 未启动 + 服务层（QRTR/PDR、`pd-mapper`/`rmtfs`）缺失 → 归入 **P3（固件 +
用户态）**：把 ADSP 固件（`qcom/sm8250/adsp.mbn` 等）放到 `/lib/firmware/`，起 `pd-mapper`/
`rmtfs`/`tqftpserv`，再验证 `/proc/asound/cards` 出现声卡（含麦克风采集）。

下面那串 mainline 符号（`SND_SOC_QCOM`/`WCD938X`…）在本下游树里**不存在**，仅作参考留档：
```
CONFIG_SOUNDWIRE=y           CONFIG_SOUNDWIRE_QCOM=y
CONFIG_QCOM_PDR_HELPERS=y    CONFIG_QCOM_PDR_MSG=y
CONFIG_QCOM_SYSMON=y         CONFIG_QCOM_Q6V5_PAS=y
CONFIG_QCOM_APR=y            CONFIG_QCOM_PD_MAPPER=y
CONFIG_SND_SOC_QCOM=y        CONFIG_SND_SOC_QCOM_COMMON=y
CONFIG_SND_SOC_QDSP6=y       CONFIG_SND_SOC_SM8250=y
CONFIG_SND_SOC_WCD938X=y     CONFIG_SND_SOC_WCD938X_SDW=y
CONFIG_SND_SOC_LPASS_RX_MACRO=y  CONFIG_SND_SOC_LPASS_TX_MACRO=y
CONFIG_SND_SOC_LPASS_VA_MACRO=y  CONFIG_SND_SOC_TFA9874=y
```
**内核配置（蓝牙）—— ❌ 已证伪（2026-09-17，见 `bluetooth-assessment.md` §6b）**：
本内核的 QCA6390 蓝牙走高通私有 SLIMbus BT/FM 路径（Android 的 `kona-perf_defconfig`
也只有 `CONFIG_BT=y`+`CONFIG_BT_SLIM_QCA6390=y`），树里的 `hci_qca` 只支持 serdev 且
`btqca` 无 QCA6390。实测开 `BT_HCIUART(_QCA)` 后 `hci0` 能出现、芯片能上电，但一打开就
在 `qca_setup()`（`hu->serdev == NULL`）崩溃。**P2 取消 BT**；要做只能复刻厂商 SLIM-HCI
或换 mainline（会失去 WiFi）。
**设备树**：在 `998000.qcom,qup_uart`（= `ttyHS0`）下加 BT 子节点
`bluetooth { compatible = "qcom,qca6390-bt"; ... }`，复用现有 `/vendor/bt_qca6390` 的
稳压器与 `bt-en`/`reset`/`sw_ctrl` GPIO（具体属性名以本树 `hci_qca`/`btqca` 的 dt-bindings
为准）。

**交付物**：配置/DT 补丁（入仓，`tools/kernel/` 下）+ 新内核 `vmlinuz/dtb`（本地）。

**Gate G3**：`fastboot boot` 后：
- `/proc/asound/cards` 出现声卡（期望名 `Xiaomi lmi`），`aplay -l` 列出 PCM；
- `rfkill unblock bluetooth` 后 `/sys/class/bluetooth` 出现 `hci0`（`hciconfig`/`bluetoothctl list`）；
- 显示/触摸/WiFi/USB 仍正常。
不通过则回到配置/DT 迭代（每次仍只 RAM 引导）。

### P3 固件落地 + 用户态（~0.5 天）

**要做**：
- 把 P0 的固件放到 `/lib/firmware/`（ADSP 按内核请求的路径；BT 放 `qca/`，版本不符时按
  WCN3990 经验做 symlink）；
- 用户态：`apk add alsa-utils`（先 `aplay` 打通）；`apk add bluez bluez-deprecated`，
  启用 OpenRC `bluetooth` 服务。

**交付物**：`tools/m1/m1b/` 载荷里的**用户态与配置**（服务、UCM 配置模板；**固件不进
仓库**，用本地注入脚本，参照现有 WiFi 凭据的注入方式）。

**Gate G4**（需现场观察）：
- 扬声器/听筒 `aplay` 出声（低音量、可一键停止）；
- **麦克风 `arecord` 能录到声音**（`arecord -l` 列出 capture PCM；录 5 s 回放确认）；
- 蓝牙能扫描并配对（耳机/键盘）。
不通过则分头排查（UCM/路由/录音通路、BT 固件名/波特率/GPIO 极性）。

### P4 持久化（~0.5 天）

- 把 P2 的内核 + P3 的载荷/固件集成进镜像构建流程：
  - 新内核替换 `tools/m0`/`tools/m1` 里的 `vmlinuz`+`dtb` 输入（本地，不入仓）；
  - 载荷走 overlay 版本号递增（v17+），固件走本地注入；
- 用 `tools/m1/rebuild-image-from-device.sh` 重建 `boot-m1b-vNN.img` → 写 `recovery`
  → 回读 sha256 校验；**保留当前 v23 镜像做回滚**；
- 回归：显示/触摸/WiFi/充电温控/切换（M2 流程）全部复测。

**Gate G5**：持久化后重启复验 G3/G4，且 `boot` 分区 sha256 不变、可一键回滚。

### P5 验收与文档（~0.5 天）

- `docs/acceptance/peripherals-YYYY-MM-DD.md`（证据：`/proc/asound/cards`、`hci0`、
  `aplay`/配对记录、回归清单、`boot` sha256）；
- 更新 `docs/feasibility.md` §3、`docs/architecture.md`、`docs/usage.md`（怎么用蓝牙/音频）；
- 把可回馈的改动（audio/BT defconfig 片段、DT 节点）整理给上游
  `jian45154/redmi-k30-pro-postmarketos`（issue/PR）。

## 4. 风险与回滚

| 风险 | 应对 |
|---|---|
| 固件拿不到（专有、分区不在本机） | **G1 硬门禁**：拿不到就停，只保留评估结论 |
| 自编译内核导致 WiFi/显示回归 | G2 先用"未改配置"内核做回归；DT 改动小步；保留预编译内核回滚 |
| 内核构建环境/网络/磁盘不足 | 先做 P1 环境体检（WSL 磁盘 ≥60 GB、网络可达）；否则改用设备内原生编译（慢） |
| BT/音频需要多轮固件名/GPIO 调试 | 每轮只 `fastboot boot`（零写入），把日志归档 |
| 专有固件被误提交 | CI 第 4 项 + 本地 forbidden 清单；固件只放本地/设备 |
| 时间成本 | 见 §5；这是 3–5 个"专注工作日"量级，不是一次会话能完成 |

**回滚**：全程只写 `recovery`（且保留 v23 镜像 / 备份）；`boot` 不动；任何一阶段失败可
`dd` 回旧镜像或走 M2/TWRP 流程。

## 5. 资源与前置条件（开工前需确认）

1. **原厂 MIUI 固件包**（fastboot 包或 firmware-only 包，含 modem/dsp/bluetooth 镜像）
   —— **P0 的关键输入**；或允许我从公开镜像下载（~100 MB–4 GB）。
2. **WSL2(Ubuntu)**：可用（当前已装），需确认：剩余磁盘 ≥60 GB、能 `apt` 装
   `clang lld llvm python3 git make dtc`；网络可达 GitHub/内核源码。
3. **设备时间窗**：P1/P2 需要多次 `fastboot boot`（每次 1–2 分钟，不改分区）；
   P4 需要一次 `recovery` 写入（会重启）。
4. 预留 **3–5 个专注工作日**；按 Gate 推进，每步产物都留证。

### 5.1 环境体检（2026-09-16，本机 WSL）

| 项 | 结果 |
|---|---|
| Ubuntu 24.04 / WSL2 内核 6.18 | ✅ |
| 磁盘可用 | ✅ 925 GB |
| CPU / 内存 | 12 核 / 5.8 GB（**偏小**：内核编译需 `-j8` 左右并监控 OOM；必要时加 swap） |
| 网络 | ✅ github / kernel.org 可达 |
| 已有 | `git` `python3` `make` `gcc` `aarch64-linux-gnu-gcc` |
| **缺（P1 需装）** | `clang` `lld` `llvm` `dtc` `mkbootimg`（LineageOS 脚本）`pmbootstrap`（可选） |

> 结论：P1 可开工，先 `apt-get install clang lld llvm device-tree-compiler`，再取
> `mkbootimg`（LineageOS `lineage-19.1` 版，仓库既有约束）与内核源码。

## 6. 其他硬件（本次盘点结论，详见 `hardware-status.md`）

- **可以在同一次内核重建里顺带开的**：环境光/距离（DT 有 `ltr`）、磁力计（DT 有 `akm0`）
  —— 只需启用对应 iio 驱动，成本几乎为 0（前提是这些驱动在本内核树里）。
- **不需要内核改动、随时可做的小项**：**手电筒**（`/sys/class/leds/led:torch_0`）、
  **红外**（`/dev/lirc0` + `/sys/class/rc/rc0`）。
- **成本高、暂不做**：加速度/陀螺仪（疑在 SLPI 传感器 DSP，需固件 + 厂商 sensor 栈）、
  NFC、GPS、SDX55 modem、摄像头（节点在但未验证）。
- **不可修复**：AW8697 震动（硬件损坏）；指纹（Goodix）需 libfprint 匹配该型号，待评估。

## 7. 与其它任务的关系

- 与 **M5 一键安装**独立；但内核/固件最终要进"通用镜像"的话，固件的**许可与分发**
  要单独决策（本期不发布固件）。
- 与 **WiFi 稳定性**（`lmi-netwatch` 兜底）无关，但 P2 改 DT 后要顺带复测 WiFi。
