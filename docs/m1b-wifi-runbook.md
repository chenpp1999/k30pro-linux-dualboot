# M1b WiFi 试飞手册（boot-m1b-v5/v6，2026-09-14）

> 目标：在 M1b 持久 rootfs 上首次拉起 QCA6390 WiFi，然后做持久化测试与 SSH 验收
> （追踪 issue #14）。本手册同时给出**方法 A（电脑 fastboot，推荐首次使用）**与
> **方法 B（纯手机 recovery 引导）**两条路径；两者共用同一镜像。

## 0. 产物与校验

| 产物 | 位置 | sha256 |
|---|---|---|
| `boot-m1b-v7.img`（**当前部署**，含 `recovery_dtbo`） | 手机 `/sdcard/Download/phone-server/lmi-m1b/`；`/data/local/lmi-dualboot/` | `754b63b4ba3789791255d414673db0a7a1fe91e66220abcfb399ffa14529cd81`（55,029,760 B） |
| `boot-m1b-v6.img`（**勿再用于 recovery 部署**） | 同上（保留为缺陷对照） | `346343b3…`（54,546,432 B；缺 `recovery_dtbo` → recovery 引导落 fastboot，T1-03） |
| `m1b-overlay-v2.tar.gz`（**当前**） | 同上 | `db760fec6e0d58343eca6d4d08f0bc05306eea27a323556a52c42985310a76ba`（5,991,807 B，212 文件） |
| `boot-m1b-v5.img`（M1b 验收产物，保留对照/回退） | 同上 | `7658da6a6ffb8f2a398ee26256ed463ad22b781f53d9a4e8a59532b99a537b93`（54,534,144 B） |
| `m1b-overlay-v1.tar.gz` | 同上 | 5,991,682 B（210 文件） |
| `rootfs-fixed2.img`（当前部署 rootfs） | 同上；已写入 super | sha256 `0734a5de607d87f3dd642fa327c66d8077a8c710dc9e1a2c2ddc888b13e7c1cf`（1.5 GiB；2026-09-14 修补 dropbear/wpa 后） |
| `boot-m1b-v7.img.buildinfo` | 同上 | 构建记录（内核/DTB 与 v5 一致；含 recovery_dtbo sha256） |
| TWRP 备份 | `/data/local/lmi-dualboot/recovery-twrp.img`（sha 与当前 recovery 分区一致，已校验） | — |

v7 相对 v6：内核、DTB、initramfs 内容不变；打包增加 `recovery_dtbo`
（本机 dtbo 表 487,424 B）——这是从 `recovery` 分区启动的必要条件（T1-03：
缺该字段时 ABL 读不到 DTBO 表并落 fastboot）。**部署到 recovery 必须用 v7**；
v6 仅可用于 `fastboot boot`（RAM 引导）对照。

v5 相对 v4 的变化：内核、DTB 字节不变；initramfs 加了 `m1b-init.sh` v5
（rootfs 增量自动应用、引导计数、mailbox 上报）与 6 MB overlay（WiFi 用户态 +
固件 + wpa 配置）；`/init` 之前仍会清 BCB（第一次写 misc 之前的所有逻辑不变）。

## 0.1 试飞结果（2026-09-14，已完成）

M1b 收尾项（issue #14）已全部通过：WiFi 直连（<SSID>，`wpa_state=COMPLETED`，
DHCP `192.168.1.x/24`，WiFi6/HE 速率）、持久化三轮读写（boot=4→5→6）、
USB 与局域网 SSH。完整记录与证据见 `acceptance/m1b-2026-09-14.md`
（证据目录 `acceptance/m1b-2026-09-14/`）。

首次试飞发现并修复的两个真机问题（修复已进入当前部署 rootfs）：

1. **dropbear 依赖链失败**：Alpine initd 为 `need net`，rootfs 未启用
   networking → `ERROR: cannot start dropbear as networking would not start`。
   现文件：`../tools/m1/m1b/etc/init.d/dropbear`（`use net`）+
   `../tools/m1/m1b/etc/conf.d/dropbear`（`-P /run/dropbear.pid`）。
2. **wpa_supplicant `-f` 不受支持**：Alpine 构建未启用 `CONFIG_DEBUG_FILE`，
   带 `-f` 会打印 usage 并退出 → WiFi 全程 `status=failed`。现文件：
   `../tools/m1/m1b/usr/sbin/lmi-wifi-start`（`2>>/var/log/wpa_supplicant.log`）。

离线修补 rootfs 镜像必须先回放 journal，否则 `e2fsck -fy` 会把修补静默回滚——
见 `m1b-persistent.md` 第 6 节与 `../tools/m1/patch-rootfs-image.sh`。

## 1. 方法 A：电脑 `fastboot boot`（零写入，推荐）

```sh
# 电脑侧（手机已用 USB 连接、USB 调试已开）
adb pull /sdcard/Download/phone-server/lmi-m1b/boot-m1b-v6.img .
sha256sum boot-m1b-v6.img          # 应等于 346343b3…
adb reboot bootloader
fastboot devices
fastboot boot boot-m1b-v6.img      # 全程不写任何分区
```

启动后（约 30 s）宿主机会多出一个 NCM/USB 网卡：

```sh
# 电脑侧（Linux；Windows 需装 RNDIS/NCM 驱动）
sudo ip addr add 172.16.42.2/24 dev <新网卡>
ssh root@172.16.42.1               # 密码 <your-password>（M1b 的 dropbear）
```

> ⚠️ 手机与电脑之间的 USB 线不要拔；WiFi 验证时仍可保持 USB。

## 2. 验证清单（USB SSH 内执行）

```sh
# 2.1 增量应用与持久化
cat /etc/m1b-overlay-version            # m1b-wifi-v1
cat /root/m1b-boot-count                # 1
cat /root/m1b-boots.log

# 2.2 WiFi bring-up
cat /var/log/lmi-wifi.log               # 逐 stage 日志；尾部应为 exit rc=0 status=ok
ip -4 addr show wlan0                   # 应为 DHCP 租约地址（实测 192.168.1.x/24）
iw dev wlan0 link                       # 实测 HE（WiFi6）速率
/sbin/wpa_cli -i wlan0 status           # wpa_state=COMPLETED
ip route show default
ping -c2 <网关 IP>
ping -c2 1.1.1.1
DNS：cat /etc/resolv.conf

# 2.3 失败时的诊断（也会写进 mailbox）
dmesg | grep -Ei 'wlan|cnss|qca|mhi|firmware|cooldown|timeout' | tail -60
ls -l /sys/kernel/cnss/ /dev/wlan /mnt/android-* /apex/com.android.runtime
cat /var/log/cnss-daemon.log 2>/dev/null
```

## 3. 验收：局域网 SSH 直连（已通过）

1. 记下 Linux 的 wlan0 IP：`ip -4 addr show wlan0`（DHCP；MAC 与 Android 相同
   `7c:2a:db:01:95:59`，路由器可能复用旧租约）。
2. 同网段主机 `ssh root@<wlan0 IP>`（用户 root，密码 `<your-password>`）。
3. 成功后 `uname -a` 应显示 `4.19.325…aarch64 Linux`（不是 Android）。

> 实测（2026-09-14）：电脑（`192.168.1.x`，同一 <SSID>）直连
> `ssh root@192.168.1.x` 成功；USB 通道（`172.16.42.1`）同时可用。

## 4. 方法 B：纯手机 recovery 引导（无需电脑）

```sh
# Termux 内以 root 运行（本仓库 tools/m1/recovery-swap.sh 已部署到 Termux home）
sh recovery-swap.sh status
sh recovery-swap.sh to-linux --force /data/local/lmi-dualboot/boot-m1b-v6.img
```

- 该命令把 v6 写入 recovery 分区并 `reboot recovery`；回 Android 只需任意重启
  （v6 init 在挂载 rootfs 前先清 BCB）。
- **残余风险**：若镜像在清 BCB 前就崩（内核 panic），设备会反复进 recovery，
  需要 USB 主机 `fastboot erase misc` 救援；`--force` 绕过的是"方式 A 已验证"
  的门禁，本手册记录这一风险由操作者确认。
- 回滚：`sh recovery-swap.sh restore-twrp`（把 TWRP 写回 recovery）。

## 5. 从 Android 读 mailbox（无 USB 也能拿报告）

```sh
# Android root（rootbridge）：
dd if=/dev/block/by-name/super bs=4096 skip=1990324 count=16 2>/dev/null | strings   # init
dd if=/dev/block/by-name/super bs=4096 skip=1990356 count=16 2>/dev/null | strings   # wifi
dd if=/dev/block/by-name/super bs=4096 skip=1990372 count=16 2>/dev/null | strings   # persist
```

（对应 super 内 rootfs 尾部 1 MiB 之后的一段空闲区；不涉及任何分区元数据。）

## 6. 已知不确定点（首次试飞重点观察；2026-09-14 复核）

> 复核结论：第 1–4 项全部通过（无需补 rmtfs/pd-mapper 等；EROFS 偏移、REGDOM、
> MAC 租约复用均正常，`wlan0` 秒级出现、数秒内完成 wpa+DHCP）。
> 唯一遗留：内核偶发 `cnss: Firmware does not support non-DRV suspend, reject`
> 告警（功能无影响），M2 评估。详见 `acceptance/m1b-2026-09-14.md`。

1. **cnss-daemon 依赖链**：v1 overlay 未包含 `rmtfs`/`tqftpserv`/`pd-mapper`
   （D80 基线里有，但它们可能只服务 modem/ADSP）。若 `wlan0` 出现但固件加载
   超时/COEX 报错，下一步再补这组二进制。
2. **vendor/system EROFS 挂载**：内核支持 EROFS；偏移来自本机 `lpdump`
   （system 3652190208、vendor 5514461184）。
3. **REGDOM**：`country=CN` 已在 wpa_supplicant.conf；regdb 固件已随 overlay。
4. **MAC**：使用 persist 里 `wlan0=7c2adb019559`，与 Android 相同 → 路由器
   大概率复用原 DHCP 租约（192.168.5.12）。
