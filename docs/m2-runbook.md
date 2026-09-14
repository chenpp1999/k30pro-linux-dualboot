# M2 双向切换器 v0.1 — 操作与验收手册

> 机制：ADR-0001（`recovery` 分区 + `misc` BCB 一次性引导）；追踪 issue #15。
> 状态（2026-09-14）：**v0.1 实机验收完成**（T1-03/T2-03/T2-04/救援/TWRP 演练
> 全过；T2-02 5 轮零失败后由负责人提前结束）。记录
> `docs/acceptance/m2-2026-09-14.md`。
> 不变式：`boot` 分区永不改动；Linux 侧任意重启回 Android。

## 0. 原理与中断安全

```
默认： boot = Android（永不动）   recovery = TWRP 或 Linux 镜像   BCB = 空
切换： 写 Linux 镜像 -> recovery（长）→ 校验回读 → 写 BCB 'boot-recovery'（短）→ 重启
进入： BootLoader 读 BCB → 引导 recovery → Linux init 早期清 BCB
返回： Linux 内 reboot / 长按电源 / 断电 → Android
```

- 顺序刻意"先镜像、后 BCB"：镜像写入阶段断电 → BCB 仍为空 → 重启回 Android；
  只有 BCB 写入→重启之间的极短窗口断电才会停在 Linux，且下次重启仍回 Android。
- `--no-reboot` 用于先准备好（BCB 已置位），由操作者另行重启。

## 1. 前置

1. 备份（必须，纯读取）：`sh recovery-swap.sh backup`（首次）。
2. Linux 镜像已通过方式 A（`fastboot boot`）实机验证，并生成 attestation：
   `sh recovery-swap.sh attest-ramboot <img>`（见 `docs/m0-runbook.md` §4 门禁）。
3. 脚本位置：本仓库 `tools/m1/recovery-swap.sh`（部署副本在 Termux home）。

## 2. 常用命令（Android root 下执行）

```sh
sh recovery-swap.sh status                                  # 备份/BCB/日志状态
sh recovery-swap.sh to-linux --dry-run <img>                # 预检，不写任何分区
sh recovery-swap.sh to-linux <img>                          # 写镜像+BCB 并重启进 Linux
sh recovery-swap.sh to-linux --no-reboot <img>              # 只准备，不重启
sh recovery-swap.sh to-linux --force <img>                  # 跳过 sha/attestation 门禁（仅救援）
sh recovery-swap.sh bcb show                                # 查看 BCB 原始值
sh recovery-swap.sh bcb boot-recovery [--dry-run]           # 单独设置一次性引导
sh recovery-swap.sh bcb clear [--dry-run]                   # 清除（取消切换/救援后清理）
sh recovery-swap.sh restore-twrp [--dry-run]                # TWRP 写回 recovery
```

- 每次 `to-linux` / `bcb` / `restore-twrp` 都会记录到
  `/data/local/lmi-dualboot/switch.log`（UTC 时间戳 + 镜像哈希 + BCB 状态）。
- 写入后为**全量 sha256 回读校验**（不是只查 `ANDROID!` 头）。
- Magisk 一键入口：`packages/magisk-module/`（Action 按钮 → `to-linux`）。

## 3. 返回 Android

- Linux（OpenRC）内 `reboot`；或长按电源强制重启；或断电。
- BCB 已在 Linux init 早期清除，以上任意方式都回 Android。

## 4. 实机验收流程（test-plan T2）

> 证据按 `docs/test-plan.md` 模板归档到 `docs/acceptance/m2-<日期>.md`；
> 每轮记录 `switch.log`、Linux 侧 `/root/m1b-boots.log`（含 bcb 原值）与
> 必要照片。**boot 分区全程未被修改**（前后 sha256 对照）。

| 项 | 步骤 | 通过标准 |
|---|---|---|
| T1-03 补课 | Android：`bcb boot-recovery`（不 reboot recovery，用普通重启触发）；进 Linux 后看 ledger `bcb=` | 确认 ABL 是否消费/改写 BCB、Linux 是否清 BCB |
| T2-02 双向 20 次 | 循环：Android `to-linux` → 等待 Linux 可用（SSH/ledger）→ Linux `reboot` → 等待 Android 起来 | 20 次往返无失败；两日志连续 |
| T2-04 切换中断电 | 在 `to-linux` 写镜像阶段拔电/断电（BCB 未写） | 重启回 Android |
| T2-03 未清 BCB | Linux 侧人为设置 BCB（`bcb boot-recovery`）后重启，或模拟 init 未清场景 | 能回 Android 或按 §5 自愈 |
| TWRP 恢复演练 | `restore-twrp` → `reboot recovery` 进 TWRP → 再用 `to-linux` 回 Linux | 全程可逆 |

自动化建议：电脑侧脚本轮询 `adb get-state` / Linux `ssh` 判断当前系统，
记录每轮耗时；`switch.log` 与 ledger 做交叉核对。

## 5. 失败处理与救援

| 现象 | 处置 |
|---|---|
| 设备循环进 fastboot（BCB 残留） | USB 宿主：`fastboot erase misc && fastboot reboot`（唯一 erase 例外，m0-runbook §5） |
| 想回 TWRP | `restore-twrp` 后 `reboot recovery` |
| 想取消已设置的切换 | `bcb clear`（未重启前） |
| recovery 里镜像损坏/未验证 | `to-linux --force` 仅救援用；正常路径重新方式 A 验证后 `attest-ramboot` |

## 6. 部署镜像的构建要求（T1-03，2026-09-14 实测）

部署到 `recovery` 的镜像**必须**带 `recovery_dtbo`：lmi 的 ABL 在 recovery
引导路径从 boot header 该字段读取 DTBO 表；字段为空时会读到镜像开头的
`ANDROID!` 魔数（`Dtbo hdr magic mismatch 52444E41`）→ `Error: Device Tree
blob not found` → 落 fastboot（v6 即此缺陷，v7 已修复）。构建：

```sh
tools/m1/build-m1b-image.sh ... --recovery-dtbo /root/work/dtbo-new.img
```

- `dtbo-new.img` = 本机当前 dtbo 表（487,424 B，sha256 `32e9ba4f…`，含 aw8697
  disabled 修改），来源 `/sdcard/Download/phone-server/lmi-bootdiag/`；
- Debian 版 `mkbootimg` 有真除 bug（`/`→`//`，带 recovery_dtbo 时 `pack('Q')`
  报 struct.error），环境修复见 handoff §五；
- RAM 引导（方法 A）不需要该字段，但同一镜像部署到 recovery 时必需；
- `buildinfo` 会记录 `recovery_dtbo_sha256` / `recovery_dtbo_bytes`。

## 7. 已知限制（v0.1）

- Linux 侧未提供图形/命令入口（`reboot` 即可）；mailbox `m2` 段暂未使用。
- Magisk 模块为骨架（Action 按钮路径），尚未实机安装验证。
- `--force` 绕过 attestation 后若内核不启动，会进入 BCB 残留循环（§5 救援）。
- T2-02 未跑满 20 轮（2026-09-14 负责人决定提前结束，标准修订待定）。
