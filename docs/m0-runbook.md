# M0 操作手册（RAM 启动验证）

> 状态：产物已构建并校验，等待部署。
> 风险级别：**方式 A 零写入；方式 B 仅写 recovery（可回滚，boot 永不改动）**。
> 本手册执行前不需要负责人额外批准（M0-M2 属于低风险阶段，见 charter §6）。

## 1. 产物清单

| 产物 | 字节数 | SHA-256 |
|---|---|---|
| `boot-m0.img` | 47,632,384 | `a216ff4790a0ee2f89a01ef38884a5d17ff8fffaf8c6de13a82a638fa4c3dd9f` |
| `initramfs.cpio.gz` | 3,492,243 | `4d26405413eb0fac4c775fb9e56b91699a1c09a7185332764789207400582326` |

> 2026-09-13 终轮重建（方式 A 验收通过，见 `docs/acceptance/m0-2026-09-13.md`）：
> USB gadget NCM 优先（RNDIS 回退，issue #2）；`init` 强制 LF（issue #3）；
> 新增 `m0-display` 显示接管（issue #4）。

组成（全部有公开来源与校验）：

- 内核 `vmlinuz`：`jian45154/redmi-k30-pro-postmarketos` D80 release 中
  `linux-xiaomi-lmi-4.19.325-r9.apk`（该内核已在本机型实机启动验证过）
- 设备树：`kona-v2.1-lmi.dtb`（同上 APK）
- initramfs：本项目自建（静态 busybox + dropbear + eventdump + init；
  USB 网络 gadget：NCM 优先、RNDIS 回退；`m0-display`：无 fbdev 下的最小
  KMS 接管——色条 + 背光 + 常驻 DRM master）
- 构建：`tools/m0/build.sh`（可复现）

产物位置（手机）：`/sdcard/Download/phone-server/lmi-m0/`

## 2. 验收标准（M0-Acceptance）

在 Linux 启动后逐项确认：

- [ ] A1 内核启动（设备进入 Linux，无 Android 界面）
- [ ] A2 USB 网卡在宿主侧出现（RNDIS，宿主可 `ping 172.16.42.1`）
- [ ] A3 SSH/telnet 可登录（`ssh root@172.16.42.1`，密码 `<your-password>`）
- [ ] A4 `eventdump /dev/input/event3`（`fts_ts`）能收到触摸事件
- [ ] A5 面板显示 1080x2400 色条（`m0-display` 自动接管：DSI/panel 绑定成功、
  `card0-DSI-1` = `enabled`、`bl_power=0`；完整 UI/Weston 属 M1）
- [ ] A6 返回 Android 正常（`reboot -f` 或长按电源；普通 `reboot` 对
  PID1=busybox sh 无效，2026-09-13 实测）
- [ ] A7 全程未写 boot/userdata/super（方式 A）或仅写 recovery（方式 B）
- [ ] A8（方式 B 前置门禁）同一镜像已通过方式 A 实机启动成功，且已生成
  attestation（§4 第 2 步）；未满足不得执行方式 B

A1–A5 为 M0 验收项（2026-09-13 终轮全过）；完整 UI（seatd/Weston 等）属 M1。

## 3. 方式 A：`fastboot boot`（零写入，需要 USB 宿主）

宿主选择：PC（Windows/Linux 均可）> 已 root 的 Android 手机 + OTG。

1. 在宿主安装 fastboot（platform-tools）；
2. 将 `boot-m0.img` 从手机拷贝到宿主（MTP 路径
   `Download/phone-server/lmi-m0/boot-m0.img`）；
3. 手机关机；
4. 按住 **音量下 + 电源** 进入 fastboot 界面；
5. USB 连接，宿主执行：`fastboot devices`（应列出设备）；
6. 宿主执行：`fastboot boot boot-m0.img`；
7. 等待 30–60 秒。宿主侧应出现一个新网卡（RNDIS）；
8. 宿主配置静态 IP：

   - Linux：`sudo ip addr add 172.16.42.2/24 dev <新网卡> && sudo ip link set <新网卡> up`
   - Windows：适配器属性 → IPv4 → 手动 `172.16.42.2 / 255.255.255.0`

9. `ssh root@172.16.42.1`（密码 `<your-password>`）；若 SSH 不通，
   `telnet 172.16.42.1` 兜底；
10. 收集证据（在宿主执行）：
    `ssh root@172.16.42.1 'dmesg' > dmesg.txt` 等；
11. **记录门禁证据**：拍照/保存 dmesg 与宿主网卡信息。方式 A 成功是方式 B
    的唯一门禁：成功后用**同一镜像**（SHA-256 一致）在手机上生成 attestation
    （见 §4 第 2 步）。
12. 退出：在 Linux 里 `reboot -f`（普通 `reboot` 不生效，见 A6 注；BCB 已被
    Linux 清除 → 回 Android）。也可长按电源强制重启。

回滚：无需（未写任何分区）。

> **Windows 宿主准备（真机救援实测）**：`fastboot.exe` 通过 `AdbWinApi` 访问设备，
> 要求设备接口带 GUID `{F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}`（Google USB Driver
> 自带；若改用 Zadig/libwdi 的 WinUSB 驱动，需给设备补上该 GUID）。
> 典型症状：`fastboot devices` 能列出设备但命令报 `AdbWriteEndpointSync failed`
> （错误 31/121）——完整重进一次 fastboot（长按电源关机 → 音量下+电源）即可恢复。

## 4. 方式 B：recovery-swap（无需宿主，需 Android root）

> 原理：ADR-0001。Linux 引导镜像写入 `recovery` 分区，`reboot recovery`
> 触发一次性进入；`boot` 分区始终是 Android。首次写入前必须完成备份。
> 缺点：没有宿主时只能看屏幕（无法 SSH），证据以照片为主。
> ⚠️ Linux 镜像若未启动，BCB 不会被清除，设备可能循环进入 fastboot；
> 救援流程见 §5。因此**写入前必须完成本节的预检门禁**。

执行环境：Termux root 通道（opencode 里可直接代跑）。

1. **备份（必须，纯读取）**：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh backup
   ```

   产物：`/data/local/lmi-dualboot/recovery-twrp.img`（+ sha256）与
   `boot-android.img`（+ sha256）。

2. **门禁：同一镜像必须先经方式 A 实机启动成功，并生成 attestation**
   （issue #1 起强制；SHA-256 必须与方式 A 使用的镜像一致）：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh attest-ramboot \
      /sdcard/Download/phone-server/lmi-m0/boot-m0.img
   ```

   产物：`boot-m0.img.ramboot-ok`。**方式 A 未成功前不得执行本步。**

3. **部署（默认预检：SHA-256 清单 + attestation + `ANDROID!` 头 + 分区大小，
   任一缺失即拒绝写入）**：

   ```sh
   # 先干跑（只做预检，不写入）：
   sh /data/data/com.termux/files/home/recovery-swap.sh to-linux --dry-run \
      /sdcard/Download/phone-server/lmi-m0/boot-m0.img
   # 确认后正式写入并重启：
   sh /data/data/com.termux/files/home/recovery-swap.sh to-linux \
      /sdcard/Download/phone-server/lmi-m0/boot-m0.img
   ```

   `--force` 可跳过门禁，仅限救援/紧急场景，绝不用于首次部署。

4. 设备自动重启进 Linux；观察屏幕自检报告（input/network/dmesg）。
5. 返回 Android：长按电源强制重启（BCB 已清）。
6. 需要 TWRP 时：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh restore-twrp
   ```

   然后 `reboot recovery` 即回到 TWRP。

回滚：`restore-twrp`；boot 分区从未改动。写入后若设备停在 fastboot（Linux
未启动），先按 §5 救援回 Android，再做 `restore-twrp`。

## 5. 失败处理与救援

原则：Android 可回退由架构保证（`boot` 从未改动），但**方式 B 下 Linux 镜像
未启动时 BCB（`boot-recovery`）会残留**，设备可能反复进入 recovery→fastboot。
按现象处置；进入 fastboot 后需要 USB 宿主（PC / platform-tools）。

### 5.1 Linux 未启动，设备停在 / 循环进入 fastboot（方式 B 已知失败模式）

症状：部署并重启后屏幕停在 fastboot，再次重启仍回 fastboot。
根因：Linux init 从未运行 → BCB 未清除；`boot` 分区与 Android 数据完好。
救援（在 USB 宿主的 platform-tools 目录执行）：

```sh
fastboot devices          # 应列出设备
fastboot getvar unlocked  # 应显示 unlocked: true
fastboot erase misc       # 唯一允许的 erase 例外：仅清 BCB（4MB）
fastboot reboot           # 应回到 Android
```

- 严禁 `fastboot -w`、严禁 relock、严禁 erase/flash 其他任何分区。
- 回到 Android 后，recovery 分区仍是 Linux 镜像，用
  `sh /data/data/com.termux/files/home/recovery-swap.sh restore-twrp`
  恢复 TWRP（备份在 `/data/local/lmi-dualboot/`）。
- 二级救援（可选）：可 `fastboot boot <已备份的 TWRP 镜像>` RAM 启动 TWRP；
  也可 `fastboot boot boot-m0.img` 先确认 Linux 镜像本身能否启动，再决定恢复动作。
- 本路径只是救援；内核为何未启动按缺陷分析另单跟踪（勿在 fastboot 里试错）。

### 5.2 Linux 启动了，但 USB 网络 / SSH 不通

强制重启回 Android（BCB 已在 Linux init 早期清除）；保留屏幕照片与（可能的）
dmesg；按 test-plan 记录，进入缺陷分析。

### 5.3 回到 Android 后仍异常（理论不可能）

`boot` 分区从未被本流程改动。先 `fastboot erase misc` 清 BCB 再试；仍失败时，
用备份重刷 `boot`（`fastboot flash boot boot-android.img`，备份位于
`/data/local/lmi-dualboot/`），并开 P1 缺陷。

### 5.4 红线

- 除救援场景的 `fastboot erase misc` 外，**任何情况下不要执行 `fastboot erase`**；
- 不要 `fastboot flash` 未经备份核对的分区，不要 relock，不要 `fastboot -w`；
- 未完成方式 A 实机验证（attestation）不得执行方式 B（§4 门禁）。

## 6. 结果记录

执行人在 `docs/acceptance/` 下新增 `m0-<日期>.md`，使用 test-plan 的验收记录
模板，附哈希与照片/日志。通过后更新 charter 里程碑表（M0 ✅）并开 M1。
