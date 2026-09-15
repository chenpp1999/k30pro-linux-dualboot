# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。

- M3 规划器 v0.1：`tools/m3/lmi-repart.sh`（`status`/`plan`/`backup`/`verify`/
  `restore`；`apply` 故意拒绝自动执行）+ `docs/m3-repart-plan.md`
  + 离线测试 `tools/tests/m3-repart-test.sh`（合成 GPT 镜像，CI 运行，
  2026-09-15 全绿）；风险台账 R1/R2 与测试计划 T2-05..07 同步更新。
  破坏性步骤仍需测试机演练 + 负责人批准（charter M3 门禁）。

## [Unreleased]

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

## [0.0.1] - 2026-09-13

### Added
- 项目启动（立项）。
