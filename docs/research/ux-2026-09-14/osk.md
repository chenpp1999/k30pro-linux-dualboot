# Weston 14 屏幕键盘（OSK）改良/替换方案调研

> 目标设备：Redmi K30 Pro（lmi），Alpine 3.23.5 + OpenRC + Weston 14.0.2（drm/pixman，DSI 1080x2400，scale=2），musl aarch64，rootfs 内无编译器。
> 调研日期：2026-09-14。方法：上游源码核查（weston 14.0.2/15.0.0/16.0.0 逐文件比对）+ Alpine aports/APKINDEX 体积核算 + 替代 OSK 源码/文档核查；未连接设备。

---

## 0. 结论速览（TL;DR）

1. **weston-keyboard 的布局/键位是编译期内置数据，weston.ini、环境变量、命令行都无法改变**（只有 `[input-method] path=`/`overlay-keyboard=` 两个开关）。上游 keyboard.c 从 14.0.2 到 16.0.0 **一字未改**（三份文件 SHA256 相同），短期不要指望上游修复。
2. **不存在 "phone 布局"**：上游只有 `normal`(12×4，即手机上的 qwerty)、`numeric`(12×2)、`arabic`(13×4) 三套。设备二进制里出现的 `_ [ ] # $ % & { } Base -->` **全部来自阿拉伯布局的数据**；`-->`/`Base` 不是翻页键，而是阿拉伯布局的退格/切层标签。因此"数据里有但点不到"是事实——正常布局里根本没有 `_` `#` `$` `%` `&` `[` `]` `{` `}`。
3. 实测缺键的准确情况（源码核对）：**Tab 和方向键其实存在**（`->|`、`/\`、`<`、`>`、`\/`，只是用 ASCII 字符画的不好认）；**真正缺的是 Ctrl 和 Esc**，以及 `_ # $ % &` 等符号；`?123` 状态下 `,` 变成 `\`、`.` 变成 `|`（`clients/keyboard.c:136-137,140`）。
4. **只替换 weston-keyboard 这一个二进制完全可行、零 ABI 风险**：它是 compositor 通过 `[input-method] path=` 启动的独立客户端，与 libweston 无链接关系；用同版本（14.0.2）源码构建即可。且有"重编客户端到 /usr/local + weston.ini 改路径"的免动原包的部署方式。
5. **squeekboard / wvkbd / maliit / stevia 在 Weston 14 上都不能用**：它们依赖 `zwp_virtual_keyboard_manager_v1`、`input-method-v2`、`wlr-layer-shell-v1`，Weston 14（乃至 16）一个都没实现（源码核查 + wayland.app 支持表）。
6. **一个被忽略的硬事实**：Weston 的 OSK 只能给绑定 `text-input-unstable-v1` 的客户端输入（`frontend/text-backend.c:595-610`），而 rootfs 里的 **weston-terminal 不支持 text-input**（toytoolkit `clients/window.c` 中 text_input/input_method 出现次数为 0）。因此**即使把布局改得再好，OSK 也打不进终端**——终端场景必须走 uinput 注入（自研小工具），或改 compositor 让 OSK 常显。这决定了推荐路线是两段式的。

---

## 1. weston 14 keyboard.c 结构与配置能力

### 1.1 架构

- OSK 是 `/usr/libexec/weston-keyboard`（Alpine `weston` 主包内；`weston-clients` 只收 `/usr/bin/weston-*`），由 compositor 在启动时按 `[input-method] path=` 拉起（`frontend/main.c:512-567 wet_client_start`，`frontend/text-backend.c:997-1023`）。
- 客户端绑定两个私有/不稳定协议：`zwp_input_method_v1` + `zwp_input_panel_v1`（同属 wayland-protocols 的 `input-method-unstable-v1`），compositor 侧实现在 `frontend/text-backend.c` 与 `desktop-shell/input-panel.c`。
- 输入链路：OSK 渲染按键 → `zwp_input_method_context_v1_commit_string/keysym` → compositor 只转发给当前聚焦的 **text-input-v1 客户端**（`text-backend.c:595-610` 的 keysym 也是发给 text-input 客户端，不走 wl_keyboard）。**这就是终端打不进字的根因。**
- OSK 可见性：桌面 shell 仅在收到 text-input 的 show 信号时才把 input-panel surface 加入图层（`desktop-shell/input-panel.c:84-149,204-206`）；没有 text-input 客户端时 OSK 不显示（overlay 模式亦然）。
- 崩溃自恢复：IM 进程 10 秒内死 5 次以内会自动重拉（`text-backend.c:957-980`）。

### 1.2 三套布局逐键（`clients/keyboard.c`，行号为上游 14.0.2）

| 布局 | 定义行 | 尺寸 | 内容 |
|---|---|---|---|
| normal（手机上就是它） | 103-147 | 12 列 × 4 行 = 48 格 | 行1 `q w e r t y u i o p <--`；行2 `->\| a s d f g h j k l Enter`；行3 `ABC z x c v b n m , . ABC`；行4 `?123 Space /\ < > \/ [style]`（含方向键与 Tab，标签是 ASCII 画法） |
| numeric（content_purpose=数字时） | 149-169 | 12×2 | 数字 1-0、退格、Space、Enter、方向键、style |
| arabic（客户端语言=ar 时） | 171-217 | 13×4 | 阿拉伯字母；切层键标签 `Shift/Base`；**唯一含 `_ [ ] # $ % & { }` 的布局** |

每个键是 `{key_type, label, uppercase, symbol, width}` 五元组，三个字符串对应三种状态显示：

- `KEYBOARD_STATE_DEFAULT` → `label`（小写 q…）
- `KEYBOARD_STATE_UPPERCASE` → `uppercase`（大写 Q…；符号键此时仍是字母的大写形式）
- `KEYBOARD_STATE_SYMBOLS` → `symbol`（q…p 变 1…0；a…l 变 `- @ * ^ : ; ( ) ~`；z…m 变 `/ ' " + = ? !`；`,`→`\`；`.`→`|`）

normal 布局逐键三态对照（`keyboard.c:103-147`）：

| 键（DEFAULT） | UPPERCASE | SYMBOLS | 键（DEFAULT） | UPPERCASE | SYMBOLS |
|---|---|---|---|---|---|
| q | Q | 1 | a | A | - |
| w | W | 2 | s | S | @ |
| e | E | 3 | d | D | * |
| r | R | 4 | f | F | ^ |
| t | T | 5 | g | G | : |
| y | Y | 6 | h | H | ; |
| u | U | 7 | j | J | ( |
| i | I | 8 | k | K | ) |
| o | O | 9 | l | L | ~ |
| p | P | 0 | z | Z | / |
| m | M | ! | x | X | ' |
| n | N | ? | c | C | " |
| b | B | = | v | V | + |
| , | , | \ | Space | （空格） | （空格） |
| . | . | &#124; | ?123 | ?123 | abc |
| ABC（×3 个） | abc | ABC | Enter/Tab/箭头/退格 | 同左 | 同左 |

> 由此可读出用户抱怨的根源：DEFAULT 层没有 `_ / - @`（要先进 `?123`），`?123` 层里 `.`/`,` 被换掉且 `_ # $ % &` 根本不存在；`- @ /` 其实藏在 `?123` 的字母位置（a/s/z）。

### 1.3 `?123` / `ABC` / `Base` 的"分页"真相（`keyboard.c:261-265,592-621`）

- 状态机只有 3 个状态，**没有翻页**：
  - `ABC` 键（keytype_switch）：DEFAULT↔UPPERCASE；
  - `?123` 键（keytype_symbols）：DEFAULT/UPPERCASE→SYMBOLS，再按回 DEFAULT（SYMBOLS 态下该键显示其 `symbol`，正常布局里就是 "abc"，见 :140）；
  - numeric 布局没有 `?123`/`ABC`。
- `-->`（阿拉伯布局退格标签，RTL 方向）、`->|`（Tab）、`Base`（阿拉伯布局切层标签）都**不是分页**。这正是为什么用户"找不到 `_` 和 `.`"：正常布局 `?123` 里 `.` 被画成 `|`、`,` 被画成 `\`，而 `_ # $ % &` 全库只存在于用户根本触发不到的 arabic 布局。

### 1.4 配置能力结论（无布局配置）

| 配置项 | 作用 | 能否改键位 |
|---|---|---|
| `[input-method] path=` | 换 OSK 程序；**支持空格分隔的 `ENV=x 程序 --arg`**（`man/weston.ini.man:669-675`；14.0 已支持） | 只能整包替换 |
| `[input-method] overlay-keyboard=true` | overlay 模式（光标旁弹出），compositor 给子进程设 `WESTON_KEYBOARD_SURFACE_TYPE=overlay` | 否 |
| `[keyboard] keymap_*` | 只作用于物理键盘的 xkb 映射，**不作用于 OSK** | 否 |
| 环境变量/命令行 | 客户端只认 `WESTON_KEYBOARD_SURFACE_TYPE`（`keyboard.c:978-990`） | 否 |
| `[keybindings]` | **weston.ini 没有这个 section**；键绑定是硬编码列表（`man/weston-bindings.man`），不能绑"执行命令" | 否 |

### 1.5 尺寸疑点（强烈建议截图核实）

normal 布局固有宽 = 12 × `key_width(60)` = **720 逻辑像素**，而 scale=2 时屏幕逻辑宽只有 540。OSK 又没有自己设置 buffer scale/尺寸适配，因此**很可能左右各被裁掉约 1.5 列**（右侧 `.` 半可见、最右 `ABC` 不可见；左侧首列被裁）。这与"找不到 `.`"的体感一致。验证：`weston-screenshooter` 截图 + 数像素；若确认裁边，补丁里把 `key_width` 60→45 即可正好 540（可再把标签字号 16→14，`keyboard.c:258-259,381`）。

---

## 2. 源码级修改与构建

### 2.1 只替换 weston-keyboard 二进制的可行性：**可行，低风险**

- `weston-keyboard` 是独立可执行文件，安装于 `libexecdir`（`clients/meson.build:364-381`），由 compositor fork/exec，**不与 libweston 静态/动态链接**，没有 ABI 问题；只要协议接口版本一致（都用 14.0.2 源码构建即可）。
- 替换后的进程崩溃会被 compositor 自动重拉（上限 5 次/10s）。
- 部署方式（推荐，不动原包、可秒回滚）：
  1. 编译产物拷到 `/usr/local/libexec/weston-keyboard-lmi`；
  2. `/etc/xdg/weston/weston.ini` 写 `[input-method] path=/usr/local/libexec/weston-keyboard-lmi`（或叠加 `WESTON_KEYBOARD_SURFACE_TYPE=overlay`）；
  3. 原 `/usr/libexec/weston-keyboard` 保持不动，回滚 = 删掉 path 行。
- 注意：若整包 `apk upgrade weston` 跨大版本，需按新版本重建该客户端（协议/行为可能漂移）。

### 2.2 Alpine 3.23 构建步骤（aarch64 原生；可在设备内，也可在宿主 proot/chroot 的 Alpine 里做）

```sh
# 1) 依赖（v3.23 aarch64 APKINDEX 实测安装体积）
apk add --no-cache build-base meson samurai pkgconf linux-headers \
  wayland-dev wayland-protocols libxkbcommon-dev pixman-dev libinput-dev \
  libevdev-dev libdrm-dev eudev-dev cairo-dev libpng-dev
# 约 209 MB：build-base≈167（gcc 140 + musl-dev 11.6 + binutils 14.9 + make/patch）、
# python3 26.7、meson 4.0、linux-headers 6.0、其余 dev 头 ≈4.5

# 2) 取源并校验（sha256 来自 Alpine APKBUILD）
cd /tmp && curl -LO https://gitlab.freedesktop.org/wayland/weston/-/releases/14.0.2/downloads/weston-14.0.2.tar.xz
echo "e8214ec893e6c3ae94eb3c92feba104b0201843e9143f726a3e9a4d396d02523c94da706c1348cf934bc339fb1a4bc1fecdb865f0ea914115fd346d9eda091f5  weston-14.0.2.tar.xz" | sha256sum -c
tar xf weston-14.0.2.tar.xz && cd weston-14.0.2

# 3) 打布局补丁（见 §2.3），然后最小配置（关掉一切与客户端无关的选项）
patch -p1 </path/to/lmi-keyboard.patch
meson setup build \
  -Dbackend-default=headless -Dbackend-headless=true \
  -Dbackend-drm=false -Dbackend-rdp=false -Dbackend-vnc=false \
  -Dbackend-wayland=false -Dbackend-x11=false -Dbackend-pipewire=false \
  -Drenderer-gl=false -Dxwayland=false -Dsystemd=false -Dtests=false \
  -Dremoting=false -Dpipewire=false -Dshell-fullscreen=false \
  -Dshell-ivi=false -Dshell-kiosk=false -Dcolor-management-lcms=false \
  -Dimage-jpeg=false -Dimage-webp=false -Dscreenshare=false \
  -Ddemo-clients=false -Dsimple-clients=
ninja -C build weston-keyboard     # 只编这一个目标
install -Dm755 build/clients/weston-keyboard /usr/local/libexec/weston-keyboard-lmi
# 完事 apk del 上述 dev 包，重建后只留 ~100 KB 的二进制
```

要点/踩坑：
- `-Ddemo-clients=false` 必须：demo 里 `subsurfaces` 需要 EGL（`clients/meson.build:328-331,342-362`）；`-Dsimple-clients=` 必须为空：`simple-egl` 等声明了 `options: ['renderer-gl']`，不关会直接报错（:88,110,150,185-191）。若空值解析异常，可退而 `-Dsimple-clients=damage`。
- meson ≥0.63（v3.23 自带 1.9.1 ✓）；`wayland-scanner` 由 `wayland-dev` 提供（若缺则补 `wayland` 包）；Alpine 的 `ninja` 命令由 `samurai`（67 KB）提供，`meson setup` 前 `apk add samurai` 或确认已有；没有 `.git` 时 `vcs_tag` 回退版本号，若报缺 git 就 `apk add git` 或按 APKBUILD 手法 `git init -q .`。
- 宿主构建（推荐，rootfs 免污染）：项目已有 Termux+proot Debian 流程，可再开一个 **Alpine aarch64 minirootfs + proot**（同架构原生跑 apk/gcc），产物与设备内构建应逐字节一致；之后用既有 `tools/m1/patch-rootfs-image.sh --put` 或 overlay tar（`tools/m1/mk-overlay.py`）入镜像。
- 设备内构建存储账：rootfs 1.4 G（已用 323 M）装依赖约 209 M + 源码/构建产物约 60-80 M，峰值 <1.0 G 可用空间，可行但要记得 `apk del`。

### 2.3 建议补丁（"最短路径先改哪几个键位"）

**方案 B-min（2 处字符串替换，风险最低，不加键）**：把 `?123` 层缺失的两个常用符号先补上：

```c
// keyboard.c:125  { keytype_default, "l", "L", "~", 1},   →  symbol "~" 改 "_"
// keyboard.c:136  { keytype_default, ",", ",", "\\", 1},  →  symbol "\\" 改 "."
```
副作用：`?123` 层失去 `~` 与 `\`（终端里 `~` 是家目录、`\` 偶用，属真实损失）。

**方案 B（推荐，新增第 5 行；不牺牲任何现有符号）**：

```c
// 1) enum key_type 末尾新增（keyboard.c:67-80）
keytype_escape, keytype_control

// 2) struct keyboard 增 bool ctrl_active; struct virtual_keyboard.keysym 增 ctrl_mask
// 3) 按下 Ctrl 键时切换 ctrl_active；Enter/Tab/方向键发送时并入 Ctrl 掩码：
//    mod_mask |= keyboard->ctrl_active ? ctrl_mask : 0;   // XKB_KEY_Escape 同理
// 4) input_method_activate() 里取掩码（keyboard.c:898-904 已有同类代码）：
//    keyboard->keyboard->keysym.ctrl_mask = keysym_modifiers_get_mask(&modifiers_map, "Control");
// 5) normal_keys 末尾追加 12 键（宽 1），normal_layout.rows: 4 → 5（keyboard.c:224）：
{ keytype_escape,  "Esc",  "Esc",  "Esc", 1 },
{ keytype_control, "Ctrl", "Ctrl", "Ctrl", 1 },
{ keytype_default, "_", "_", "_", 1 }, { keytype_default, "-", "-", "-", 1 },
{ keytype_default, "/", "/", "/", 1 }, { keytype_default, "@", "@", "@", 1 },
{ keytype_default, ".", ".", ".", 1 }, { keytype_default, ",", ",", ",", 1 },
{ keytype_default, "#", "#", "#", 1 }, { keytype_default, "$", "$", "$", 1 },
{ keytype_default, "&", "&", "&", 1 }, { keytype_default, "|", "|", "|", 1 },
// 新行三字段相同 → 三种状态（含 ?123）下都常显，`_ . , / - @` 一步可达。
```
- 新行宽 12 单位、行高 50 → OSK 高度 250 逻辑像素；再加 `key_width 60→45`（若截图确认裁边）则宽度正好 540。
- 想更全可把 `~ * [ ] { }` 放第 6 行（rows=6，高 300），但会挤占屏幕，建议先上 5 行。
- 需要强调：**Esc/Ctrl 通过 input-method 发给的仍然只是 text-input 客户端**（编辑器类）；对终端无效（见 §1.1）。终端需求见 §4/§5。

补丁核心代码骨架（相对 14.0.2 的增量，供实现参考）：

```c
/* 1) 新键类型 */
enum key_type { /* ... 原枚举 ... */ keytype_style, keytype_escape, keytype_control };

/* 2) 需要保存 Ctrl 掩码与开关状态 */
struct virtual_keyboard { /* ... */ struct { xkb_mod_mask_t shift_mask, ctrl_mask; } keysym; /* ... */ };
struct keyboard { /* ... */ bool ctrl_active; };

/* 3) 状态无关的按键处理（keyboard_handle_key 内新增两个 case） */
case keytype_escape:
        virtual_keyboard_commit_preedit(keyboard->keyboard);
        zwp_input_method_context_v1_keysym(keyboard->keyboard->context,
                display_get_serial(keyboard->keyboard->display), time,
                XKB_KEY_Escape, key_state,
                mod_mask | (keyboard->ctrl_active ? keyboard->keyboard->keysym.ctrl_mask : 0));
        break;
case keytype_control:
        if (state == WL_POINTER_BUTTON_STATE_PRESSED)
                keyboard->ctrl_active = !keyboard->ctrl_active;   /* 粘滞 Ctrl */
        break;

/* 4) 已有 Enter/Tab/方向键的调用里把 ctrl 掩码并进去（共 6 处） */
xkb_mod_mask_t mod_mask = /* ... 原 shift 逻辑 ... */;
if (keyboard->ctrl_active) mod_mask |= keyboard->keyboard->keysym.ctrl_mask;

/* 5) 激活时取掩码（input_method_activate，紧随 shift_mask 一行后） */
keyboard->keyboard->keysym.ctrl_mask =
        keysym_modifiers_get_mask(&modifiers_map, "Control");

/* 6) 布局常量 */
static const struct layout normal_layout = { normal_keys, /* count 自动 */ 12, 5, "en", ... };
static const double key_width = 45;   /* 12*45 = 540 = scale=2 下的屏宽；待截图确认后启用 */
```

---

### 2.4 与仓库/镜像流程集成（建议）

1. 新增 `tools/m1/weston-keyboard-lmi/`：`lmi-keyboard.patch` + `build-keyboard.sh`（§2.2 的可复现脚本，固定 tar 包 sha256）+ `README`（记录构建环境与产物哈希）。
2. 产物入库方式二选一：
   - 小体积直接进 `tools/m1/m1b/usr/local/libexec/`（overlay 树），随下次镜像重建（v8 / overlay v3）；
   - 或单文件用 `tools/m1/patch-rootfs-image.sh --put weston-keyboard-lmi:/usr/local/libexec/weston-keyboard-lmi:0755` 离线注入。
3. `weston.ini` 片段的回收：审计 §0 提到 live 修改尚未入仓，本次一并把 `[input-method] path=` 写回 `tools/m1/m1b/etc/xdg/weston/weston.ini`。
4. 验收脚本建议加入：部署后 sha256 比对、`weston-editor` 打字截图、`lmi-key` 终端注入用例（§7）。

## 3. 替代 OSK 可行性结论（明确"能用/不能用"）

Weston 14 的协议清单（源码核查：`protocol/meson.build`、`frontend/text-backend.c`、全树 grep）：
**只有** `zwp_text_input_v1` + `zwp_input_method_v1` + `zwp_input_panel_v1`；**没有** `text-input-v3`、`input-method-v2`、`zwp_virtual_keyboard_manager_v1`、`wlr-layer-shell-v1`。16.0.0 复核不变（text-backend.c 中 `input_method_v2` 计数 0）。

| 方案 | 需要协议 | Weston 14 支持？ | 结论 |
|---|---|---|---|
| squeekboard | layer-shell + virtual-keyboard-v1（"强烈建议" input-method-v2） | 全无 | **不能用**（其 README 明列要求；且 Alpine 包 21 MB，GTK3） |
| wvkbd | virtual-keyboard-v1（--auto 才要 input-method-v2） | 无 virtual-keyboard | **不能用**（README 首行即 "for wlroots"） |
| maliit-keyboard | 走 maliit-framework 的 Wayland 平台（input-method-v1/v2 + Qt 私有 inputpanel shell） | 理论 v1 可用，实测不行 | **不能用**（maliit/keyboard#192：Weston 下不工作；另 Qt5/QML 依赖 108 MB+） |
| stevia | input-method-v2 + virtual-keyboard | 无 | **不能用** |
| wtype / wlrctl | virtual-keyboard | 无 | 不能用（Alpine 有包也不要装） |
| matchbox-keyboard / onboard / xdotool | X11 | 需 Xwayland 且只服务 X 客户端 | 不适用于终端场景 |

> 佐证：wayland.app 的 `zwp_virtual_keyboard_manager_v1` 支持表中 **Weston 14.0.2 标"x"**；NXP 论坛 2025-10 同类问题（Weston 缺 text-input-v3/input-method-v2/virtual-keyboard/layer-shell）的回复同样是"要么改内置键盘，要么换 wlroots 系 compositor"。

---

## 4. 自研最小 OSK：两条架构与工作量

| 架构 | 做法 | 工作量 | 风险/限制 |
|---|---|---|---|
| A. fork keyboard.c（input-method 路线） | 直接改 `clients/keyboard.c` 布局/状态机，用 toytoolkit 构建 | 1-2 人日（含构建打通，补丁本身半天） | 只服务 text-input 客户端（终端不可用）；toytoolkit 无 text-input 支持 |
| B. uinput 注入路线 | 自定义面板客户端（可 fork keyboard.c 或仿 `clients/simple-im.c`，裸 wayland-client+cairo 约 600-900 行）把按键写 `/dev/uinput` 虚拟键盘 | 3-6 人日 | **可以打进终端和一切客户端**（libinput→wl_keyboard→聚焦窗口）；需要 root/`/dev/uinput`（设备已有 `uinput-goodix`，说明内核与设备节点具备）；注意面板窗口不能抢焦点（用 input-panel surface 就不会被聚焦） |
| C. B + compositor 补丁（OSK 常显） | 另补 `desktop-shell/input-panel.c`：input-panel surface 提交时无条件 `show_input_panel_surface()`（去掉 `showing_input_panels` 门控） | +1-2 人日 | 替换 `desktop-shell.so` 属于 compositor 模块级改动，故障影响会话（保留 SSH 兜底）；换来"手机式常驻键盘" |
| D. 换 wlroots 系栈（sway/wayfire + squeekboard/wvkbd） | 重新适配 DRM/输入/面板 | 2-4 周 | 与审计 §4"长期项"一致，M4 前不建议 |

补充：`weston-simple-im`（weston-clients 内）就是一个只读 stdin、用 input-method-v1 提交文本的 561 行示范客户端，可作 A 路线的协议样板，也可用它快速验证 input-method 链路。

---

## 5. 不改 OSK 的折中方案（可执行性排序）

1. **配置级（立即可做，零构建）**
   - `[input-method] overlay-keyboard=true`：键盘改为光标旁 overlay，减少遮挡（仅对 text-input 应用有意义）。
   - 若想保留 toplevel：在 `[input-method] path=` 里写 `WESTON_KEYBOARD_SURFACE_TYPE=overlay /usr/libexec/weston-keyboard`（14.0 支持 env 前缀，`man/weston.ini.man:671-675`）。
   - 输出一份《OSK 键位地图》放 docs：`ABC`=切大写/符号；`?123`=数字+`-@*/^:;()~ /'"+=?!\|`；`_# $%&` 不存在；Tab=`->|`、方向键=`/\ < > \/`；后退=`<--`。

   `/etc/xdg/weston/weston.ini` 参考片段（回滚只需删 path 一行）：

```ini
[input-method]
# 部署新客户端后（推荐）；保留原二进制，随时回退
path=/usr/local/libexec/weston-keyboard-lmi

# 纯配置实验（不改任何文件）：改为 overlay 模式
#path=WESTON_KEYBOARD_SURFACE_TYPE=overlay /usr/libexec/weston-keyboard
#overlay-keyboard=true

[terminal]
# 与 §1.5 的宽度问题联动：字号/键宽一起调
font-size=14
```

   验证 OSK 是否属于 input-method 体系的最快方法：只启动 `weston-editor`（text-input 客户端）对比 `weston-terminal`，观察键盘是否出现/是否收字。
2. **uinput 快捷键小工具 + 面板图标（需要编译一个 ~150 行 C 工具）**
   - 写 `lmi-key esc|ctrl-c|ctrl-d|tab|up|down|enter|underscore|...`：打开 `/dev/uinput`，发 keycode 后自动释放；由 weston 面板 `[launcher]` 图标触发。
   - 关键性质：点面板/启动无窗口客户端**不会改变键盘焦点**，注入的键会进当前聚焦窗口（终端有效）。可提供终端刚需一排：Esc、Tab、Ctrl-C、Ctrl-D、↑、↓、←、→、Enter。
   - Alpine 没有现成注入器（`ydotool`/`evemu` 均未打包；`wtype`/`wlrctl` 依赖 virtual-keyboard 无用），所以这步绕不开一次编译——好在与 §2 共用同一套 build-base。
3. **weston.ini keybinding 路线：不可行**。weston 没有 `[keybindings]` section，绑定是硬编码列表且不能"执行命令"；音量/电源键会作为普通 keysym 进聚焦客户端，无法当快捷键面板用。
4. **终端转义/宏：不可行**。转义序列只控制终端输出，不能向其他应用注入输入；`TIOCSTI` 需要 CAP_SYS_ADMIN 且要拿到目标 pty，工程上不值得。
5. **物理键盘兜底**：USB-OTG 键盘经 libinput 即插即用（蓝牙当前不可用，见审计 G2/B6），可先作为"调试期终端输入"文档化。

---

## 6. 方案对比表与推荐路线

| 方案 | 工作量 | 风险 | 维护性 | 体验收益 |
|---|---|---|---|---|
| 0. 仅文档+overlay 配置 | 0.5 h | 极低 | 好 | 小（编辑器内更易找键；终端仍无输入） |
| 1. B-min 两处字符串 | 0.5-1 天 | 低（损失 `~ \`） | 中（weston 升级重建） | 小-中（补齐 `_` `.`） |
| 2. **B：布局补丁（5 行 + Esc/Ctrl）+ 独立客户端部署** | 1-2 天 | 低-中 | 中 | **大（editor/IM 应用一步可达常用键）** |
| 3. C：再加 uinput 常显 OSK（终端可用） | 3-7 天 | 中-高 | 中 | **大（覆盖终端，手机化）** |
| 4. 面板图标 + lmi-key（不动 OSK） | 1-2 天 | 低-中 | 中 | 中（终端刚需键一键可达） |
| 5. 替代 OSK / 换栈 | 不可行 / 2-4 周 | —/高 | —/中 | — |

**推荐路线（分三段，按最短路径先行）**：
1. **今天**：§5.1 配置 + 键位地图文档；顺手截图核实 §1.5 裁边问题（决定是否 `key_width=45`）。
2. **第一优先补丁（最短路径）**：先做 B-min 两处——① `l` 的 symbol `~`→`_`；② `,` 的 symbol `\`→`.`（1 小时内可出结果）；若不接受失去 `~`/`\`，直接做 B 方案——③ `normal_keys` 末尾加 12 键第 5 行、④ `normal_layout.rows=5`、⑤ Esc/Ctrl 两个 case 与 ctrl 掩码（约 40 行代码）。产出 `weston-keyboard-lmi`，`[input-method] path` 指过去。**先在编辑器验证，不动原二进制，随时回滚。**
3. **第二优先（终端）**：先做 §5.2 的 `lmi-key` + 面板图标（工期最短）；若体验满意再考虑 §4.C 的"常显 + uinput OSK"一步到位。任何 compositor 模块补丁前保证 SSH 可用（审计 A4 重启竞态先修）。

---

## 7. 验证步骤（可执行）

1. 构建侧：`ninja -C build weston-keyboard` 成功后 `file`/`readelf -l` 确认 aarch64 动态可执行；`sha256sum` 记录（若宿主与设备各构建一次，应字节一致，符合仓库 G5）。
2. 设备侧（先 SSH 保留）：
   - `strings /usr/bin/weston-terminal | grep -c zwp_text_input` → 预期 0（证实 §1.1 结论）；
   - 部署新二进制 + 更新 weston.ini，`rc-service m1-weston restart`（注意 A4 竞态），截图（weston-screenshooter）；
   - 截图核对：第 5 行出现、宽是否被裁（若裁→`key_width=45` 再测）。
3. 功能验证：在 weston-editor 中点 `_ . , / - @ # $ & |`、Esc、Ctrl+方向键，确认字符/行为；在终端确认"仍无输入"是预期，转向 §5.2 验证 `lmi-key esc` 注入后终端收到按键。
4. 回归：OSK 进程被杀后 10 s 内自动重拉（≤5 次）；亮度/音量键行为不受影响；`weston.ini` 回滚路径可用。
5. 入库（项目惯例）：补丁文件 + 构建脚本 + 产物哈希 + weston.ini 片段进 `tools/m1/`，镜像走 overlay/`patch-rootfs-image.sh`（参考 §0/§4 审计落地路径）。

---

## 8. 未决问题与风险

- **裁边假设**未实机截图确认；两套坐标模型下 720 逻辑宽都超出 540 逻辑屏，基本可断定会溢出，但具体哪几个键受影响需看截图。
- 若实测"OSK 在终端里能打字"，说明本报告对 weston-terminal 的源码判断与设备二进制不一致——请以 `strings` 检查为准，并回报以便修正结论。
- uinput 注入依赖 `/dev/uinput` 与 root（当前 m1-weston 以 root 跑，OK）；注意冲突：`uinput-goodix` 已有一个虚拟键盘设备，注入设备务必独立命名，避免与 goodix 驱动打架。
- weston 大版本升级（15/16）后需重建客户端；上游 15/16 的 keyboard.c 未变，但协议层如果变动需重测。
- compositor 模块补丁（方案 C）一旦出错可能黑屏失联；必须保留 SSH/恢复路径，并在 TWRP 兜底流程内演练。

---

## 附：主要来源

- weston 14.0.2 关键源码（可在线看）：
  - `clients/keyboard.c`（布局/状态机/尺寸）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/clients/keyboard.c
  - `frontend/text-backend.c`（input-method v1 实现、OSK 拉起、keysym 转发）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/frontend/text-backend.c
  - `desktop-shell/input-panel.c`（OSK 显示/定位门控）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/desktop-shell/input-panel.c
  - `clients/meson.build`（keyboard 目标/依赖）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/clients/meson.build
  - `man/weston.ini.man`、`man/weston-bindings.man`（配置与绑定能力）：https://gitlab.freedesktop.org/wayland/weston/-/tree/14.0.2/man
  - 16.0.0 复核：`protocol/meson.build`、`frontend/text-backend.c`（无 virtual-keyboard / input-method-v2）
- 版本事实：14.0.2 与 15.0.0、16.0.0 的 `clients/keyboard.c` SHA256 一致（本次实测，去 CRLF 后无差异）。
- Alpine 打包：`community/weston/APKBUILD`（3.23-stable，14.0.2-r4，仅 libdisplayinfo 补丁）：https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.23-stable/community/weston/APKBUILD
- 包体积：Alpine v3.23 aarch64 `main`/`community` APKINDEX（本次下载解析）。
- 协议支持表：https://wayland.app/protocols/virtual-keyboard-unstable-v1（Weston 14.0.2 不支持）、https://wayland.app/protocols/input-method-unstable-v2
- 替代 OSK：squeekboard README（compositor 要求）：https://gitlab.gnome.org/World/Phosh/squeekboard ；wvkbd README：https://github.com/jjsullivan5196/wvkbd ；maliit：https://github.com/maliit/keyboard/issues/192 、https://github.com/maliit/framework ；stevia：https://stevia.readthedocs.io/ ；NXP 论坛同题讨论：https://community.nxp.com/t5/i-MX-Graphics/Implementing-Better-On-Screen-Keyboard-Support-in-Weston-and/td-p/2183165
- wayland.app 协议支持与 wlroots/Phosh 背景：https://phosh.mobi/posts/phosh-osk-interface/ 、https://dorotac.eu/posts/input_method/
- 项目内参考：`docs/linux-ux-audit-2026-09-14.md`（A2/A6/B2 条目及设备实测数据）。
