# M3 — `lmi-repart` 扩容设计（v0.1：规划器）

> 状态：v0.1 已实现（`tools/m3/lmi-repart.sh`，dry-run/备份/回滚规划，**不执行破坏性操作**）。
> 追踪：`docs/charter.md` M3 门禁、`docs/architecture.md` §3 阶段 C。
> **未获负责人批准、未经测试机演练之前，不得对主力机执行任何写操作。**

## 1. 目标与非目标

- 目标：在 userdata 尾部划出约 16 GiB 的 `lnx` 分区，把 Linux rootfs 从
  super 未分配区迁移到该分区（不再依赖 super 空闲区，容量与独立性更好）。
- 非目标：不动 super/vendor/boot/recovery/misc 的既有内容；不改 Android 的
  分区号顺序；不迁移 Android 数据。
- 不变式（`docs/architecture.md` §1）：`boot` 永不变；只调整 userdata 尾部；
  每个写操作先有备份；任何时刻断电必须能回到 Android 或可救援状态。

## 2. 布局（由 `plan` 计算并落盘）

```
磁盘: /dev/block/sda (≈118 GiB 可用)
  ... 既有分区不变 ...
  userdata : start S, end E            ->  end E' = S + new_sectors - 1
  lnx      : start A = align1MiB(E'+1), end A + lnx_sectors - 1
```

- 对齐 1 MiB；`lnx` 默认 16 GiB；`--lnx-size` / `--shrink` 可调。
- 只移动 userdata 的**结束位置**；userdata 的起始、GUID、名称、类型必须原样保留
  （`sgdisk -d` + `-n` 重建条目时用 `-u`/`-t`/`-c` 还原）。
- 产物：`plan.json`（机器可读）、`plan.env`（shell 可读）、日志 `repart.log`。

## 3. 前置检查（`plan` 自动 + 人工确认）

自动：userdata 存在且以 **f2fs 超级块**开头（magic `10 20 F5 F2` @ +1024）；
`lnx` 不小于 256 MiB；尾部有足够空间（含次级 GPT 33 扇区）；磁盘/分区可读。

人工（`plan` 输出里列明，必须逐项确认）：
1. TWRP **全量备份 userdata** 已完成且可读；
2. userdata 的 **f2fs 空闲空间 ≥ shrink + 10% 余量**（`df` 于 Android/TWRP 查看；
   f2fs 的 shrink 只能缩到已用空间之上）；
3. 设备电量充足、USB/供电稳定；
4. `lmi-repart.sh backup` 已运行（GPT 二进制 + 文本 + 关键区域清单）。

## 4. 手工执行步骤（dry-run 输出即为此序列）

```
0. lmi-repart.sh backup            # GPT + manifest
1. fsck.f2fs -f /dev/block/by-name/userdata         # 卸载状态（TWRP）
2. resize.f2fs -s <new_sectors> /dev/block/by-name/userdata
3. sgdisk -d <ud_idx> -n <ud_idx>:<start>:<new_end> -c <ud_idx>:userdata \
          -u <ud_idx>:<uuid> -t <ud_idx>:<type> /dev/block/sda
4. sgdisk -n <lnx_idx>:<start>:<end> -c <lnx_idx>:lnx -t <lnx_idx>:8300 /dev/block/sda
5. sgdisk -v /dev/block/sda && blockdev --rereadpt /dev/block/sda
6. mkfs.ext4 -L lnx /dev/block/by-name/lnx
7. 迁移 rootfs（当前 super 区 → lnx），更新 Linux cmdline（by-name）并重建
   `boot-m1b-*.img`（`tools/m1/build-m1b-image.sh`），再部署到 recovery
```

> 第 2 步之后 userdata 的逻辑容量变小；若此时发现异常，先做第 3 步的
> GPT 还原再 `resize.f2fs` 扩回原大小（见 §6）。

## 5. v0.1 的范围（为什么 `apply` 被拒绝）

- `plan`/`status`/`backup`/`verify`/`restore` 已实现；**`apply` 故意不实现**：
  M3 的破坏性步骤必须手工、逐步、在测试机上按 §7 演练后执行。
- 原因：GPT 条目重建 + f2fs shrink 任何一步出错都可能损坏 userdata；
  自动化收益低、风险高。工具的价值在于把参数算准、把备份留全、把回滚做顺。

## 6. 回滚

```
1. lmi-repart.sh restore --yes       # 还原 GPT（sgdisk --load-backup）
2. blockdev --rereadpt /dev/block/sda（或重启）
3. resize.f2fs /dev/block/by-name/userdata     # 扩回原大小
4. 校验：Android 正常启动、userdata 挂载、TWRP 能读取
```
数据面的最终兜底 = TWRP 全量备份 restore（§3 第 1 项）。

## 7. 演练清单（测试机，M3 门禁）

1. 全量备份 → `lmi-repart.sh backup` → `verify`；
2. 跑 §4 全部步骤（测试机），记录每步耗时与输出；
3. 重启进 Android：检查 userdata 容量、应用数据完好、sdcard 可读写；
4. 重启进 Linux：检查 `lnx` 挂载、rootfs 完整（对比文件清单/关键文件 sha256）；
5. **回滚演练**：执行 §6，确认 Android 与 TWRP 均恢复正常；
6. 断电演练：在第 2/3 步之间断电一次，按救援流程恢复；
7. 记录到 `docs/acceptance/m3-YYYY-MM-DD.md`，更新风险台账与测试计划。

## 8. 风险（同步进 `docs/risk-register.md`）

| 风险 | 影响 | 缓解 |
|---|---|---|
| f2fs shrink 失败/中断 | userdata 损坏 | 全量备份；shrink 只缩未用区；先测机演练 |
| GPT 条目重建写错 UUID/类型 | Android 无法挂载 userdata | `plan` 打印原 UUID/类型；`gpt-table.txt` 留档；`restore` 一键还原 |
| 分区表与 Android 缓存不一致 | Android 首次启动异常 | `blockdev --rereadpt` 或重启；Android 会 fsck |
| 断电落在 shrink 与 GPT 更新之间 | 分区与 fs 大小不一致 | 先 shrink 后改表；回滚路径覆盖该场景 |
| 主力机误操作 | 数据丢失 | 本设计默认拒绝 `apply`；测试机先行；负责人批准 |

## 9. 关联文件

- 工具：`tools/m3/lmi-repart.sh`；测试：`tools/tests/m3-repart-test.sh`（CI 运行）
- 文档：`docs/architecture.md` §3/§6、`docs/risk-register.md`、`docs/test-plan.md`（T3 组）
- 后续（v0.2，可选）：`apply` 的分步确认模式、f2fs 空闲空间自动探测、
  迁移脚本（rootfs 从 super 区 → lnx）与 cmdline 生成
