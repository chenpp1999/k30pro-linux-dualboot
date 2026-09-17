# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed
- **音频无声卡的根因＝`deferred_probe_timeout`（2026-09-17 定位并入库修复）**：
  `drivers/base/dd.c` 在 `CONFIG_MODULES` 下默认 **30 秒**的 deferred-probe 超时；超时后
  任何 `-EPROBE_DEFER` 都被**强制忽略**（`deferred probe timeout, ignoring dependency`）
  且被强制的 probe 不再重试。而我们的音频链（ADSP 固件在 rootfs + 用户态 `lmi-adsp`/
  `pd-mapper`）最早 **t≈89s** 才 `of_platform_populate` 出 `q6core-audio` 子设备 ——
  同一批里**最后**创建的 provider（`lpi_pinctrl@33c0000`，实测绑定成功）还没就绪，
  前面的 4 个 `msm-cdc-pinctrl` 消费者就被强制 probe → `devm_pinctrl_get()` = **-110**
  → `tx/rx_macro: failed to get swr pin state` → `sound` 不绑 `kona-asoc-snd` → 无声卡。
  修复：`tools/m1/kernel-cmdline-m1b.txt` 加 **`deferred_probe_timeout=300`**
  （0/负数＝永不超时）。**下一轮**：用带新 cmdline 的镜像 `fastboot boot`（零写入）复验
  `/proc/asound/cards` 与 `aplay`/`arecord`。证据见 `docs/bluetooth-assessment.md` §6c.6。

### Changed
- **P3 音频第二轮（2026-09-17，实机）：apps 侧 locator 已打通，卡在 SWR pinctrl（-110）**：
  - 新增 `tools/p3/pd-mapper-downstream.patch`（针对
    `linux-msm/pd-mapper@5ecd2fe`：remoteproc 缺失时直接扫 `*.jsn`；
    按下游内核的 `(0x40, 0x01, 0x01)` 发布）+ `tools/p3/build-pd-mapper.sh`
    （**设备内原生 musl 编译**、装 OpenRC 服务，支持 `--source` 离线构建）。
    实测 `qrtr-lookup` 出现 `64 1 1 1 ... Service registry locator service`，内核
    `service_locator` 随即完成：`init_service_locator: Service locator initialized`。
  - 由此**内核链真正跑通**：`apr_add_child_devices → q6core_probe` 创建了
    `q6core-audio`/`sound`/`bolero-cdc`/`wcd938x-codec`/SWR pinctrl 等子设备，
    `kona-asoc-snd` 也 probe 到 `populate_snd_card_dailinks`（对比第一轮"子设备全缺"）。
  - **发现 ADSP 必须由用户态触发加载**：`adsp-loader` 只在写 `/sys/kernel/boot_adsp/boot`
    时 `subsystem_get("adsp")`（Android 的 vendor init 就是这么做的），且固件在 rootfs，
    内核启动早期的尝试必然失败。新增 payload 服务 `lmi-adsp`
    （`before pd-mapper`，并加入 `m1b-init.sh` 的 `rc-update` 列表）；实测开机
    `t=48.8s adsp: Brought out of reset` → `t=89.7s Service locator initialized`。
  - **新阻塞（下一步）**：`msm-cdc-pinctrl` 的 `devm_pinctrl_get()` 返回 **-110(ETIMEDOUT)**
    → `tx_macro/rx_macro: failed to get swr pin state` → `sound` 节点不绑 `kona-asoc-snd`
    → **仍无声卡**。证据与代码位置见 `docs/bluetooth-assessment.md` §6c.6。
- **P3 音频（2026-09-17，实机）：ADSP 已通，声卡未出，根因收敛到 `pd-mapper`**：
  ADSP 固件本机自带（`/vendor/firmware_mnt/image`，22 文件 20,356,050 B），部署到
  `/lib/firmware/` 后，`/sys/kernel/boot_adsp/boot` 写 `1` 即可让 ADSP 启动：
  dmesg 出 `adsp: Brought out of reset`、`adsprpc ... adsp subsystem is up`、
  `qcom_smd_qrtr_probe`、**`apr_tal_rpmsg ... Channel[apr_audio_svc] state[Up]`**。
  **同时修正 09-16 的旧判断**：内核音频栈并不缺驱动 —— `adsp-loader`/`audio_apr`/
  `q6core_audio`/`kona-asoc-snd`/`wcd938x_codec`/`bolero-codec`/`swr-wcd`/`msm-pcm-*`/
  `msm-dai-*` 全都编入并绑定，DT（`q6core-audio`/`sound`/`bolero-cdc`/`wcd938x-codec`）
  也齐全；声卡出不来的真正原因是 **`audio_apr` 的 DT 子设备只在 ADSP "up" 通知里
  `of_platform_populate()` 创建**，而该通知链要求 apps 侧 `SERVREG_LOC`(QMI 0x40) 服务，
  只能由 `pd-mapper` 提供；linux-msm 版 `pd-mapper` 需要 `/sys/class/remoteproc`
  （本下游内核 `CONFIG_REMOTEPROC` 未开）→ 直接退出（`no pd maps available`）。
  下一步（已收敛）：移植/补丁 `pd-mapper` 免 remoteproc、直接读 `*.jsn`（地图内容已知：
  `avs/audio` → `domain=adsp`/`subdomain=audio_pd`/`qmi_instance_id=74`）。
  完整根因链/源码位置/踩坑见 `docs/bluetooth-assessment.md` §6c。
- **勘误：蓝牙固件其实是有的**（2026-09-17 实测）：`/vendor/bt_firmware`（`/dev/block/sde35`
  `bluetooth` 分区）里有 `htbtfw10/20.tlv` + `htnv10/20.bin`。此前
  `docs/bluetooth-assessment.md` §1/§6b 说"Android 侧没有 QCA6390 BT 固件"，是因为当时
  该分区未挂载/为空。**BT 结论不变**（平台走私有 SLIMbus、`hci_qca` 只支持 serdev 且
  `btqca` 无 QCA6390）。
- **P2 结论（2026-09-17，实机）**：
  - **蓝牙**：本内核 QCA6390 BT 走高通私有 SLIMbus 路径（Android `kona-perf_defconfig`
    也只开 `CONFIG_BT_SLIM_QCA6390`）；开 `BT_HCIUART(_QCA)` 后 `hci0` 会出现、芯片会
    上电，但打开即在 `qca_setup()` 崩溃（该下游 `hci_qca` 只支持 serdev，`hu->serdev==NULL`），
    且 `btqca` 无 QCA6390 实现 → **P2 取消蓝牙**（详见 `docs/bluetooth-assessment.md` §6b）。
  - **音频**：发现 `techpack/audio`（kona 机器驱动 + wcd938x/bolero + SoundWire）**已被
    `ARCH_KONA` 无条件编进内核**，DT routing 也在 → 音频**不需要改 config**，阻塞在运行时
    （ADSP 固件 + QRTR/PDR + `pd-mapper`/`rmtfs`）→ 转入 P3（固件+用户态）。
### Fixed
- **`m1-weston` 自愈 seatd 卡死**（2026-09-17 实测）：运行中 `seatd` 卡住（进程与
  `/run/seatd.sock` 都在，但连接被拒）时，weston 每次启动都失败 → wrapper 无限重试 →
  **屏幕反复灭/亮**。现在失败日志命中 `libseat`/`could not open seat`/`seatd.sock` 且
  尝试次数 ≤3 时会自动 `rc-service seatd restart` 再重试（实测重启后 weston 立即恢复）。
- **G2 通过（2026-09-17）**：打完上游两个补丁后，`fastboot boot boot-g2b.img` 自编内核
  30 s 内进 rootfs，`/proc/version` 显示 **Ubuntu clang 18.1.3**（区别于设备原内核的
  Alpine 22.1.8）；显示/触摸/WiFi（自动连 502，`192.168.5.27`）/USB-NCM/SSH/监控全部
  正常。证据与后续（P2 音频+蓝牙）见 `docs/peripheral-bringup-plan.md`。
- **G2 回归定位：自编内核挂不上 rootfs**（2026-09-17，实机）：按"干净 `a5b3099`"构建的
  内核能启动（USB-NCM 起来），但 SSH 落在**救援 dropbear**（rootfs 口令失败、救援口令
  成功）⇒ rootfs 挂载失败。根因是上游内核包 `linux-xiaomi-lmi` 还打了两个补丁我们没打，
  其中 **`lmi-vfs-mount-diagnostic.patch` 含功能修复**：`do_new_mount()` 在 `fc->source`
  为空时用 `name` 兜底，否则 `mount -t ext4 /dev/...` 返回 **ENOENT**（`FS_REQUIRES_DEV`）。
  另 `lmi-rmtfs-mem-node.patch` 影响 base dtb。补丁已收入 `tools/kernel/patches/` 并由
  `build-kernel.sh` 自动应用；重建得到 `Image` sha256 `98f21ff0…`。
  同时修掉了暴露出来的 initramfs 缺陷：**`/bin/sh` 缺失**（`/etc/passwd` 指向 `/bin/sh`
  但只装了 `bin/busybox`）→ 救援 SSH 永远起不了 shell，现已加 `bin/sh` 软链接。
  实机复验见 `docs/peripheral-bringup-plan.md`（设备需物理重启后重试 G2）。
### Added
- **P3 音频：pd-mapper 下游补丁 + 原生构建 + ADSP 引导服务**（2026-09-17）：
  `tools/p3/pd-mapper-downstream.patch`、`tools/p3/build-pd-mapper.sh`、
  `tools/p3/pd-mapper.openrc`（`respawn_max=0` —— 默认的 5 次会把开机早期短暂失败的
  supervisor 永久杀掉，实测复现）、`tools/p3/pd-mapper.confd`；
  payload `tools/m1/m1b/etc/init.d/lmi-adsp`（用户态触发 ADSP 加载）。
  固件清单与工具见上一条。
- **P3 音频工具与固件清单**（2026-09-17）：
  - `docs/firmware-inventory.md`（**P0 交付物**）：本机自带固件的来源/目标路径/大小/
    **逐文件 sha256**/许可 —— ADSP 分段 22 文件（`adsp.mdt` + `adsp.b00…b18` +
    `adspr.jsn`/`adspua.jsn`）、CDSP/SLPI/Venus、QCA6390 BT（存档）；明确固件**不入仓**。
    其中 `adspua.jsn` 就是音频 PD 地图（`adsp`/`audio_pd`/`qmi_instance_id=74`、
    provider `avs`/service `audio`）。
  - `tools/p3/adsp-firmware.sha256`（校验清单，两处工具共用）+
    `tools/p3/{extract-adsp-firmware.sh,install-adsp-firmware.sh,audio-probe.sh}`：
    PC 侧只读抽取（adb，设备侧也做 sha256 校验）、设备侧安装校验（`--boot` 只写
    adsp-loader 的 sysfs，不动分区）、只读体检（逐环节报告 firmware→ADSP→QRTR→locator→card
    哪一环断了）。`tools/p3/README.md` 给出用户态安装（`alsa-utils`/`qrtr` +
    pmOS v25.06 的 `rmtfs`/`pd-mapper`/`tqftpserv`）与复验顺序。
- **P1：下游内核可复现构建**（`tools/kernel/`，2026-09-17）：`build-kernel.sh` 按
  LineageOS `android_kernel_xiaomi_sm8250 @ a5b3099` 浅取源码、套用配置、`LLVM=1`
  编出 `Image`（12 分钟，clang 18.1.3）。**关键发现**：上游那 4 个 config 片段不足以
  复现设备内核（差 49 行：SELinux 关闭、`VT`/console、`DEVTMPFS`、`USB_F_RNDIS`、
  `QCOM_RMTFS_MEM=y`、`INIT_STACK_NONE`、`IKHEADERS` 等），故改为采用**设备实测
  config**（`tools/kernel/config-xiaomi-lmi.aarch64`，`zcat /proc/config.gz` +
  `olddefconfig`）作为权威配置；配方/差异/下一步（P2 开音频+蓝牙）见
  `tools/kernel/README.md`，计划状态同步到 `docs/peripheral-bringup-plan.md`。
- **手电筒（flashlight）可用**（overlay `m1b-ux-v17`）：新增 `lmi-torch`
  （`on|off|toggle|status`，`--level`/`--seconds`/`--dry-run`，`LMI_TORCH_LEVEL`），
  按 QPNP flash LED v2 语义**先设 `led:torch_N` 电流、再置 `led:switch_N` 使能**；
  面板加"手电"启动器（`/usr/share/lmi/torch-icon.png` → `lmi-torch`，点一下开/再点关），
  `lmi-help` 与 `docs/usage.md` 同步。离线测试 `tools/tests/m1b-torch-test.sh`
  （假 sysfs，7 组，CI 运行）。硬件盘点里该项从"未接"改为"已实现"。
- **`docs/bluetooth-assessment.md`：蓝牙可行性评估**（2026-09-16，实测 + 上游资料）：
  确认 BT 串口是 `/dev/ttyHS0`（`998000.qcom,qup_uart`），BT 供电/复位节点已生效，
  但内核未编任何用户态 HCI 传输、Android 侧也没有 QCA6390 BT 固件，且上游内核提供方
  （`jian45154/redmi-k30-pro-postmarketos`）同样未做并把 BT 排在音频之后。给出
  Step 0–3 的修复路径（确认固件 → 重建 LineageOS 4.19 内核 + DT BT 节点 →
  装 `qca/*.tlv`+`qca/*.bin` → bluez）、工作量/回归风险与"本期不做"的建议。
- **`docs/hardware-status.md`：整机硬件盘点 + `docs/peripheral-bringup-plan.md`：外设
  bring-up 计划**（2026-09-16 实测）：逐项列出可用（显示/触摸/键/WiFi/USB/电源温控/
  存储/RTC）、节点在但未接（**手电筒、红外**、摄像头、指纹）、缺驱动/固件（**音频含
  麦克风**、**蓝牙**、光感/距离 LTR、磁力计 AKM、NFC、加速度/陀螺仪（疑在 SLPI））、
  不可修复（AW8697 震动、modem/GPS）。计划分 P0–P5（固件侦察 → 内核构建环境 → 配置/DT
  → 固件+用户态 → 持久化 → 验收），每步带 Gate/回滚/证据，并指出音频与蓝牙**共用同一次
  内核重建**、光感/磁力计可顺带开、手电筒/红外是不需要内核改动的便宜项。
  文档同时覆盖**音频（声卡）**：`/proc/asound/cards` 无卡、`/dev/snd` 仅 timer，
  `# CONFIG_SND_SOC_QCOM is not set` + `# CONFIG_QCOM_APR is not set`（高通音频驱动
  全关）、缺 ADSP 固件、无用户态音频栈——与蓝牙同源且**共用同一次内核重建**。
- **M5 一键安装地基**（设计 `docs/installer-design.md`）：
  - `tools/install/lp-metadata.py`：只读解析 `super` 的 liblp 元数据（geometry/header/
    tables，AOSP 校验和），计算未分配空闲区并支持 `select --size/--align`；已在真机
    `super` 上核对（最大空闲区 offset 12,774,816 扇区、≈2.41 GiB，与 issue #13 一致），
    纯标准库、可对镜像或块设备工作；
  - `tools/tests/m5-lp-parse-test.sh`：合成 super 镜像的离线测试（CI 运行）；
  - `tools/install/build-generic-image.sh`：**零固定凭据**的通用镜像组装（fail-closed 门禁：
    WiFi 网络/可用 root 口令/非空 machine-id/预置主机密钥或 authorized_keys/凭据正则一律拒绝），
    注入 firstboot 载荷后调用 `tools/m1/build-m1b-image.sh`，支持 `--dry-run`；
  - `tools/install/firstboot/`（`lmi-firstboot` + OpenRC 服务）：首次启动随机生成 root 口令
    （显示到控制台、存 `/root/lmi-root-password.txt` 0600）、重生成 dropbear 主机密钥与
    machine-id、SSH 仅公钥、准备 `/root/.ssh`；幂等、支持 `--dry-run`/`--root` 沙箱/
    `--force`，离线测试 `tools/tests/m5-firstboot-test.sh`（CI 运行）；
  - `tools/ci/checks.sh` 第 5 项与 `.gitattributes` 纳入 `tools/install/firstboot/*`
    （必须 755 + LF）。
  - `tools/install/lmi-install.sh`：**PC 一键安装**（`check`/`plan`/`install`/`rollback`）——
    经 `fastboot boot twrp`（只 RAM 引导、不刷写）进入 TWRP，先备份 recovery/boot/misc/
    super 元数据，再用 LP 元数据算偏移、修补引导镜像 cmdline、流式 `dd` 写 rootfs(super
    空闲区)/recovery、最后写 BCB（写后校验、可回滚）；**不重分区、不写 `boot`**，
    全程 `--dry-run`。
  - `tools/install/patch-cmdline.py`：原地改 boot 镜像 cmdline 的 `lmi_root_off`（无需
    mkbootimg）。默认 rootfs 槽位固定 1.5 GiB（与 `m1b-init.sh` 一致，实测系统仅占 ~1 GiB）。
  - `tools/tests/m5-install-test.sh`：合成 super/boot 镜像的离线测试（偏移选择、cmdline
    修补、写入顺序、体积/镜像/无空闲区门禁），CI 运行。
  - `tools/tests/m5-install-sim-test.sh`：**完整模拟安装**（假 adb/fastboot + 沙箱分区，
    跑真正的非 dry-run 路径：进 TWRP → 备份 → 修补 cmdline → 写 super/recovery → 写 BCB
    → 回滚），断言 rootfs 逐字节落位、recovery cmdline、BCB、boot 未变、回滚生效；CI 运行。
  - `docs/install-guide.md`：**一键安装说明（含醒目风险提示）**——前置条件、3 个文件、
    3 条命令、首次启动行为、回滚、救援、限制与验证状态。
  - `docs/installer-design.md` 扩充用法、1.5 GiB 槽位与 `--grow`(M3) 说明；**设备端到端
    安装验证待做**（破坏性，需负责人 + 测试机）。
- **使用说明书 `docs/usage.md`**：切换系统（Magisk 一键 / 命令行 / 救援）、WiFi 连接与排障、
  SSH 与改口令/公钥、监测台（`lmi-status` + 网页面板 + CSV 指标解读）、充电温控策略与调参、
  CPU 降温、桌面/中文输入/按键、服务与日志速查、FAQ、安全提醒；README 索引已挂。
- 桌面与终端体验（overlay `m1b-ux-v10`，补丁 0012/0013）：
  - **手指拖动＝滚动**终端（原先拖动被当作文本选择，触屏上没有鼠标、历史内容不可达），
    力度约每 0.75 个字高滚一行；
  - **键盘不再遮挡提示行**：键盘弹出时终端内容自动上移（`--keyboard-inset`，
    `/etc/conf.d/m1-weston` 的 `KEYBOARD_INSET=300`），最后一行始终在键盘之上；
  - 会话默认只开**一个最大化窗口**（`HINT=1`：说明书终端，打印完直接进 shell）；
    `TERMINAL=1`/`EDITOR=1` 可加开；重启时清理残留客户端（避免重复窗口），
    并修复了旧版残留 `weston-editor` 被重新映射的问题；
  - `keyboard-inset` 从 `weston.ini` 读取（补丁 0014），面板启动器等多开的窗口也自动避让键盘。
    注意：weston 14 的终端**不读** ini 的 `shell=`（只读 font/font-size/term），补丁 0015 补上。
- 终端交互（补丁 0012–0019，overlay `m1b-ux-v14`）：手指拖动=滚动历史；`--keyboard-inset`
  避让键盘（ini 可配）；快捷栏 `Esc/Tab/Ctrl/Alt/方向/Home/End/PgUp/PgDn`；**每个**终端启动
  都打印 `lmi-help` 说明书（补丁 0015 让终端读取 ini 的 `shell=`）；`LMI_NO_MOTD=1` 可跳过。
- `tools/m1/dev/lmi-inject.py` 新增 `type`（注入字符串，US 布局）与 `drag`（触摸拖动）两种
  测试模式——用于无人值守地验证键盘/滚动；配合 `weston-screenshooter`（输出写到当前目录的
  `wayland-screenshot-*.png`）可以端到端截图核对界面。

- `lmi-help` 命令一览（大标题 + 分组指令表）：**每个** weston 终端启动时都会打印
  （`weston.ini [terminal] shell=` + 补丁 0015，面板启动器开的窗口同样生效），SSH 登录横幅
  （`etc/profile.d/20-lmi-motd.sh`）与仪表盘"常用指令"表共用同一份内容；
  `LMI_NO_MOTD=1` 可跳过（要一个干净终端时用），每次调用记一行到 `/var/log/lmi-help.log`。
- `lmi-netwatch` WiFi 看门狗：`wlan0`/`wpa_supplicant` 消失后自动 `rc-service lmi-wifi restart`
  （掉线不必再重启），带指数退避、状态文件与 `NETWATCH_*` 配置；`NETWATCH_REBOOT=1` 为最后手段
  （写 BCB 重启回 Linux，绝不进 Android）。
- `lmi-wifi` 改为**一次性服务**：原先 bring-up 脚本退后台，成功后 OpenRC 会误报 `crashed`。
- 载荷完整性防线：重建脚本断言"暂存 payload 与源逐字节一致"并做空间预检；CI 新增第 5 项
  （payload 脚本必须 755、文本必须 LF）。

### Fixed
- **`lmi-wifi-join` 会清掉已配置的网络**（2026-09-16，实机复现；overlay **m1b-ux-v16**）：
  旧实现用 `/etc/wpa_supplicant/wpa_supplicant.conf.template` **重建**配置，而模板里只有
  占位符（`<router-ssid>` 等）——一次 `lmi-wifi-join <SSID> <pw>` 就把构建时注入的真实网络
  换成了永远连不上的占位条目（实测：仓库里的 `502` 加入后，`CMCC-*`/`CX8` 被覆盖，且因为
  `lmi-wifi` 是 oneshot、旧 `wpa_supplicant` 仍占着控制套接字，新配置根本没被尝试）。
  现在改为：**通过运行中的 `wpa_cli` 增删网络并 `save_config`**（保留其它网络、立即生效），
  未运行时才回退为"往现有配置追加"；`etc/init.d/lmi-wifi` 的 `stop()` 也会等进程退出并清理
  `/run/wpa_supplicant*`。已用 `wpa_cli save_config` 把设备上的真实网络救回并追加 502。
- **两边切换/开机慢**（2026-09-16，实机日志定位；overlay **m1b-ux-v15**）：
  - **Linux→Android 4.5 分钟**：长按电源键让 PMIC 硬复位（ABL `PM: HARD RESET by
    KPDPWR`）→ 冷启动时引导器初始化本机损坏的 AW8697（i2c 重试 549 次 = 273 s）。
    系统内 `reboot` 走 PS_HOLD 热复位（~3 s）。新增 `lmi-reboot`（干净重启脚本），
    `lmi-keys` 现在把**长按电源键 3 s** 变成干净重启（短按仍是息屏/唤醒，`-p` 可调，
    0 = 关闭），`lmi-help`/`docs/usage.md` 写清"别长按电源键硬复位"。
  - **开机多等 ~1 分钟**：`udev-settle` 在等 venus/vidc 固件加载失败（rc=-110）的
    udev worker，默认超时 120 s → 新增 `etc/conf.d/udev-settle`（`udev_settle_timeout=15`）。
  - **开机再等 ~85 秒**：`lmi-wifi`（default runlevel 的阻塞 oneshot）在配置网络都不在
    范围内时白等 `LMI_WPA_WAIT`（原 60 s）后退出 1，拖慢后面所有服务并被 `lmi-netwatch`
    反复重启 → 现在先扫后等，无可连网络立即 `status=idle` 退出（`LMI_WPA_WAIT=25`，
    `wpa_supplicant` 保留在后台，网络出现会自动连）。
  - 证据：`/var/log/messages`（`ERROR: lmi-wifi failed to start` → 紧接 `getty`）、
    `/var/log/lmi-wifi.log`（stage 时间戳）、Linux `dmesg`（`udevd worker ... video33
    is taking a long time`）、ABL 日志 `uefiFast-warm.txt` / `uefiSlow-coldboot.txt`。
  - **实测（v16 部署后，ledger boot=30）**：`syslogd → getty` 由 **93 s → 38 s**；
    WiFi bring-up 由"白等 60 s 后失败"变为 **30 s 内 `rc=0 status=ok` 并连上 502**；
    overlay v16 已应用，`lmi-reboot` / `udev_settle_timeout=15` 均在位。
- **Magisk Action 一键切换"点了没反应"**（2026-09-16，实测）：模块只从
  `/data/local/lmi-dualboot`、`/sdcard/Download/phone-server/lmi-m1b` 挑**版本号最大**的
  镜像（v11），而 `recovery` 里已是设备内重建的 v21 → 判为 FULL → v11 无
  `.ramboot-ok` 被 attestation 门禁拒绝，且 `recovery-swap.sh` 的 `FATAL` 走 stderr、
  Magisk 窗口只收 stdout，所以看起来毫无反应。修法（模块 **v0.3**）：
  - 新优先级：`LMI_SWITCH_IMG` > **recovery 里已是 Linux**（`ANDROID!` + cmdline 含
    `lmi_root_off=`）→ FAST 只写 BCB > 选**最新且已 attest** 的镜像做 FULL；
  - 脚本 `exec 2>&1`，门禁报错与诊断在 Magisk 输出里可见；无可部署镜像时列出候选
    与 attest 方法并非零退出；
  - 只读回归测试 `tools/tests/m2-action-test.sh`（合成镜像 + `LMI_SWITCH_DRY=1`，
    6 组，CI 运行）。
- **rootfs 实际只有 1.4 GiB**（迁移到 `lnx` 16 GiB 分区时没有把 ext4 扩到分区大小），写满后
  `dd` 与脚本写入**静默失败**（一次镜像构建因此产出截断文件）。已在线 `resize2fs` 扩到
  **15.7 GiB（可用 13.8 GiB）**；重建脚本新增"空间不足即报错"与 dd 失败提示。
- 设备上安装的 `/usr/sbin/lmi-wifi-start` 曾被 `tr -d "r"` 削掉全部字母 r（`mkdi`、`/va/log`），
  导致 WLAN 栈掉线后**永远无法恢复**：已按仓库逐字节校验回填，并加了完整性断言防止复发。
- **终端滚动后"输出被吞"**（overlay `m1b-ux-v14`，补丁 0018/0019）：滚动期间输出会推进
  `terminal->start`，而"回到活区"的锚点 `saved_start` 不跟着走，于是回滚的钳制量变成负数、
  视图越过活区滚进旧行（表现为只剩命令行、下面一大片空）。现在锚点跟随输出；并且屏幕键盘
  输入（`text_input` 的 preedit/commit/keysym 三条路径）也像物理按键一样把视图拉回活区，
  不再出现"打字后输出在视野之外"。
- **键盘遮挡提示行**（补丁 0013/0014/0016/0017）：weston 把虚拟键盘做成**常驻覆盖层**
  （`zwp_input_panel_v1.set_overlay_panel`），且**从不发送** text-input 的
  `input_panel_state` 事件——所以合成器永远不会把窗口挪开，客户端只能自己避让。
  现在终端按"可用高度 = 窗口高度 − 键盘高度"重排网格（并把新的 winsize 告诉 PTY），
  网格底边贴着键盘上沿：没有黑带、提示行与命令输出始终可见。`keyboard-inset` 可配
  （`weston.ini [terminal]` 与 `/etc/conf.d/m1-weston`，实测 K30 Pro 为 480）。
- **M1b WiFi 手册 §4 与 §0 自相矛盾**（独立验证者 issue #20）：§4 曾指示把缺
  `recovery_dtbo` 的 `boot-m1b-v6.img` 用 `--force` 写入 recovery（必然落 fastboot）。
  已标注为历史、指向 `docs/m2-runbook.md`，并明确 `--force` 仅限救援。
- **隐私清理遗漏**：`docs/handoff.md` 的真实 SSID/内网 IP、M1b WiFi 证据里的
  BSSID/本机 WiFi MAC/uuid、UX 审查里的 SSID 均已移除或占位化
  （CI 第 4 项未覆盖这些形式；政策见 `SECURITY.md`）。

### Security
- **个人信息与凭据清理**（2026-09-15）：仓库不再包含设备序列号/CPUID/证书、
  Wi-Fi SSID 与内网 IP、任何口令或口令哈希、主机路径。
  - 构建脚本改为"构建时随机生成或由 `LMI_ROOT_PASSWORD` 指定"（salt 由口令派生，
    保持可复现）；`lmi-wifi-join` 不再接受硬编码网络。
  - **全部 Git 历史已重写**（`git filter-repo`，含标签）并强推；旧的不可达提交
    在 GitHub 侧仍需人工申请回收，因此**凭据一律按已泄露处理并已轮换**：
    root 口令、部署镜像的 initramfs 救援口令均已更换。
  - `tools/m1/rebuild-image-from-device.sh` 新增 `--root-password` /
    `--random-root-password`：救援口令不再随镜像固定。
  - CI 新增第 4 道防线（`tools/ci/checks.sh`）：命中已知个人信息特征即失败。
  - 政策见 `SECURITY.md` §凭据与隐私。

### Changed
- **文档同步（2026-09-15）**：README / architecture / handoff / charter / test-plan /
  reproduce / usage / release 更新到"v1.0 已发布 + M5 现状（真机端到端待验证）"；
  `docs/test-plan.md` 新增 **T5**（M5 一键安装）组；`.gitignore` 忽略 M5 安装备份目录
  与构建附属文件。
- **勘误：蓝牙在本项目内核上不可用（2026-09-16 实测）**。`docs/charter.md`/`feasibility.md`
  原先"蓝牙可用"说的是**社区 mainline**；本项目部署的下游 4.19 内核
  （`yuweiyuan8/linux` + qcacld/cnss2）**没有编任何用户态 HCI 传输**
  （`CONFIG_BT_HCIUART`/`BT_HCIVHCI`/`BT_HCIBTUSB` 全未编，只有 `BT_SLIM_QCA6390`），
  DT 也无标准 BT 节点 → `bluez`/`btattach` 无从接入（`rfkill` 有 `bt_power` 可 unblock，
  但 `/sys/class/bluetooth` 始终为空）。已更新 `docs/feasibility.md` §3、
  `docs/linux-ux-audit-2026-09-14.md` B6、`docs/handoff.md` §六 第 19 条，说明
  "要支持需重建内核 + DT BT 节点 + QCA BT 固件 + bluez"，避免后续会话重复排查。

### Security
- **隐私清理补漏**（2026-09-17）：`docs/handoff.md` §二 里仍留着一处**真实 WiFi SSID**
  （隐私政策要求 SSID 一律不入仓，`SECURITY.md`），已在改版该节时改为占位说明；
  提交前跑 `tools/ci/checks.sh` 第 4 项（本轮同时确认 `tools/p3/*` 无凭据/标识符）。

## [1.0.0] - 2026-09-15

### Added
- Phase 0 立项文档：立项书、可行性研究、系统架构、风险台账、测试计划、ADR-0001。
- 项目仓库与 README。
- M0 构建链 `tools/m0/`：上游产物获取与校验、initramfs 构建、boot 镜像组装、
  ramboot init（含 BCB 清除与自检报告）、eventdump 触摸检测工具。
- M0 操作手册 `docs/m0-runbook.md`（方式 A：fastboot boot 零写入；
  方式 B：recovery-swap 无宿主部署）。
- `tools/m1/recovery-swap.sh`：recovery 分区切换部署工具（备份/写入/回滚）。
- `recovery-swap.sh attest-ramboot`：方式 A RAM 启动通过后的 attestation
  （issue #1 部署门禁）；`to-linux` 新增 `--dry-run` / `--force` 选项。
- `tools/m0/init`：USB 网络 gadget 优先 NCM、RNDIS 回退（issue #2）。
- `.gitattributes`：构建输入与 shell 脚本强制 LF（issue #3）。
- `tools/m0/display.c`：`m0-display` 最小 KMS 接管工具（无 fbdev 内核下设置
  DSI 模式 + 色条 + 背光，常驻持有 DRM master；issue #4）；init 后台拉起。
- `docs/acceptance/m0-2026-09-13.md`：M0 方式 A 真机验收记录与证据
  （A1–A5 全过；完整 UI 推迟 M1）。
- M1a：全量 Alpine + Weston RAM 引导（issue #12）——  `tools/m1/m1-init.sh`、`tools/m1/m1-weston.sh`（RAM 引导 init 与
  Weston/OSK 接管：splash 释放 + pixman + DSI-1 + 手机键盘布局）、
  `tools/m1/utouch.c`（uinput 触摸注入，无头 UI 验证）、
  `tools/m1/patch-libweston.sh`（msm 重复 IN_FORMATS 断言修补）、
  `docs/m1a-ramboot.md` 复现手册、
  `docs/acceptance/m1a-2026-09-14.md` 验收记录（含屏幕截图证据）。
- M1b：持久化 rootfs（issue #13）——
  `tools/m1/m1b-init.sh`（小 initramfs：清 BCB/NCM → `losetup -o` 挂载
  super 空闲区内的 ext4 rootfs → `switch_root` 进 OpenRC；救援 SSH 仅在
  挂载失败时启动）、`tools/m1/kernel-cmdline-m1b.txt`（`lmi_root_off=1596852`）、
  `docs/m1b-persistent.md`（布局/引导/回滚实录）。
- M1b 验收（issue #14，2026-09-14）：持久 rootfs + WiFi 直连 + 持久化三轮 +
  USB/局域网 SSH 全过；`docs/acceptance/m1b-2026-09-14.md` 与证据目录
  `docs/acceptance/m1b-2026-09-14/`（引导账本 / WiFi 状态 / SSH 会话 /
  持久化轮测 / super 写回校验 / 根因摘录）。
- `tools/m1/patch-rootfs-image.sh`：离线修补 rootfs 镜像（先回放 journal →
  debugfs 写入 → 修计数 → dump+cmp 校验；支持 `--dry-run`）。
- dropbear 覆盖文件入仓：`tools/m1/m1b/etc/init.d/dropbear`（`use net`）、
  `tools/m1/m1b/etc/conf.d/dropbear`（`-P /run/dropbear.pid`）。
- overlay v2 / `boot-m1b-v6.img` 重建（2026-09-14）：三个修补文件进入 overlay 树
  （`m1b-old` → `m1b2` 增量），overlay 版本升至 `m1b-wifi-v2`；产物 sha256
  `346343b3…`（54,546,432 B）、overlay v2 `db760fec…`（5,991,807 B，212 文件）。
  v5 内嵌 overlay v1（旧 `lmi-wifi-start`）只影响全新部署的首启，已由 v6 修正；
  实机 RAM 验证与 attestation 待 M2 会话执行。
- M2 切换器 v0.1（issue #15）：`tools/m1/recovery-swap.sh` 演进——显式写 BCB
  `boot-recovery`（写后校验）、recovery 全量 sha256 回读校验、先镜像后 BCB 的
  中断安全顺序、`--no-reboot`、`bcb show|clear|boot-recovery` 子命令、
  `switch.log` 证据日志；离线功能测试 `tools/tests/m2-switch-test.sh`（8 组，
  CI 运行）；手册 `docs/m2-runbook.md`；Magisk 一键骨架
  `packages/magisk-module/`（Action 按钮）。
- T1-03 修复产物 `boot-m1b-v7.img`（sha256 `754b63b4…`，55,029,760 B）：
  `build-m1b-image.sh` 新增 `--recovery-dtbo`；记录
  `docs/acceptance/m2-2026-09-14.md`（T1-03/T2-03/T2-04/救援/TWRP 演练全过；
  T2-02 5 轮零失败）。
- Linux UX Phase 1（overlay `m1b-ux-v4`）：时钟（NTP + swclock + 时区）、
  CJK 字体（wqy-zenhei）、黑化桌面/启动器/24h 时钟、`m1-weston`/init 健壮性
  修复；`docs/linux-ux-audit-2026-09-14.md` §6 记录 weston 合成卡死规避
  （不用 `background-color`/`panel-color`/`background-image`）与 RTC 只读结论。
- Linux UX Phase 2（overlay `m1b-ux-v5`）：`tools/m1/weston-patches/`（6 个补丁）
  + `tools/m1/build-weston-clients.sh` + overlay 二进制：
  `weston-terminal` 支持 text-input v1（OSK 可输入终端）、`weston-keyboard`
  补 `_ . ,` 符号、宽度适配 540 逻辑像素、普通键逐键立即提交、无 surrounding
  text 时退格发 BackSpace keysym。
  关键坑：meson 必须 `-Dprefix=/usr`，否则客户端主题加载失败启动段错误。
- Linux UX Phase 2（按键/息屏）：`tools/m1/lmi-keys.c`（音量键→背光、
  电源键开关屏、空闲灭背光）+ `m1-weston IDLE_TIME=300`（原 `--idle-time=0`
  不允许息屏）+ `tools/m1/dev/lmi-inject.py`（uinput 注入，无人值守验证）。
- Linux UX Phase 2（中文输入，overlay `m1b-ux-v5` 追加）：自补丁
  weston-keyboard 加**拼音页 + 候选条**（补丁 0007、引擎 `tools/m1/ime/src/`、
  词典 `tools/m1/ime/pinyin.dict` 221 KB，数据源 pinyin-data/rime/CC-CEDICT）；
  终端配 `font=WenQuanYi Zen Hei Mono`（cairo toy API 无字形回退，否则中文
  显示豆腐块）；端到端实机验证（nihao→你好 上屏终端）。
  调研：`docs/research/ux-ime-2026-09-15.md`（路线与协议约束）。

- M3 扩容（可选、受控风险）：
  - 规划器 v0.1 `tools/m3/lmi-repart.sh`（`status`/`plan`/`backup`/`verify`/`restore`，
    `apply` 故意拒绝自动执行）+ 方案 `docs/m3-repart-plan.md`（§4b 独立子代理审计）
    + 离线测试 `tools/tests/m3-repart-test.sh`（合成 GPT 镜像，CI 运行）。
  - **2026-09-15 本机实做**：userdata 107→91 GiB（PARTUUID/名字保留、数据完好）、
    新建 `lnx` 16 GiB、rootfs 迁移并自 `lnx` 启动；init 改为按 GPT `PARTNAME=lnx`
    优先挂载（保留 super 固定偏移回退）。验收 `docs/acceptance/m3-2026-09-15.md`。
- 设备侧镜像重建 `tools/m1/rebuild-image-from-device.sh`：从 `recovery` 分区解包
  kernel/DTB/cmdline/DTBO 与 initramfs 底座 → 重打全量 overlay → 自检（各段 sha256
  与源镜像一致）→ `dd` 回写，**无需 Android/fastboot/USB 主机**；
  手册 `docs/m1b-rebuild-on-device.md`；CRLF 自动规范化。
- Magisk 一键切换模块 v0.2（`packages/magisk-module/`）：内置 `recovery-swap.sh`、
  跨目录选最新 `boot-m1b-vNN.img`、hash 一致时只写 BCB（FAST）否则走带 attestation
  门禁的完整流程（FULL）、`LMI_SWITCH_DRY=1` 预演、`build.py` 跨平台打包（强制 LF）。
- Linux UX（overlay `m1b-ux-v6`）：终端配色/`TERM=xterm-256color`/PS1
  （`etc/profile.d/10-lmi-term.sh`）、WiFi CLI（`lmi-wifi-status|scan|join`）、
  kiosk 开关（`/etc/conf.d/m1-weston KIOSK=1`）；面板 24 小时制 + **电量**（补丁 0011）；
  光标主题未入包（12 MB 且全为符号链接，触屏价值低）。
- 电源/温控/长期监控（overlay `m1b-ux-v7`，`docs/m1b-thermal-charging.md`）：
  `lmi-power`（开机 governor → `schedutil`）、`lmi-chargectl`（停充 80 %/恢复 70 %、
  停充 42 °C/恢复 38 °C、最小驻留 300 s、卡死保护 → 写 BCB 重启回 Linux、24 h 安全阀）、
  `lmi-monitor`（60 s 采样 → tmpfs 快照 + 静态面板页、10 min 落 CSV 保留 60 天、
  累计高压 SOC 与 >40 °C 时长）、`lmi-status`（一屏/JSON/单行）、内网面板
  （`darkhttpd` → `busybox httpd` → `python3 -m http.server` 回退链）。
- 发布资产：`VERSION`、`docs/reproduce.md`（G5 外部复现指南）、
  `docs/release-v1.0.0.md`（发布说明）、handoff 全文重写（设备当前状态/存储布局/
  操作流程/14 条已知坑）。

### Changed
- `recovery-swap.sh to-linux` 默认启用部署预检：SHA-256 清单 + attestation +
  `ANDROID!` 头 + 分区大小，任一缺失/不符即拒绝写入（issue #1）。
- M0 门禁收紧：方式 B 写入前，同一镜像必须已通过方式 A 实机启动并生成
  attestation（charter §6、runbook §2 A8）。
- README：M0 状态更新为方式 A 实机验收 A1–A5 全过（2026-09-13）；
  M1 更新为 M1a 完成（RAM 全量 Alpine+Weston，触摸+虚拟键盘可用，2026-09-14），
  M1b 持久化待做。
- runbook §1 产物哈希更新（2026-09-13 终轮：NCM + LF + display 接管）；§2/§3
  注明退出方式 A 用 `reboot -f`（普通 `reboot` 对 PID1=busybox sh 无效）。
- `.gitattributes`：`tools/m1/m1b/**` 强制 LF（overlay 载荷按字节写入 rootfs，
  CRLF 会破坏 OpenRC init 脚本与 conf.d）。
- README / handoff / m1b-persistent：M1b 状态更新为已验收（2026-09-14）。
- m1b-wifi-runbook：新增 §0.1 试飞结果与两个真机根因；§3 更新为局域网 SSH
  实测方法；§6 给出复核结论。
- `tools/m1/m1b-init.sh`：overlay 版本常量升为 `m1b-wifi-v2`（引导逻辑不变），
  供 `boot-m1b-v6` 内嵌 overlay v2 使用。
- `recovery-swap.sh` 分区写入改用 `dd conv=notrunc`（文件式测试分区不再被
  截断；真实块设备语义不变），并补充写后全量 sha256 回读校验。
- README / handoff / test-plan：M2 v0.1 状态、文档索引与验收入口更新；
  handoff 新增"电脑→手机"通道与 overlay 重建避坑记录。
- test-plan/handoff/README：T1-03 标记完成（结论：ABL 不清 BCB、Linux init 清；
  recovery 引导需 `recovery_dtbo`）；T2-02 记录"5 轮零失败 + 负责人提前结束
  （时间成本），标准修订待定"。

- 存储布局（M3 之后）：`recovery`=Linux 引导镜像槽位、`userdata`=91 GiB、
  新增 `lnx` 16 GiB = 当前 rootfs；`super` 内旧 rootfs 区保留（回滚）；
  `docs/architecture.md` §2/§3 同步。
- 引导镜像演进：v8（UX Phase 1）→ v9b（设备内重建，overlay v5）→ v10（`lnx` 启动）
  → v11（CRLF 修复 + `lmi-keys` 入包）→ v12（overlay v6）→ **v13（overlay v7，当前）**；
  `boot` 分区 sha256 `8d441fc5…` 全程未变。
- `tools/m1/m1b-init.sh`：新增 `lmi-power`/`lmi-chargectl`/`lmi-monitor` 的 runlevel；
  `OVERLAY_VERSION` 与重建脚本默认版本同步升到 `m1b-ux-v7`。
- 风险台账：R1/R2（M3 数据丢失）**关闭**（已执行并双向验收）；R4/R5/R8 更新为
  已缓解/已落地；测试计划新增 **T4 长期运行**（电源/温控/监控）。

### Fixed
- **T1-03 根因（2026-09-14 实机）**：写入 `recovery` 的镜像缺 `recovery_dtbo`
  时，lmi ABL 的 recovery 引导路径读不到 DTBO 表（读到 `ANDROID!` 魔数）→
  `Error: Device Tree blob not found` → 落 fastboot（v6/M0 方式 B 失败的真正
  根因；此前误判为 init CRLF）。修复：`build-m1b-image.sh --recovery-dtbo`
  （内容=本机 dtbo 表 487,424 B）；另修复 Debian 版 `mkbootimg`
  `get_number_of_pages` 真除 bug（`/`→`//`，否则 `pack('Q')` 报错）。
- M1b 实测（issue #13）：`baseband_guard` 禁止 Android 用户态写入 `super`
  （root/SELinux/RO 均无关）→ 镜像写入改在 TWRP 执行；RAM initramfs 的救援
  dropbear 会在 `switch_root` 后存活并占用 22 端口 → v4 起救援 SSH 仅在
  挂载失败时启动。
- 验证者 issue #5–#11 修复：
  - #5 `eventdump` 改为 `poll(2)` 多设备监听（原实现只轮询第一个设备）；
  - #6 `attest-ramboot` 同步刷新 `<img>.sha256` 清单（`to-linux` 预检依赖）；
  - #7 `restore-twrp` 增加 `--dry-run` 与写后 `ANDROID!` 校验；新增
    `tools/ci/checks.sh`（md 本地链接 / 设备节点白名单 / `--dry-run` 守则）
    并接入 CI；
  - #8 initramfs 打包确定性化（`sort` + `gzip -n`）、busybox 动态版随带库、
    固定口令哈希（去除 `python3 crypt` 依赖）、`mkbootimg` 记录到构建日志；
  - #9 telnet 默认关闭（cmdline `lmi_telnet=1` 显式启用，且经 login 认证），
    architecture 增加调试通道威胁模型；
  - #10 `display.c` 平面计数与缓冲上限夹取；
  - #11 文档一致性：README 阶段/构建依赖、runbook 状态与 NCM 术语、宿主侧
    备份副本步骤、产物哈希随重建说明。
- M1a 实测根因（issue #12）：weston 在 lmi 启动即 abort（msm 驱动 IN_FORMATS
  重复格式触发 libweston `weston_drm_format_array_add_format` 断言）→
  二进制补丁 `bl __assert_fail` → NOP；libinput 报 `no input devices found`
  （Alpine 基座无 udevd）→ 安装并启动 eudev；`weston-screenshooter` 需
  `weston --debug` 才被授权（headless 验证依赖）。
- M1b 实测根因（issue #14，2026-09-14）：
  - dropbear 无法启动：Alpine initd 依赖 `need net`，rootfs 未启用 networking
    → `cannot start dropbear as networking would not start`；改 `use net` 并为
    conf.d 加 `-P /run/dropbear.pid`（stop/status 生效）。
  - wpa_supplicant 打印 usage 即退出：Alpine 构建未启用 `CONFIG_DEBUG_FILE`，
    `-f <log>` 不受支持；`lmi-wifi-start` 改为 stderr 追加重定向
    （`2>>/var/log/wpa_supplicant.log`）后 WiFi 正常（`status=ok`）。
  - 离线修补镜像的 journal 陷阱：从分区 dump 的 ext4 若带未回放 journal，
    debugfs 直写后 `e2fsck -fy` 会先回放 journal 并**静默回滚**修补（实测
    `conf.d/dropbear` 被截断为 190 B）→ 固化为"先回放 → 写入 → 修计数 →
    校验"顺序与 `tools/m1/patch-rootfs-image.sh`。
- M0 黑屏根因：内核无 fbdev（`CONFIG_FB=n`）且无用户态 KMS 接管，且
  `bl_power=4` 且 msm 在最后 DRM 客户端退出时熄屏；以 `m0-display` 解决
  （issue #4）。触摸验证设备修正为 `fts_ts` → `/dev/input/event3`。
- M0 启动失败根因：`tools/m0/init` 为 CRLF → busybox shebang 失效 →
  init 退出 127 → kernel panic（issue #3；方式 B 失败链条见 issue #1）。
- runbook §3 补充 Windows 宿主 fastboot 驱动/接口 GUID 注意事项与
  `AdbWriteEndpointSync failed` 恢复方法（2026-09-13 真机救援实测）。
- runbook §5 重写为 BCB 救援流程（`fastboot erase misc` + 二级救援）；
  `misc` 列为唯一 erase 例外；删除"方式 B 后无法进 Android 理论不可能"的错误假设。
- architecture 失败模式表补充"内核未启动 → BCB 残留 → fastboot 循环"；
  明确 T1-03 完成前不得假设 bootloader 会自动清 BCB。
- test-plan 新增 T1-05（部署门禁预检）与 T1-03 备注；risk R3 更新为已触发
  （2026-09-13 真机实测）。
- initramfs 补全动态链接器 `ld-linux-aarch64.so.1`（此前 dropbear 无法执行）。
- ramboot init 挂载 `/dev/pts`（SSH/telnet 需要 PTY）。
- ramboot init 关键步骤改用 `/bin/busybox` 绝对路径，并增加 misc 分区兜底
  路径，保证 BCB 一定被清除。
- recovery-swap 写入后校验 `ANDROID!` 头，防止不完整写入。

- **payload CRLF 事故**（2026-09-15）：`tr -d "\r"` 中反斜杠被 shell 吃掉，
  删掉了 `m1-weston`/`lmi-wifi-start` 里的字母 `r`（WiFi 起不来）；以设备上的正确
  文件回填 + payload 逐文件 sha256 与设备比对（100% 一致）；重建脚本新增自动去 CR。
- **payload 缺口**：此前 payload 缺 `usr/sbin/lmi-keys`（新装会丢音量键/息屏），已入包。
- **字体白框根因**：冷启动早期 fontconfig 重建缓存的窗口 + weston 一次 SIGABRT 后
  wrapper 自弃退出；现启动前 `fc-cache -f`，重试策略改为永不自弃（退避 3 s/30 s）。
- **文档控制字符**：CHANGELOG 中三处被终端 backspace 控制符（0x08）吃掉首字母
  （`boot-m1b-v12/v13`、`battery/temp`），已修复并全仓扫描确认无同类残留。
- M2 遗留（2026-09-14/15）：recovery 引导镜像必须带 `recovery_dtbo`（否则落 fastboot）；
  ABL 不清 BCB、由 Linux init 清；Debian 版 `mkbootimg` 整除 bug（`/`→`//`）。

## [0.0.1] - 2026-09-13

### Added
- 项目启动（立项）。
