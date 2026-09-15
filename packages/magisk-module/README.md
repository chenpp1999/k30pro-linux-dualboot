# packages/magisk-module — Android → Linux 一键切换（v0.2）

Magisk 模块，把 M2 的切换器包装成"一键"入口：

- **Action 按钮**（Magisk 27+ 的模块卡片）或 root shell 里执行
  `/data/adb/modules/lmi-dualboot-switch/action.sh`。
- **镜像自动选择**：`/data/local/lmi-dualboot/boot-m1b-vNN.img` 或
  `/sdcard/Download/phone-server/lmi-m1b/boot-m1b-vNN.img` 中版本号最大的一个；
  也可用 `LMI_SWITCH_IMG=<path>` 指定。
- **安全门禁**：沿用 `recovery-swap.sh to-linux` 的规则——没有方式 A
  （RAM 引导）attestation 的镜像会被拒绝；`LMI_SWITCH_FORCE=1` 仅用于救援/测试。
- **只读演练**：`LMI_SWITCH_DRY=1 .../action.sh` 只打印将执行的操作（`--dry-run`），
  不写任何分区。
- **不变式**：`boot` 分区永不修改；切过去后 Linux init 会清 BCB，之后任何重启都回
  Android（`docs/architecture.md` §4）。

## 构建

```sh
packages/magisk-module/build.sh          # -> packages/magisk-module/lmi-dualboot-switch.zip
```

## 安装

- Magisk App → 模块 → 从本地安装（选 zip）；或
- root shell：`magisk --install-module /path/to/lmi-dualboot-switch.zip`。

⚠️ **安装后需要重启一次**：Magisk 30.x 的 CLI 安装会把模块放进
`/data/adb/modules_update/`，重启时才搬到 `/data/adb/modules/` 并让模块卡片与
Action 按钮生效（`ls` 只看到 `module.prop` 是正常现象）。

## 两条路径（action.sh）

| 场景 | 行为 |
|---|---|
| **FAST**：`recovery` 里已经是所选镜像（前 N 字节 sha256 与镜像一致） | 只写一次性 BCB 然后重启——**不重写任何镜像**，也无需 attestation |
| **FULL**：镜像不同 | 委托 `recovery-swap.sh to-linux`：写镜像 → 回读校验 → 写 BCB → 重启；无方式 A attestation 的镜像会被拒绝（`LMI_SWITCH_FORCE=1` 仅救援/测试） |

镜像选择：`$LMI_SWITCH_IMG` > 两个已知目录里 **版本号最大** 的
`boot-m1b-vNN.img`（`/data/local/lmi-dualboot`、`/sdcard/Download/phone-server/lmi-m1b`）。

实测（2026-09-15，Magisk 30.7）：`LMI_SWITCH_DRY=1 .../action.sh` 会打印
"recovery already holds this image -> fast path"，即当前 recovery（v11）与
`sdcard/.../boot-m1b-v11.img` 哈希一致时，一键切换 = 写 BCB + 重启。

## 用法

```sh
# 演练（不动分区）
adb shell su -c 'LMI_SWITCH_DRY=1 /data/adb/modules/lmi-dualboot-switch/action.sh'

# 真切换（会写 recovery + BCB 并重启）
adb shell su -c '/data/adb/modules/lmi-dualboot-switch/action.sh'
```

切回 Android：在 Linux 里 `reboot`（或长按电源/断电）即可——BCB 已被 Linux 清掉。

## 备注

- 这是便利封装，安全语义与 `tools/m1/recovery-swap.sh` 完全一致（M2 v0.1）。
- 更"图形化"的入口（快捷磁贴/独立 App）不在本期范围（`packages/android-app` 仍为空）。
