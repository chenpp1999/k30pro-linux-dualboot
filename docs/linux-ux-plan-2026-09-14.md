# Linux UX 优化实施计划（2026-09-14）

> 背景：M2 验收完成后，负责人实测指出 Linux 侧可用性问题（无启动器/关闭终端
> 无法重开、OSK 缺符号、时间错乱、界面"像模拟器"等）。按"专业化处理"要求，
> 启动了 5 路并行调研（OSK / Shell 交互模型 / 时间与字体 / 输入与电源 /
> 服务与仓库落地），产出入库为 `docs/research/ux-2026-09-14/`；本文汇总为
> 可执行计划。追踪 issue #17。

## 1. 结论速览

| # | 问题 | 根因（调研结论） | 方案 | 阶段 |
|---|---|---|---|---|
| 1 | 关闭终端后无法重开 | weston.ini 无 launcher；默认图标加载失败 | ✅ 已修：`[shell] panel-position=top` + `[launcher]` + 自绘图标（live 已生效，文件已入仓） | 完成（需入 overlay） |
| 2 | "桌面"背景存在（用户困惑） | Weston 是合成器，desktop-shell 自己绘制壁纸/面板；终端只是客户端 | 方案 A（推荐）：配置级"黑化"（`background-color=0xff000000`、`panel-color`、`clock-format=minutes-24h`），保留瘦面板作触摸入口；方案 B：kiosk-shell + 终端 respawn 的纯控制台模式（可选开关） | P0 |
| 3 | OSK 缺 `_ . , / - @` 等 | 上游 weston 14 只有 normal/numeric/arabic 三套布局；无 phone 布局、无配置项；符号只在 arabic 数据里 | 源码级补丁 weston-keyboard（只换该客户端二进制，零 ABI 风险）：加第 5 行 `Esc Ctrl _ - / @ . , # $ & \|` 等；顺带修键盘宽度 720>540 的裁边（`key_width 60→45`） | P1 |
| 4 | **OSK 打不进终端**（调研发现，比缺符号更根本） | weston-terminal 不实现 `zwp_text_input_v1`；OSK 只能给 text-input 客户端输入 | 补丁 weston-terminal 增加 text-input v1 支持（editor 已有实现可参考）；或（次选）uinput 注入助手 | P1 |
| 5 | 时间 1970 | 无 NTP、无 RTC 初始化、无时区 | busybox ntpd（圆 `need net`→`use net` + `after lmi-wifi`）+ hwclock boot 服务 + ntpd `-S` 定期回写 RTC + tzdata/Asia-Shanghai；weston 时钟 24h | P0 |
| 6 | 中文显示方块 | 仅 DejaVu；无 CJK | `font-wqy-zenhei`（装后 16.29 MB，可入 overlay）+ fc-cache；`LANG=C.UTF-8` | P0 |
| 7 | 音量键无反应 | Weston 14 **没有** `[keybindings]` 配置（硬编码） | udev hwdb 把音量键重映射为亮度键（Weston 内置 brightness-up/down）；或 acpid + brightnessctl 脚本 | P1 |
| 8 | 永不息屏/OLED 风险 | `--idle-time=0`；msm DPMS 息屏有黑屏风险 | 实验：开 idle→DPMS/锁屏，SSH 兜底测试协议（见 input-power.md §3.2）；不安全则退"低亮度+定时提醒" | P2 |
| 9 | 无电量指示 | 面板只支持时钟；Waybar 需 layer-shell | LED 表示低电 + SSH 查询；不做 UI | P2 |
| 10 | weston 重启竞态（stop 杀不掉子进程） | wrapper 只 `wait`，pidfile 指向 wrapper | 重写 m1-weston（trap 全量子进程）+ init stop 三级升级（TERM→等待→KILL+孤儿清理） | P0 |
| 11 | 光标主题告警 / 其他 | 无 cursor theme；FTS 触摸日志噪声；无 BT/音频 | 装 cursor theme（可选）；其余列入 P2/非目标 | P2 |

## 2. 分阶段实施

### Phase 1（P0，配置级 + 服务修复；不动代码）
**目标**：时间正确、中文可读、桌面不再"像模拟器"、服务可安全重启。

文件清单（全部进 overlay 树 `tools/m1/m1b/**`，随 `m1b-ux-v3` overlay 下发）：
- `etc/xdg/weston/weston.ini`：加 `background-color=0xff000000`、`panel-color=0xff202020`、
  `clock-format=minutes-24h`（保留 launcher/panel）
- `etc/init.d/ntpd`（覆盖：`need net`→`use net` + `after lmi-wifi`）
- `etc/conf.d/ntpd`（国内 NTP pool + `-S` 回写 RTC）
- `etc/init.d/lmi-hwclock-save` + `etc/conf.d/`（可选，或直接用 openrc 的 hwclock）
- `etc/localhost`/`etc/timezone`（Asia/Shanghai）+ `usr/share/zoneinfo/Asia/Shanghai`（tzdata 提取）
- `etc/profile.d/00-lmi-locale.sh`（`LANG=C.UTF-8`）
- `usr/share/fonts/**`（wqy-zenhei 字体 + fontconfig 配置）
- `usr/sbin/m1-weston` + `etc/init.d/m1-weston`（A4 修复稿，见 `research/integration.md` §1）
- runlevel symlink：`etc/runlevels/default/ntpd` 等（overlay 不能建符号链接，需要在
  m1b-init 或 overlay 解包脚本中 `rc-update add`——落地时处理）

构建/部署：`m1b-init.sh` 常量 bump → `overlay-version m1b-ux-v3` → 重建
`boot-m1b-v8.img`（核/DTB/dtbo 沿用 v7）→ 方法 A RAM 启动验证 → 部署
recovery + attestation → 首启应用 overlay → 验收。

### Phase 2（P1，源码级；让触摸打字可用）
1. 在设备 Linux 内装 build-base + dev 头（约 209 MB，临时）或 proot/chroot 构建；
2. 补丁 `clients/keyboard.c`（布局：symbol 行 + Esc/Ctrl；宽度 45）→ 产出
   `weston-keyboard`；
3. 补丁 `clients/terminal.c`（实现 `zwp_text_input_v1`）→ 产出 `weston-terminal`；
4. 用 `[input-method] path=` 指向补丁版 keyboard（或直接替换 `/usr/libexec/weston-keyboard`）；
5. 真机验证：OSK 打字进终端、符号齐全、Ctrl-C 可用；入 overlay。
风险：weston 客户端与 14.0.2 源码必须严格对应（同上游 tag），先 live 验证再固化。

### Phase 3（P2，可选）
- 音量键亮度（hwdb 或 acpid+brightnessctl）；idle/DPMS 黑屏实验（SSH 兜底）；
- kiosk 纯控制台模式开关（`/usr/lib/weston/kiosk-shell.so` 需先确认存在）；
- LED 低电提示；cursor theme；WiFi 配置脚本；
- 非目标：蓝牙/音频/中文输入法（另评估）；Sxmo/Phosh 迁移（M4 战略评估）。

## 3. 验收清单（UX 子项，按 test-plan 风格）
- UX1-01 时间：开机（含无网/有网）后 60 s 内 `date` 正确（±2 s），重启保持；
- UX1-02 时钟面板 24 小时制且显示日期；
- UX1-03 关闭终端后可从面板图标重开（连续 3 次）；
- UX1-04 `rc-service m1-weston restart` × 3 无残留、无 fatal；SSH 全程可用；
- UX1-05 中文文件名/文本在终端与编辑器显示正常（fc-list :lang=zh 非空）；
- UX1-06 OSK：`_ . , / - @` 等符号可达；Esc/Ctrl/Tab 可用（Phase 2）；
- UX1-07 OSK 输入可进入终端（Phase 2）；
- UX1-08 桌面背景为纯黑、无花哨壁纸；
- UX1-09 分区不变式：`boot` sha 不变；M2 切换路径（to-linux/reboot 回 Android）不回归；
- UX1-10 overlay 幂等：重复启动不重复应用；失败不阻断启动（沿用现设计）。

## 4. 回退
- 单文件级：overlay 只增不删；m1-weston 回退稿=原脚本（随 overlay 覆盖）或 SSH 手工恢复；
- 镜像级：回退 `boot-m1b-v7.img`（attestation 仍在 `/data/local/lmi-dualboot/`）；
- 系统级：`recovery-swap.sh restore-twrp` / TWRP 恢复（验收演练已做）。

## 5. 调研产物与来源
- `docs/research/ux-2026-09-14/osk.md`（weston 键盘布局与构建路径）
- `docs/research/ux-2026-09-14/shell.md`（Shell/交互模型选型）
- `docs/research/ux-2026-09-14/time-fonts-locale.md`（NTP/RTC/时区/字体/本地化）
- `docs/research/ux-2026-09-14/input-power.md`（音量键/亮度/息屏/电量）
- `docs/research/ux-2026-09-14/integration.md`（服务修复与仓库落地流程）
- 各报告末尾附官方文档/源码/包索引等来源链接。

## 6. 待负责人决策
1. Phase 1 立即执行？（会重建 `boot-m1b-v8.img` 并部署到 recovery；不动 boot 分区）
2. 桌面形态：方案 A（黑化桌面+面板）默认，还是方案 B（kiosk 纯控制台）默认？
3. 是否启动 Phase 2（weston 客户端补丁构建，需在设备上临时安装 ~209 MB 构建依赖）？
