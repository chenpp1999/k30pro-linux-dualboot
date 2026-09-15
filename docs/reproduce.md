# 复现指南（G5 外部可复现性）

> 目标：让**没有参与本项目**的人，在另一台 Redmi K30 Pro / POCO F2 Pro（`lmi`）上，
> 按本指南走完 M0 → M2（可选 M3），得到与本项目一致的结果。
> 本文不重复细节，逐步引用各阶段手册；**每一步都有明确的通过标准和回滚点**。

## 0. 前置条件

| 项目 | 要求 |
|---|---|
| 设备 | Redmi K30 Pro / POCO F2 Pro（`lmi`，SM8250）。**A-only 单槽**、GPT |
| 主机 | Windows/Linux + `adb`/`fastboot`；能连 USB 网络（NCM/RNDIS） |
| 引导链 | Bootloader 已解锁（官方解锁流程）；已知本机 `boot`/`recovery`/`dtbo` 的**原始镜像已备份** |
| 备份 | TWRP 全量备份（含 userdata）+ GPT + `super` 元数据 + `boot`/`recovery`/`dtbo` 镜像 |
| 时间 | M0 约 30 分钟；M1 约 1–2 小时；M2 约 30 分钟；M3 约 1 小时（含两次重启） |
| 授权 | **所有破坏性步骤需设备所有者本人确认**。M3 尤其如此 |

> ⚠️ 本项目**不发布设备镜像**：引导镜像与 rootfs 里含按设备注入的 WiFi 凭据、
> 主机名、SSH 口令等私有内容。请一律**自行构建**。

## 1. 环境与构建

构建发生在**设备自身的 Linux 侧**（真 rootfs 内），不需要交叉编译环境：

```sh
# 设备 Linux 内（或先按 M0 起来再进 M1）
apk add gcc musl-dev meson ninja cpio gzip python3 curl sgdisk e2fsprogs \
        f2fs-tools dtc       # 按需；Alpine 侧
```

关键约束（详见 `docs/handoff.md` §6）：
- **weston 客户端必须在设备内原生编译**（`tools/m1/build-weston-clients.sh`）——
  WSL/proot 产物在手机上会 SIGSEGV。
- `meson setup -Dprefix=/usr`；补丁用 `patch -p0`。
- `mkbootimg` 用 **LineageOS `lineage-19.1`** 版本（A15 版顶层 `from gki…` 会 ImportError）。

## 2. M0 — 零写入 RAM 引导（必做，作为回归基线）

按 [`docs/m0-runbook.md`](m0-runbook.md) 方式 A：

```sh
fastboot boot <boot-m0.img>
```

通过标准：面板出现色条接管（A1–A5）、USB-NCM 起来、SSH 可用、`misc` 未被写入。
通过后执行 `recovery-swap.sh attest-ramboot` 生成 attestation —— **M1/M2 的部署门禁依赖它**。
记录：`docs/acceptance/m0-2026-09-13.md` 可作为对照。

## 3. M1 — 持久 rootfs（低风险）

按 [`docs/m1b-persistent.md`](m1b-persistent.md) + [`docs/m1b-wifi-runbook.md`](m1b-wifi-runbook.md)：

1. 构建 rootfs 镜像（ext4，约 1.5 GiB）与 `boot-m1b.img`。
2. 写入 `super` 空闲区（**必须经 TWRP**：Android 用户态写 super 会被 `baseband_guard` 拒绝）。
3. 写 `recovery` 分区 + `misc` BCB → 重启进 Linux。
4. 验证：`rootfs` 挂载、WiFi `wpa_state=COMPLETED`、SSH（USB `172.16.42.1` / 局域网）、
   **持久化 3 轮**（`/root/m1b-persist.log` 的 `boot=` 递增）。

回滚：不再引导即可；或在 TWRP 内清零该区域。`boot` 分区全程不动。

## 4. M2 — 双向切换器（低风险）

按 [`docs/m2-runbook.md`](m2-runbook.md)：

- Linux 引导镜像必须带 **`recovery_dtbo`**（否则 ABL 报 `Dtbo hdr magic mismatch` → 落 fastboot；
  这是本项目踩过的最贵的坑，见 `docs/acceptance/m2-2026-09-14.md` T1-03）。
- Android 侧一键切换 = Magisk 模块 [`packages/magisk-module/`](../packages/magisk-module/)；
  或直接跑 `tools/m1/recovery-swap.sh to-linux`。
- 验证：往返切换 ≥5 轮、切换中断电回 Android、Linux 自愈清 BCB、TWRP 恢复演练。
- **`boot` 分区 sha256 全程不变** —— 这是项目的核心不变式，请记录你机器上的起始值。

## 5. M3 — 可选扩容（受控风险）

**仅在测试机/已全量备份的设备上做**，按 [`docs/m3-repart-plan.md`](m3-repart-plan.md)：

1. `tools/m3/lmi-repart.sh status` → `plan`（dry-run，读 GPT 与 f2fs 超级块）。
2. `backup` → 保存 GPT 表与关键区域。
3. 人工复核后执行方案里的命令（`apply` 故意不实现自动执行）：
   ```sh
   fsck.f2fs -f /dev/sdXN        # 必须连续两次 clean
   resize.f2fs -s -t <new_sectors> /dev/sdXN   # 缩容必须 -s；-t 单位是设备扇区(4096)
   sgdisk -d N -n N:start:end -c N:userdata -u N:<PARTUUID> -t N:<type>   # 一条命令完成
   ```
4. 迁移 rootfs → `lnx`，init 按 `PARTNAME=lnx` 优先挂载；重启验证 `root=/dev/sd...`（新分区）。
5. `verify`（GPT 与 fs 一致性）；Android 侧确认 `/data` 可挂载且数据完整。

回滚：`restore` 恢复 GPT；rootfs 旧区仍保留在 `super` 内（本项目未回收）。

## 6. 长期运行（可选，但强烈建议）

按 [`docs/m1b-thermal-charging.md`](m1b-thermal-charging.md) 启用：
`lmi-power`（governor→`schedutil`）、`lmi-chargectl`（停充 80 %/恢复 70 %、42/38 °C）、
`lmi-monitor` + `lmi-status` + 内网面板。
验证标准见 `docs/test-plan.md` T4。

## 7. 请回报的内容（G5 验收所需）

在本仓库开 issue，注明：

- 设备型号/ROM 版本/内核版本、构建环境（设备内 or 交叉）；
- M0/M1/M2（/M3）各部分：**通过与未通过项**、与原记录**不一致**的地方；
- 你遇到的**新坑**与根因；
- 产物 sha256（`boot-m1b*.img`、overlay tar）与 `git rev-parse HEAD`。

## 8. 已知不可复现/差异点

- 本项目使用的具体手机（硬件个体差异：本机有 aw8697 震动芯片导致冷启动卡 logo 4–5 分钟）；
- WiFi 凭据、主机名、SSH 口令等**按设备注入或首次启动生成**，仓库与发布物均不含；
- 上游内核 fork（`yuweiyuan8/linux`）与固件镜像的可用性（见风险台账 R6）；
- 具体 `boot-m1b-vNN.img` 属于构建产物，随 overlay 版本演进，**不必复现同一 sha256**，
  复现的是**流程与行为**。
