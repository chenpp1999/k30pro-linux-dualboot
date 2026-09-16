# packages/magisk-module — Android → Linux 一键切换（v0.3）

Magisk 模块，把 M2 的切换器包装成"一键"入口：

- **Action 按钮**（Magisk 27+ 的模块卡片）或 root shell 里执行
  `/data/adb/modules/lmi-dualboot-switch/action.sh`。
- **按优先级决定做什么**（第一条命中即止）：
  1. `LMI_SWITCH_IMG=<path>` → 部署**指定镜像**（recovery 已一致就 FAST，否则 FULL）；
  2. **`recovery` 里已经是 Linux**（`ANDROID!` 魔数 + 启动 cmdline 含 `lmi_root_off=`）
     → **FAST：只写一次性 BCB 然后重启**，不挑镜像、不需要 attestation；
  3. 否则（`recovery` 是 TWRP/空）→ 挑**最新且已 attest** 的镜像做 FULL。
- **为什么默认是 2**：装好之后 `recovery` 里就是当前 Linux 镜像（设备内
  `tools/m1/rebuild-image-from-device.sh` 直接 dd 的，见 `docs/handoff.md` §二），
  点按钮就该只是"切过去"，**不该**去 `/sdcard` 找旧镜像重装。2026-09-16 的 bug
  就是它拿了 v11（未 attest）去覆盖，被门禁拒绝且 FATAL 走 stderr，Magisk 窗口
  什么都看不到，表现为"点了没反应"。
- **部署别的镜像**：显式设 `LMI_SWITCH_IMG`；或先把 TWRP 写回 `recovery`
  （那样走第 3 条）。第 3 条只接受带匹配 `<img>.ramboot-ok` 的镜像，
  `LMI_SWITCH_FORCE=1` 仅救援/测试。
- **诊断可见**：脚本开头 `exec 2>&1`，子脚本的 `FATAL` 会出现在 Magisk 输出里；
  没有任何可部署镜像时会列出候选并说明如何 attest。
- **只读演练**：`LMI_SWITCH_DRY=1 .../action.sh` 只打印将执行的操作（`--dry-run`），
  不写任何分区、不重启。
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

## FAST 与 FULL（action.sh）

| 路径 | 触发 | 行为 |
|---|---|---|
| **FAST** | `recovery` 已经是要用的 Linux 镜像（第 2 条），或所选镜像与 `recovery` 前 N 字节 sha256 一致 | 只写一次性 BCB 然后重启——**不重写任何镜像**，也无需 attestation |
| **FULL** | 所选镜像与 `recovery` 不同 | 委托 `recovery-swap.sh to-linux`：写镜像 → 回读校验 → 写 BCB → 重启；无方式 A attestation 的镜像会被拒绝（`LMI_SWITCH_FORCE=1` 仅救援/测试） |

镜像选择（仅第 1/3 条用得到）：`$LMI_SWITCH_IMG`，或两个已知目录
（`/data/local/lmi-dualboot`、`/sdcard/Download/phone-server/lmi-m1b`）里
**已 attest 且版本号最大**的 `boot-m1b-vNN.img`。

离线回归测试：`tools/tests/m2-action-test.sh`（合成镜像 + `LMI_SWITCH_DRY=1`，
不写分区、不重启，CI 运行）。

## 用法

```sh
# 演练（不动分区）
adb shell su -c 'LMI_SWITCH_DRY=1 /data/adb/modules/lmi-dualboot-switch/action.sh'

# 真切换（默认：recovery 已有 Linux → 只写 BCB + 重启）
adb shell su -c '/data/adb/modules/lmi-dualboot-switch/action.sh'

# 部署指定镜像（会写 recovery + BCB 并重启）
adb shell su -c 'LMI_SWITCH_IMG=/sdcard/Download/phone-server/lmi-m1b/boot-m1b-v21.img \
  /data/adb/modules/lmi-dualboot-switch/action.sh'
```

不想进 Magisk UI 也想立刻切换（只写 BCB，最轻量）：

```sh
adb shell su -c 'sh /data/adb/modules/lmi-dualboot-switch/recovery-swap.sh bcb boot-recovery && reboot'
```

切回 Android：在 Linux 里 `reboot`（或长按电源/断电）即可——BCB 已被 Linux 清掉。

## 备注

- 这是便利封装，安全语义与 `tools/m1/recovery-swap.sh` 完全一致（M2 v0.1）。
- 更"图形化"的入口（快捷磁贴/独立 App）不在本期范围（`packages/android-app` 仍为空）。
