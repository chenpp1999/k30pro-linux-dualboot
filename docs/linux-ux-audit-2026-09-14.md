# Linux 适配全面审查（K30 Pro / lmi，2026-09-14）

> 范围：M1b 持久化 rootfs（Alpine 3.23.5 + Weston 14.0.2 + OpenRC）在
> Redmi K30 Pro 上的**可用性/适配性**审查。方法：rootfs 离线盘点（debugfs）
> + 真机在线实测（SSH over USB-NCM/局域网、weston-screenshooter 截图、
> /sys 与进程状态检查）。
> 结论供后续"Linux UX 优化"工作流排期；追踪 issue 待建。

## 0. 已在线验证的即时修复（live，尚未入仓）

1. **终端重开**：`/etc/xdg/weston/weston.ini` 增加
   `[shell] panel-position=top` + `[launcher]`（图标 `/usr/share/lmi/term-icon.png`，
   命令 `weston-terminal --maximized --font-size=16`）→ 顶栏左侧出现终端图标，
   点击即可重开终端（替换原来加载失败的默认图标）。
2. 自绘 64×64 图标已放置 `/usr/share/lmi/term-icon.png`。
3. 备份：`/etc/xdg/weston/weston.ini.orig`（原始 102 B）。
4. ⚠️ 这些文件目前在**已部署 rootfs** 里；仓库的 overlay/staged 树还没有，
   需随下一次镜像重建（v8 / overlay v3）入库，详见 §4。

## 1. 问题清单（按优先级）

### P0 — 直接影响"能不能用"

| # | 问题 | 现象/证据 | 根因 | 建议修复 |
|---|---|---|---|---|
| A1 | **系统时间错误（1970）** | `date`=1970-02-05；面板时钟 `Thu Feb 05`；截图文件名/日志时间戳全错 | 无 NTP 服务、无 RTC 初始化、无时区 | 启用 NTP（busybox ntpd 客户端或 chrony）+ `hwclock -w` 回写 RTC；设 `Asia/Shanghai`；RTC 设备存在（`/dev/rtc0`，`since_epoch`≈35 天）→ 可持久 |
| A2 | **OSK 缺常用符号**（用户实测） | 手机布局主层无 `_ . , / - @` 等；`?123` 符号层分页不明 | weston-keyboard 布局编译期内置，不可配置 | 短期：实测 `?123`/`-->`/`Base` 各页可达性并在文档给出图解；中期：源码级补丁 weston-keyboard 布局（加常用符号行 + Ctrl/Esc/Tab） |
| A3 | **无桌面启动器**（用户实测） | 关掉终端后无法重开 | weston.ini 无 launcher 配置 | ✅ 已 live 修复（§0.1），待入仓 |
| A4 | **weston 服务重启竞态** | `rc-service m1-weston stop` 后 weston 子进程未退；再 start 因 seat 被占 fatal | m1-weston 脚本只 `wait`，init 脚本 pidfile 指向 wrapper | init 脚本 `stop` 改为杀进程组；m1-weston 加 `trap` 清理 weston/客户端 |
| A5 | **无中文字体**（CJK 缺失） | 仅 font-dejavu + encodings；`fc-list :lang=zh` 为空 | 基础镜像未装 CJK 字体 | 安装轻量 CJK 字体（如 `font-noto-cjk` 或 wqy 系列）并 `fc-cache` |
| A6 | **无物理键盘时的终端可用性差** | OSK 无 Ctrl/Esc/Tab/方向键（待确认）；无复制粘贴触摸方案 | weston-keyboard 能力有限 | 与 A2 同批；文档说明"接 USB/蓝牙键盘"路径（蓝牙当前不可用，见 G2） |

### P1 — 明显影响体验

| # | 问题 | 现象/证据 | 根因 | 建议修复 |
|---|---|---|---|---|
| B1 | 终端列数偏少 | font-size=16 + scale=2 → 约 52 列，`ls -l`/`top` 等 80 列输出易折行 | 字号偏大 | 试 13~14 并截图对比；把字号做成可配置（`[terminal] font-size`） |
| B2 | OSK 弹出遮挡终端 | weston-terminal 不支持 text-input 协议，键盘不触发避让/resize | 客户端限制 | 评估换终端（foot?）或用 `--fullscreen`；至少文档说明 |
| B3 | 无亮度 UI/快捷键 | 背光只有 sysfs（536/2047）；音量键未映射 | 无工具/绑定 | 加 `brightnessctl`/脚本 + weston.ini `[keybindings]` 映射音量键（qpnp_pon 暴露 KEY_VOLUMEUP/DOWN，待实测） |
| B4 | 永不息屏 + 无锁屏 | `weston --idle-time=0`；无屏保/锁屏 | 开发期配置 | OLED 烧屏/耗电：评估 idle blank + 触摸唤醒；或低亮度+定时提示 |
| B5 | 无电量/网络状态指示 | 面板只有时钟；电池 sysfs 可读（100%/Full） | 无客户端 | 可写轻量状态脚本（周期性更新面板？weston 面板不支持）→ 评估小工具或放弃 |
| B6 | 无蓝牙 | `bluez` 未装、`/sys/class/bluetooth` 空 | 未启用 | 评估内核 BT 支持与 bluez 打包（蓝牙耳机/键盘） |
| B7 | 无音频 | `/dev/snd` 仅 timer，无声卡 | 内核音频/UCM/pipewire 未配置 | 评估 lmi 音频链路（D80 基线称可用）与最小方案（alsa-utils + UCM） |
| B8 | WiFi 无 UI | 改网络需编辑 `wpa_supplicant.conf` + 重启服务 | 无网络管理器 | 可选：封装脚本 `lmi-wifi-add`（扫/连/切）或评估 nmcli |
| B9 | cursor 主题缺失告警 | weston 日志 `could not load cursor 'dnd-copy'` | 无 cursor theme | 装 `adwaita-cursor-theme` 或忽略（触摸设备无鼠标） |

### P2 — 生态与长期项

| # | 问题 | 说明 |
|---|---|---|
| C1 | 应用极少 | 仅 weston 自带 terminal/editor/tests；无文件管理器/浏览器/图片查看器/计算器 |
| C2 | 无中文输入法 | 无 IME（weston 无 input-method-v2 支持，需 weston 私有协议客户端） |
| C3 | 无自动旋转 | 无加速度计驱动暴露（iio 只有 PMIC ADC） | 
| C4 | 无 htop/tmux/nano/python | 调试/长任务不便；busybox 有 vi |
| C5 | 日志无轮转 | 检查 `syslog`/`weston.log` 增长策略（1.5G rootfs 剩 ~1.0G） |
| C6 | 无 swap | 7.6 GB 内存当前用 0.45 GB，压力不大；可忽略 |

### 设备特有（记录，多为设计内）

- 震动（aw8697）硬件损坏并已在 dtbo 禁用 → 无触觉反馈；
- 无 modem/通话/GPS（非目标）；FOD 指纹无驱动；
- 面板 1080×2400、scale=2（540×1200 逻辑）→ 所有触摸目标按 2x 渲染；
- 三色通知 LED 与手电筒（`/sys/class/leds`）可用，可做通知/手电功能。

## 2. 环境实测数据（摘要）

- 内核 `4.19.325-cip128-st12-perf #10-postmarketOS`；OpenRC 服务：
  `m1-weston / dropbear / seatd / syslog / lmi-wifi`（default）；内存 7.6 GB（用 0.45）；
  rootfs 1.4 G（用 323 M）；Alpine 3.23.5。
- 时间：`date`=1970；`/dev/rtc0` 存在；无 NTP 进程；无 `/etc/localtime`。
- 显示：backlight 536/2047、DPMS On、Weston pixman/DRM；`weston.log` 有
  `computed repaint delay ... abnormal` 告警（已知 msm/weston 时序问题，低危）。
- 输入：`xiaomi-touch`、`qpnp_pon`（电源/音量键，kbd）、`uinput-goodix`（驱动创建的
  虚拟键盘）、`fts_ts`（触摸，event3）；FTS 驱动对每次触摸刷 `[Error] P0 TOUCH_UP!`
  噪声日志。
- 传感器：仅 PMIC ADC（无加速度计/ALS）。
- 网络：WiFi（CX8）正常；NCM `172.16.42.1` 正常；无蓝牙。
- 音频：无声卡（仅 timer）。

## 3. 待用户配合的快速验证项

1. 点 OSK 左下 `?123` → 看是否有 `_` `.`；若没有，找 `-->`（下一页）/`Base` 翻页；
2. 点面板左上角**终端图标** → 应从桌面直接开出新终端；
3. 按音量键 → 是否有任何反应（亮度/音量）；
4. 终端字号偏好：16（现状，约 52 列） vs 13/14（约 64/60 列）。

## 4. 落地路径（建议排期）

1. **立即（配置级，1 次重建即可入仓）**：
   - 时间：NTP + RTC + 时区（新 init 脚本/配置，入 overlay 树）；
   - weston.ini（launcher/panel/字号/时钟格式）+ 图标文件入
     `tools/m1/m1b/etc/xdg/weston/`、`tools/m1/m1b/usr/share/lmi/`；
   - `m1-weston` + init 脚本重启清理修复；
   - CJK 字体包（体积评估后入 rootfs 镜像或 overlay）；
   - rootfs 重建（v8 / overlay v3）+ 验收（参照 M2 流程：方法 A 验证 + 部署）。
2. **短期（需要编译/验证）**：
   - weston-keyboard 布局补丁（在 Linux 内构建或二进制补丁；先在测试设备验证）；
   - 音量键映射（weston keybindings）；
   - 终端字号/避让方案定稿。
3. **中期（调研）**：蓝牙、音频、亮度/息屏策略、WiFi 配置工具、轻量应用集。
4. **长期**：中文输入法、自动旋转、锁屏；以及"是否迁移到 wlroots 系栈"的战略评估
   （会解锁 squeekboard/waybar 生态，但需重新适配显示/输入，成本高，M4 前不做）。

## 5. 风险与注意事项

- 所有 live 修改目前只在**部署 rootfs**（super 内，持久），仓库未记录；
  下次重建镜像前务必把文件回收进仓库（可用 `debugfs dump` 从 `rootfs-live2.img`
  或直接从 Linux 拉取，见本文 §0 路径）。
- 修改 weston.ini/m1-weston 属于低风险（不动分区），但 weston 重启竞态会导致
  黑屏（无输入），修复 A4 时应保证服务可恢复（SSH 保留）。
- weston-keyboard 补丁需注意与 weston 14.0.2 的 ABI/协议一致，先在测试设备验证。

## 6. 实测补充（2026-09-15，v8 首启验证中发现）

### 6.1 weston 合成卡死（黑屏）根因：`background-color`/`panel-color`/`background-image`

- 现象：屏幕全黑（只剩冻结帧），`weston-debug scene-graph` 显示
  `repaint status: awaiting completion`（有未完成的 flip），desktop-shell 的
  fade 黑幕停在全屏不透明。
- 二分实验（同一镜像、只改 weston.ini）：
  | 配置 | repaint 状态 |
  |---|---|
  | 基线（outputs + `[terminal]`） | `no repaint`（健康） |
  | + `[shell] panel-position/clock-format` | 健康 |
  | + `background-color`/`panel-color` | **卡死** |
  | + `background-image`（1080×2400 壁纸） | **卡死** |
  | panel/clock + launchers（**无颜色/无壁纸**） | 健康 ✅ |
- 结论：msm（shadow framebuffer + pixman）路径对 **solid-colour buffer**
  与大尺寸 SHM 壁纸的 flip 完成事件存在问题；**规避方式 = 不使用
  `background-color`/`panel-color`/`background-image`**，保留面板+启动器+24h
  时钟（已验证可用，见 `tools/m1/m1b/etc/xdg/weston/weston.ini`）。
- 备注：该问题是 v8 首启 UX 验证时发现并修复的；`wallpaper.png` 已从 payload
  移除（保留此结论，待内核/weston 修复后可重试）。

### 6.2 其它 v8 修复（首启验证发现）

- `m1-weston` 重写版漏 `export XDG_RUNTIME_DIR` → weston `fatal`（已修）。
- init 脚本 `after seatd` 不足以保证 seatd 可用（首启出现过 seatd socket
  不可接受的窗口）→ 恢复 `need seatd`（已修）。
- **lmi RTC 对 AP 只读**（`hwclock -w` → `ioctl ... Permission denied`）→
  弃用 hwclock 写回，改 **swclock 时间戳 + 每次开机 NTP 校正**：
  `lmi-time-save` 先试 RTC，失败则 `touch /var/lib/misc/openrc-shutdowntime`；
  runlevel 改 `hwclock boot` → `swclock boot`（已修）。

### 6.3 OSK/终端源码补丁（Phase 2，2026-09-15 完成）

- 补丁集 `tools/m1/weston-patches/`（weston 14.0.2 客户端）：
  1. `0001` weston-terminal 实现 `zwp_text_input_v1` → **OSK 可以输入终端**
     （Weston 14 只有 text-input v1；此前 OSK 只能输入编辑器）；
  2. `0002` OSK 符号层补 `_ . ,`（`?123` 层显示每键的第三字段）；
  3. `0003` terminal 目标加入 text-input 协议源码（meson）；
  4. `0004` 键盘宽度 60→45（12 键 ×45 = 540 逻辑宽，消除右侧裁边）；
  5. `0005` 普通键立即 `commit_string`（去掉 preedit 缓冲，敲键即上屏）。
- 构建：`tools/m1/build-weston-clients.sh`（设备内原生编译；产物入 overlay 树
  `tools/m1/m1b/usr/bin/weston-terminal`、`tools/m1/m1b/usr/libexec/weston-keyboard`）。
- **构建坑（务必遵守）**：meson 必须 `-Dprefix=/usr`——默认 `/usr/local` 会让客户端
  去 `/usr/local/share/weston` 找主题图（background.png 等），加载失败 →
  `window_frame_create` 返回 NULL → 启动即段错误（gdb 回溯已确认）。
  另：补丁需 `patch -p0` 应用；跨环境（WSL 与手机 rootfs 的库版本不同）编译的二进制
  不可互换，务必在设备内构建。
- 验证：终端聚焦时 OSK 自动弹出；字母/符号逐键上屏；`Enter`/`Backspace`/方向键可用。
  6. `0006` 退格键修复：客户端未提供 surrounding text 时（weston-terminal），
     OSK 的退格改发 `XKB_KEY_BackSpace` keysym（终端映射为 `0x7f`），
     而不是依赖 `delete_surrounding_text`（无 surrounding text 时那条路是空操作）。

### 6.4 按键与息屏（Phase 2 追加，2026-09-15 完成）

- **音量键 → 亮度**：`tools/m1/lmi-keys.c`（静态 musl 二进制，`/usr/sbin/lmi-keys`，
  OpenRC 服务 `lmi-keys`）：音量 ± 每步 10%；实测注入事件 536↔944 双向生效。
  设备能力实测：`qpnp_pon` = POWER+VOLDOWN，`gpio-keys` = VOLUP（音量上下分属
  两个设备），`uinput-goodix` = 三键全有；守护进程按能力位扫描全部 event 节点。
- **空闲息屏**：weston 的 `--idle-time` 会覆盖 weston.ini `[core] idle-time`，
  故在 `m1-weston` 中设为 `IDLE_TIME=300`（CRTC off）；lmi-keys 同时把背光写 0
  （DRM 后端不动 `panel0-backlight`）。任意触摸/按键恢复亮度。实测：20s 空闲 →
  背光 0；注入触摸 → 恢复；电源键短按 → 开关屏。
- **电源键**：短按切换开关屏（长按由 PMIC 直接复位，与系统无关）。
- 测试工具：`tools/m1/dev/lmi-inject.py`（/dev/uinput 注入按键/触摸，供无人值守
  验证；本轮全部现象均用它复现/验证）。
- 坑：`qpn_pon`（真实设备）只报 VOLDOWN，VOLUP 在 `gpio-keys`；触摸设备
  `fts_ts` 的 BTN_TOUCH + ABS_MT 能力位需按 EV_KEY/EV_ABS 分别读；sysfs
  `capabilities/key` 是高位字在前（解析注意）。

### 6.5 中文输入（Phase 2/IME，2026-09-15 完成）

- **实现**：在自补丁 weston-keyboard 内加拼音页 + 候选条（补丁 0007 + 引擎
  `tools/m1/ime/src/pinyin.c` + 词典 `pinyin.dict`，221 KB）。协议上零改动
  （预编辑 `preedit_string`、提交 `commit_string`、ASCII 走 `keysym`）。
  布局：候选条 + qwerty 三行 + `123/中英/符/空格/，。、/退格/回车`（12 列）。
- **词典数据**：pinyin-data(MIT) 单字读音 + rime-essay-simp(LGPL-3.0) 字/词频
  + rime-luna-pinyin(LGPL-3.0) 多音字权重 + CC-CEDICT(CC BY-SA 4.0) 词语拼音
  （保证"银行/行走/北京大学"等多音节词正确）；生成器与格式见
  `tools/m1/ime/README.md`。431 音节 / 19631 字 / 18130 词。
- **引擎**：音节切分（有界 DFS 打分：整串词 > 最长前缀词 > 首音节单字 > 少音节
  > 长首音节），候选合并前 4 种切分（`xian` 同页给 先/线/… 与 西安）；逐字提交
  （选词只消费其覆盖的音节，剩余拼音继续）；`空格/，/。` 有候选先提交首选；
  `回车` 提交首选或把原始拼音按 ASCII 上屏；`退格` 先删拼音缓冲再发给客户端。
- **踩坑（务必记住）**：
  1. 字符表是"每音节一个 u16 计数 + 数据"**交织**布局，数据下标 =
     `sum(counts[0..n-1]) + n`（漏掉 `+n` 会读到别的音节，曾导致候选乱码）；
  2. stock `input_method_activate()` 会把键盘状态重置为 DEFAULT → 补丁改为
     词典可用时保持拼音态（否则每次聚焦文本框都会悄悄切回英文）；
  3. **cairo toy 字体 API 没有逐字形回退**：DejaVu 缺 CJK 就是豆腐块（即使
     fontconfig 有回退）→ 键盘显式请求 `WenQuanYi Zen Hei`；终端在 weston.ini
     里配 `font=WenQuanYi Zen Hei Mono`（编辑器用 Pango，无此问题）；
  4. weston 只在 seat 有**键盘焦点**时才把输入面板上屏（触摸点击即给焦点）；
  5. 该驱动（msm/pixman）的截图可能混入陈旧帧：几何用 `weston-debug
     scene-graph` 为准（见 `tools/m1/dev/kbd-tap.py`），内容用小裁剪区检查；
  6. proot 构建环境里 `weston-debug | grep/tail` 会丢输出，写文件再读。
- **验证（自动化注入触摸完成）**：`nihao` → 候选首选"你好"（蓝框）→ 点击提交
  → 终端显示 `你好`（字体修复后）；`back` 删除拼音缓冲（`nihao`→`niha` 后提交
  得到"你哈"）；`中/英` 切换正常；候选翻页 `1/4` 显示正常。
