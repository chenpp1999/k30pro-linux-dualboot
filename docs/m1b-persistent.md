# M1b 持久化 rootfs — 设计与实录

> 状态（2026-09-14）：rootfs 已写入 `super` 空闲区并以 RAM initramfs 引导，
> OpenRC + Weston 真机运行（屏幕可见 Wayland Terminal + Text Editor）。
> 收尾中：SSH 救援端口冲突修复（v4 init）、持久化读写测试。
> 关键设备限制见 issue #13（baseband_guard）。

## 1. 存储布局（实测）

- `super`（`/dev/block/sda32`，9,126,805,504 B）动态分区容器
- 已分配：odm / product / system / system_ext / vendor（`lpdump`）
- **空闲区**：扇区 12,774,816 起，约 2.41 GiB
- Linux rootfs 以 **ext4 镜像（1.5 GiB）** 写入空闲区，偏移：
  - 12,774,816 × 512 = **6,540,705,792 B**（= 1,596,852 × 4096）
  - **不修改 super 元数据**（不新增逻辑分区），Android 无感、可回滚
  - cmdline 传递 `lmi_root_off=1596852`（单位：4096 B 块）

## 2. 设备限制：baseband_guard（issue #13）

Android 用户态（含 root）对 super 的写入被内核 `baseband_guard` 拒绝，
`blockdev --setrw` 与 SELinux 均无关；**写入必须在 TWRP 内执行**
（实测 1.5 GiB @ 484 MB/s，回读 sha256 一致、ext4 magic `53 ef`）。

## 3. 引导路径

```
fastboot boot boot-m1b.img          # 小 initramfs（~4.5 MB）+ 同款内核/DTB
  ├─ 清 BCB、NCM gadget（serial lmi-m1b-0001）、ip 172.16.42.1/24
  ├─ PARTNAME=super 定位设备 → losetup -o <offset> /dev/block/sda32
  ├─ mount ext4 → /newroot
  ├─ mount --move /dev /proc /sys /run /tmp
  ├─ 清理可能存在的 dropbear（壳内建 read/kill；v4 起救援 SSH 只在挂载失败时启动）
  └─ exec switch_root /newroot /sbin/init（OpenRC）
持久 rootfs（OpenRC）：udev → hostname → localmount → dropbear / seatd /
  m1-weston（Weston DSI-1 + 手机键盘）/ syslog
```

## 4. 回滚

- 停用：不再 `fastboot boot boot-m1b.img`（Android 完全无感）
- 清除：TWRP 中将该区域清零（`dd if=/dev/zero ... bs=4096 seek=1596852`）
- 元数据备份：`/sdcard/Download/phone-server/backup/super-metadata.bin`
  （+ `super-lpdump-20260914.txt`）

## 5. 产物

| 产物 | 位置 | 说明 |
|---|---|---|
| `rootfs.img`（1.5 GiB ext4） | 手机 sdcard `lmi-m1b/` | sha256 `843b956d…`；含 Alpine 3.23 + Weston + OpenRC 服务 |
| `boot-m1b.img` | 手机 sdcard `lmi-m1b/` | RAM initramfs 引导镜像（v4 起修复救援端口冲突） |
