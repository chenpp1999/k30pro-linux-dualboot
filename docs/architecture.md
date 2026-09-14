# 系统架构

## 1. 不变式（Invariants）

以下规则在任何阶段、任何脚本中都不得违反：

1. `boot` 分区内容永远保持 Android 引导镜像，除非用户显式选择"切换"、
   且切换协议保证失败可回退。
2. Android 既有分区（super、userdata、vendor 等）的内容不被修改；
   扩容阶段仅允许调整 userdata 尾部大小。
3. 每个写操作都有对应备份，且恢复路径事先验证过。
4. 任何时刻断电，重启后必须能进入 Android，或进入 fastboot/TWRP 等可救援状态
   （救援流程见 docs/m0-runbook.md §5）。

## 2. 现状（实测）

| 分区 | 设备节点 | 大小 | 用途 |
|---|---|---|---|
| boot | /dev/block/sde50 | 128 MB | Android 内核+ramdisk（**永不改动**） |
| recovery | /dev/block/sda28 | 128 MB | 当前为 TWRP；计划作为 Linux 引导镜像槽位 |
| misc | /dev/block/sda11 | 4 MB | BCB 一次性引导指令 |
| super | /dev/block/sda32 | 8.5 GiB | 动态分区；实测有 **~2.4 GiB 未分配空间** |
| userdata | /dev/block/sda34 | 107 GiB | Android 用户数据（83 GiB 空闲），位于磁盘末尾 |

设备为 **A-only 单槽**（无 A/B 槽位可用），GPT 分区表。

## 3. 三级演进路径

### 阶段 A（M0）— 零风险：RAM 启动
`fastboot boot <linux-boot.img>` 从内存启动 Linux，不写任何分区。
用于 bring-up 验证与回归。

### 阶段 B（M1）— 低风险：无重分区持久化
- Linux rootfs 装入 super 的 **未分配空间**（新增逻辑分区，不动既有分区；
  super 元数据先备份，异常时还原即回滚）。
- Linux boot 镜像写入 recovery 分区（TWRP 镜像备份成文件；需要时刷回）。
- 不做 GPT 修改、不缩 userdata。

### 阶段 C（M3，可选）— 受控风险：扩容
- `lmi-repart`：离线 `resize.f2fs` 缩小 userdata 尾部 + `sgdisk` 新增 `lnx`
  GPT 分区，Linux rootfs 迁移到该分区。
- 必须带 dry-run、GPT 备份、校验与一键回滚；先在测试机演练。

## 4. 启动切换协议（核心）

```
默认状态：
  boot     = Android（永远）
  recovery = TWRP 或 Linux 引导镜像（按最近一次选择）
  BCB      = 空

切换到 Linux（Android 端，root）：
  1. 确保 recovery 分区 = Linux boot.img（首次切换时写入）
  2. 向 misc 写入 BCB "boot-recovery"
  3. reboot
  → Bootloader 读 BCB → 引导 recovery 分区 → 进入 Linux

Linux 启动早期（initramfs 阶段）：
  4. 清除 BCB 中的引导指令
  → 此后任何重启都会回到 Android（boot 分区未动）

注：BCB 清除只在 Linux 内核成功启动并运行 initramfs 时发生。内核未启动则
BCB 残留，设备可能循环进入 recovery→fastboot，须按 runbook §5 救援。
**T1-03（2026-09-14 实测）**：ABL **不**清 BCB，清除责任方是 Linux init
（ledger 记录 `bcb=boot-recovery` 后由 init 清零）；且 ABL 的 recovery 引导
路径要求镜像自带 `recovery_dtbo`（DTBO 表），缺该字段会落 fastboot——
部署镜像必须用 `build-m1b-image.sh --recovery-dtbo` 构建
（见 `docs/m2-runbook.md` §6 与 `docs/acceptance/m2-2026-09-14.md`）。

回 Android：
  任意方式重启即可（reboot / 长按电源 / 断电）
```

> v0.1 实现（2026-09-14，issue #15）：`tools/m1/recovery-swap.sh` 按
> "写镜像 → 全量 sha256 回读校验 → 写 BCB（写后校验）→ 重启"执行（先镜像后
> BCB，缩小断电窗口）；`bcb show|clear|boot-recovery` 子命令可单独操作/验证
> BCB；操作与验收流程见 `docs/m2-runbook.md`。

失败模式分析：

| 场景 | 结果 |
|---|---|
| 切换命令执行中断电（BCB 未生效） | boot 仍是 Android → 重启回 Android |
| Linux 启动、init 清 BCB 后 panic/卡死/断电 | boot 仍是 Android → 强制重启回 Android |
| Linux 内核未启动 / init 未清 BCB（含早期 panic、断电） | BCB 残留 → 重启仍进 recovery，失败则进 fastboot；按 runbook §5 救援（`fastboot erase misc`，唯一 erase 例外） |
| 需要 TWRP | 从 Android（root）把 TWRP 镜像 dd 回 recovery 后重启 recovery；设备困在 fastboot 时也可 `fastboot boot` TWRP 备份镜像（runbook §5） |

## 5. 备份与恢复

| 对象 | 备份位置 1 | 备份位置 2 | 恢复方式 |
|---|---|---|---|
| Android boot.img | /data 下普通文件 | Linux 根文件系统内 | root dd 回 boot |
| TWRP recovery.img | /data 下普通文件 | Linux 根文件系统内 | root dd 回 recovery |
| GPT 分区表 | 文本导出 | 二进制备份 | sgdisk 还原 |
| 全机数据 | TWRP 全量备份 | 外部存储 | TWRP restore |

## 6. 组件划分

- `tooling/repart` — M3 扩容工具（dry-run/回滚）
- `tools/m1/recovery-swap.sh` — Android 端切换器 v0.1（`tooling/switch` 落地；
  Linux 侧清 BCB 在 `tools/m1/m1b-init.sh`）
- `packages/magisk-module` — Android 端一键切换入口
- `packages/android-app` — 可选图形入口
- `packages/pmaports` — 设备包贡献（上游）
- `kernel/` — 必要的 DTS / 补丁（GPL-2.0-only）

## 7. 调试通道威胁模型（M0/M1a）

- USB 网络（NCM/RNDIS）链路上的 SSH 使用仓库中公开记录的测试口令，仅适用于
  USB 直连的受控宿主；不得将设备 USB 网络桥接到不可信网络。
- telnet 默认关闭；仅在 boot cmdline 带 `lmi_telnet=1` 时启动，且经 login
  认证（2026-09-14，issue #9）。未认证 shell 通道不属于任何交付形态。
- M1 起用户态为完整 rootfs：接入真实网络前必须更换凭据并关闭调试服务。
