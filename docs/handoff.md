# 开发交接（Handoff）— 2026-09-15（v1.0 已发布；M5 地基落地）

> 给接手本项目的 AI 会话/开发者：阅读顺序 = `AGENTS.md` → `docs/ai-protocol.md` → 本文，
> 再按需深入 `docs/`。所有结论以**仓库 + 设备实测**为准，不依赖任何会话记忆。

## 一、里程碑状态

| 里程碑 | 状态 | 证据 |
|---|---|---|
| Phase 0 | ✅ 立项文档（Charter/可行性/风险/ADR/测试计划） | `docs/{charter,feasibility,risk-register,test-plan}.md`、`docs/adr/` |
| M0 | ✅ 2026-09-13 方式 A 实机验收 A1–A5 | `docs/acceptance/m0-2026-09-13.md` |
| M1a | ✅ Alpine + Weston RAM 全量 bring-up（触摸 + OSK） | `docs/acceptance/m1a-2026-09-14.md` |
| M1b | ✅ 持久 rootfs + WiFi 直连 + 持久化 3 轮 + USB/LAN SSH | `docs/acceptance/m1b-2026-09-14.md` |
| M2 | ✅ v0.1 实机验收（T1-03/T2-03/T2-04/救援/TWRP 全过；T2-02 5 轮零失败，负责人决定提前结束） | `docs/acceptance/m2-2026-09-14.md` |
| Linux UX | ✅ Phase 1 + Phase 2 + 中文输入法 + 快捷键栏，实机验证 | `docs/acceptance/ux-2026-09-15.md` |
| M3 | ✅ **已在本机执行完成**（userdata 107→91 GiB + 新建 `lnx` 16 GiB，rootfs 迁移到 `lnx`） | `docs/acceptance/m3-2026-09-15.md`、`docs/m3-repart-plan.md` |
| 电源/温控/监控 | ✅ 实机落地（见 §五） | `docs/m1b-thermal-charging.md` |
| 桌面/终端体验 | ✅ 指纹拖动滚动、键盘避让、单窗口、`lmi-help`、WiFi 看门狗 | `docs/usage.md` |
| M4 | ✅ v1.0 已发布（tag `v1.0.0`） | `docs/release-v1.0.0.md`、`docs/reproduce.md` |
| M5 | 🚧 一键安装：PC 一键已实现，离线模拟全绿，**真机端到端待验证** | `docs/install-guide.md`、`docs/installer-design.md`、`tools/tests/m5-*.sh` |

## 二、设备当前状态（2026-09-15 深夜，实测）

- **运行中**：手机在 **Linux**（一次长会话，未重启）；`recovery` = **`boot-m1b-v21.img`**
  （`9064c43b…`，**overlay `m1b-ux-v14`**，回读校验通过）；rootfs 在 **`/dev/sda35`（`lnx`）**。
  引导账本仍是 `boot=23`（账本只在**启动**时写），所以**下一次 Linux 启动才会把 v14 overlay 落盘**；
  当前运行态是我今天逐文件同步并验证过的（见 §六之二）。
- **WiFi 正常**：`wlan0 up`，SSID/IP 属于按机信息（**不入仓**）；`lmi-netwatch`（看门狗）在跑，
  `/run/lmi-netwatch.state` = `status=ok`。
- **充电/温控在生效**：`lmi-chargectl` 把 SOC 控制在 70–80 % 锯齿（`/run/lmi-chargectl.state`），
  governor = `schedutil`；监控 `lmi-monitor` + 面板 `http://172.16.42.1:8080/` 正常。
- **rootfs 空间已修好**：`lnx` 上的 ext4 原来只有 1.4 GiB（迁移时忘了扩容，写满后 `dd` 会**静默失败**），
  已在线 `resize2fs` 到 **15.7 GiB（可用 ~14 GiB）**。
- **凭据已轮换**（2026-09-15 的隐私事件后）：root 口令与部署镜像里的 initramfs 救援口令都换过，
  存在设备 `/root/lmi-root-password.txt`(600) 与电脑侧 `%TEMP%\opencode\lmi-*-password.txt`；
  **仓库/发布物里没有任何口令或哈希**。
- **镜像**：`/root/m1b-rebuild/boot-m1b-v21.img`（当前部署，回滚点已清理；需要旧版就从当前镜像
  重建或走方式 A RAM 引导 / TWRP）。`super` 内的旧 rootfs 区仍完整保留（终极回滚）。
- **Android 侧**：Magisk 模块 `lmi-dualboot-switch` v0.2 已激活；`/data` = 91 GiB；
  `/dev/block/by-name/lnx → /dev/block/sda35`。
- **`boot` 分区 sha256 `8d441fc5…` 自始至终未变**（项目第一原则）。

## 三、存储布局（M3 之后，本机）

| 分区 | Android 名 | Linux 名 | 内容 |
|---|---|---|---|
| GPT 12 | `recovery` | `/dev/sda28` | **Linux 引导镜像**（当前 `boot-m1b-v21.img`；M2 双向切换的落点） |
| GPT 16 | `super` | `/dev/sda32` | Android 动态分区；**内部旧 rootfs 区（偏移 4K 单元 1,596,852）仍完整保留**（回滚用，未回收） |
| GPT 18 | `userdata` | `/dev/sda34` | 91 GiB（M3 由 107 GiB 缩容，PARTUUID 保留） |
| GPT 19 | `lnx` | `/dev/sda35` | **16 GiB，当前 rootfs 所在**（ext4，PARTUUID `91B8F669-…` 之外的独立新条目） |

- init 挂载策略：**优先 GPT `PARTNAME=lnx`**，回退到 super 内固定偏移（`lmi_root_off=1596852`），
  两者都支持 → 新旧部署都能启动。
- M3 规划/审计工具：`tools/m3/lmi-repart.sh`（`apply` 故意拒绝自动执行）+ 离线测试
  `tools/tests/m3-repart-test.sh`（CI 运行）+ 方案 `docs/m3-repart-plan.md`（§4b 独立子代理审计）。

## 四、功能资产（overlay `m1b-ux-v14` = 当前最新）

| 领域 | 内容 |
|---|---|
| 桌面/时间 | weston 正常桌面（非 kiosk，`KIOSK=1` 可切）、面板 + 24h 时钟 + **电量**（补丁 0011）、`swclock`+NTP 时区 |
| 字体 | WenQuanYi Zen Hei（键盘）、Zen Hei Mono（终端，weston.ini）；**cairo toy 字体不会逐字形回退**，必须显式指定 |
| 输入法 | 拼音页 + 候选条（`tools/m1/ime/`，词典 221 KB：431 音节/19631 字/18130 词）；终端 `delete_surrounding_text`（退格） |
| 快捷键栏 | Esc/Tab/Ctrl/Alt/方向/Home/End/PgUp/PgDn；Ctrl/Alt latch（双击锁定）；终端解析 `modifiers_map` |
| 按键/息屏 | 音量键→背光、电源键开关屏、空闲 300 s 灭背光（`lmi-keys` + `m1-weston IDLE_TIME`） |
| 终端体验 | `TERM=xterm-256color`、`LS_COLORS`、PS1（`/etc/profile.d/10-lmi-term.sh`） |
| 网络 | `lmi-wifi-scan` / `lmi-wifi-join <SSID> <PSK>` / `lmi-wifi-status`（PSK 在构建时注入，**不入仓**） |
| 电源/温控 | `lmi-power`（schedutil）、`lmi-chargectl`（停充 80 %/恢复 70 %、42/38 °C、卡死保护、24 h 安全阀）、`lmi-monitor` + `lmi-status` + LAN 面板 |

**weston 客户端补丁**（`tools/m1/weston-patches/0001-0011`）**必须在设备内原生编译**
（`tools/m1/build-weston-clients.sh`）；WSL/alpine/proot 产物在手机上 SIGSEGV。


### weston 客户端补丁索引（`tools/m1/weston-patches/`，**应用顺序即文件名顺序、`-p0`**）

| # | 作用 |
|---|---|
| 0001 | 终端支持 text-input v1（屏幕键盘可输入终端） |
| 0002–0006 | 键盘符号 `_ . ,`、宽度适配 540、逐键立即提交、无 surrounding text 时退格发 BackSpace |
| 0007 | 键盘**拼音页 + 候选条**（引擎与词典在 `tools/m1/ime/`） |
| 0008 | 终端实现 `delete_surrounding_text`（退格真正删字） |
| 0009 | 键盘**快捷键栏**（Esc/Tab/Ctrl/Alt/方向/Home/End/PgUp/PgDn，Ctrl/Alt 单击锁定、双击常锁） |
| 0010 | 终端解析 `modifiers_map`（Ctrl/Alt 组合正确翻译成终端字节） |
| 0011 | 面板时钟追加**电量** + 默认 24 小时制 |
| 0012 | 终端**手指拖动=滚动**历史（原来拖动被用于文本选择） |
| 0013/0014/0016 | 终端**键盘避让**：预留/读取 `keyboard-inset`（ini `[terminal]` 与 `/etc/conf.d/m1-weston`，实测 480） |
| 0015 | 终端从 `weston.ini` 读 `shell=`（**每个**终端都打印 `lmi-help` 说明书） |
| 0017 | 终端**网格按可用高度重排**、底边贴键盘上沿（不再有黑带，提示行始终可见） |
| 0018 | 修**滚动锚点**（`saved_start` 随输出/resize 同步）——修掉"滚动后输出被吞" |
| 0019 | 屏幕键盘输入（preedit/commit/keysym）也把视图拉回活区 |

> 构建：`tools/m1/build-weston-clients.sh`（**必须在设备内原生编译**；meson 需 `-Dprefix=/usr`，
> 补丁 `-p0`）。装好后把二进制放进 payload（`tools/m1/m1b/usr/bin/`、`usr/libexec/`）再重建镜像。

## 五、两条关键操作流程

### A. 改 overlay → 出新镜像（不需要 Android/fastboot/USB 主机）

```sh
# 设备 Linux 侧
cd /root/k30pro-linux-dualboot
tools/m1/rebuild-image-from-device.sh --mkbootimg /root/mkbootimg.py --out boot-m1b-vNN.img
# 自检全绿后部署（破坏性，需负责人确认；跳过方式 A 门禁）
dd if=/root/m1b-rebuild/boot-m1b-vNN.img of=/dev/sda28 bs=1M && sync
# 回读校验；下次 Linux 启动即应用新 overlay（账本 /root/m1b-boots.log）
```
流程/自检/回滚细节：`docs/m1b-rebuild-on-device.md`。

### B. Android 侧一键切换

Magisk 模块 `lmi-dualboot-switch` **v0.3**（`packages/magisk-module/`）：优先级 =
`LMI_SWITCH_IMG` > **recovery 里已是 Linux**（`ANDROID!` + cmdline 含 `lmi_root_off=`）
→ 只写 BCB 重启（**FAST**）> 选**最新且已 attest** 的 `boot-m1b-vNN.img` 走
`recovery-swap.sh to-linux`（**FULL**，带 attestation 门禁）。`LMI_SWITCH_DRY=1` 预演、
`LMI_SWITCH_FORCE=1` 绕过门禁（仅救援）。脚本 `exec 2>&1`，子脚本 `FATAL` 在 Magisk
窗口可见；无可部署镜像时列出候选与 attest 方法。回归测试 `tools/tests/m2-action-test.sh`。
注意：Magisk 安装模块后需重启一次才生效（`/data` 在 Linux 侧不可写）。

## 六、已知坑（务必读，不要重复踩）

1. **recovery 引导镜像必须带 `recovery_dtbo`**（否则 ABL 读到 `ANDROID!` → 落 fastboot）；
   ABL **不清** BCB，由 Linux init 清。
2. **weston.ini 绝不能含** `background-color`/`panel-color`/`background-image`（合成器卡死）。
   weston 只在 seat 有键盘焦点时上屏输入面板。
3. **weston-terminal 的 `--font=` 不接含空格的名字**；toytoolkit 解析。
4. **所有 payload 文本文件必须 LF**：曾用 `tr -d "\r"` 误删字母 `r`（毁 `lmi-weston`/`lmi-wifi-start`）。
   现在重建脚本会统一去 CR，并做 payload 逐文件 sha256 与设备比对。PowerShell 里别信 `tr` 的转义。
5. **mkbootimg 必须用 LineageOS `lineage-19.1` 版**（A15 版顶层 `from gki…` 直接 ImportError）。
6. **`resize.f2fs` 缩容必须 `-s`**（否则静默不执行，形成 fs>分区 → Android 恢复出厂风险）；
   `-t` 单位是**设备扇区（4096）**。`sgdisk -p` 不含 PARTUUID，要 `sgdisk -i`。
7. **温度单位**：`battery/temp` 是 **0.1 °C**（337 = 33.7 °C）；`thermal_zone<type=battery>` 是毫度。
8. **`input_suspend` 挂起充电不影响 USB 数据**（实测 usb0/adb 正常）；`constant_charge_current_max`
   写入返回 **EPERM**（限流不可用，默认关闭）；**保留 `sw_jeita_enabled=1`**。
9. **Linux 侧没有 `/dev/block/by-name/`**，分区是 `/dev/sdaN`；`/dev/sda` 是 4096 B 逻辑扇区。
10. **离线修补 rootfs 镜像必须先回放 journal**，否则 `e2fsck` 会静默回滚（`tools/m1/patch-rootfs-image.sh`）。
11. **冷启动卡 Redmi logo ~4.5 分钟 = 长按电源键硬复位（KPDPWR）**：ABL 的
    `VibratorDxe` 会去初始化本机损坏的 AW8697（i2c 重试 549 次 → 273 s），
    ABL 签名不可改，**无法软件根治**。系统内 `reboot`/`lmi-reboot` 走 PS_HOLD
    热复位（~3 s），所以**别长按电源键硬复位**；`lmi-keys` 已把长按电源键 3 s
    变成干净重启（overlay v15）。UEFI 日志对照：
    `/sdcard/Download/phone-server/lmi-bootdiag/uefilogs/{uefiFast-warm,uefiSlow-coldboot}.txt`。
12. `od` 缩写重复行 → 定长数据必须 `od -An -v -tx1`；fastboot/TWRP 后常需重插 USB；
    NCM 启动到 SSH 偶发 6–10 分钟（轮询超时给 ≥5 分钟）。
13. **Magisk 覆盖 init `.rc` 无效**（init 解析早于 Magisk 挂载）。
14. **凭据不得入库**：仓库/镜像里不允许出现任何真实口令、哈希、SSID、设备标识
    （CI `tools/ci/checks.sh` 第 4 项会拦）。构建时用 `LMI_ROOT_PASSWORD` 或随机生成；
    重建镜像换救援口令用 `--root-password` / `--random-root-password`；政策见 `SECURITY.md`。
15. 改 overlay 后**别忘了 bump 版本号**：`tools/m1/m1b-init.sh` 的 `OVERLAY_VERSION` 与
    `tools/m1/rebuild-image-from-device.sh` 的默认 `VERSION`（应用是一次性的，靠版本号判断）。
16. 开工前检查 open issues，`[VFY]` 开头 = 独立验证者产出，按 `docs/ai-protocol.md` 只能
    评论 `Resolved-by:`/`Rejected:`。
17. **开机慢的两个坑（overlay v15 修）**：
    - `udev-settle` 会等那个卡在 venus/vidc 固件加载（必失败，rc=-110 ~60 s）的
      udev worker，默认超时 120 s → 新增 `etc/conf.d/udev-settle`（`udev_settle_timeout=15`）；
    - `lmi-wifi` 是 default runlevel 里的**阻塞 oneshot**，配置网络都不在范围内时白等
      `LMI_WPA_WAIT`（原 60 s）再退出 1，把后面的服务全拖慢、还被 `lmi-netwatch` 反复重启
      → 现在先扫后等，没有可用网络就 `status=idle` 立刻退出（`LMI_WPA_WAIT=25`）。
    证据：`/var/log/messages`（`lmi-wifi failed` 紧接 getty）与 `/var/log/lmi-wifi.log`。

## 六之二、weston 终端/键盘实测结论（2026-09-15，补丁 0012–0019）

这几条都是**读源码 + 截图核对**得出的结论，不要再凭猜测改：

- **合成器不下发键盘几何**：`zwp_text_input_v1.input_panel_state` 在 weston 里**没有任何发送方**
  （libweston/desktop-shell/compositor 全搜过）。键盘是 `set_overlay_panel` 的**常驻覆盖层**，
  不会隐藏、也不会让窗口让位 → **避让只能客户端自己做**。
- **`weston-terminal` 不读 ini 的 `shell=`**（只读 font/font-size/term，程序来自 `$SHELL` 或
  `--shell=`）→ 想让"每个终端都显示说明书"必须打补丁 0015。
- **网格在哪算**：`resize_handler()` 由 `(height - margin - inset)/extents.height` 得出行列数，
  并经 `terminal_resize_cells()` 把 winsize 告诉 PTY。要"提示行可见"，就**缩小网格**而不是
  平移内容（0017）。行高在 font-size=15 时约 21 逻辑像素；本机窗口 540×1168，键盘+快捷栏
  占底部 480。
- **滚动锚点缺陷（上游）**：视图位置 = `(row + start) & mask`；`saved_start` 是"活区"锚点。
  输出滚动只推进 `start`（`terminal_scroll_buffer()`），resize 也会动它——**锚点不跟就会让
  "回滚"的钳制 `saved_start - start` 变负、失效**，视图越界到旧行（表现为"输出被吞"）。
  0018 让锚点处处跟随，0019 让屏幕键盘输入也回到活区。
- **验证手段**：`weston-screenshooter` 把 PNG 写到**当前目录**（`wayland-screenshot-*.png`，忽略
  传入路径）；`tools/m1/dev/lmi-inject.py` 支持 `taps`/`drag`/`type`，可以无人值守地"点键盘、
  拖动、打字"再截图核对。本次修复就是这样逐张截图确认的。

## 七、开发环境与通道

- **电脑**：`<host>\k30pro-linux-dualboot`（本仓库）。
  adb/fastboot = `<host>\k30Linux\tools\platform-tools\`（adb 序列号 `REDACTED`）。
- **手机 Linux（当前主机）**：USB-NCM 固定 `172.16.42.1`，root / `<your-password>`（构建时设置或随机生成，仓库不含口令）；
  WiFi 侧 IP 随热点变（曾 `10.84.40.x` / `192.168.1.x`）。
- 电脑侧辅助脚本（`%TEMP%\opencode\`）：`lssh.py`（SSH 执行）、`lcp.py`（put/get），
  **复杂命令一律写成脚本文件再 push 执行**（PowerShell 引号坑）。
- 仓库同步：电脑侧 `git pull --ff-only` / 收工 `git push`；手机侧仓库副本在
  `/root/k30pro-linux-dualboot/`（**部分文件**，仅供设备内重建；回 Android 后需 `git pull`）。
- 手机 Android 侧：Magisk 模块目录 `/data/adb/modules/lmi-dualboot-switch/`，
  镜像与备份 `/sdcard/Download/phone-server/`、`/data/local/lmi-dualboot/`。

## 八、下一步

1. **M5 一键安装（PC 一键已实现，设备端验证待做）**：目标是"别人也能装"。设计见
   `docs/installer-design.md`；约束：Android 用户态写不了 `super`（`baseband_guard`，
   issue #13）→ 纯 App 不可行，形态 = **PC 一键脚本 + TWRP 写入 + 通用镜像**；安装器自动
   备份 → 解析 super LP 元数据找空闲区 → 写 rootfs → 写 recovery → 写 BCB → 回滚；
   **不自动重分区**（M3 永远可选、手动）。**已完成**：
   - `tools/install/lp-metadata.py`（只读 LP 解析/空闲区选择；真机 `super` 核对：
     最大空闲区 offset 12,774,816 扇区 / ≈2.41 GiB，与 issue #13 一致；checksum 与 AOSP 一致）；
   - `tools/tests/m5-lp-parse-test.sh`、`tools/tests/m5-firstboot-test.sh`（合成镜像/沙箱，CI 运行）；
   - `tools/install/build-generic-image.sh`（零凭据门禁 fail-closed + 注入 firstboot + 调用
     `build-m1b-image.sh`；`--dry-run`）；
   - `tools/install/firstboot/`（随机 root 口令/主机密钥/machine-id、SSH 仅公钥、幂等）。
   - `tools/install/lmi-install.sh`（PC 一键：`check`/`plan`/`install`/`rollback`；经
     `fastboot boot twrp` 进 TWRP，先备份再写，流式 `dd`，全程 `--dry-run`）与
     `tools/install/patch-cmdline.py`（改 `lmi_root_off`）；测试 `tools/tests/m5-install-test.sh`
     与 `tools/tests/m5-install-sim-test.sh`（假 adb/fastboot + 沙箱分区跑**真路径**安装与回滚）。
   - **用户文档**：`docs/install-guide.md`（一键安装说明，含醒目风险提示）。
   **下一步**：**设备端到端安装验证**（破坏性，需负责人 + 测试机；先 `check`/`plan`/`--dry-run`）、
   安装时公钥注入、`--grow`（大 rootfs = 自动化 M3）。默认 rootfs 槽位固定 **1.5 GiB**（与
   `m1b-init.sh` 一致），实测系统仅占 ~1 GiB；大 rootfs 需 M3。注意 `super` 空闲区**不持久**
   （Android OTA 可能重新分配并覆盖）。
2. **G5 外部复现**：`docs/reproduce.md` 已就绪，需要一位**外部用户**跑通并回报（仓库无法自证）。
3. **回馈上游**：`saved_start` 锚点缺陷、以及 ini `shell=` 不生效，都是 weston-terminal 的真实问题，
   值得整理成上游 patch（我们的 0018/0019/0015 可作素材）。
4. **WiFi 掉线根因未定**：已用 `lmi-netwatch` 自动恢复兜底；下次复现时先看
   `/var/log/lmi-netwatch.log`、`dmesg | grep -i cnss`、`/var/log/lmi-wifi.log` 再动手。
5. **可选收尾**：super 内旧 rootfs 区回收（观察期后）、`docs/architecture.md` §2/§3 与
   `docs/test-plan.md` T4 回填、IME 第二页、电池 LED 提示。

## 九、新会话开工清单

1. `git pull --ff-only`，确认 HEAD = `origin/main`（≥ `8d26a65`，即 v1.0 之后的 M5 系列）。
2. 读 `AGENTS.md` → `docs/ai-protocol.md` → 本文 → 按任务进 `docs/acceptance/*`、
   `docs/install-guide.md`、`docs/installer-design.md`、`docs/m1b-rebuild-on-device.md`、
   `docs/m1b-thermal-charging.md`、`docs/m3-repart-plan.md`。
3. 检查 open issues（`[VFY]` = 验证者产出）+ `git log --oneline -10` 对照 §八。

可直接粘贴给新会话的提示词：

> 你在开发仓库 `k30pro-linux-dualboot`（Redmi K30 Pro 双系统）。先读 `AGENTS.md` →
> `docs/ai-protocol.md` → `docs/handoff.md`，再 `git pull` 并确认 HEAD 与 `origin/main`
> 一致（≥ `8d26a65`）。当前：M0–M4 已完成、**v1.0.0 已发布**；M3 扩容已在本机执行
> （rootfs 在 `/dev/sda35`/`lnx`，镜像 `boot-m1b-v21`，overlay `m1b-ux-v14`）；Linux UX +
> 中文输入法 + 快捷键栏 + 电源温控监控均已落地。**M5 一键安装**：PC 侧（`tools/install/`）
> 已实现、离线模拟全绿，**真机端到端安装待验证**。任务：按 §八推进——真机安装演练（破坏性，
> 需负责人 + 测试机，先 `check`/`plan`/`--dry-run`）、外部复现（G5）、回馈上游、WiFi 根因。
> 收到后先复述计划再动手。
