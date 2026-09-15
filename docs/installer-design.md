# M5 — 一键安装设计（PC 一键脚本 + 通用镜像）

> 状态：**v0.1 设计 + 地基已落地**（LP 解析器、离线测试、通用镜像构建脚本、
> 首次启动初始化载荷）。**PC 一键安装脚本与 TWRP 集成尚未实现**。
> 追踪：`docs/charter.md` M5 门禁、`docs/handoff.md` §八、issue #13（super 写保护）。
> **任何写分区步骤都必须由设备所有者本人确认**；本文的自动步骤同样受此约束。

## 1. 目标与非目标

- **目标**：让没参与本项目的人，用一台 PC + 数据线，就能在另一台 `lmi`
  上装出与本项目一致的双系统，且**不需要他懂分区**。
- **非目标**：
  - 不改 Android 既有分区内容（`boot` 永不动，见 `docs/architecture.md` §1）；
  - **不自动重分区**：M3（userdata 缩容 + 新建 `lnx`）永远保持手动、可选
    （`tools/m3/lmi-repart.sh` 的 `apply` 故意不实现）；
  - 不发布设备镜像（通用镜像里不能有任何按设备生成的秘密）。

## 2. 为什么是"PC 脚本 + 通用镜像"

| 形态 | 可行性 | 结论 |
|---|---|---|
| 纯 Android App 一键 | Android 用户态（含 Magisk root）写 `super` 被 `baseband_guard` 内核拒绝（issue #13，实测 `deny write to protected partition`） | ❌ 不可行 |
| PC 脚本 + TWRP 写入 stage | TWRP 是独立内核，无 `baseband_guard`；实测写 super 484 MB/s、回读 sha256 一致 | ✅ 选定 |
| 只发"按机镜像" | 镜像里有 WiFi 凭据、主机名、救援口令 | ❌ 违反 `SECURITY.md` |

因此：**PC 一键脚本（负责编排）+ 通用镜像（零固定凭据）**。安装阶段必须经
TWRP（或等价的独立恢复环境）写入 `super`，其余步骤可在 Android 用户态完成。

## 3. 安装流程（目标形态）

```
PC 侧 install 脚本（对用户是一条命令）：
  0. 前置检查：设备型号 lmi、bootloader 解锁、adb 可用、镜像 sha256 匹配、
     电量 ≥ 50 %、可用磁盘空间。
  1. 备份：读 recovery/boot/misc、super 的 LP 元数据、GPT（文本 + 二进制）。
     ——没有备份就不继续（硬门禁）。
  2. 解析 super：tools/install/lp-metadata.py 找空闲区（见 §4）。
  3. 写入（用户确认后，全部在 RAM 引导的 TWRP 内完成，`fastboot boot twrp.img`
     只引导不刷写；`super` 从 PC 经 adb 流式 `dd` 写，不在设备上落临时文件）：
     a. 备份 recovery / boot / misc / super 元数据到 PC（**没有备份不继续**）；
     b. 按设备 LP 元数据算偏移，把引导镜像 cmdline 的 `lmi_root_off` 改成实际值；
     c. 写 rootfs 镜像到 super 空闲区（`dd` + 回读 sha256 校验）；
     d. 写 recovery = 通用 Linux 引导镜像（dd + 回读校验）；
     e. 写 misc/BCB = "boot-recovery"（写后校验）。
  4. 重启：BCB → recovery(Linux) → Linux 首次启动做凭据/身份初始化（§5）。
  5. 回滚：任一步失败或用户取消 → 恢复备份的 recovery/misc（BCB 清零）；
     rootfs 区未被引用即"未生效"，可清零。
```

每一步都遵循 `docs/architecture.md` §1 的不变式：**先备份、再写、写后校验、
任何时刻断电都能回到 Android 或可救援状态**。

### 3.1 断电窗口

- 先写 rootfs（长）+ recovery（长），最后写 BCB（短）。
- 在写 rootfs/recovery 期间断电：BCB 仍为空 → 重启回 Android；recovery 可能
  处于"半新半旧"，但 `boot` 分区未动，Android 可正常启动并重刷 recovery。
- 只在 BCB 写入后、重启前断电：重启进 Linux；Linux init 会清 BCB，之后重启回 Android。
- Linux 内核未启动（BCB 残留）→ 按 `docs/m0-runbook.md` §5 救援：
  `fastboot erase misc`（唯一 erase 例外）。

## 4. super 空闲区定位（LP 元数据）

`super` 的空间不是由 GPT 描述，而是由分区开头的 **liblp 元数据**描述。安装器
只能用"LP 未分配的空隙"。工具：`tools/install/lp-metadata.py`（只读，纯标准库）。

### 4.1 布局（实测 `lmi`，`super` = /dev/sda32，512 B 扇区）

```
偏移 0        : 保留（4096 B）
偏移 4096     : 主 geometry   (LP_METADATA_GEOMETRY_SIZE = 4096)
偏移 8192     : 备份 geometry
偏移 12288    : 主元数据 slot 0..N-1（metadata_max_size 各一份）
...           : 备份元数据 slot 0..N-1
```

- geometry 魔数 `0x616c4467`（`67 44 6c 61`）；header 魔数 `0x414C5030`
  （`30 50 4c 41`）。工具**扫描** geometry 位置，不硬编码 4096。
- 校验：geometry/header 的 checksum 是"把 checksum 字段清零后的整块 SHA-256"，
  tables 是 tables 区 SHA-256（与 AOSP 一致，已在真机与合成镜像上验证）。
- `LpMetadataBlockDevice.size` 单位是**字节**（真机 9,126,805,504 = `/dev/sda32` 实际大小）。

### 4.2 本机实测结果

```
partitions: odm / product / system / system_ext / vendor
metadata region: 274,432 B (268 KiB)
最大空闲区: offset 12,774,816 扇区 = 6,540,705,792 B，size 5,050,976 扇区 ≈ 2.41 GiB
```

这与 issue #13 记录的"空闲区扇区 12,774,816 起、约 2.41 GiB"完全一致；项目
M1b 的 rootfs 就落在该处（cmdline `lmi_root_off=1596852`，单位 4096 B）。

### 4.3 工具用法

```sh
# 在 super 的副本上（推荐；adb 拉出或 TWRP 里 dd 出来）
python3 tools/install/lp-metadata.py info   super.img
python3 tools/install/lp-metadata.py json   super.img
python3 tools/install/lp-metadata.py free   super.img --min-size 1G
python3 tools/install/lp-metadata.py select super.img --size 1500M --align 1M
# -> offset=... size=... offset_sectors=... size_sectors=...
```

`select` 选**最大**的、按 `--align` 对齐后仍装得下的空隙（对齐后起点必须落在
空隙内），并把偏移/大小打印给安装脚本。退出码 2 = 装不下。

> ⚠️ LP 报告的"空闲"只表示**未被 LP 逻辑分区占用**。项目自己的旧 rootfs
> （或第三方工具写入的内容）也在这里；安装器必须在写入前把目标区域清零/覆盖，
> 并把它当作"可回收空间"处理，不能假设里面是空的。

## 5. 通用镜像：零固定凭据

通用镜像 = 一份可公开发布的引导镜像，**不含任何秘密或设备身份**：

| 项目 | 通用镜像的做法 |
|---|---|
| root 口令 | 首次启动随机生成，写 `/etc/shadow`（SHA-512 crypt），明文显示到控制台并留在 `/root/lmi-root-password.txt`(600) |
| SSH 主机密钥 | 不预置；首次启动用 `dropbearkey` 重新生成 |
| SSH 认证 | 仅公钥（`DROPBEAR_OPTS` 追加 `-s` 关闭口令登录），`/root/.ssh/authorized_keys` 由用户自行放入 |
| machine-id | 不预置/置空；首次启动重新生成（32 hex） |
| WiFi | 不预置任何网络（只保留 `wpa_supplicant.conf.template`） |
| 救援口令（initramfs dropbear） | 不随镜像固定；构建时随机生成或安装时按机注入 |
| 设备标识 | 不收录序列号/CPUID/证书 |

### 5.1 首次启动载荷（已实现）

- `tools/install/firstboot/lmi-firstboot`：一次性初始化（幂等，`/etc/lmi-firstboot-done` 守卫）。
  支持 `--dry-run`、`--root <dir>`（测试沙箱）、`--force`。
- `tools/install/firstboot/lmi-firstboot.initd`：OpenRC 服务，`before dropbear lmi-wifi m1-weston`。
- 构建时由 `tools/install/build-generic-image.sh` 注入到 payload overlay。

### 5.2 构建通用镜像（已实现）

```sh
tools/install/build-generic-image.sh \
  --tree <rootfs-tree> --initramfs-dir <dir> \
  --kernel <vmlinuz> --dtb <dtb> --cmdline <file> \
  --overlay-version m1b-generic-vN \
  --recovery-dtbo <dtbo.img> \
  --out boot-m1b-generic-vN.img
```

- **零凭据门禁（fail-closed）**：树里出现
  `etc/wpa_supplicant/wpa_supplicant.conf`、root 有可用口令哈希（非 `!`/`*`）、
  非空 `machine-id`、预置 SSH 主机密钥或非空 `authorized_keys`、或命中凭据正则，
  一律**拒绝构建**。私有用途可用 `--allow-credentials` 跳过（并打警告）。
- 随后调用 `tools/m1/build-m1b-image.sh` 组装，两者不会走偏。
- **recovery 部署必须带 `recovery_dtbo`**（T1-03：缺该字段 ABL 落 fastboot）。

## 6. 安全与威胁模型

- 通用镜像、仓库、Release **不得**出现真实口令/哈希/SSID/设备标识（CI 第 4 项拦截）。
- 安装器的备份（`boot`/`recovery`/`misc`/super 元数据）落在 PC 侧/设备数据区，
  含设备私有信息，**不得**随日志上传。
- SSH 只走 USB-NCM（`172.16.42.1`）或受控局域网；`lmi-monitor` 面板无鉴权，
  不得暴露公网（`docs/release-v1.0.0.md` 已知限制 6）。
- 首次启动初始化**必须在网络服务与桌面之前**完成（`before dropbear lmi-wifi m1-weston`），
  否则随机口令/主机密钥生成前可能已暴露默认状态。

## 7. 交付物与状态

| 交付物 | 路径 | 状态 |
|---|---|---|
| LP 元数据解析器 | `tools/install/lp-metadata.py` | ✅ 已实现，真机核对通过 |
| LP 解析离线测试 | `tools/tests/m5-lp-parse-test.sh` | ✅ 合成 super 镜像，CI 运行 |
| 首次启动初始化载荷 | `tools/install/firstboot/` | ✅ 已实现 + 沙箱测试（`tools/tests/m5-firstboot-test.sh`） |
| 通用镜像构建脚本 | `tools/install/build-generic-image.sh` | ✅ 已实现（零凭据门禁 + dry-run） |
| 引导镜像 cmdline 修补 | `tools/install/patch-cmdline.py` | ✅ 已实现（把 `lmi_root_off` 改成设备实际偏移） |
| PC 一键安装脚本 | `tools/install/lmi-install.sh` | ✅ 已实现（`check`/`plan`/`install`/`rollback`，全 `--dry-run`） |
| 安装器离线测试 | `tools/tests/m5-install-test.sh` | ✅ 合成 super/boot 镜像，CI 运行 |
| 设备端到端验证 | — | 🚧 **未做**（破坏性；需负责人 + 测试机，见 §8） |
| 安装时公钥注入 | 待建 | 🚧 未实现（通用镜像 SSH 仅公钥，用户自行放 `authorized_keys`） |
| `--grow`（大 rootfs = 自动化 M3） | 待建 | 🚧 未实现（默认不做，见 §9） |

### 7.1 用法（小白一条命令）

```sh
# 0. 需要：解锁的 lmi + USB 线 + 已开 USB 调试；准备好三个文件：
#    boot-m1b-generic-vN.img（Linux 引导镜像）
#    rootfs-generic-vN.img（≤1.5 GiB 的 ext4 rootfs 镜像）
#    twrp.img（TWRP，仅 RAM 引导，不刷写）
tools/install/lmi-install.sh check   --recovery boot-m1b-generic-vN.img \
                                     --rootfs rootfs-generic-vN.img --twrp twrp.img
tools/install/lmi-install.sh plan    --recovery boot-m1b-generic-vN.img \
                                     --rootfs rootfs-generic-vN.img
tools/install/lmi-install.sh install --recovery boot-m1b-generic-vN.img \
                                     --rootfs rootfs-generic-vN.img --twrp twrp.img
# 出问题回滚：
tools/install/lmi-install.sh rollback --twrp twrp.img
```

`install` 会自动：进入 fastboot → `fastboot boot twrp`（只引导、不刷写）→ 备份
recovery/boot/misc/super 元数据 → 用 LP 元数据算偏移并修补 cmdline → 写 rootfs →
写 recovery → 写 BCB → 重启进 Linux。加 `--dry-run` 只打印步骤、不碰设备。

## 8. 验收标准（M5）

1. 在**干净的** `lmi` 上，一条命令完成安装；全程无手工分区命令。
2. 安装前 `boot` 分区 sha256 记录，安装后**不变**。
3. 中断电演练：BCB 写入前断电 → 重启回 Android；BCB 写入后断电 → 进 Linux 且
   再重启回 Android。
4. 通用镜像零凭据检查通过（CI 门禁 + 人工复核）。
5. 任意一步失败可一键回滚（recovery / misc 恢复原状）。
6. 外部用户（G5）能按 `docs/reproduce.md` + 本脚本装成。

## 9. 未决问题 / 下一步

1. **rootfs 大小（已定：默认 1.5 GiB 固定槽位）**：`super` 空闲区实测 ≈ 2.41 GiB，
   而 `m1b-init.sh` 的 rootfs 槽位与 mailbox 都是按 **1.5 GiB（393216 × 4096 B）** 常量
   排布的，所以通用 rootfs 目标 ≤ 1.5 GiB。实测整套系统（Alpine + weston + 字体 +
   输入法 + 监控，去掉构建残留）只占 **~1.0 GiB**，够用；安装器会拒绝 > 1.5 GiB 的镜像。
   想要更大 rootfs 的正解是 M3（独立 `lnx` 分区），后续可做成安装器的 opt-in `--grow`
   （复用 `tools/m3/lmi-repart.sh`，备份门禁后自动执行）。**注意**：`super` 空闲区不持久，
   Android OTA 可能重新分配逻辑分区把它覆盖——这是独立分区（M3）存在的根本原因。
2. **TWRP 获取与校验**：安装器要能自动进入 TWRP 并校验其来源（首选中立镜像源，
   记录 sha256）。
3. **recovery 槽位复用**：安装后 recovery = Linux 镜像，原 TWRP 需备份成文件
   （现有 `recovery-swap.sh backup` 已覆盖）。
4. **首次启动口令的可见性**：桌面起来之前要保证用户能看到控制台上的口令
   （显示路径、串口、或 USB SSH 的 `firstboot` 输出）。
5. WiFi 掉线根因（`lmi-netwatch` 兜底）与上游回馈（0015/0018/0019）与本里程碑并行。

## 10. 关联

- 工具：`tools/install/`、`tools/m1/build-m1b-image.sh`、`tools/m1/recovery-swap.sh`、
  `tools/m3/lmi-repart.sh`
- 文档：`docs/reproduce.md`、`docs/architecture.md` §2/§3、`docs/m2-runbook.md`、
  `docs/m3-repart-plan.md`、`docs/handoff.md` §八
- 测试：`tools/tests/m5-lp-parse-test.sh`、`tools/tests/m5-firstboot-test.sh`（CI）
