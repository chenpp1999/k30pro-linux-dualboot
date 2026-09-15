# 一键安装说明（M5）

> ## ⚠️ 风险提示 —— 动手前务必读完
>
> **本项目会修改手机的引导与分区，操作不当可能造成数据丢失、系统无法启动
> （俗称"变砖"）。**
>
> - **会覆盖 `recovery` 分区**：原来的 TWRP/恢复镜像会被 Linux 引导镜像替换。
>   安装器会**先备份**到电脑，可用 `rollback` 恢复，但**备份丢了就回不来**。
> - **会写入 `super` 分区的空闲区**：那里不属于任何 Android 逻辑分区，但
>   **Android 系统更新（OTA）可能重新分配这块空间并覆盖你的 Linux rootfs**。
>   要长期稳定，请做 M3（独立 `lnx` 分区），见 `docs/m3-repart-plan.md`。
> - **`boot` 分区永不写入**（这是本项目的核心不变式）：正常情况下任何重启都会
>   回到 Android；但**读坏镜像、写错偏移、断电落在写字过程中**等极端情况仍可能
>   导致设备进入 fastboot/无法启动，需要用电脑救援（见 §7）。
> - **安装时可能要求解锁 Bootloader**：解锁会**清除全部用户数据**，且部分机型
>   会影响保修/支付相关功能。
> - **本说明与工具目前只做了离线模拟测试，尚未在真机上端到端验证**（见 §9）。
> - **任何破坏性步骤都由设备所有者自行确认并承担风险**；项目不对数据丢失或硬件
>   损坏负责（见 `README.md` 免责声明）。
> - **务必先做全量备份**（TWRP 完整备份 + 电脑留一份），并在**非主力机 / 测试机**
>   上先试。

---

## 1. 这是什么

在 Redmi K30 Pro / POCO F2 Pro（代号 `lmi`）上，用**一条命令**装出一套与
Android 并存的 Linux（Alpine + Weston 桌面），并且：

- **Android 优先**：`boot` 分区永不动，日常重启永远回 Android；
- **不重分区**：不改 GPT、不缩 `userdata`，Linux rootfs 放进 `super` 的空闲区；
- **可回滚**：安装前自动备份 recovery/boot/misc，出问题能恢复。

设计细节见 [`installer-design.md`](installer-design.md)。

## 2. 前置条件（缺一不可）

| 项目 | 要求 |
|---|---|
| 设备 | Redmi K30 Pro / POCO F2 Pro（`lmi`，SM8250），**A-only 单槽** |
| Bootloader | 已解锁 |
| 电脑 | Windows 或 Linux + `adb` / `fastboot`；能连 USB |
| 手机 | Android 能开机；已开"USB 调试"；电量 ≥ 50 % |
| 文件 | 见 §3 |
| 数据 | **已全量备份**（TWRP 完整备份 + 电脑留档） |

> 如果 `data` 里什么都没有、也不在意，可以跳过备份；否则**先备份再继续**。

## 3. 需要准备的文件（3 个）

| 文件 | 说明 | 从哪来 |
|---|---|---|
| `boot-m1b-generic-vN.img` | Linux **引导镜像**（含内核 + initramfs + firstboot 载荷） | 用 `tools/install/build-generic-image.sh` 构建（见 §3.1） |
| `rootfs-generic-vN.img` | Linux **rootfs**（ext4 镜像，**≤ 1.5 GiB**） | 项目构建产物（按 `docs/reproduce.md` 在本机/Alpine 构建） |
| `twrp.img` | TWRP 恢复镜像（**只被 RAM 引导，不刷写**） | 官方/可信来源的 `lmi` TWRP |

> ⚠️ 本项目**不发布设备镜像与 rootfs**（里面可能含按机信息）。请自行构建。
> 通用镜像**不含任何口令/SSH 密钥/WiFi**，首次启动才会随机生成（见 §5）。

### 3.1 构建通用引导镜像（可选，已会做可跳过）

```sh
tools/install/build-generic-image.sh \
  --tree <rootfs-tree> --initramfs-dir <initramfs-dir> \
  --kernel <vmlinuz> --dtb <dtb> --cmdline <cmdline> \
  --overlay-version m1b-generic-v1 \
  --recovery-dtbo <dtbo.img> \
  --out boot-m1b-generic-v1.img
```

**必须带 `--recovery-dtbo`**（否则 lmi 的引导器读不到 DTBO 会落到 fastboot）。

## 4. 一键安装（3 步）

把 §3 的三个文件放到同一目录，`cd` 过去，然后：

```sh
# ① 只读体检：检查文件、大小、sha256、super 空闲区是否够
tools/install/lmi-install.sh check \
  --recovery boot-m1b-generic-vN.img \
  --rootfs   rootfs-generic-vN.img \
  --twrp     twrp.img

# ② 预演：只打印将要做什么（不碰设备）
tools/install/lmi-install.sh plan \
  --recovery boot-m1b-generic-vN.img \
  --rootfs   rootfs-generic-vN.img

# ③ 正式安装（会重启、会写入；过程中别拔线）
tools/install/lmi-install.sh install \
  --recovery boot-m1b-generic-vN.img \
  --rootfs   rootfs-generic-vN.img \
  --twrp     twrp.img
```

> 想先看不执行，就在 ③ 后面加 `--dry-run`。
> 想免去确认提示，加 `--yes`（**不推荐**，请保留人工确认）。

安装器会自动依次完成：

```
1. 让手机重启到 bootloader
2. fastboot boot twrp.img        （只把 TWRP 载入内存运行，不刷写 recovery）
3. 备份 recovery / boot / misc / super 元数据  ->  ./lmi-install-backup/
4. 读出 super 的 LP 元数据，算出 rootfs 该放哪，并改好引导镜像的 lmi_root_off
5. 把 rootfs 写进 super 空闲区（写完回读 sha256 校验）
6. 把 Linux 引导镜像写进 recovery（回读校验）
7. 最后写一次性引导标记 BCB（写后校验）
8. 重启 -> 进入 Linux
```

每一步都"先备份、再写、写后校验"；**写 BCB 是最后一步**，所以在它之前断电，
重启都还是回 Android。

## 5. 首次启动会发生什么

- 屏幕先出现 Linux 桌面（Weston），以及一个说明书终端窗口。
- **随机生成 root 口令**：显示在控制台，并存到设备 `/root/lmi-root-password.txt`(600)。
  请第一时间记下并妥善保存；**它不会出现在任何发布物里**。
- 自动重新生成 **SSH 主机密钥** 和 **machine-id**（通用镜像不带这些）。
- **SSH 仅公钥**登录：把你的公钥放到设备 `/root/.ssh/authorized_keys` 才能用。
- **不预置任何 WiFi**：用 `lmi-wifi-scan` / `lmi-wifi-join <SSID> <PSK>` 连网。

日常使用（切系统、WiFi、监测台、充电温控、输入法）见 [`usage.md`](usage.md)。

## 6. 回滚（不想玩了 / 出问题）

```sh
tools/install/lmi-install.sh rollback --twrp twrp.img
```

它会进 TWRP，把备份的 `recovery` 恢复回去并清空 BCB（`boot` 不写）。
备份目录默认是运行 `install` 时的当前目录下的 `./lmi-install-backup/`；
换过目录用 `--work <目录>` 指定。

## 7. 出事了怎么救援

| 现象 | 处理 |
|---|---|
| 设备反复进 fastboot | 电脑上：`fastboot erase misc && fastboot reboot`（`misc` 是唯一允许 erase 的分区，见 `docs/m0-runbook.md` §5） |
| 想彻底退回原厂恢复 | `rollback`（用安装时的备份），或在 Android（root）里 `tools/m1/recovery-swap.sh restore-twrp` |
| Linux 起不来 | 任意重启都回 Android（BCB 已被 Linux 清除）；再从 §4 重新装 |
| 冷启动卡 Redmi logo 几分钟 | 已知硬件问题（aw8697），不是安装造成的，等一会儿或用"重启" |

## 8. 已知限制

1. **rootfs ≤ 1.5 GiB**：`super` 空闲区放得下，但更大的 rootfs 需要 M3。
2. **super 空闲区不持久**：Android OTA 可能覆盖，长期请做 M3。
3. **需要 TWRP 文件**：安装器不自动下载 TWRP。
4. **仅 `lmi`**：针对 K30 Pro / POCO F2 Pro；其他机型未验证。
5. **首次启动前没有可用口令**：通用镜像不带凭据，这是有意设计。
6. 内网监控面板无鉴权，勿暴露公网（见 `docs/release-v1.0.0.md`）。

## 9. 当前验证状态（重要）

- ✅ **离线模拟全绿**：LP 解析、cmdline 修补、写入顺序、体积/镜像/空闲区门禁、
  完整"假 adb/fastboot + 沙箱分区"的安装与回滚，均在 CI 与本地多轮通过
  （`tools/tests/m5-*.sh`）。
- 🚧 **真机端到端安装尚未验证**：本说明的所有真机行为（TWRP 会话、adb 流式 dd、
  首次启动）都还需要在**测试机 / 已备份设备**上由设备所有者确认后演练一遍。
  在有人跑通并记录到 `docs/acceptance/` 之前，请把它当作**实验性**功能。

## 10. 反馈

按 [`docs/reproduce.md`](reproduce.md) §7 开 issue 回报：设备/ROM/内核版本、
哪一步失败、日志、产物 sha256 与 `git rev-parse HEAD`。
