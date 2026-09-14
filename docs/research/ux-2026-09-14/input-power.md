# 音量键映射 / 亮度 / 息屏防烧屏 / 电量指示 — 落地方案（K30 Pro / lmi）

> 范围：Alpine 3.23.5 + OpenRC + Weston 14.0.2（DRM/pixman，DSI 1080x2400@scale2），musl，无 systemd、无桌面生态、触摸为主。
> 结论基于 **Weston 14.0.2 / eudev 3.2.14 / acpid 2.0.34 / Alpine 3.23 包库** 的源码与手册核对，并对照本仓库
> `docs/linux-ux-audit-2026-09-14.md` 的实测环境。文中标注【待实测】的项必须在真机确认后才能定型。
> 本报告不修改仓库、不连接设备。

## 0. 结论速览（先看这节）

| # | 结论 | 影响 |
|---|---|---|
| 1 | **Weston 14 没有 `[keybindings]` 配置节**（手册与源码均无）。`weston.ini` 里写它没有任何效果；desktop-shell 快捷键全部硬编码 | 任务书里"用 keybinding 把音量键绑到亮度"的路线 **不可行**，需要换方案 |
| 2 | 硬编码绑定里**有**亮度键：裸 `KEY_BRIGHTNESSDOWN/UP`(224/225) + `mod+F9/F10`（mod 默认 super）；截图 `Super+S`（硬编码 Super）；录屏 `Super+R` | 音量键（XF86Audio*）无绑定，这就是"按了没反应"的直接原因 |
| 3 | 音量键落地方案二选一：**A. udev hwdb 把音量键重映射成 `brightnessup/down`**（零守护进程，直接命中 Weston 内置亮度动作）或 **B. acpid + brightnessctl**（最稳，可扩展截图/终端）。**两者不可同时启用**（会双触发） | 建议 B 做主线、A 做零依赖试验 |
| 4 | `weston --idle-time=N` 的息屏路径是 fade→lock→`weston_compositor_sleep()`→**DPMS off**（源码），唤醒靠任意输入 + 点一下 "Unlock your desktop" 对话框。msm/DSI 的 DPMS 恢复存在风险，必须先按 §3.2 测试协议在真机验证，SSH 兜底 | idle 是否启用取决于实测结果 |
| 5 | 电量指示：Weston 面板只能改时钟格式（`none/minutes/seconds/…-24h`），**无电池**；Waybar 等需要 `wlr-layer-shell`，Weston 不支持 | **放弃 UI**：低电用 LED 闪烁 + SSH 查询；可选"电池窗口"用终端 watch |
| 6 | 振动（aw8697）已禁用且无替代；反馈只能用 LED 或屏幕 | 记录项，无解 |

## 1. 音量键映射

### 1.1 事实核对：Weston 14 的按键绑定机制

- 手册 **weston.ini(5) 14.0.2 无 KEYBINDINGS 节**（节列表仅：core/libinput/shell/launcher/output/input-method/keyboard/terminal/xwayland/screen-share/autolaunch/color_characteristics）[S1]。
- 源码核对：`desktop-shell/shell.c 14.0.2` 中没有任何 `keybindings` 解析；`shell_add_bindings()` 全部是硬编码（[S2]，shell.c:4802）。
- 老资料里的 `[keybindings]`（如 `screenshot=super+s`）来自更老的 Weston 或第三方模块 `weston-binder`（2013 年，早已不兼容）[S3]，**不要照抄**。
- 实际生效的硬编码绑定（Weston 14.0.2，[S2] 源码行号）：

| 组合 | 动作 | 说明 |
|---|---|---|
| `mod + F9` / `mod + F10` | 亮度 -/+（±25/255，下限 5，上限 255） | mod=`binding-modifier`，默认 super；shell.c:4867-4870 |
| **裸** `KEY_BRIGHTNESSDOWN` / `KEY_BRIGHTNESSUP`（内核 224/225） | 同上 | 无修饰键，shell.c:4824-4827 |
| `Super + S` | 截图（启动 `weston-screenshooter` 客户端） | 硬编码 Super，frontend/weston-screenshooter.c:142 |
| `Super + R` | 开始/停止录屏到 `capture.wcap` | 同上 :144 |
| `mod + Shift + F` / `mod + M` / `mod + K` | 全屏 / 最大化 / 杀窗口 | shell.c:4839-4872 |
| `Ctrl + Alt + Backspace` | 退出 weston（`allow-zap=true` 时） | shell.c:4807 |
| `mod + Tab` / `mod + Shift + 方向键` | 切窗 / 平铺 | shell.c:4852-4865 |

- 音量键（`XF86AudioRaiseVolume/LowerVolume`）**不在**任何绑定表中；无物理键盘时 `mod+*`、`Super+S` 也按不出来。

### 1.2 qpnp_pon 的键码与 keysym 映射

内核层（evdev keycode）→ XKB keycode（+8）→ keysym（xkeyboard-config `evdev`/`inet`）[S4]：

| 物理键 | 内核 KEY_* | 内核码 | XKB keycode | keysym |
|---|---|---|---|---|
| 音量- | KEY_VOLUMEDOWN | 114 | 122 `<VOL->` | `XF86AudioLowerVolume` |
| 音量+ | KEY_VOLUMEUP | 115 | 123 `<VOL+>` | `XF86AudioRaiseVolume` |
| 电源 | KEY_POWER | 116 | 124 `<POWR>` | `XF86PowerOff` |
| （内置亮度键） | KEY_BRIGHTNESSDOWN/UP | 224/225 | 232/233 | `XF86MonBrightnessDown/Up` |

**重要坑（必须实测）**：同平台多台设备上，`qpnp_pon` 只暴露 `KEY_POWER + KEY_VOLUMEDOWN`，**音量+在另一个 `gpio-keys` 设备**上 [S5]。本机 audit 只写了"qpnp_pon（电源/音量键，kbd handler event1）"，未逐键验证。先做：

```sh
# 在 Linux（SSH）里：
cat /proc/bus/input/devices                 # 看每个 eventX 的 Name/Handlers
apk add evtest libinput-tools               # community
evtest /dev/input/event1                    # 逐键按：记录 KEY_* 名字
# 或看能力位图（bit 114/115/116）：
od -An -v -tu1 /sys/class/input/event1/device/capabilities/key
# libinput 侧：libinput debug-events --device /dev/input/event1
```

若音量+在别的设备（如 event0/gpio-keys），§1.3/§1.4 的匹配规则要覆盖两个设备名。

### 1.3 方案 A：udev hwdb 重映射（零守护进程）

思路：把音量键在**内核设备级**改成亮度键（eudev 的 keyboard builtin 用 `EVIOCSKEYCODE` 改写设备键表 [S6]），Weston 的裸亮度绑定（224/225）直接生效，不需要任何常驻进程、不需要 weston.ini（它本来也没有可配的键绑定）。

文件（overlay 路径 `tools/m1/m1b/etc/udev/hwdb.d/90-lmi-keys.hwdb`）：

```
# 音量键 -> 亮度键（Weston 内置动作）；KEY_VOLUMEDOWN=114=0x72, KEY_VOLUMEUP=115=0x73
evdev:name:qpnp_pon:*
 KEYBOARD_KEY_72=brightnessdown
 KEYBOARD_KEY_73=brightnessup
# 如果音量+在 gpio-keys 设备上，再加一段（名字按 /proc/bus/input/devices 实测替换）：
evdev:name:gpio-keys:*
 KEYBOARD_KEY_73=brightnessup
```

生效（运行中即可验证）：

```sh
udevadm hwdb --update            # eudev 语法，见 [S6]
udevadm trigger /dev/input/event1   # 重放 rules，触发 keyboard builtin
# 按音量键；同时看日志确认 Weston 是否接管背光：
grep -n "Initialized backlight" /var/log/weston.log
```

前置条件与风险：
1. **Weston 必须成功初始化背光**，否则内置亮度动作空转（`output->set_backlight == NULL` 时直接 return，shell.c:4418）。验证：
   ```sh
   cat /sys/class/backlight/panel0-backlight/type     # 需要是 raw
   readlink /sys/class/drm/card0/device; readlink /sys/class/backlight/panel0-backlight/device
   ```
   Weston 的 `libbacklight` 对非 LVDS/eDP（DSI 就是）**只接受 `type=raw`**，且要求背光设备 `device` 符号链接与 DRM card 的 device 同名 [S7]。若 `type=platform` 或链接不匹配 → Weston 找不到背光 → 改用方案 B。
2. 键被改成亮度后**失去音量语义**（本机无声卡，无影响；未来加音频要改回）。
3. 若设备带 MSC_SCAN，hwdb 左侧要用 evtest 里 `MSC_SCAN value` 的十六进制（`evtest` 输出里的 `KEYBOARD_KEY_<scan>`）。
4. 该重映射只影响 Linux 启动后的 udev 环境，Android 不受影响。

### 1.4 方案 B：acpid + 脚本（推荐主线）

acpid 2.0.34 在 Alpine **main**，apk 36.9 KiB / 安装 202 KiB，含 openrc 子包；它监听 `/dev/input/event*`，把按键翻译成 `button/volumeup`、`button/volumedown` 等事件并执行动作 [S8][S9]。

安装与文件（overlay 路径按仓库 `tools/m1/m1b/` 映射）：

```sh
apk add acpid acpid-openrc brightnessctl   # brightnessctl 8.8KiB/安装 65.8KiB [S10]
rc-update add acpid default
```

`/etc/acpi/events/lmi-volup`：

```
event=button/volumeup
action=/usr/sbin/lmi-key volumeup
```

`/etc/acpi/events/lmi-voldown`：

```
event=button/volumedown
action=/usr/sbin/lmi-key volumedown
```

`/usr/sbin/lmi-key`（亮度单击；双击=截图/终端；不依赖系统时间，用 `/proc/uptime`）：

```sh
#!/bin/sh
# usage: lmi-key volumeup|volumedown
key="$1"
state="/run/lmi-key-$key"
now=$(cut -d. -f1 /proc/uptime)
last=$(cat "$state" 2>/dev/null || echo 0)
if [ $((now - last)) -le 1 ]; then
    rm -f "$state"
    case "$key" in
        volumeup)   exec /usr/sbin/lmi-screenshot ;;
        volumedown) exec /usr/sbin/lmi-terminal ;;
    esac
fi
printf '%s\n' "$now" > "$state"
# 延迟单击动作，给双击留窗口
( sleep 1.2
  [ "$(cat "$state" 2>/dev/null)" = "$now" ] || exit 0
  rm -f "$state"
  case "$key" in
      volumeup)   exec /usr/sbin/lmi-brightness + ;;
      volumedown) exec /usr/sbin/lmi-brightness - ;;
  esac
) &
```

`/usr/sbin/lmi-brightness`（root 直写 sysfs，不依赖 logind）：

```sh
#!/bin/sh
d=/sys/class/backlight/panel0-backlight
max=$(cat "$d/max_brightness")
cur=$(cat "$d/brightness")
step=$((max / 20))            # 5% 一档；小于 1 时取 1
case "$1" in
    +) new=$((cur + step)); [ "$new" -gt "$max" ] && new=$max ;;
    -) new=$((cur - step)); [ "$new" -lt $((max / 100)) ] && new=$((max / 100)) ;;
    *) new="$1" ;;
esac
printf '%s\n' "$new" > "$d/brightness"
```

`/usr/sbin/lmi-screenshot`（Weston 14 的截图为外部客户端，硬编码 Super+S 无键盘按不出来）：

```sh
#!/bin/sh
mkdir -p /root/screenshots
export XDG_RUNTIME_DIR=/run/lmi-weston WAYLAND_DISPLAY=wayland-0
export XDG_PICTURES_DIR=/root/screenshots
exec weston-screenshooter
```

`/usr/sbin/lmi-terminal`：

```sh
#!/bin/sh
export XDG_RUNTIME_DIR=/run/lmi-weston WAYLAND_DISPLAY=wayland-0
exec weston-terminal --maximized --font-size=16
```

行为与风险：
- acpid 只上报**按下**事件（`acpi_listen` 可实测；按住不放不会有按下/释放对），所以做不了长按，这里用"双击"实现第二功能。
- 亮度写 sysfs 需要 root：acpid 以 root 运行、Weston 的 wayland socket 属 root（`/run/lmi-weston`），脚本可直接用；若改成非 root 用户，需要 udev 规则给 `video` 组写权限（`brightnessctl-udev` 子包即此用途 [S10]）。
- **不要**为 `button/power` 写事件文件：电源键交由 PMIC 硬件长按处理，误绑 acpid 动作（如关机）容易造成意外断电。

### 1.5 电源键

- 现状正确：Weston 无电源键绑定，OpenRC 无 logind，按电源键无动作是预期。
- 若要加功能（如短按锁屏），也只建议在明确需要时加；长按硬件关机/复位路径不受影响。
- 不推荐把电源键当"截图/终端"触发器：误触代价过高。

## 2. 亮度控制

### 2.1 工具与体积（Alpine 3.23）

| 包 | 版本 | 体积（apk/安装） | 说明 |
|---|---|---|---|
| brightnessctl | 0.5.1-r8 | 8.8 KiB / 65.8 KiB | community；自动找 `/sys/class/backlight/*`；`-d panel0-backlight` 指定设备；`set +5%`、`set 300`、`info`、`--save/--restore` [S10][S11] |
| light | 无此包 | — | **Alpine v3.23 仓库不存在**（已核实）[S12] |
| （自写脚本） | — | ~0 | 直写 sysfs，见 §1.4，无额外依赖 |

常用运行中命令（立即可验证）：

```sh
apk add brightnessctl
brightnessctl -l                                  # 列出设备
brightnessctl -d panel0-backlight info
brightnessctl -d panel0-backlight set 30%         # 亮度约 614/2047
brightnessctl -d panel0-backlight set +200        # 原始值步进
cat /sys/class/backlight/panel0-backlight/{brightness,max_brightness,bl_power}
```

### 2.2 与 Weston 内置亮度的配合与冲突

- Weston 在 DRM backend 启动时把背光归一化到 0..255（`drm_get_backlight`，drm.c:1400），按键步进 ±25/255（≈±10% 满量程，本机最大 ≈±200 原始值），下限 5（≈40 原始值）[S2][S7]。
- Weston 只用 sysfs 直写（`libbacklight.c` 打开 `brightness` O_RDWR，无 D-Bus/logind 依赖；root 运行即可）[S7]——**不依赖 systemd**。
- 外部（brightnessctl）改亮度后，Weston 内部的 `backlight_current` 会过期：下次按亮度键会以旧值为基准跳变。混用时建议只保留一条控制路径。
- **方案 A 与方案 B 不可同时启用**：hwdb 重映射后按键变成 `brightnessup/down`，acpid 会收到 `video/brightnessup` 类事件（若你也绑了就会双触发），同时 Weston 也会响应。

### 2.3 权限/udev 规则（仅非 root 场景需要）

```sh
# /etc/udev/rules.d/90-lmi-backlight.rules
# SUBSYSTEM=="backlight", ACTION=="add", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod 0660 /sys/class/backlight/%k/brightness"
```

当前设计里所有调用者都是 root（OpenRC/acpid），可省略；`brightnessctl-udev` 子包已经做了同类规则 [S10]。

## 3. 息屏与防烧屏

### 3.1 Weston 14 的 idle 行为（源码结论）

`--idle-time=N`（命令行优先于 `weston.ini [core] idle-time`）[S13] 触发后：

1. `libweston/compositor.c`：空闲定时器到 → 状态置 `WESTON_COMPOSITOR_IDLE` 并发 `idle_signal`（compositor.c:6153）。
2. `desktop-shell/shell.c`：`idle_handler()` → `shell_fade(FADE_OUT)`（全屏黑色遮罩，shell.c:3988）。
3. 淡出完成 → `shell_fade_done()` 调 `lock()` → **`weston_compositor_sleep()` → DPMS off 全部输出**（shell.c:3747、3819-3821；compositor.c:6130）。
4. 任意输入 → `weston_compositor_wake()` → DPMS on + `wake_signal` → `unlock()`：向 desktop-shell 客户端要锁屏 surface，出现 **"Unlock your desktop" 对话框，触摸点一下解锁**（clients/desktop-shell.c:1093 起，支持 touch down/up）[S2]。
5. 若桌面 shell 客户端已退出，`unlock()` 直接 `resume_desktop()`，无需点击（shell.c:3789-3797）。

结论：Weston 14 的 idle **必然走 DPMS**（锁屏-睡眠是一体的），没有"只黑屏不 DPMS"的配置档位；也不支持外部工具控制 DPMS（Weston 未实现 `wlr-output-power-management`，别的进程也无法在 Weston 持有 DRM master 时用 modetest 改 DPMS）[S14]。

### 3.2 msm/DSI 上的风险与测试协议【待实测】

风险点：DPMS off→on 要重新走 DRM modeset/panel on，msm + DSI（DSC）面板的恢复失败在多平台有先例（唤醒后黑屏类失败属常见模式）[S15]；触摸唤醒在架构上没问题（输入设备不随 DPMS 关闭，libinput 事件会触发 wake），风险集中在**面板能否重新点亮**。

测试（全程保留 SSH，随时可救）：

```sh
# 1) 记录现状与备份
tr '\0' ' ' < /proc/$(pidof weston)/cmdline; echo
cp /usr/sbin/m1-weston /root/m1-weston.bak
# 2) 临时把 idle 改为 30s（命令行参数优先，改 ini 无效）
sed -i 's/--idle-time=0/--idle-time=30/' /usr/sbin/m1-weston
rc-service m1-weston restart
# 3) 不动屏幕 35s → 预期黑屏；触摸 → 预期亮屏 + Unlock 对话框 → 点一下解锁
# 4) 查日志证据
grep -Ei 'dpms|idle|Initialized backlight|DSI-1' /var/log/weston.log | tail -30
# 5) 若唤醒黑屏/卡死：
rc-service m1-weston restart      # 重跑 modetest splash release + modeset
# 仍不行：reboot（BCB 空 → 回 Android）或长按电源
```

判定：
- 触摸能唤醒、面板能恢复 → 可以启用 idle（建议 120–300 s），同时可以拿到防烧屏收益。
- 唤醒后黑屏/花屏/只有背光 → **回退 `--idle-time=0`**，走 §3.4 替代策略。

### 3.3 OLED（AMOLED）烧屏策略（推荐）

- 烧屏来自**静态、高亮**内容：顶部面板（时钟/图标）、终端标题/状态行、长期不动的终端文字。
- 首选：idle 黑屏（若 §3.2 通过）——OLED 黑 = 像素关闭，既省电又防老化；DPMS 后整屏断电。
- 亮度纪律：日常 25%–40%（当前 536/2047≈26% 合适）；避免长时间 70%+ 白底。
- 减少静态元素：长挂机时可 `[shell] panel-position=none` 隐藏顶栏（代价是无时钟/启动器）；终端背景深色、避免固定高亮行。
- 不用照抄"锁屏壁纸/屏保"：Weston 14 已无 `[screensaver]` 节，锁屏即黑屏对话框。

### 3.4 若 DPMS 不安全的替代方案

1. **保持 `--idle-time=0` + 手动低亮度**：SSH 里 `brightnessctl set 5%`；适合"当服务器用"的场景（最稳）。
2. **`bl_power` 伪熄屏实验【P2，待实测】**：`/sys/class/backlight/panel0-backlight/bl_power` 当前 =0。
   ```sh
   echo 4 > /sys/class/backlight/panel0-backlight/bl_power   # FB_BLANK_POWERDOWN，观察
   echo 0 > /sys/class/backlight/panel0-backlight/bl_power   # 恢复
   ```
   若驱动真的关背光/面板，可用 acpid 做一个"按键熄屏/亮屏"开关（无自动 idle、无触摸唤醒）；若无效（下游驱动常忽略 bl_power）则放弃。**注意**：它能物理关面板，同样有恢复风险，按 §3.2 的 SSH 兜底方式测试。
3. **定时提醒**：无法做自动屏保（Weston 无 idle 信号给外部进程、无 layer-shell）；只能用 LED/终端提示"该歇屏了"，不作为主方案。

## 4. 电量/状态指示

### 4.1 面板能力的硬限制

- `[shell] clock-format` 仅支持 `none / minutes / seconds / minutes-24h / seconds-24h`，**不能显示电池** [S1]。
- 面板没有通用插件机制；Weston 不实现 `wlr-layer-shell`，Waybar 等状态栏**无法运行**（官方确认）[S16]。
- 运行中可读数据齐全：`/sys/class/power_supply/battery/{capacity,status,voltage_now,current_now,uevent}`；本机实测 `capacity=100, status=Full`。

### 4.2 可行做法与工作量

| 方案 | 体积/工作量 | 说明 |
|---|---|---|
| **LED 低电指示（推荐）** | 0 依赖，脚本 + OpenRC 服务，约半天含测试 | 轮询 capacity/status；低电红闪、充电绿稳、正常灭。用内核 `timer` trigger 闪烁，无需额外进程 |
| 电池窗口 | 小（脚本 + `[launcher]` 图标） | 面板加一个 launcher，打开终端跑 `watch`；能看数值，但占用屏幕且不常驻 |
| 面板改造 | 大（改 weston 源码/自写 wayland 客户端） | 需要编译、适配，不划算，不排期 |
| **SSH 查询（基线）** | 0 | `cat /sys/class/power_supply/battery/uevent`；已有 SSH 可用 |

`/usr/sbin/lmi-powerled`（名称按 `ls /sys/class/leds` 实测替换）：

```sh
#!/bin/sh
# 低电闪红/充电绿；周期 30s
LED_RED=${LED_RED:-/sys/class/leds/red}
LED_GREEN=${LED_GREEN:-/sys/class/leds/green}
led_off() { [ -e "$1/brightness" ] && { echo none > "$1/trigger" 2>/dev/null; echo 0 > "$1/brightness"; }; }
while :; do
    cap=$(cat /sys/class/power_supply/battery/capacity)
    st=$(cat /sys/class/power_supply/battery/status)
    case "$st" in
        Charging|Full) led_off "$LED_RED"; [ -e "$LED_GREEN/brightness" ] && { echo none > "$LED_GREEN/trigger"; echo 255 > "$LED_GREEN/brightness"; } ;;
        *) if [ "$cap" -le 15 ]; then
               [ -e "$LED_RED/trigger" ] && { echo timer > "$LED_RED/trigger"; echo 500 > "$LED_RED/delay_on"; echo 500 > "$LED_RED/delay_off"; }
           else led_off "$LED_RED"; led_off "$LED_GREEN"; fi ;;
    esac
    sleep 30
done
```

`/etc/init.d/lmi-powerled`（照抄仓库 `tools/m1/m1b/etc/init.d/lmi-wifi` 的 OpenRC 风格）：

```sh
#!/sbin/openrc-run
name="lmi-powerled"
description="battery capacity LED indicator"
command="/usr/sbin/lmi-powerled"
command_background="yes"
pidfile="/run/lmi-powerled.pid"
output_log="/var/log/lmi-powerled.log"
error_log="/var/log/lmi-powerled.log"
depend() { need localmount; after m1-weston; }
```

运行中快速验证：`ls /sys/class/leds`；`echo 255 > /sys/class/leds/<led>/brightness`；`echo timer > .../trigger`。
旧版 audit 的设备还有 `flash`/`torch`（手电），可另做按键开关，与本项无关。

## 5. 触觉反馈

- aw8697 硬件损坏且已在 dtbo 禁用，**无振动**，也没有第二个执行器可用 [S17]。
- 替代反馈：LED 闪一下（如确认音量键动作）、屏幕亮度变化本身就是反馈；不做额外开发。

## 6. 落地方式

### 6.1 运行中 Linux 上立即可验证（不改仓库、不改镜像）

```sh
# 键码核对
evtest /dev/input/event1 | grep -E 'KEY_(VOLUME|POWER|BRIGHTNESS)'
# 亮度三连
apk add brightnessctl; brightnessctl -l; brightnessctl -d panel0-backlight set 50%
cat /sys/class/backlight/panel0-backlight/type
grep -n 'Initialized backlight' /var/log/weston.log
# 截图（现有能力）
XDG_RUNTIME_DIR=/run/lmi-weston WAYLAND_DISPLAY=wayland-0 weston-screenshooter
# 方案 B 试验（可回滚：删文件 + rc-service acpid stop）
apk add acpid acpid-openrc brightnessctl
cat > /etc/acpi/events/lmi-volup <<'EOF'
event=button/volumeup
action=/usr/sbin/lmi-brightness -
EOF
cat > /etc/acpi/events/lmi-voldown <<'EOF'
event=button/volumedown
action=/usr/sbin/lmi-brightness +
EOF
/etc/init.d/acpid start
# 建议同时跑 acpi_listen 看事件名是否匹配
# 方案 A 试验（可回滚：删 hwdb 文件后 udevadm hwdb --update && udevadm trigger）
# 写 /etc/udev/hwdb.d/90-lmi-keys.hwdb（内容见 §1.3）
udevadm hwdb --update; udevadm trigger /dev/input/event1
# idle/DPMS 实测：见 §3.2（SSH 兜底）
# 电量
apk add acpid acpid-openrc 2>/dev/null; cat /sys/class/power_supply/battery/{capacity,status}; ls /sys/class/leds
```

### 6.2 需要入 overlay / 重建镜像的文件清单

仓库侧（下次 overlay 版本；沿用 `tools/m1/m1b/` 树 + `m1b-init.sh` 的 `OVERLAY_VERSION` 机制）：

| 仓库路径 | 用途 | 备注 |
|---|---|---|
| `tools/m1/m1b/etc/xdg/weston/weston.ini` | 面板/启动器/字号（现状保持） | 本项不改键绑定（无此机制）；可选加 `clock-format=minutes-24h` |
| `tools/m1/m1b/etc/udev/hwdb.d/90-lmi-keys.hwdb` | 方案 A：音量键→亮度键 | A/B 二选一 |
| `tools/m1/m1b/etc/acpi/events/lmi-volup`、`lmi-voldown` | 方案 B 事件 | 不添加 `button/power` |
| `tools/m1/m1b/usr/sbin/lmi-key`、`lmi-brightness`、`lmi-screenshot`、`lmi-terminal` | 方案 B 脚本（chmod +x） | 脚本内容见 §1.4 |
| `tools/m1/m1b/usr/sbin/lmi-powerled`、`etc/init.d/lmi-powerled` | 电量 LED | 名称按实测 LED 调整 |
| `tools/m1/m1b/usr/sbin/m1-weston` 或同步 `tools/m1/m1-weston.sh` | 调整 `--idle-time=N`（若 §3.2 通过）、导出 `XDG_PICTURES_DIR=/root/screenshots` | 部署 rootfs 里现有的是 `/usr/sbin/m1-weston`；入仓前先 SSH/dump 与仓库副本 `diff` |
| 包依赖 | `apk add` 需进入 rootfs（brightnessctl/acpid/acpid-openrc） | 离线镜像走构建流程装包，或打包 apk 进 overlay |

流程要点：更新文件 → 提升 `OVERLAY_VERSION`（`tools/m1/m1b-init.sh:36`）→ 用 `mk-overlay.py` 生成 overlay（注意 handoff 记录：base 用 `--base-tree`）→ 重建 `boot-m1b-*.img` → 部署（recovery + BCB）→ 按 `docs/m2-runbook.md` 验收。overlay 不会删除文件，回滚 = 发新 overlay 版本恢复旧文件。

### 6.3 验收步骤

1. 音量+/- 各按 3 次：亮度按预期步进，无异常跳变（记录 raw 值序列）。
2. 双击音量±：截图文件出现在 `/root/screenshots/` / 打开新终端。
3. （若启用）idle 到点黑屏，触摸唤醒 → 点 Unlock → 桌面恢复；连测 10 次无失败；`weston.log` 无 error。
4. 低电场景（可拔充电线等待或脚本内临时改阈值）LED 闪烁正确；充电绿灯。
5. 电源键无任何新行为；长按仍能硬件复位。
6. 回归：重启 3 轮，按键功能保持（overlay 一次性生效验证）。

## 7. 优先级建议

**P0（必须先做，决定后续路线）**
- 实测 `qpnp_pon` 逐键键码（可能音量+在其他设备上）与 `panel0-backlight/type`、weston 是否 "Initialized backlight"。
- 音量键→亮度二选一落地：B（acpid+brightnessctl，推荐）或 A（hwdb）；不做则保持"按了没反应"。
- 按 §3.2 做 DPMS/idle 真机测试，决定 idle-time 策略。

**P1**
- 若 DPMS 通过：`--idle-time=180` 入 overlay + 防烧屏策略（亮度上限、长挂机提示）。
- 电量 LED 指示（脚本 + OpenRC，零依赖）。
- `m1-weston` 收尾：`XDG_PICTURES_DIR`、截图目录；确认与仓库副本一致。

**P2**
- 双击截图/终端（依赖 P0 的 B 方案脚本）。
- `bl_power` 伪熄屏实验（若 DPMS 不通、又必须关屏）。
- 自定义 C 键守护（支持长按/组合，可替代 acpid，复用 `tools/m1/utouch.c` 的构建方式）；不建议为此升级 Weston 15（lua shell 生态未验证）。

## 8. 来源

- [S1] weston.ini(5) 14.0.2（Debian trixie）：https://manpages.debian.org/trixie/weston/weston.ini.5.en.html （节列表无 keybindings；clock-format 枚举；idle-time 语义）
- [S2] weston 14.0.2 源码（Debian sources）：https://sources.debian.org/src/weston/14.0.2-1/ ；关键：`desktop-shell/shell.c`（backlight_binding:4402、lock:3747、idle_handler:3988、shell_add_bindings:4802）、`libweston/backend-drm/drm.c`（drm_get_backlight:1400、drm_set_dpms:1473）、`libweston/compositor.c`（wake:6071、sleep:6130、idle:6153）、`frontend/weston-screenshooter.c`（Super+S/Super+R:142-145）、`clients/desktop-shell.c`（Unlock 对话框）
- [S3] weston-binder（第三方旧模块）：https://github.com/tarvi-verro/weston-binder
- [S4] xkeyboard-config 2.47：https://sources.debian.org/src/xkeyboard-config/2.47-1/ （`keycodes/evdev`：`<VOL->=122 <VOL+>=123 <POWR>=124`；`symbols/inet`：`XF86AudioLowerVolume/RaiseVolume/PowerOff/MonBrightness*`）
- [S5] 同平台 qpnp_pon 键位差异示例：https://github.com/luckylca/nubiaz17_linux/blob/master/tools/desktop/keys-daemon.py ；https://github.com/Temmie-T/android-native-init-lab
- [S6] eudev keyboard builtin（EVIOCSKEYCODE 重映射）与 `udevadm hwdb --update`：https://github.com/eudev-project/eudev （`src/udev/udev-builtin-keyboard.c`、`src/udev/udevadm-hwdb.c`、`hwdb/70-touchpad.hwdb` 注释）
- [S7] weston 背光实现：`libweston/backend-drm/libbacklight.c`（sysfs 直写、DSI 要求 type=raw）与 `drm.c` 归一化（见 [S2]）
- [S8] acpid 包（Alpine main, 2.0.34-r7）：https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/acpid
- [S9] ArchWiki acpid（`event=button/volumeup`、`video/brightnessup` 示例）：https://wiki.archlinux.org/title/Acpid
- [S10] brightnessctl 包（Alpine community, 0.5.1-r8，8.8 KiB；udev 子包）：https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/brightnessctl ；用法：https://github.com/Hummer12007/brightnessctl
- [S11] （同 S10）
- [S12] Alpine 包搜索 `light`：无结果（v3.23） https://pkgs.alpinelinux.org/packages?name=light&branch=v3.23
- [S13] weston(1) 14.0.2（`--idle-time` 命令行优先、DPMS 描述）：https://manpages.debian.org/trixie/weston/weston.1.en.html
- [S14] Weston 运行中无法外部控制 DPMS（modetest 被 DRM master 阻塞）：https://community.toradex.com/t/weston-switch-on-off-display-during-runtime/21681
- [S15] DPMS off/on 后黑屏属跨平台常见失效模式（示例）：https://github.com/swaywm/wlroots/issues/2373
- [S16] Weston 无 `wlr-layer-shell`，Waybar 不可用：https://github.com/Alexays/Waybar/discussions/2791
- [S17] 本仓库：`docs/linux-ux-audit-2026-09-14.md`（设备现状、aw8697 禁用、LED 存在、weston 参数）
