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

## 4b. 独立审计结论与修正（2026-09-15，子代理审计）

审计发现两处**会导致数据丢失**的错误，已修正：

1. **`resize.f2fs` 缩容必须带 `-s`**：不带该 flag 时 f2fs-tools 直接拒绝
   （`Nothing to resize, now only supports resizing with safe resize flag`），
   缩容不会发生；而 GPT 若照缩，就会留下 **fs > 分区** 的状态 → Android 挂载
   userdata 失败 → 可能触发"恢复出厂" → 数据丢失。现在工具输出的步骤含
   `resize.f2fs -s -t <512B 扇区数>`，并在测试里加了回归断言。
   `-t` 的单位是 **512 字节扇区**（f2fs 内部固定 512B/扇区），且含义是**新总大小**
   （非增量）。`f2fs_resize_check()` 会在写入新超级块前校验
   `valid_block_count ≤ user_block_count`，所以"装不下"的缩容会安全失败。
2. **rootfs 的 `lmi_root_off` 是相对 `super` 分区的偏移**（init 用
   `losetup -o $((ROOT_OFF_BLOCKS*4096)) /dev/sda32`），**不是整盘偏移**。
   迁移时按整盘 skip 会搬错区域。实测校正：`super` 起始扇区 647168（4096B/扇区）
   + 1596852 = **整盘扇区 2244020**，该处 +1080 处有 ext4 魔数 `53 ef`（已实测）。
   因此迁移命令为：
   `dd if=/dev/sda bs=4096 skip=2244020 count=393216 of=/dev/sda35 conv=fsync`
   （或 `dd if=/dev/sda32 bs=4096 skip=1596852 count=393216 ...`）。
3. **PARTUUID 必须从 `sgdisk -i 34` 取**（`sgdisk -p` 不打印唯一 GUID）；name、
   PARTUUID、type 三者都要保留，否则 Android 找不到 userdata（`by-name`/`by-partuuid`）。
4. **userdata 缩小与 `lnx` 新建必须合并为一条 `sgdisk` 调用**（sgdisk 按参数顺序
   解释），避免出现"userdata 已缩、lnx 未建"的中间表状态。
5. 收紧执行纪律：`set -e` + 每步后校验；`blockdev --rereadpt` 在 rootfs 循环设备
   占用磁盘时可能 `EBUSY`，此时**重启**（旧镜像仍指向未动的 super 区，照常启动）。
6. 提交前抓取（回滚需要）：`sgdisk --backup`、`sgdisk -i` 全量、userdata 首 1 MiB、
   f2fs SB0@1024/SB1@5120、`dump.f2fs -s 0` 的 block_count、`s_uuid`。

审计建议的最终顺序（每步后校验）：

```
1. fsck.f2fs -f /dev/sda34        # 连续两次干净
2. resize.f2fs -s -t <sectors> /dev/sda34
   verify: dump.f2fs -s 0 /dev/sda34 | grep -i block_count；fsck 干净
3. sgdisk -d 34 -n 34:<s>:<e> -c 34:userdata -u 34:<PARTUUID> -t 34:A03A \
          -n 35:<s>:<e> -c 35:lnx -t 35:8300 /dev/sda      # 一条命令
   verify: sgdisk -v（仅既有无害 gap 警告）；sgdisk -i 34 GUID 不变
4. blockdev --rereadpt /dev/sda（或重启）→ /proc/partitions 出现 sda35
5. dd ... of=/dev/sda35 conv=fsync → 源/目标双 sha256 比对
6. e2fsck -fn /dev/sda35（或只读挂载）→ UUID 与源一致
7. 改 init（改为挂载 lnx，偏移 0）→ 重建镜像 → 部署 → 重启验证 → 再回收 super 内旧区
```

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
