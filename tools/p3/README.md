# tools/p3 — 音频（ADSP）bring-up 工具

`docs/peripheral-bringup-plan.md` **P3** 的落地工具。背景、根因链与全部实机证据见
[`docs/bluetooth-assessment.md`](../../docs/bluetooth-assessment.md) §6c；
固件来源与 sha256 见 [`docs/firmware-inventory.md`](../../docs/firmware-inventory.md)。

## 现状（2026-09-17 P3 第二轮实测）

| 环节 | 状态 |
|---|---|
| ADSP 固件（本机自带，22 文件） | ✅ 已抽取，sha256 入仓（清单 `adsp-firmware.sha256`） |
| ADSP 加载/启动 | ✅ 但**必须用户态触发**：写 `/sys/kernel/boot_adsp/boot` → OpenRC 服务 `lmi-adsp`（在 payload `tools/m1/m1b/etc/init.d/lmi-adsp`） |
| QRTR / APR 通道 | ✅ `qcom_smd_qrtr_probe`、`apr_audio_svc state[Up]` |
| 内核音频驱动/DT | ✅ 编入；ADSP-up 后 `apr_add_child_devices` 会创建 `q6core-audio`/`sound`/`bolero`/`wcd938x` |
| apps 侧 `SERVREG_LOC`（0x40）= `pd-mapper` | ✅ **已解决**：本目录补丁 + `build-pd-mapper.sh` → 内核 `Service locator initialized` |
| **SWR pinctrl（`msm-cdc-pinctrl`）** | ❌ **当前阻塞**：`devm_pinctrl_get` = **-110** → `tx/rx_macro: failed to get swr pin state` → `sound` 不绑 `kona-asoc-snd` |
| 声卡 | ❌ 未出现（`/proc/asound/cards` 空） |

**下一步**：查 `msm-cdc-pinctrl.c:228 devm_pinctrl_get()` 的 -110 来源 —— 提供者是
`techpack/audio/soc/pinctrl-lpi.c`（`:774 devm_pinctrl_register` / `:800 snd_event_client_register`，
日志有 `snd_event_notify: No snd dev entry found`）。最省事：开 `CONFIG_DYNAMIC_DEBUG`
或临时 printk 定位。完整证据链见
[`docs/bluetooth-assessment.md`](../../docs/bluetooth-assessment.md) §6c.6。

## 工具

```sh
# PC 侧（Android 在线，只读抽取）
tools/p3/extract-adsp-firmware.sh --out "$TEMP/opencode/p3/fw" [--serial <serial>] [--dry-run]

# 设备 Linux 侧（root；--boot 只写 adsp-loader 的一次性 sysfs，不动分区）
tools/p3/install-adsp-firmware.sh --from <dir> [--boot] [--dry-run]

# 设备 Linux 侧：编译 + 安装 pd-mapper（原生 musl；含 OpenRC 服务）
tools/p3/build-pd-mapper.sh [--dry-run]

# 设备 Linux 侧（只读体检：逐环节报告哪一环断了）
tools/p3/audio-probe.sh

# PC/WSL 侧：静态 aarch64 TFA9874 寄存器工具（Android 无 i2c-tools/debugfs）
# 交叉编译（WSL: aarch64-linux-gnu-gcc）后 push 到 /data/local/tmp，用 Magisk su 跑
tools/p3/build-tfa-regs-aarch64.sh /tmp/tfa-regs
#   tfa-regs scan [maxbus]                       # 找 0x34 所在 i2c 总线（lmi = 1）
#   tfa-regs i2c 1 0x00 0x20 0x21=0x2890         # 读/写寄存器（8 位地址+16 位大端）
#   tfa-regs misc /dev/tfa_reg /dev/tfa_rw 0x00  # 驱动 misc 节点（Android 同名）
#   tfa-regs dump 1 0x00 0x100                   # 全量 dump
```

**音频链的启动顺序坑（2026-09-18 实测定根因）**：`lmi-qrtr-ns`（用户态 QRTR 名字
服务，D80 rootfs 自带 `/usr/sbin/lmi-qrtr-ns`）必须开机运行，否则 `pd-mapper` 的
SERVREG_LOC 注册不出去、内核 `servloc` 永不初始化 → **无声卡**。服务/顺序修复见
`tools/m1/m1b/etc/init.d/{lmi-qrtr-ns,rmtfs,lmi-adsp}` 与
`docs/bluetooth-assessment.md` §6c.10。

补丁要点（`pd-mapper-downstream.patch`，针对上游
`linux-msm/pd-mapper@5ecd2fe926aca7abfe40724177f63b942cff3947`）：

| 改动 | 原因 |
|---|---|
| `/sys/class/remoteproc` 打不开时**直接扫 `PD_MAPPER_FIRMWARE_DIR`（默认 `/lib/firmware`）里的 `*.jsn`** | 本下游内核用 QTI PIL，`CONFIG_REMOTEPROC` 未开 → 上游逻辑拿到的是 `ENOENT`（`no pd maps available`） |
| 发布元组 `(service 0x40, version 0x01, instance 1)`（上游是 `0x101 / 0`） | 内核 `service_locator.c` 的查找是 `SERVREG_LOC_SERVICE_VERS_V01=0x01` / `SERVREG_LOC_SERVICE_INSTANCE_ID=1`，必须严格一致 |

固件**不入仓**：`--out`/`--from` 指向本机暂存目录或设备 `/lib/firmware`，
仓库里只有 sha256 清单（`SECURITY.md`）。

## 用户态（设备 rootfs，Alpine v3.23）

```sh
apk add alsa-utils alsa-ucm-conf qrtr
# rmtfs / pd-mapper / tqftpserv 不在 Alpine 仓库；pmOS 的包可以直接装进 v3.23 rootfs
apk add -U --repository https://mirror.postmarketos.org/postmarketos/v25.06 \
    --allow-untrusted --no-cache rmtfs pd-mapper tqftpserv
rc-service rmtfs start; rc-service pd-mapper start; rc-service tqftpserv start
```

`/dev/qcom_rmtfs_mem1` 已存在（部署内核含 `qcom,rmtfs-mem` DT 补丁）；
`tqftpserv` 已验证（QRTR 里出现 `4096 ... TFTP`）。

## 复验顺序

1. `tools/p3/install-adsp-firmware.sh --from <dir-on-device>`（固件 + 校验）。
2. `tools/p3/build-pd-mapper.sh [--source <pristine-tree>]`（编译安装 pd-mapper + OpenRC 服务；
   设备无网时先在 PC 导出上游源码再 `--source`）。
3. 确认 OpenRC 里 `lmi-adsp` 与 `pd-mapper` 都在 `default` runlevel
   （`rc-update show default`）；`lmi-adsp` 必须在 `pd-mapper` 之前。
4. **重启**（`service_locator` 的一次性等待只在开机生效），然后 `tools/p3/audio-probe.sh`：
   §1–§4 应全绿，`qrtr-lookup` 同时出现 `0x42`（ADSP）与 **`0x40`（locator）**。
5. 声卡出现后：`aplay -l` / `arecord -l`，再低音量出声与 `arecord` 录音
   （当前还卡在 SWR pinctrl，见上表）。
