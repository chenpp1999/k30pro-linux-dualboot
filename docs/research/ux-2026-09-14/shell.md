# Weston Shell / 交互模型（Shell）策略调研报告

- 调研对象：Redmi K30 Pro（lmi, SM8250）Alpine 3.23.5 + OpenRC + Weston 14.0.2（pmOS r10，pixman/DRM，DSI-1 1080×2400 scale=2）
- 触发问题：用户期望"Linux 是黑白的控制台"，当前 desktop-shell 关掉终端后仍露出桌面背景 + 面板，"像模拟器里的终端"
- 结论一句话：**Weston 是合成器，桌面背景和面板是 desktop-shell（及其 weston-desktop-shell 客户端）自己画的东西，终端只是它的一个客户端窗口**；想变成"控制台"，要么让 desktop-shell 不再画"桌面感"（纯黑背景 + 去面板，配置级），要么换 `kiosk-shell`（单应用全屏、无面板无壁纸，二进制已在设备上，概率极高）。
- 推荐：**方案 A（desktop-shell 纯黑化 + 可选的终端守护/重开）立即做；方案 B（kiosk-shell 控制台）作为可选"纯控制台模式"紧随其后；方案 C（wlroots/Sxmo/Phosh）作为 M4 以后的战略选项，不在本阶段做。**

---

## 0. 先回答"为什么关掉终端后还有图形背景"

Wayland 是 C/S 架构：`weston` 是显示服务器（合成器），任何 GUI 程序（包括 `weston-terminal`）都是连接它的客户端。

| 组件 | 角色 | 谁画的 |
|---|---|---|
| weston（合成器进程） | 管理 DRM/输入、合成所有 surface | — |
| desktop-shell（shell 插件 `desktop-shell.so`） | 窗口管理策略（最大化/移动/切换/关闭） | — |
| `weston-desktop-shell`（客户端进程） | **壁纸（background surface）+ 顶栏面板 + 锁屏对话框** | 它自己 |
| `weston-terminal` | 普通 xdg-shell 客户端 | 终端内容 |

所以：终端关掉只是"一个客户端窗口消失"，**shell 自己的壁纸 surface 和 panel surface 不会消失**。默认情况下 desktop-shell 的壁纸来自配置 `[shell] background-image`；未显式设置时，weston-desktop-shell 内置默认指向 `DATADIR/weston/background.png`（Alpine 的 weston 包确实随附 `/usr/share/weston/background.png`，[Alpine v3.23 weston 内容清单](https://pkgs.alpinelinux.org/contents?name=weston&repo=community&branch=v3.23&arch=aarch64)；ivi 版同一逻辑可见 [ivi-shell-user-interface.c 示例](https://github.com/renesas-rcar/weston/commit/68d84325d3b7ef0612f79e8280b91c4a1a6dfebc)）。设备上可用以下命令实锤：

```sh
strings /usr/libexec/weston-desktop-shell | grep -i background.png   # 看内置默认壁纸路径
```

**让"背景不再是桌面"的选项（从轻到重）**：

1. desktop-shell + `[shell] background-color=0xff000000`（纯黑，覆盖壁纸）+ `panel-position=none`（或保留瘦面板）→ 关掉终端后是黑屏/瘦黑条，而不是"桌面"；
2. 换 `kiosk-shell`：它没有壁纸客户端，只有一块 `background-color` 的纯色 surface（默认黑），无面板，天然"控制台"；
3. 换 `fullscreen-shell`/`ivi-shell`：都不适合普通终端客户端（见 §1）；
4. 用 wlroots 系合成器（sway/cage）自定义：成本最高（见 §3）。

依据链接：[weston.ini(5) 14.0.2（Debian trixie）](https://manpages.debian.org/trixie/weston/weston.ini.5.en.html)、[weston(1)](https://man.archlinux.org/man/weston.1.en)、[kiosk-shell 官方文档](https://wayland.pages.freedesktop.org/weston/toc/kiosk-shell.html)。

---

## 1. Weston 可用 Shell 全表

Weston 用"shell 插件"实现不同交互模型，可在 `weston.ini` 的 `[core] shell=` 或命令行 `--shell=` 选择（两种写法都生效；官方文档给出的写法是 `shell=kiosk-shell.so` / `--shell=kiosk-shell.so`）。
来源：[weston.ini(5) CORE 段（14.0.2 原文）](https://manpages.debian.org/trixie/weston/weston.ini.5.en.html)、[weston(1) shell 说明](https://man.archlinux.org/man/weston.1.en)、[kiosk-shell 文档](https://wayland.pages.freedesktop.org/weston/toc/kiosk-shell.html)。

| shell | 行为 | 配置方式 | Weston 14 是否发布 | Alpine 3.23 打包 | 本设备现状 |
|---|---|---|---|---|---|
| **desktop-shell** | 默认。壁纸 + 面板（时钟/启动器）+ 窗口管理 + 任务切换 | `[core] shell=desktop-shell.so`；`[shell]`、`[launcher]`、`[terminal]` 等节生效 | ✅（默认构建） | 子包 `weston-shell-desktop`（含 `desktop-shell.so`）；壁纸/辅助客户端在主包 | ✅ 已装（r10 覆盖） |
| **kiosk-shell** | 单应用/看板：所有顶层窗口强制全屏；无面板、无壁纸客户端；输出级 `app-ids=` 指派应用；支持 `[shell] background-color`（默认黑） | `[core] shell=kiosk-shell.so` 或 `--shell=kiosk-shell.so`；`--shell=kiosk-shell.so -- <应用>` 可直接拉起应用 | ✅（14.0 还新增了 kiosk 的 Xwayland 窗口按输出摆放） | **主包 `weston` 内 `/usr/lib/weston/kiosk-shell.so`**（v3.23 未拆子包；edge/16 才拆出 `weston-shell-kiosk`） | ❓ 大概率在（见下方分析），需一条 `ls` 验证 |
| **fullscreen-shell** | ⚠️ 已弃用（deprecated）。只服务使用 `zwp_fullscreen_shell_v1` 专用接口的客户端（如"在 Weston 上再跑一个 compositor"）；普通 xdg-shell 客户端不显示 | `shell=fullscreen-shell.so` | ✅（保留但弃用） | 子包 `weston-shell-fullscreen` | ❌ 未装 |
| **ivi-shell** | 车载 GENIVI：需 controller 模块（`hmi-controller.so`）+ ivi 专用客户端；普通客户端不显示 | `shell=ivi-shell.so` + `[ivi-shell]` 配置/controller | ✅ | 子包 `weston-shell-ivi`（主包含 `hmi-controller.so`） | ❌ 未装 |
| lua-shell | weston 15/16 才有的可脚本化 meta-shell，14 没有 | — | ❌ | 仅 edge（16.x） | ❌ |

要点：

- **kiosk-shell 的"背景"**：它读 `[shell] background-color` 画一块纯色 surface（无 `background-image` 支持）。默认值即黑色，所以"没有客户端时"就是黑屏，不会出现桌面壁纸。依据：[上游 commit 73aaf14e（kiosk-shell 读取 background-color，默认黑）](https://code.tokarch.uk/mainnika/weston/commit/73aaf14ebe9157baf825a02525c850606b66d202)、[weston-devel 邮件列表确认](https://lists.freedesktop.org/archives/wayland-devel/2022-October/042458.html)、[实测博客](https://blog.wincak.name/linux/missing-background-image-support-in-weston-kiosk/)。
- **Alpine 打包差异**：v3.23（=设备的 weston 14.0.2）里 `kiosk-shell.so` 在主包 `weston` 中，不分包；edge 的 weston 16 才拆成 `weston-shell-kiosk`。依据：[Alpine v3.23 weston 内容清单](https://pkgs.alpinelinux.org/contents?name=weston&repo=community&branch=v3.23&arch=aarch64)（`/usr/lib/weston/kiosk-shell.so` 属 `weston` 包）、[edge weston-shell-kiosk](https://pkgs.alpinelinux.org/package/edge/community/x86_64/weston-shell-kiosk)、[v3.23 weston-shell-fullscreen](https://pkgs.alpinelinux.org/package/v3.23/community/x86/weston-shell-fullscreen)。
- **设备用的是 D80 pmOS weston r10**：其 APKBUILD（基于 Alpine 14.0.2-r5 改造）里 `_shell="shell-desktop shell-fullscreen shell-ivi"`，**没有把 kiosk 拆出去**；而 `package()` 只把列出的 shell 移到子包，**未被移动的 `kiosk-shell.so` 留在主包 `weston` 里**。上游 meson 默认 `-Dshell-kiosk=true`，该 APKBUILD 未禁用。因此设备上很可能已经有 `/usr/lib/weston/kiosk-shell.so`。依据：[d80-weston-r10-aport/APKBUILD](https://github.com/jian45154/redmi-k30-pro-postmarketos/blob/master/notes/d80-weston-r10-aport/APKBUILD)。反例（说明"他们有些构建会禁用 kiosk"）：D114 六排键盘包显式 `-Dshell-kiosk=false`，但它只产出两个客户端二进制到 `/usr/libexec/lmi-p2-d114/`，不影响主包：[lmi-weston-sixrow/APKBUILD](https://github.com/jian45154/redmi-k30-pro-postmarketos/blob/master/files/lmi-weston-sixrow/APKBUILD)。
- **验证命令（在 Linux 内跑一次即可定论）**：
  ```sh
  ls -l /usr/lib/weston/                 # 期望看到 kiosk-shell.so desktop-shell.so 等
  apk info -L weston | grep -E '\.so$'   # 或按包清点
  ```

---

## 2. "终端优先 / 无桌面"的可行做法

### 2.1 kiosk-shell + 全屏终端 + 关闭后自动重启（respawn）

结构：

```
weston --shell=kiosk-shell.so（1 个全屏终端）
        └── 监督脚本 while :; do weston-terminal; sleep 0.3; done
```

- kiosk-shell 把终端窗口强制全屏（无标题栏/无边框），没有面板和壁纸 → 屏幕就是终端本身；
- 终端退出（`exit`、被 kill）→ 监督脚本立刻再拉起一个 → 用户永远看到"终端"，看不到"桌面"；
- weston 自己由现有 `m1-weston` 脚本的 `wait` 维持；建议把"weston 死亡→重启"也纳入循环（可选，注意 seatd/DRM 释放竞态，参考已知问题 A4）。

入口设计（触摸设备、无物理键盘）：

| 入口 | 做法 | 适用 |
|---|---|---|
| 关闭即重开（respawn） | 监督脚本循环；这是最"控制台"的形态 | kiosk（无面板时唯一入口） |
| 面板启动器 | desktop-shell `[launcher]` 图标（当前已有，live 已修） | desktop-shell 方案 A |
| 多客户端切换 | kiosk 单应用模型**没有**切换器（第二应用启动会顶掉第一应用，且切不回去）；desktop-shell 有 `mod+Tab` 切换（需键盘） | 见下 |
| 真正的"开第二个终端" | 在终端里跑 `tmux`/`screen`（一个终端多窗口），或方案 A 用面板再开一个窗口 | 两种方案 |
| 退出整个 UI | SSH 执行 `rc-service m1-weston stop`；或终端里 `touch /run/lmi-console.stop` 后退出（脚本检测到标记就不再重开）；或直接重启（M2 机制：Linux 侧 BCB 已清，重启即回 Android） | 兜底 |

注意点（都影响体验，需在 UX 文档标注）：

- kiosk 模式下 `weston-editor` 这类第二应用会把终端顶掉且无法切回 —— 应把启动列表精简为"只有终端"；
- weston-keyboard（OSK）仍然工作（input-method 客户端与 shell 插件无关），但 **weston-terminal 不声明 text-input**，OSK 不会自动弹出（M1a 已知项）；D114 已在上游打"六排键盘 + 终端 text-input"补丁，属于后续 UX 项；
- 无物理键盘时，`mod+Tab`/`mod+K` 等 desktop-shell 快捷键不可用；**weston 14 的 `weston.ini` 没有 `[keybindings]` 自定义节**（第三方 `weston-binder` 模块是外部项目），不要指望用配置加"快捷键开终端"。

### 2.2 配置/脚本草案

**方案 A 的 `weston.ini`（desktop-shell 去桌面感）**，可直接在现有 `tools/m1/m1b/etc/xdg/weston/weston.ini` 上增量修改：

```ini
[core]
# 显式声明 shell（不写也行，默认就是 desktop-shell）
shell=desktop-shell.so

[shell]
panel-position=top
panel-color=0xff000000        # 面板纯黑（隐藏"桌面工具条"感）
clock-format=none             # 去掉时钟
background-color=0xff000000   # 纯黑背景（覆盖默认 background.png 壁纸）
close-animation=none
startup-animation=none

[output]
name=DSI-1
mode=preferred
scale=2

[output]
name=Virtual-1
mode=off

[terminal]
font-size=16

[launcher]
icon=/usr/share/lmi/term-icon.png
path=/usr/bin/weston-terminal --maximized --font-size=16
```

- 若要"彻底没有面板"：把 `panel-position=top` 换成 `panel-position=none`（14.0.2 支持该值）；代价是失去触摸重开入口，需要配 §2.1 的 respawn。
- 依据：[weston.ini(5) 14.0.2 SHELL 段](https://manpages.debian.org/trixie/weston/weston.ini.5.en.html)（`panel-position` 可为 `none`、`background-color`、`clock-format=none` 均存在）；同类嵌入式做法参考 [Rockchip SDK 文档](https://github.com/mfkiwl/rk-open-docs/blob/d5530e3aabaca7ddebd98681352b4aec355d7d58/Dept3/Linux/Rockchip_Developer/Rockchip_Developer_Guide_Linux_Software_CN.md) 与 [nixos-superbird 的 weston.ini](https://github.com/JoeyEamigh/nixos-superbird)。

**方案 B 的启动脚本草案（在 `tools/m1/m1-weston.sh` 基础上改）**：

```sh
# ...（前半段 splash release / XDG_RUNTIME_DIR 不变）...
SHELL_PLUGIN="kiosk-shell.so"
[ -f /usr/lib/weston/kiosk-shell.so ] || SHELL_PLUGIN=""   # 缺失则回退 desktop-shell

weston --config=/etc/xdg/weston/weston.ini \
  --backend=drm-backend.so --drm-device=card0 \
  --renderer=pixman --socket=wayland-0 --idle-time=0 \
  --continue-without-input --debug --log=/var/log/weston.log \
  ${SHELL_PLUGIN:+--shell=$SHELL_PLUGIN} &
wpid=$!
# ...（等待 wayland-0 socket 的循环不变）...

# 控制台监督：终端退出即重开；/run/lmi-console.stop 是退出开关
while [ ! -e /run/lmi-console.stop ]; do
  WAYLAND_DISPLAY=wayland-0 weston-terminal --maximized --font-size=16
  sleep 0.3
done &

wait "$wpid"
```

- 若 kiosk-shell.so 确认缺失：从 Alpine v3.23 的 `weston` 包（14.0.2-r4，aarch64）取出同名 `.so`（同一 14.0.2 版本、ABI 一致）：
  ```sh
  cd /tmp && apk fetch --allow-untrusted weston && \
  tar -xzf weston-14.0.2-r4.apk usr/lib/weston/kiosk-shell.so && \
  install -Dm755 usr/lib/weston/kiosk-shell.so /usr/lib/weston/kiosk-shell.so
  ```
  更稳的做法是用 D80 r10 的同源 APKBUILD 重编一个 `kiosk-shell.so`（源码 patch 不影响该插件）。
- 也可用 `[autolaunch] path=/usr/sbin/lmi-console`（14 支持 `path=`/`watch=`）让 weston 自己拉起监督脚本；`watch=true` 表示"脚本退出则 weston 退出"，与"终端重开"无关，别混淆。

---

## 3. "手机化"桌面调研（M4 战略项）

目标设备约束：Alpine/musl/OpenRC（非 systemd）、内核 4.19 downstream msm、pixman（无稳定 GPU 加速）、rootfs 1.4 GB 已用 323 MB（剩余 ≈1.0 GB）、无 modem/GPS/加速度计/蓝牙/音频。以下依赖/体积为估算，落地前应在设备上 `apk add --simulate` 实测。

### 3.1 Sxmo（重点评估）

- **定位**：为 Linux 手机设计的极简手势 UI，Wayland 用 sway、Xorg 用 dwm；官方支持 postmarketOS/Alpine；会话由 `tinydm` 拉起，用户服务由 `superd` 管理（OpenRC 下工作，pmOS 官方明确 Sxmo 留在 OpenRC）。来源：[Sxmo 手册](https://sxmo.org/docs/user/sxmo.7.html)、[Sxmo INSTALLGUIDE](https://man.sr.ht/~anjan/sxmo-docs-stable/INSTALLGUIDE.md)、[pmOS 系统化 systemd 公告（Sxmo 保持 OpenRC）](https://postmarketos.org/blog/2024/03/05/adding-systemd/)。
- **Alpine 3.23 已有包**（aarch64/community）：`sxmo-utils 1.18.1-r2`、`sxmo-utils-sway`、`sxmo-utils-wayland`、`sxmo-utils-common`、`sxmobar`、`sxmo-dwm`、`lisgd`、`wvkbd 0.17`、`tinydm 1.3.0`、`superd`、`sway 1.11-r2`、`wlroots 0.19.2`、`foot 1.25.0`、`cage 0.2.1`。
  - **关键好消息**：`sxmo-utils-sway` 依赖的是 **seatd**（不是 elogind），与设备现有 seatd 会话模型完全一致，`tinydm` 也有 `tinydm-openrc`。来源：[sxmo-utils-sway](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-sway)、[sxmo-utils-wayland](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-wayland)、[tinydm](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/tinydm)、[sway](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sway)。
  - **坏消息（体积）**：任何 `sxmo-utils-*` 变体都会拖入 `sxmo-utils-common`，其依赖 43 个包，含 `modemmanager`、`geoclue`、`mmsd-tng`、`mpv`、`yt-dlp`（→ python3）、`vim`、`conky`、`iio-sensor-proxy`、`upower`、`polkit`、`dnsmasq`、`pulseaudio-utils` 等。粗估 300–600 MB；其中 modem/GPS/音频在本设备无用。来源：[sxmo-utils-common 依赖表](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-common)。
  - **替代**：不装 Sxmo meta，只手搓"迷你 sway 手机壳"：`sway + foot + wvkbd + lisgd + bemenu + sxmobar/waybar + swayidle + wob + wl-clipboard + grim/slurp`（估计新增 <50 MB，因为 libinput/libxkbcommon/mesa 等已存在）。
- **设备适配风险**：
  1. wlroots 0.19 只支持 atomic DRM（无 legacy 回退）；Weston 在 msm 4.19 上能跑不代表 atomic 路径一定可用 —— **这是最大未知数**，建议先用 `cage`/`sway` 做 RAM 启动冒烟测试；
  2. msm 驱动 IN_FORMATS 重复项曾让 libweston 断言崩溃（本项目打过补丁）；wlroots 若报类似错误，可试 `WLR_DRM_NO_MODIFIERS=1`；
  3. 渲染用 `WLR_RENDERER=pixman`（与 Weston 现状一致，性能可接受；1080×2400 约 2.6 MP）；
  4. 无 modem/GPS/震动（硬件坏）→ Sxmo 的通话/短信菜单无用，但终端/手势/电源管理仍可用；
  5. `superd` 用户服务在 OpenRC 下的行为需实测（Sxmo 官方支持 pmOS/OpenRC，但对"非 pmOS 的 Alpine"没有背书）。
- **移植成本**：中（1–2 天装包 + 3–5 天适配输入/显示/会话与验收）；前提是 atomic 路径可用。

### 3.2 Phosh

- **Alpine 3.23 有包**：`phosh 0.51.0-r2` + `phoc 0.51.0`（wlroots 系 phone compositor），并有 `phosh-systemd` 子包（说明非 systemd 场景也在支持）。来源：[phosh](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/phosh)、[phoc](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/phoc)。
- **依赖重量**：phosh 直接依赖 56 项，含 `gnome-session`、`gnome-settings-daemon`、`gnome-control-center`、`gnome-keyring`、`evolution-data-server`、`evince-libs`、`gtk+3.0`、`gtk4.0`、`libadwaita`、`libhandy1`、`libelogind`、`polkit`、`upower`、`feedbackd`、`callaudiod`、`squeekboard`、`libnm`/`libmm-glib`、pulse 库等；phoc 还需要 `mesa-egl/gles`、`vulkan-loader`、`libdisplay-info`。粗估 **500 MB–1 GB**，且需要 D-Bus 会话、登录管理器（Alpine 有 `greetd-phrog`）、`elogind`。
- **与现状的冲突**：设备用 **seatd** 管会话，而 phosh 硬依赖 `libelogind`（Alpine 明确不建议 seatd 与 elogind 并存做 seat 管理）；GNOME 系组件在 OpenRC 下需要大量 polyfill（pmOS 有 `postmarketos-ui-phosh-openrc` + greetd，但那套依赖 pmOS 基座）。来源：[pmOS phosh-openrc](https://pkgs.postmarketos.org/package/main/postmarketos/x86_64/postmarketos-ui-phosh-openrc)。
- **结论**：技术上"能装"，但**投入产出比差**：对"服务器 + 偶尔 GUI + 控制台审美"的目标，Phosh 是最不划算的选项；不建议现阶段做。

### 3.3 Plasma Mobile

- Alpine 3.23 有 `plasma-mobile-meta 6.5.6`，依赖 `elogind`、`polkit-elogind`、`plasma-mobile`、`powerdevil`、`pipewire`、`pulseaudio`、`networkmanager`、`modemmanager`、`tinydm`、KDE/Plasma 全套。来源：[plasma-mobile-meta](https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/plasma-mobile-meta)。
- 体积粗估 1–2 GB（>剩余空间），KWin 需要 GL；本设备 kernel/GPU 适配成本最高。**不可行**。

### 3.4 sway + waybar（自组）

- 轻、包全（见 3.1 依赖表）；没有 Sxmo 的成套手机交互（手势菜单、锁屏、按键逻辑），但可作为"手机化"最小骨架。
- 风险与 Sxmo 相同（wlroots atomic / modifiers / pixman），成本 2–4 天。

---

## 4. 推荐策略（三案对比）

| 维度 | **A. desktop-shell 黑化（推荐先做）** | **B. kiosk 控制台模式（可选，随后）** | **C. 迁移 wlroots 栈（M4 评估）** |
|---|---|---|---|
| 用户体验 | 全屏终端；关闭后是黑屏 + 瘦黑面板（或全黑），点面板图标重开；可开多个终端窗口（触摸点选） | 永远一个全屏终端；关闭即自动重开；**无面板、无桌面**；单应用，不能同时开两个 | 手势手机 UI（Sxmo/自组 sway）或 Phosh 系桌面 |
| 实现 | 只改 `weston.ini`（+ 可选守护脚本）：`background-color=0xff000000`、`panel-color`、`clock-format=none`、（可选）`panel-position=none` | 加 `--shell=kiosk-shell.so` + 监督循环；验证 `kiosk-shell.so` 存在（大概率已有，兜底可从 v3.23 主包提取/同源重编） | 装 sway/cage/sxmo 包，写会话/手势/输入配置，替换或并存 m1-weston 服务 |
| 工作量 | ~0.5 天（配置 + 重建 overlay + 验收） | +0.5 天（脚本 + 真机验证 kiosk） | +2–5 天（Sxmo 或迷你 sway）；Phosh 1–2 周 |
| 风险 | 极低；纯配置，回滚 = 恢复 `.orig`；唯一注意：A4 的 weston 重启竞态先修 | 低-中：kiosk-shell.so 缺失时 weston 起不来 → 黑屏（SSH 可救）；单应用模型限制"偶尔 GUI" | 中-高：wlroots atomic/IN_FORMATS/性能/无 GPU 加速；Sxmo meta 体积大；Phosh 依赖 elogind+D-Bus+GNOME |
| 与 M2 切换/持久化 | 完全兼容：只动 rootfs 内文件；随 overlay v3/rootfs 重建生效；不影响 BCB/recovery/boot | 同上 | 同上；建议并存为第二服务（`/etc/conf.d` 选 MODE），不动已验收的 Weston 路径 |
| 验证方法 | 方法 A RAM 启动 + `weston-screenshooter` 截图 + `utouch` 注入点面板图标 + SSH；再走 3 轮持久化 | 同上；额外确认 kiosk 下关闭终端自动重开、无面板/无壁纸 | 冒烟：`cage`/`sway` 能否点亮 DSI（截图）、触摸/OSK、一小时后稳定性；不行就放弃 |

**推荐**：

1. **先做 A**：它用最小代价直接消除用户抱怨的"桌面感"，且保留 panel 图标作为触摸重开入口（用户"关掉重开"的直觉得到满足）。建议保留瘦面板（纯黑、无时钟），不要一上来 `panel-position=none`。
2. **B 作为 A 的"纯控制台"开关**：如果用户明确说"连面板都不要/就要黑屏终端"，就切 B。做成 `/etc/conf.d/m1-weston` 里的 `SHELL_MODE=desktop|kiosk`，两个模式共用同一 `weston.ini`，可随时切回。
3. **C 只立项调研，不在 M2 收尾期动手**：先花 1 小时用 `cage` 做 wlroots 冒烟测试（RAM 启动、不动持久化），确认 atomic 可用再谈 Sxmo；Phosh/Plasma Mobile 明确不建议。

---

## 5. 最小实施步骤（建议按此执行）

> 前置：先把 `docs/linux-ux-audit-2026-09-14.md` §0 的 live 修复（weston.ini launcher/图标、A4 重启竞态）收进仓库，一次重建一并生效。

### 阶段 0：设备侧取证（5 分钟，SSH）

```sh
ls -l /usr/lib/weston/                      # 确认 kiosk-shell.so 是否存在
strings /usr/libexec/weston-desktop-shell | grep -i background   # 看默认壁纸/背景来源
cat /etc/xdg/weston/weston.ini              # 确认当前配置（含 launcher 修复）
```

### 阶段 1：方案 A（配置级，仓库改动）

1. `tools/m1/m1b/etc/xdg/weston/weston.ini`：
   - 新增 `[core] shell=desktop-shell.so`（显式化）；
   - `[shell]` 增 `background-color=0xff000000`、`panel-color=0xff000000`、`clock-format=none`、`close-animation=none`、`startup-animation=none`；
   - 保留 `[launcher]` 终端图标（触摸重开入口）；`[terminal] font-size=16` 不变。
2. （可选）`tools/m1/m1b/usr/sbin/lmi-console`：respawn 监督脚本 + `/run/lmi-console.stop` 开关；`m1-weston.sh` 里用它替代直接 `weston-terminal`。默认**不启用**自动重开（保留面板图标即可），需要时再开。
3. 重建 + 部署：
   - 方法 A RAM 启动（`fastboot boot`，零写入）验证：
     - `XDG_RUNTIME_DIR=/run/lmi-weston weston-screenshooter` 截图 → 背景应为纯黑、面板纯黑无时钟、终端最大化；
     - `utouch` 注入点击面板左上图标 → 新终端出现；
     - 终端 `exit` → 屏幕为黑 + 面板（不再是壁纸桌面）。
   - 通过后按 `docs/m1b-persistent.md` 的流程重建 overlay v3 / rootfs（v8 或 patch-rootfs-image 修补），先方法 A 再落 super。
4. 验收：3 轮持久化（boot 计数）+ M2 一次往返切换（Android→Linux→Android）+ 截图归档 `docs/acceptance/`。

### 阶段 2：方案 B（可选开关）

1. 若阶段 0 显示 `kiosk-shell.so` 不存在，先从 Alpine v3.23 主包提取（见 §2.2）或按 D80 r10 APKBUILD 重编，再入 rootfs。
2. `m1-weston.sh` 加 `--shell=kiosk-shell.so` + 监督循环；`/etc/conf.d/m1-weston` 加 `SHELL_MODE`；`kiosk` 模式下不要启动 `weston-editor`。
3. 验证：kiosk 下终端始终全屏；`exit` 后 0.3 s 内自动重开；屏幕无面板无壁纸；SSH / `touch /run/lmi-console.stop` 可退出循环。

### 阶段 3（M4 立项，不在本期）

- 1 小时冒烟：装 `cage`（或 `sway`）+ `WLR_RENDERER=pixman` RAM 启动，确认 DSI 点亮 + `WLR_DRM_NO_MODIFIERS=1` 是否必要；
- 通过则评估"迷你 sway 手机壳"或 Sxmo（重点核对 `apk add --simulate` 体积与 atomic）；Phosh/Plasma Mobile 不做。

---

## 6. 来源链接汇总

- Weston shell 行为/配置：<https://man.archlinux.org/man/weston.1.en>、<https://manpages.debian.org/trixie/weston/weston.ini.5.en.html>（14.0.2 原文，`[core] shell=`、`background-color`、`panel-position=none`）、<https://wayland.pages.freedesktop.org/weston/toc/kiosk-shell.html>、<https://man.archlinux.org/man/weston-bindings.7.en>
- Weston 14 发布说明（kiosk/Xwayland）：<https://www.collabora.com/news-and-blog/news-and-events/weston-14-release-new-drm-backend.html>、<https://www.phoronix.com/news/Wayland-Weston-14.0>
- kiosk 背景色/默认黑：<https://code.tokarch.uk/mainnika/weston/commit/73aaf14ebe9157baf825a02525c850606b66d202>、<https://lists.freedesktop.org/archives/wayland-devel/2022-October/042458.html>、<https://blog.wincak.name/linux/missing-background-image-support-in-weston-kiosk/>
- Alpine 打包：<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/weston>、<https://pkgs.alpinelinux.org/contents?name=weston&repo=community&branch=v3.23&arch=aarch64>、<https://pkgs.alpinelinux.org/package/v3.23/community/x86/weston-shell-fullscreen>、<https://pkgs.alpinelinux.org/package/edge/community/x86_64/weston-shell-kiosk>
- 设备 weston 来源（D80 pmOS r10 / 六排键盘变体）：<https://github.com/jian45154/redmi-k30-pro-postmarketos/blob/master/notes/d80-weston-r10-aport/APKBUILD>、<https://github.com/jian45154/redmi-k30-pro-postmarketos/blob/master/files/lmi-weston-sixrow/APKBUILD>
- Sxmo：<https://sxmo.org/docs/user/sxmo.7.html>、<https://man.sr.ht/~anjan/sxmo-docs-stable/INSTALLGUIDE.md>、<https://postmarketos.org/blog/2024/03/05/adding-systemd/>
- Sxmo on Alpine 包：<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-sway>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-wayland>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sxmo-utils-common>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/tinydm>
- wlroots 栈：<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/sway>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/wlroots>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/foot>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/cage>、<https://pkgs.alpinelinux.org/packages?name=wvkbd*&branch=v3.23&repo=community&arch=aarch64>
- Phosh：<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/phosh>、<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/phoc>、<https://pkgs.postmarketos.org/package/main/postmarketos/x86_64/postmarketos-ui-phosh-openrc>
- Plasma Mobile：<https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/plasma-mobile-meta>
- 仓库内部依据：`docs/linux-ux-audit-2026-09-14.md`、`tools/m1/m1-weston.sh`、`tools/m1/m1b/etc/xdg/weston/weston.ini`、`docs/m1a-ramboot.md`

---

## 7. 风险与未决问题

1. **kiosk-shell.so 是否在设备上**：推断为"在"（r10 APKBUILD 未禁用且未拆包），但必须用 §5 阶段 0 验证；缺失时的兜底（提取/重编）会引入 ABI 验证成本。
2. **weston 重启竞态（A4）**：改 `m1-weston`/init 前先修 stop 语义（杀进程组 + trap），否则切 shell 模式时可能黑屏且 SSH 之外无恢复手段。
3. **单应用限制**：kiosk 模式无法"同时开两个终端"，也无法跑第二次要 GUI；如用户"偶尔 GUI"的需求强，A 更合适。
4. **OSK 限制**：weston-terminal 不声明 text-input（M1a 已知），控制台模式不会弹出虚拟键盘；D114 的六排键盘/终端补丁是独立工作项。
5. **wlroots 未知数**：msm 4.19 的 atomic 支持与 IN_FORMATS 兼容性需实机冒烟（`cage` 1 小时测试）后才能给 C 方案定级。
6. **体积**：Sxmo 完整依赖闭包可能吃掉剩余 1 GB 的相当一部分（估算 300–600 MB），需 `apk add --simulate` 复核后再决定。
7. **持久化路径**：所有方案都只改 rootfs 内文件，务必按既有流程（overlay v3 / rootfs 重建、先 RAM 后 super、3 轮持久化）落地，避免"live 修改又没回仓"的重复劳动（audit §5）。
