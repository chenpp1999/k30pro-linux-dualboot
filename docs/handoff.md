# 开发交接（Handoff）— 2026-09-15（M4 开工前快照）

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
| M4 | 🚧 v1.0 发布（本文档即其开工快照） | `docs/release-v1.0.0.md`、`docs/reproduce.md` |

## 二、设备当前状态（2026-09-15 晚）

- **运行中**：手机在 **Linux**，内核镜像 = recovery 里的 `boot-m1b-v13.img`
  （`e4684d05…`，overlay `m1b-ux-v7`，回读校验通过），rootfs 在 **`/dev/sda35`（`lnx`）**，
  引导账本记 `boot=23`。**注意**：本次开机时 overlay 仍是 v6，v7 会在下次 Linux 启动时应用。
- **充电控制正在生效**：`lmi-chargectl` 已把 SOC 控制在 70–80 % 锯齿内，当前 `soc≈99 temp≈34 °C
  suspended=1`（放电中，约 160–330 mA），降到 ≤70 % 自动恢复充电；CPU governor = `schedutil`。
- **监控在跑**：`lmi-monitor`（60 s 采样 → `/run/lmi-monitor/latest`，CSV 落 `/var/log/lmi-monitor/`），
  LAN 面板 `http://172.16.42.1:8080/`（python3 回退服务器）。`lmi-status` 可命令行查看。
- **镜像清单**（`/root/m1b-rebuild/`）：
  - `boot-m1b-v13.img` = 当前部署（`e4684d05…`，overlay v7）
  - `boot-m1b-v11.img`（含 .sha256，也导出到 Android `/sdcard/Download/phone-server/lmi-m1b/`）
  - `boot-m1b-v9b.img`（旧回滚点）
  - 回滚 = `dd` 任一旧镜像回 `/dev/sda28`（`rollback-v12.img` 视需要重建）
- **Android 侧**：Magisk 模块 `lmi-dualboot-switch` v0.2 已激活（可在 Android 一键切 Linux）；
  `/data` = 91 GiB（数据完整）；`/dev/block/by-name/lnx → /dev/block/sda35` 可见。
- **`boot` 分区 sha256 `8d441fc5…` 自始至终未变**（项目第一原则）。

## 三、存储布局（M3 之后，本机）

| 分区 | Android 名 | Linux 名 | 内容 |
|---|---|---|---|
| GPT 12 | `recovery` | `/dev/sda28` | **Linux 引导镜像**（v13；M2 双向切换的落点） |
| GPT 16 | `super` | `/dev/sda32` | Android 动态分区；**内部旧 rootfs 区（偏移 4K 单元 1,596,852）仍完整保留**（回滚用，未回收） |
| GPT 18 | `userdata` | `/dev/sda34` | 91 GiB（M3 由 107 GiB 缩容，PARTUUID 保留） |
| GPT 19 | `lnx` | `/dev/sda35` | **16 GiB，当前 rootfs 所在**（ext4，PARTUUID `91B8F669-…` 之外的独立新条目） |

- init 挂载策略：**优先 GPT `PARTNAME=lnx`**，回退到 super 内固定偏移（`lmi_root_off=1596852`），
  两者都支持 → 新旧部署都能启动。
- M3 规划/审计工具：`tools/m3/lmi-repart.sh`（`apply` 故意拒绝自动执行）+ 离线测试
  `tools/tests/m3-repart-test.sh`（CI 运行）+ 方案 `docs/m3-repart-plan.md`（§4b 独立子代理审计）。

## 四、功能资产（overlay `m1b-ux-v7` = 当前最新）

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

Magisk 模块 `lmi-dualboot-switch` v0.2（`packages/magisk-module/`）：自动选最新 `boot-m1b-vNN.img`；
recovery 内容与目标 sha256 一致 → 只写 BCB 重启（**FAST**），否则走 `recovery-swap.sh to-linux`
（**FULL**，带 attestation 门禁）。`LMI_SWITCH_DRY=1` 预演、`LMI_SWITCH_FORCE=1` 绕过门禁。
注意：Magisk CLI 安装模块后需重启才生效。

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
11. 冷启动会卡 Redmi logo 4–5 分钟（aw8697 硬件问题，不可软件修复）；日常用"重启"。
12. `od` 缩写重复行 → 定长数据必须 `od -An -v -tx1`；fastboot/TWRP 后常需重插 USB；
    NCM 启动到 SSH 偶发 6–10 分钟（轮询超时给 ≥5 分钟）。
13. **Magisk 覆盖 init `.rc` 无效**（init 解析早于 Magisk 挂载）。
14. 改 overlay 后**别忘了 bump 版本号**：`tools/m1/m1b-init.sh` 的 `OVERLAY_VERSION` 与
    `tools/m1/rebuild-image-from-device.sh` 的默认 `VERSION`（应用是一次性的，靠版本号判断）。
15. 开工前检查 open issues，`[VFY]` 开头 = 独立验证者产出，按 `docs/ai-protocol.md` 只能
    评论 `Resolved-by:`/`Rejected:`。

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

## 八、下一步（M4 v1.0）

1. **文档收尾**：`README.md` 状态表、`docs/architecture.md` §2/§3 存储布局、风险台账 R1/R2 关闭、
   测试计划 T2-05..07 状态、`docs/reproduce.md`（G5 外部复现指南）、`docs/release-v1.0.0.md`。
2. **发布**：`VERSION` + `CHANGELOG` v1.0.0 段 → tag `v1.0.0` → GitHub Release
   （**只发源码/文档，不发设备镜像**：镜像含注入的 WiFi 凭据，属隐私）。
3. **CI**：把新增的无扩展名脚本纳入 shellcheck 清单（`tools/ci/checks.sh`）。
4. **G5**：需**外部用户**按 `docs/reproduce.md` 复现一次（本仓库无法自证）。
5. **可选收尾**：观察数日后回收 super 内旧 rootfs 区、rootfs 清理 ~450 MB 构建依赖、
   电池 LED 提示、IME 第二页。

## 九、新会话开工清单

1. `git pull --ff-only`，确认 HEAD = `origin/main`（≥ `522e42b`）。
2. 读 `AGENTS.md` → `docs/ai-protocol.md` → 本文 → 按任务进 `docs/acceptance/*`、
   `docs/m1b-rebuild-on-device.md`、`docs/m1b-thermal-charging.md`、`docs/m3-repart-plan.md`。
3. 检查 open issues（`[VFY]` = 验证者产出）+ `git log --oneline -10` 对照 §八。

可直接粘贴给新会话的提示词：

> 你在开发仓库 `k30pro-linux-dualboot`（Redmi K30 Pro 双系统）。先读 `AGENTS.md` →
> `docs/ai-protocol.md` → `docs/handoff.md`，再 `git pull` 并确认 HEAD 与 `origin/main`
> 一致（≥ `522e42b`）。当前：M0–M2 已实机验收；M3 扩容已在本机执行完成（rootfs 在
> `/dev/sda35`/`lnx`，镜像 `boot-m1b-v13`，overlay `m1b-ux-v7`）；Linux UX + 中文输入法 +
> 快捷键栏 + 电源温控监控均已落地。任务：按 §八推进 M4 v1.0 发布（文档收尾 → VERSION/
> CHANGELOG → tag `v1.0.0` → GitHub Release，**不发含凭据的设备镜像**）。收到后先复述计划再动手。
