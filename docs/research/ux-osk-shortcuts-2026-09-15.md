# OSK 快捷键栏设计调研（Redmi K30 Pro / Weston 14）

> 日期：2026-09-15。仅调研，无代码改动。栈约束：Weston 14.0.2 只有 `zwp_input_method_v1` + `zwp_text_input_v1`（无 text-input-v3 / input-method-v2 / virtual-keyboard-v1）；OSK = 打过补丁的 `weston-keyboard`（cairo 自绘，12 列 x 45 逻辑 px = 540，行高 50）；终端 = 打过补丁的 `weston-terminal`（仓库 patch 0001/0003/0008 已接 text-input v1）。
> 标记：【验证】= 上游/本项目源码或官方文档确认；【推断】= 由已验证事实推导。所有源码行号按未打补丁的 14.0.2 计（补丁为行内插入）。

## 0. 结论速览

1. 首版建议固定 12 键一行，正好 540 逻辑 px，不做滚动：`Esc Tab Ctrl Alt ← ↑ ↓ → Home End PgUp PgDn`；第二页（Fn）放 `PgDn Ins Del F1-F10`。【推断，见 Q6】
2. 修饰键语义：点按 = one-shot（下一个键生效后自动释放），再点 = 取消，双击 = 锁定；必须高亮反馈（active/locked 两种视觉）。HK、iOS、Termux 都是这套的三变体【验证，Q2】。
3. 硬限制：OSK 的 keysym 只送达"当前聚焦的 text-input 客户端"，永远不触发 compositor 键绑定（Super+Tab、Ctrl+Alt+F1、Alt+Tab 均不可实现）；修饰键含义由 IM 自发的 modifiers_map 定义，compositor 原样转发【验证，Q4】。
4. 终端侧必须新增 `(keysym, modifiers) -> pty 字节` 映射表（xterm 约定）；并修一个真实冲突：OSK 当前 map 顺序使 Ctrl=0x2，而终端 `function_key_response()` 把 0x2 当 toytoolkit 的 Alt【验证，Q4】。
5. 横向滚动可实现（toytoolkit 提供 touch_motion handler），但首版不值得做；真要做用"8-10 px 阈值 + 抬手确认 + 吸附"，并给点按翻页替代（WCAG 2.5.7）【验证/推断，Q3】。

## 1. 键位优先级（Q1）

对比结论：Android 系统输入法（Gboard/LatinIME）本身没有修饰键行，Gboard 的"物理键盘工具栏"只是建议条+快捷键列表【验证，9to5Google】；Linux 终端 OSK 的现实对标是 Hacker's Keyboard（HK）和 Termux。HK：Shift 双击锁定，Ctrl/Alt 不锁、只影响下一键，Fn 页提供 Home/PgUp/PgDn/F1-F12【验证，HK UsersGuide】。Termux：默认 extra-keys 一行 `ESC TAB CTRL ALT - DOWN UP`，常见两行再加 `/ - HOME END PGUP PGDN`；CTRL/ALT/SHIFT 点按 toggle、长按锁定【验证，termux.properties / ExtraKeysView.java】。

| 优先级 | 键 | 理由 |
|---|---|---|
| P0 | Esc, Tab, Ctrl(latch), Alt(latch), ←, ↑, ↓, → | 终端/readline/vi 刚需；当前 OSK 无 Ctrl/Esc，无硬件键盘时完全不可达（keyboard.c:103-147）|
| P1 | Home, End, PgUp, PgDn | less/man/htop/multiplexer；Ctrl+A/E 只能部分替代 Home/End |
| P2 | Del, Ins, F1-F12 | 编辑器/vim/mc；可放第二页 |
| P2 | Shift(latch), Super/Meta | Shift 已有 ABC 大写态；Super 在终端无消费者、compositor 绑定也不可达 |
| P2 | 组合宏键（Ctrl+C 专键等） | Ctrl latch 后一键即可，专键浪费栏位；只适合当"应急"键 |
| 不可交付 | Alt+Tab, Super+Tab, Ctrl+Alt+F1..F12 | IM 注入不经过 `notify_key`，compositor 绑定不执行；Weston 窗口切换绑定修饰键是 Super（shell.c:538），Alt+Tab 本就不是它的绑定 |

## 2. Latching / 锁定语义（Q2）

- HK：Shift 点按后影响下一键；双击锁定（左 Shift 出现绿点指示）；再点取消。Ctrl/Alt **不**锁定，仅影响下一键；再点取消【验证，HK UsersGuide】。
- Termux：CTRL/ALT/SHIFT/FN 点按 toggle active（one-shot）；长按 = lock（锁定后读取不取消）；再次点按取消。终端读取修饰态时 `if (active && !locked) deactivate`【验证，ExtraKeysView.java:519-585、643-655，SpecialButtonState.java】。
- iOS/iPadOS（外接键盘 Sticky Keys）：修饰键（Cmd/Option/Shift）按一次再按目标键即可；双击修饰键锁定，再按一次解除；屏幕右上角显示修饰键图标，锁定时图标变白【验证，AbilityNet iOS 15 指南 + Apple 支持页】。
- Android 无障碍 Sticky Keys（物理键盘）：按下并松开修饰键后保持激活，直到按下一个键；官方文档只描述 one-shot，没有双击锁定【验证，Google 无障碍支持页】。
- 状态反馈三要素：a) 高亮（active 用反色/灰底，locked 用更深填充或角标，不能只靠文字变色——浅色键面上对比度不足）【推断】；b) 发送下一个 keysym 后自动清 one-shot；c) 双击锁定，阈值取 300 ms（Android DOUBLE_TAP_TIMEOUT=300 ms、DOUBLE_TAP_SLOP=100 dp）【验证，AOSP ViewConfiguration】。
- 双指"按住修饰键+另一指按键"的实体键盘式操作不适合手机 OSK（单指模型、易误触），不采用【推断】。

## 3. 一行键的横向滚动（Q3）

- 首选"不滚动"：每页 11 键 + 1 个翻页键（HK Fn 模型），或把集合压到 12 内。纯点按无手势冲突；且 WCAG 2.5.7 明确：内容自己实现的滚动机制属于该条款适用范围，必须提供不需拖拽的单指替代（如翻页按钮）【验证，W3C Understanding SC 2.5.7】。
- 若做拖拽滚动：touch down 只记录起点并暂缓按键动作，|dx| > touch slop 进入拖动；抬手时未超阈值才当作点按、超阈值则取消该次按键。AOSP 默认 touch slop 8 dp，我们建议 10 逻辑 px（在 540 宽、45 px 键宽下等于 1/4 键宽）【验证 AOSP ViewConfiguration；阈值取舍为推断】。
- 吸附/惯性：12-24 键规模只需吸附到 45 px 边界，不需要 fling 与回弹【推断】；滚动条/指示器对 50 px 高的行不划算。
- 可发现性：最廉价做法是让下一个键在边缘露出被裁切的一部分；或行尾固定一个"▸"提示键，不要只依赖隐藏手势【推断】。
- 触摸目标：键宽 45 x 高 50 逻辑 px，达到 48 dp 级目标（Android 建议 48 dp 最小触摸目标）【推断】。
- 现有代码陷阱：`button_handler`/`touch_handler` 在 down 和 up 都触发按键（keyboard.c:666-755），加拖拽必须改为"抬手确认 + 超阈值取消"；长按连发（Termux 的方向键连发）与拖拽判定天然互斥，首版不实现连发【验证源码 + 推断】。

## 4. 协议能力与字节映射（Q4）

已验证的链路事实：

- `zwp_input_method_context_v1.keysym(serial, time, sym, state, modifiers)` 的参数被 Weston **原样转发**为 `zwp_text_input_v1.keysym` 事件，无校验、无转换（text-backend.c:595-610）。
- `modifiers` 是被 modifiers_map 索引的 bitmask：客户端先收 `modifiers_map` 事件，文档原文 "The position in the array is the index of the modifier as used in the modifiers bitmask in the keysym event"；Weston 把 IM 发来的 map 原样转发（text-backend.c:582-592）【text-input-unstable-v1.xml】。
- 当前 weston-keyboard 在 activate 时发 `Shift/Control/Mod1` 三个名字，只按 Shift 取 mask（keyboard.c:898-904）→ 该 map 下 Shift=0x1、Control=0x2、Mod1=0x4。
- weston-terminal 现有 `text_input_keysym`（patch 0001）只处理 BackSpace/Tab/Linefeed/Escape/Return/Delete/PgUp/PgDn/四方向/Home/End，其它 keysym 直接 return；且把协议 mask 直接喂给 `function_key_response()`，后者检查的是 toytoolkit 的 `MOD_SHIFT/ALT/CONTROL = 0x1/0x2/0x4`（window.h:717-719）→ **Ctrl(0x2) 会被当成 Alt，Alt(0x4) 被当成 Ctrl**（terminal.c:338-361、2371-2602）。修法二选一：终端解析 modifiers_map（参考 editor.c:380-386），或把 OSK map 顺序改成 Shift/Mod1/Control；推荐前者。
- 硬件键盘不会自动产生 text-input keysym：全树只有 text-backend.c:607 一处 `send_keysym`，只来自 IM 转发【验证】。
- 备选路径（记录用）：`zwp_input_method_context_v1.key()/modifiers()` 携带 raw evdev keycode 与 wl_keyboard modifiers，Weston 直接走 default grab 送往聚焦客户端，绕过 compositor 绑定（text-backend.c:702-741；libweston/input.c:2694-2701）。走这条路 weston-terminal 现有 `key_handler` 的 Ctrl/Alt 逻辑可原样生效，但 OSK 需要 grab_keyboard 并解析真实 keymap 拿 mod index，成本高。

P0/P1 键的 pty 字节（xterm 约定；Ctrl+字母 = ASCII 0x01-0x1A；termios 默认 VINTR=^C、VEOF=^D、VSUSP=^Z、VKILL=^U、VWERASE=^W、VREPRINT=^R）【验证，XTerm Control Sequences + termios(3)】：

| 键 | 发送的字节 | 备注 |
|---|---|---|
| Esc / Tab | 0x1B / 0x09 | Shift+Tab = CSI Z，当前 terminal.c 未实现 |
| Ctrl+C / D / Z / L / A / E / U / W / K / R | 0x03 / 04 / 1A / 0C / 01 / 05 / 15 / 17 / 0B / 12 | 通用 Ctrl+字母 = `sym & 0x1F`（key_handler 已有该逻辑）|
| Ctrl+Space / Ctrl+[ / \ / ] / Ctrl+/ | 0x00 / 1B 1C 1D / 1F | Ctrl+[ 与 Esc 同为 0x1B |
| Alt+字母 | ESC+字母（默认行为）| terminal.c 默认开 `MODE_ALT_SENDS_ESC`（terminal.c:509-512），DECRST 1039 才会退回 8-bit meta |
| ← ↑ → ↓ | normal `CSI A/B/C/D`；application `SS3 A/B/C/D`；带修饰 `CSI 1;N x` | N = 1 + (Shift 1 \| Alt 2 \| Ctrl 4)，即 xterm 修饰码表 |
| Home / End | `CSI H` / `CSI F`（application `SS3 H/F`）| |
| PgUp / PgDn | `CSI 5~` / `CSI 6~` | |
| Ins / Del | `CSI 2~` / `CSI 3~` | |
| F1-F4 | `SS3 P/Q/R/S` | 带修饰时前缀变 CSI（由 function_key_response 处理）|
| F5-F12 | `CSI 15~/17~/18~/19~/20~/21~/23~/24~` | 当前 terminal.c 缺 F11 分支，需补 |

## 5. 实现草图（Q5）

### weston-keyboard（OSK）

- 位置：不改三套 layout 的键表，在 `redraw_handler` 里把快捷键栏画在第 `layout->rows` 行（normal/pinyin 均 4 行 → 总高 250 逻辑 px）；三处 `window_schedule_resize`（handle_commit_state、input_method_activate、keyboard_create，keyboard.c:827-829、908-910、1021-1023）统一高度 +`key_height`。这样与 patch 0007 的 pinyin 4 行布局解耦。
- 命中：`button_handler/touch_handler` 先判断 `y >= layout->rows * key_height` 进栏位表，其余走原逻辑（keyboard.c:666-755）。
- 状态：`struct keyboard` 增 `xkb_mod_mask_t latched, locked; uint32_t last_tap_time;`；在 `input_method_activate()` 用 `keysym_modifiers_get_mask(&modifiers_map, "Control"/"Mod1")` 取 mask（沿用 keyboard.c:898-904 已含 Mod1 的 map）。
- 发键：普通键按下时 `mods = shift_mask | latched | locked`；若 mods 含 Ctrl/Alt 位，则不调 `commit_string`，改调 `zwp_input_method_context_v1_keysym(ctx, serial, time, sym, PRESSED, mods)` 及同 mods 的 RELEASED（客户端按 wl_keyboard 惯例需要成对事件），随后清 latched、重绘。ASCII 单字符可直接用 codepoint 作 keysym；pinyin 候选等非 ASCII 不走此路径【推断】。
- latch 状态机：修饰键 PRESSED 时，若该位已 locked → 清零；否则 300 ms 内同一键再次按下 → 置 locked；否则置 latched。locked 不进 `last_tap` 判定前需先清除以防抖动。
- 高亮：`draw_key()`（keyboard.c:306-342）按 active/locked 画两种填充（例如 active=浅灰、locked=深灰+白字），locked 最好带角点标记；触摸 handler 已会 `widget_schedule_redraw`。
- 不建议跨客户端复用 Shift 的 `keysym.shift_mask` 语义；Ctrl/Alt 单独位。

### weston-terminal

- `text_input_modifiers_map` 用 `keysym_modifiers_get_mask`（window.h:803 已导出）保存 shift/ctrl/alt mask；`text_input_keysym` 先把协议 mask 映射成 toytoolkit `MOD_*` 再进入共用逻辑。
- 把 `key_handler`（terminal.c:2371-2602）里的 keysym→bytes switch 抽成共用 helper，`text_input_keysym` 与硬件路径共用；default 分支补 Ctrl 字母/符号（0x01-0x1A）与 Alt 处理。
- `function_key_response()`（terminal.c:338-361）可直接复用；补 F11、Shift+Tab（CSI Z）、Insert、应用光标模式（`KM_APPLICATION`，terminal.c:322-336）。
- Alt 无需改默认：terminal.c 已默认 ESC 前缀（`MODE_ALT_SENDS_ESC`，terminal.c:509-512），与 readline 预期一致。
- 只对 PRESSED 动作；避免在 text_input 路径重复 `MODE_DELETE_SENDS_DEL` 的 0x04 行为（保持与硬件路径一致即可）。

## 6. 首版键表（Q6）

- 第一页（12 键，固定，不滚动）：`Esc | Tab | Ctrl | Alt | ← | ↑ | ↓ | → | Home | End | PgUp | PgDn`。
  理由：8 个 P0 + 4 个 P1 正好占满 540 px；零手势冲突；Esc/Tab/方向键的标签可读性顺带修复（现有标签是 `->|`、`/\`、`<`、`>`、`\/`，keyboard.c:116、142-145）。
- 第二页（可选，v2；需要一个翻页键）：第一页末位退为 `Fn`（PgDn 进第二页），第二页 = `PgDn | Del | Ins | F1 | F2 | F3 | F4 | F5 | F6 | F7 | F8` + 翻回键。
- 横向滚动的启用条件：若最终想同时保留 P0/P1 并加入 Del/Ins/F 键，则把栏位改为 24 键可拖动条（12 可见），或维持"11+1 翻页"；首版不启用。

## 7. 第一个实现步骤（给维护者）

1. 终端优先：在 terminal.c 实现共用 `(sym, toytoolkit mods) -> bytes`，解析 modifiers_map，处理 Ctrl 字母/Alt/F11/Shift+Tab/Insert；用 `lmi-key` 或 USB 键盘回归，确认硬件路径无回归。
2. OSK 栏位：keyboard.c 加 12 键表、第 5 行绘制/命中与 resize；先不做 latch，验证 Esc/Tab/方向/Home/End/PgUp/PgDn 在终端生效。
3. 加 Ctrl/Alt latch（tap 切换、300 ms 双击锁、两态高亮、发送后自动释放），在终端验证 Ctrl+C（中断 `ping`）、Ctrl+D、Ctrl+Z、Ctrl+L、Ctrl+A/E/U/W/K/R。
4. 设备验收：截图确认 250 高不遮内容、无裁边；vi/less/htop 用例；Android 双系统回归。
5. 前 4 步稳定后再决策第二页/滚动；若做滚动，按 Q3 的阈值与 WCAG 替代方案实现。

## 参考来源

- Weston 14.0.2 源码（本次已下载 tarball 核对 meson.build version=14.0.2）：
  - clients/keyboard.c：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/clients/keyboard.c
  - clients/terminal.c：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/clients/terminal.c
  - clients/window.h、window.c（MOD_* 与 keysym_modifiers_get_mask）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/clients/window.h
  - frontend/text-backend.c（keysym/key/modifiers 转发）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/frontend/text-backend.c
  - libweston/input.c（notify_key 与 key binding）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/libweston/input.c
  - desktop-shell/shell.c（binding_modifier=MODIFIER_SUPER）：https://gitlab.freedesktop.org/wayland/weston/-/blob/14.0.2/desktop-shell/shell.c
- wayland-protocols：text-input-unstable-v1.xml、input-method-unstable-v1.xml：https://gitlab.freedesktop.org/wayland/wayland-protocols/-/tree/main/unstable
- XTerm Control Sequences（光标键/功能键/修饰码表）：https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- termios(3)（VINTR/VEOF/VSUSP 等默认控制字符）：https://man7.org/linux/man-pages/man3/termios.3.html
- Hacker's Keyboard UsersGuide（sticky/双击锁定/Fn 页）：https://github.com/klausw/hackerskeyboard/wiki/UsersGuide
- Termux extra keys 源码（点按 one-shot、长按锁定）：https://github.com/termux/termux-app/blob/master/termux-shared/src/main/java/com/termux/shared/termux/extrakeys/ExtraKeysView.java 、SpecialButtonState.java；默认键位 https://github.com/termux/termux-tools/blob/master/termux.properties
- iOS Sticky Keys（双击锁定/图标反馈）：https://mcmw.abilitynet.org.uk/how-to-use-an-external-keyboard-in-ios-15-with-your-iphone-ipad-or-ipod-touch 、https://support.apple.com/en-lk/guide/iphone/ipha7c3927eb/ios
- Android 无障碍 Sticky Keys：https://support.google.com/accessibility/android/answer/16318538
- Android ViewConfiguration（touch slop 8dp、double-tap 300ms/100dp）：https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/view/ViewConfiguration.java 、https://developer.android.com/reference/android/view/ViewConfiguration
- WCAG 2.5.7 Dragging Movements：https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements.html
- Gboard 物理键盘工具栏（非修饰键行）：https://9to5google.com/2024/01/10/gboard-physical-keyboard-toolbar/ ；ChromeOS 屏幕键盘 AltGr：https://support.google.com/chromebook/answer/6076237
- 项目内：`docs/research/ux-2026-09-14/osk.md`（Weston 协议栈与裁边分析）、`tools/m1/weston-patches/0001-0008`（现状）。
