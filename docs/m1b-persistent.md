# M1b 持久化 rootfs — 设计与实录

> 状态（2026-09-14）：**已验收**（issue #14）。rootfs 写入 `super` 空闲区并以
> RAM initramfs 引导（OpenRC + Weston，屏幕可见）；WiFi 直连（<SSID>，
> DHCP `192.168.1.x/24`）、持久化三轮读写（boot=4→6）、USB + 局域网 SSH
> 全部通过。验收记录：`acceptance/m1b-2026-09-14.md`。
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
| `rootfs.img`（1.5 GiB ext4，初始） | 手机 sdcard `lmi-m1b/` | sha256 `843b956d…`；Alpine 3.23 + Weston + OpenRC 服务 |
| `rootfs-fixed2.img`（**当前部署**） | 手机 sdcard `lmi-m1b/`；已写入 super | sha256 `0734a5de607d87f3dd642fa327c66d8077a8c710dc9e1a2c2ddc888b13e7c1cf`；修补 dropbear（initd/confd）与 `lmi-wifi-start` |
| `boot-m1b.img` | 手机 sdcard `lmi-m1b/` | RAM initramfs 引导镜像（v4 起修复救援端口冲突） |
| `boot-m1b-v5.img` | 同上 + `/data/local/lmi-dualboot/` | 内嵌 overlay v1 + 引导计数（sha256 `7658da6a…b937`） |

## 6. 离线修补 rootfs 镜像（journal 陷阱，已固化工具）

镜像可以离线修补（把文件写入 ext4 镜像后再写回 super），但**顺序关键**：

1. 从分区 dump 出的 ext4 可能带未回放 journal（强制重启/非正常卸载）。
2. 若直接 debugfs 写入、之后再跑 `e2fsck -fy`，e2fsck 会**先回放 journal**，
   用旧 inode/数据块**静默回滚**刚写入的内容（2026-09-14 实测：
   `etc/conf.d/dropbear` 被回滚为 190 B 截断文件，导致 dropbear 语法错误）。
3. 正确顺序：

   ```sh
   e2fsck -fy rootfs.img            # 1) 先回放 journal（归位到最终状态）
   # debugfs -w -R "rm/write/sif"   # 2) 逐文件写入（rm -> write -> 修 mode/uid/gid）
   e2fsck -fy rootfs.img            # 3) 修计数（journal 已空，不会再回放）
   # debugfs dump + cmp 校验        # 4) 逐文件字节校验，最后 sha256sum
   ```

4. 工具：`../tools/m1/patch-rootfs-image.sh`（支持 `--dry-run`，自动完成
   上述 1–4 步并在任一文件校验失败时中止）。
5. 写回设备：TWRP 内 `dd if=<img> of=/dev/block/by-name/super bs=4096
   seek=1596852 conv=notrunc`，随后同法回读 sha256 核对（本次回读
   `0734a5de…` 与导出镜像一致）。
