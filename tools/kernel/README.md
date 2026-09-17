# tools/kernel — 下游内核构建（P1/P2）

本目录是 `docs/peripheral-bringup-plan.md` 的 **P1/P2** 工具：复现设备上正在运行的那个
内核，并为打开**音频/蓝牙**改配置与设备树。

## 事实（2026-09-16/17 实测）

| 项 | 值 |
|---|---|
| 设备内核 | `Linux 4.19.325-cip128-st12-perf`（`uname -r`），由 **Alpine clang 22.1.8 / LLD 22.1.8** 构建 |
| 源码 | `LineageOS/android_kernel_xiaomi_sm8250` @ **`a5b3099017ae581aae8bf597b2f9c8c765026af1`**（与内核字符串 `ga5b3099017ae` 吻合） |
| 上游构建配方 | `vendor/kona-perf_defconfig` + `vendor/debugfs.config` + `vendor/xiaomi/sm8250-common.config` + `vendor/xiaomi/lmi.config`，`LLVM=1` |
| 本机复现 | ✅ 见下；`Image` 43,251,728 B（部署镜像里是**未压缩 Image**，43,253,784 B） |
| 工具链 | `clang 18.1.3 + ld.lld`（Ubuntu 24.04 仓库版），`-j4`，**12 分钟**编完 |

## 重要发现：上游那 4 个片段**不够**

只合并那 4 个片段得到的 `.config` 与设备 `/proc/config.gz` 差 **49 行**，其中功能性差异：

| 符号 | 设备值 | 仅 4 片段 | 说明 |
|---|---|---|---|
| `CONFIG_SECURITY_SELINUX` | **not set**（`DEFAULT_SECURITY_DAC=y`） | y | 上游文档也说 "then SELinux off" |
| `CONFIG_VT` / `VT_CONSOLE` / `HW_CONSOLE` / `DUMMY_CONSOLE*` / `CONSOLE_TRANSLATIONS` | **y** | not set | 没有 VT 就没有 getty 与 weston 的 tty7 |
| `CONFIG_DEVTMPFS` / `DEVTMPFS_MOUNT` | **y** | not set | initramfs 依赖 /dev |
| `CONFIG_USB_F_RNDIS` / `USB_CONFIGFS_RNDIS` | **y** | not set | NCM 失败时的 USB 网络回退 |
| `CONFIG_QCOM_RMTFS_MEM` | **y** | not set | 上游 v28 的 RMTFS 修复 |
| `CONFIG_INIT_STACK_*` | `INIT_STACK_NONE=y` | `INIT_STACK_ALL_ZERO=y` | |
| `CONFIG_IKHEADERS` | not set | y | |
| `CONFIG_SPEAKUP` | not set | （符号缺失） | |

因此本目录**直接使用设备实测的 config**：`config-xiaomi-lmi.aarch64`（`zcat /proc/config.gz`
导出后 `make olddefconfig`），这样"原样内核"能逐项对齐；P2 再在它的**副本**上改。

## 必须打的补丁（**关键**，2026-09-17 踩到）

上游内核包 `linux-xiaomi-lmi` 在 `a5b3099` 之上还打了两个补丁（本目录
`patches/`，`build-kernel.sh` 会自动应用）：

| 补丁 | 作用 |
|---|---|
| `lmi-vfs-mount-diagnostic.patch` | 加了一堆 `LMI_VFS_DIAG` 打印，但**含一处功能修复**：`do_new_mount()` 里 `if (!err && name && !fc->source) fc->source = kstrdup(name, ...)`。没有它，`mount -t ext4 /dev/sdaXX /newroot` 会因 `fc->source == NULL` 返回 **-ENOENT**（`FS_REQUIRES_DEV` 检查）→ initramfs 挂不上 rootfs，直接掉进救援 shell。 |
| `lmi-rmtfs-mem-node.patch` | 把 DT 的 `pil_wlan_fw_region` 改成 `qcom,rmtfs-mem`（`/dev/qcom_rmtfs_mem`，rmtfs 用），会影响 base dtb。 |
| `lmi-lpi-pinctrl-defer-hw-vote.patch` | **音频必需（2026-09-17 加）**：`techpack/audio/soc/pinctrl-lpi.c` 原本把 `devm_clk_get("lpass_core_hw_vote"/"lpass_audio_hw_vote")` 的 **`-EPROBE_DEFER` 吞成 NULL**（provider 是同批 `of_platform_populate` 里**后**创建的 `vote_lpass_*`）。结果：vote 永远开不了 → `lpi_gpio_read/write: core hw vote clk is not enabled` → SWR master 读不到 codec 逻辑地址（-22）→ `wcd938x-slave` 绑不上 → **无声卡**。现在 `-EPROBE_DEFER` 会走 `err_defer` 正常延迟重试。 |
| `lmi-q6afe-skip-missing-topology.patch` | **音频必需（2026-09-17 加）**：`techpack/audio/dsp/q6afe.c` 的 `afe_send_port_topology_id()` 在**没有 ACDB 标定**（Linux 侧没有 `libacdbloader`）时返回 `-EINVAL`，导致 `__afe_port_start()` 直接失败（`AFE enable for port 0x1000 failed -22`）→ **播放/录音都没有数据**（功放照常启动，所以"看起来在放但没声"）。现在"拿不到标定"＝"不设 topology"（返回 0），RX 端口实测 `ret 0`、TFA 正常起停、`aplay` 有数据；TX 端口仍会在后续 enable 步骤被 ADSP 拒（-22，需 ACDB 标定，见文档 §6c.9）。 |

**实证**：第一次"干净 a5b3099"内核（无补丁）经 `fastboot boot` 后，NCM 起了但 SSH 是
**救援 dropbear**（rootfs 口令认证失败、救援口令成功）→ 说明 rootfs 挂载失败；同时暴露
initramfs 里 **没有 `/bin/sh`**（`/etc/passwd` 写的是 `/bin/sh`），救援 SSH 连 shell 都
起不来。补丁应用后重新构建，得到 `Image` sha256 `98f21ff0…`。

## 用法

```sh
# 依赖（Debian/Ubuntu；本机 WSL 的 sudo 需要密码，故用 root 跑 wsl 命令）
wsl -u root -e bash -lc 'apt-get install -y clang lld llvm device-tree-compiler \
    bc flex bison libssl-dev libelf-dev git'

# 构建（在 WSL 里；源码 ~1.3 GB，产物在 $HOME/kbuild/out）
wsl -u root -e sh tools/kernel/build-kernel.sh --jobs 4

# 只拉源码 / 只预演
wsl -u root -e sh tools/kernel/build-kernel.sh --fetch-only
wsl -u root -e sh tools/kernel/build-kernel.sh --dry-run

# 用另一份 config（P2 实验用副本，别改仓库这份）
wsl -u root -e sh tools/kernel/build-kernel.sh --config /root/kbuild/config-p2.aarch64
```

产物：

- `out/arch/arm64/boot/Image` —— **未压缩**内核（部署镜像的 `kernel` 字段就是它）；
- `out/arch/arm64/boot/dts/vendor/qcom/*.dtb`（`kona-v2.1.dtb` 等；注意设备用的
  `kona-v2.1-lmi.dtb` 是 LineageOS 打包后的名字，`dtbo` 覆盖面见 P2）。

## 下一步（P2）与验证纪律

1. **先做 G2**：用**本目录配方编出的"原样"内核** + 部署镜像原有的 initramfs/dtb/dtbo
   组装 `boot-g2.img`，`fastboot boot`（**零写入**）验证显示/触摸/WiFi/USB/SSH 不回归，
   并用 `/proc/version` 里的 **clang 版本**（设备是 Alpine 22.1.8，自编是 Ubuntu 18.1.3）
   证明跑的是自编内核。
2. P2（2026-09-17 实测后修订）：**音频不用改 config**——`techpack/audio`（`asoc/kona.c`、
   `wcd938x`、`bolero`、SoundWire）由 `ARCH_KONA=y` 经 `konaauto.conf` 无条件编译，DT
   routing 也在；阻塞是运行时（ADSP 固件 + QRDR/PDR 服务），归 P3。**蓝牙本内核不可行**：
   Android 的 `kona-perf_defconfig` 只开 `CONFIG_BT_SLIM_QCA6390`（高通私有 SLIMbus），
   树里 `hci_qca` 只支持 serdev 且 `btqca` 无 QCA6390；实测开 UART HCI 后 `hci0` 能建但
   打开即在 `qca_setup()` 崩溃（`hu->serdev == NULL`）。详见
   `docs/bluetooth-assessment.md` §6b。
   以下 mainline 符号仅作历史参考：
   - 音频：`SND_SOC_QCOM`、`SND_SOC_QDSP6`、`SND_SOC_SM8250`、`SND_SOC_WCD938X(_SDW)`、
     `SND_SOC_LPASS_{RX,TX,VA}_MACRO`、`SND_SOC_TFA9874`、`QCOM_APR`、`SOUNDWIRE(_QCOM)`、
     `QCOM_PDR_HELPERS/MSG`、`QCOM_SYSMON`、`QCOM_Q6V5_PAS`；
   - 蓝牙：`BT_HCIUART`(+`BT_HCIUART_QCA`/`_SERDEV`)、`BT_QCA`，并在 `998000.qcom,qup_uart`
     下补 BT serdev 节点（复用 `bt_qca6390` 的稳压器与 GPIO）；
   - 顺带：光感 `ltr`、磁力计 `akm0` 的 iio 驱动。
3. 每次只改一类、每次 `fastboot boot` 验证，日志与 `Image` sha256 存档；`recovery` 的
   写入（持久化）留到最后并保留旧镜像回滚。
