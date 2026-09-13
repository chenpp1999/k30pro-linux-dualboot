# M0 操作手册（RAM 启动验证）

> 状态：产物已构建并校验，等待部署。
> 风险级别：**方式 A 零写入；方式 B 仅写 recovery（可回滚，boot 永不改动）**。
> 本手册执行前不需要负责人额外批准（M0-M2 属于低风险阶段，见 charter §6）。

## 1. 产物清单

| 产物 | 字节数 | SHA-256 |
|---|---|---|
| `boot-m0.img` | 47,206,400 | `5d9d56021e4f18a0d7f4c04225fd2a3855ebef20156eb8200306b17f618a205e` |
| `initramfs.cpio.gz` | 3,064,071 | `77b1455a3564639d7994766c1b323dd799d1794aec40c5bf0769c03c73418730` |

组成（全部有公开来源与校验）：

- 内核 `vmlinuz`：`jian45154/redmi-k30-pro-postmarketos` D80 release 中
  `linux-xiaomi-lmi-4.19.325-r9.apk`（该内核已在本机型实机启动验证过）
- 设备树：`kona-v2.1-lmi.dtb`（同上 APK）
- initramfs：本项目自建（静态 busybox + dropbear + eventdump + init）
- 构建：`tools/m0/build.sh`（可复现）

产物位置（手机）：`/sdcard/Download/phone-server/lmi-m0/`

## 2. 验收标准（M0-Acceptance）

在 Linux 启动后逐项确认：

- [ ] A1 内核启动（设备进入 Linux，无 Android 界面）
- [ ] A2 USB 网卡在宿主侧出现（RNDIS，宿主可 `ping 172.16.42.1`）
- [ ] A3 SSH/telnet 可登录（`ssh root@172.16.42.1`，密码 `<your-password>`）
- [ ] A4 `eventdump /dev/input/event*` 能收到触摸事件
- [ ] A5 `dmesg | grep -i -E "drm|dsi|panel"` 显示面板 DRM 初始化
- [ ] A6 返回 Android 正常（重启即回）
- [ ] A7 全程未写 boot/userdata/super（方式 A）或仅写 recovery（方式 B）

A1-A3 为 M0 门禁；A4/A5 允许记为部分通过（显示接管推迟到 M1 完整 rootfs）。

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
11. 退出：在 Linux 里 `reboot`（BCB 已被 Linux 清除 → 回 Android）。
    也可长按电源强制重启。

回滚：无需（未写任何分区）。

## 4. 方式 B：recovery-swap（无需宿主，需 Android root）

> 原理：ADB-0001。Linux 引导镜像写入 `recovery` 分区，`reboot recovery`
> 触发一次性进入；`boot` 分区始终是 Android。首次写入前必须完成备份。
> 缺点：没有宿主时只能看屏幕（无法 SSH），证据以照片为主。

执行环境：Termux root 通道（opencode 里可直接代跑）。

1. **备份（必须，纯读取）**：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh backup
   ```

   产物：`/data/local/lmi-dualboot/recovery-twrp.img`（+ sha256）与
   `boot-android.img`（+ sha256）。

2. 写入并重启进 Linux（第一个写操作，只写 recovery）：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh to-linux \
      /sdcard/Download/phone-server/lmi-m0/boot-m0.img
   ```

3. 设备自动重启进 Linux；观察屏幕自检报告（input/network/dmesg）。
4. 返回 Android：长按电源强制重启（BCB 已清）。
5. 需要 TWRP 时：

   ```sh
   sh /data/data/com.termux/files/home/recovery-swap.sh restore-twrp
   ```

   然后 `reboot recovery` 即回到 TWRP。

回滚：`restore-twrp`；boot 分区从未改动。

## 5. 失败处理

- Linux 起不来/无 USB 网络：强制重启回 Android，保留屏幕照片与（可能的）
  dmesg；按 test-plan 记录，进入缺陷分析。
- 方式 B 后无法进 Android（理论不可能，boot 未动；且 BCB 已在 Linux init 清除）：
  进入 fastboot（音量下+电源），用宿主 `fastboot flashing unlock` 状态检查并
  重刷 `boot-android.img`（备份在内）。
- 任何情况下不要执行 `fastboot erase`、不要 relock。

## 6. 结果记录

执行人在 `docs/acceptance/` 下新增 `m0-<日期>.md`，使用 test-plan 的验收记录
模板，附哈希与照片/日志。通过后更新 charter 里程碑表（M0 ✅）并开 M1。
