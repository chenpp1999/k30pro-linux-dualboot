# M1b WiFi 试飞手册（boot-m1b-v5，2026-09-14）

> 目标：在 M1b 持久 rootfs 上首次拉起 QCA6390 WiFi，然后做持久化测试与 SSH 验收
> （追踪 issue #14）。本手册同时给出**方法 A（电脑 fastboot，推荐首次使用）**与
> **方法 B（纯手机 recovery 引导）**两条路径；两者共用同一镜像。

## 0. 产物与校验

| 产物 | 位置 | sha256 |
|---|---|---|
| `boot-m1b-v5.img` | 手机 `/sdcard/Download/phone-server/lmi-m1b/`；`/data/local/lmi-dualboot/` | `7658da6a6ffb8f2a398ee26256ed463ad22b781f53d9a4e8a59532b99a537b93`（54,534,144 B） |
| `m1b-overlay-v1.tar.gz` | 同上 | 6,0 MB（210 文件；rootfs 增量） |
| `boot-m1b-v5.img.buildinfo` | 同上 | 构建记录（内核/DTB hash 与旧版一致） |
| TWRP 备份 | `/data/local/lmi-dualboot/recovery-twrp.img`（sha 与当前 recovery 分区一致，已校验） | — |

v5 相对 v4 的变化：内核、DTB 字节不变；initramfs 加了 `m1b-init.sh` v5
（rootfs 增量自动应用、引导计数、mailbox 上报）与 6 MB overlay（WiFi 用户态 +
固件 + wpa 配置）；`/init` 之前仍会清 BCB（第一次写 misc 之前的所有逻辑不变）。

## 1. 方法 A：电脑 `fastboot boot`（零写入，推荐）

```sh
# 电脑侧（手机已用 USB 连接、USB 调试已开）
adb pull /sdcard/Download/phone-server/lmi-m1b/boot-m1b-v5.img .
sha256sum boot-m1b-v5.img          # 应等于 7658da6a…
adb reboot bootloader
fastboot devices
fastboot boot boot-m1b-v5.img      # 全程不写任何分区
```

启动后（约 30 s）宿主机会多出一个 NCM/USB 网卡：

```sh
# 电脑侧（Linux；Windows 需装 RNDIS/NCM 驱动）
sudo ip addr add 172.16.42.2/24 dev <新网卡>
ssh root@172.16.42.1               # 无密码（M1b 的 dropbear）
```

> ⚠️ 手机与电脑之间的 USB 线不要拔；WiFi 验证时仍可保持 USB。

## 2. 验证清单（USB SSH 内执行）

```sh
# 2.1 增量应用与持久化
cat /etc/m1b-overlay-version            # m1b-wifi-v1
cat /root/m1b-boot-count                # 1
cat /root/m1b-boots.log

# 2.2 WiFi bring-up
cat /var/log/lmi-wifi.log               # 逐 stage 日志
ip -4 addr show wlan0
iw dev
/sbin/wpa_cli -i wlan0 status           # wpa_state=COMPLETED
ip route show default
ping -c2 192.168.5.1
ping -c2 1.1.1.1
DNS：cat /etc/resolv.conf

# 2.3 失败时的诊断（也会写进 mailbox）
dmesg | grep -Ei 'wlan|cnss|qca|mhi|firmware|cooldown|timeout' | tail -60
ls -l /sys/kernel/cnss/ /dev/wlan /mnt/android-* /apex/com.android.runtime
cat /var/log/cnss-daemon.log 2>/dev/null
```

## 3. 验收：OPPO 经局域网 SSH 直连

1. 记下 Linux 的 wlan0 IP（通常路由器会给回手机 Android 用过的同一个地址
   `192.168.5.12`，因为 MAC 相同）。
2. OPPO（连同一路由器 CMCC-9rgu）用 Termius 或 `ssh` 直连该 IP、用户 root。
3. 成功后 `uname -a` 应显示 4.19.325 内核（Linux，不是 Android）。

## 4. 方法 B：纯手机 recovery 引导（无需电脑）

```sh
# Termux 内以 root 运行（本仓库 tools/m1/recovery-swap.sh 已部署到 Termux home）
sh recovery-swap.sh status
sh recovery-swap.sh to-linux --force /data/local/lmi-dualboot/boot-m1b-v5.img
```

- 该命令把 v5 写入 recovery 分区并 `reboot recovery`；回 Android 只需任意重启
  （v5 init 在挂载 rootfs 前先清 BCB）。
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

## 6. 已知不确定点（首次试飞重点观察）

1. **cnss-daemon 依赖链**：v1 overlay 未包含 `rmtfs`/`tqftpserv`/`pd-mapper`
   （D80 基线里有，但它们可能只服务 modem/ADSP）。若 `wlan0` 出现但固件加载
   超时/COEX 报错，下一步再补这组二进制。
2. **vendor/system EROFS 挂载**：内核支持 EROFS；偏移来自本机 `lpdump`
   （system 3652190208、vendor 5514461184）。
3. **REGDOM**：`country=CN` 已在 wpa_supplicant.conf；regdb 固件已随 overlay。
4. **MAC**：使用 persist 里 `wlan0=7c2adb019559`，与 Android 相同 → 路由器
   大概率复用原 DHCP 租约（192.168.5.12）。
