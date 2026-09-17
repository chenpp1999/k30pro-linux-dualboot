# tools/p3 — 音频（ADSP）bring-up 工具

`docs/peripheral-bringup-plan.md` **P3** 的落地工具。背景、根因链与全部实机证据见
[`docs/bluetooth-assessment.md`](../../docs/bluetooth-assessment.md) §6c；
固件来源与 sha256 见 [`docs/firmware-inventory.md`](../../docs/firmware-inventory.md)。

## 现状（2026-09-17 实测）

| 环节 | 状态 |
|---|---|
| ADSP 固件（本机自带，22 文件） | ✅ 已抽取，sha256 入仓（清单 `adsp-firmware.sha256`） |
| ADSP 加载/启动（`subsystem_get("adsp")`） | ✅ `adsp: Brought out of reset` |
| QRTR / APR 通道 | ✅ `qcom_smd_qrtr_probe`、`apr_audio_svc state[Up]` |
| 内核音频驱动/DT | ✅ 全部编入并绑定（`kona-asoc-snd`、`wcd938x_codec`、`bolero`、`msm-dai-*`…） |
| **apps 侧 `SERVREG_LOC`（0x40）= `pd-mapper`** | ❌ **阻塞**：linux-msm 版需要 `/sys/class/remoteproc`（本下游内核没有） |
| 声卡 | ❌ 未出现（`audio_apr` 的 DT 子设备只在 ADSP-up 通知里创建） |

**下一步**：移植/补丁 `pd-mapper`，让它直接读 `*.jsn`（不依赖 remoteproc）。
地图内容已知：`avs/audio` → `domain=adsp`、`subdomain=audio_pd`、`qmi_instance_id=74`
（Android 自带 `/vendor/bin/pd-mapper` 就是这么做的，但它是 bionic 二进制）。

## 工具

```sh
# PC 侧（Android 在线，只读抽取）
tools/p3/extract-adsp-firmware.sh --out "$TEMP/opencode/p3/fw" [--serial <serial>] [--dry-run]

# 设备 Linux 侧（root；--boot 只写 adsp-loader 的一次性 sysfs，不动分区）
tools/p3/install-adsp-firmware.sh --from <dir> [--boot] [--dry-run]

# 设备 Linux 侧（只读体检：逐环节报告哪一环断了）
tools/p3/audio-probe.sh
```

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

1. `tools/p3/audio-probe.sh` —— 看 §1–§4 是否全绿（固件/ADSP/QRTR）。
2. 修好 `pd-mapper` 后**必须重启**再验（`service_locator.c` 的 `service_timedout`
   是一次性粘滞标志，热插拔不会重试）。
3. 声卡出现后：`aplay -l` / `arecord -l`，再低音量出声与 `arecord` 录音。
