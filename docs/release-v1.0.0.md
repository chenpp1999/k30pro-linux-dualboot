# v1.0.0 发布说明 — k30pro-linux-dualboot

> 发布日期：2026-09-15 · 对应里程碑 **M4**（M0–M3 均已实机验收）
> 许可证：工具链/脚本 MIT；内核补丁/DTS GPL-2.0-only；中文词典数据见
> [`tools/m1/ime/README.md`](../tools/m1/ime/README.md)

## 一句话

在 Redmi K30 Pro / POCO F2 Pro（`lmi`）上，**Android 永远优先**地并排放一套**能日常用**
的真 Linux：一次引导开关切换，Linux 坏了不影响 Android，
并且这套 Linux 有正常桌面、中文输入法、快捷键栏、按键/息屏以及**长期插电的充电与温控保护**。

## 亮点

| 能力 | 说明 |
|---|---|
| **故障安全** | `boot` 分区自始至终未被改动（sha256 全程一致）；Linux 引导镜像装在 `recovery`，经 BCB 一次性引导；一切重启默认回 Android |
| **可回滚** | 每步都有备份/回滚；`super` 内旧 rootfs 区保留；TWRP 可恢复（已演练） |
| **正常桌面** | Weston 桌面 + 面板（时间 + 电量）+ 启动器 + 终端；weston.ini 已规避卡死配置 |
| **中文输入** | 屏幕键盘拼音页 + 候选条（431 音节 / 19631 字 / 18130 词）；终端内可直接上屏 |
| **快捷键栏** | Esc/Tab/Ctrl/Alt/方向/Home/End/PgUp/PgDn；Ctrl/Alt 单次锁定 + 双击常锁 |
| **按键/息屏** | 音量键调背光、电源键开关屏、空闲 300 s 灭屏 |
| **网络** | WiFi 直连（CNSS2/qcacld + wpa_supplicant）；`lmi-wifi-scan/join/status` |
| **长期插电保护** | 停充 80 %/恢复 70 %、42/38 °C 门限、卡死保护 + 24 h 安全阀；governor 改 `schedutil` 降温 |
| **可观测** | `lmi-status` 一屏摘要；60 s 采样 + CSV 落盘 + 内网面板；累计高压 SOC 与 >40 °C 时长 |
| **可复现构建** | 设备内原生编译（无交叉工具链）；设备侧镜像重建**不需要 Android/fastboot** |

## 组件与产物

- 工具：`tools/{m0,m1,m3}`、`tools/ci`、`tools/tests`；Android 端一键切换 `packages/magisk-module`（v0.2）
- Linux 侧服务与载荷：`tools/m1/m1b/**`（Weston/字体/键盘/终端/按键/WiFi/电源温控/监控）
- weston 客户端补丁：`tools/m1/weston-patches/0001-0011` + `tools/m1/build-weston-clients.sh`
- 中文输入法引擎与词典管线：`tools/m1/ime/**`
- 文档：见 [README](../README.md) 文档索引；复现见 [`docs/reproduce.md`](reproduce.md)；
  **日常使用见 [`docs/usage.md`](usage.md)**（切系统 / WiFi / 监测台 / 充电温控 / 输入法）

**不发布**：设备引导镜像与 rootfs（内含按设备注入的 WiFi 凭据等私有内容）。
发布物 = 本仓库源码与文档。

## 验收矩阵（摘要）

| 里程碑 | 结论 | 证据 |
|---|---|---|
| M0 | 方式 A RAM 引导 A1–A5 全过，零写入 | `acceptance/m0-2026-09-13.md` |
| M1a/M1b | 持久 rootfs + WiFi + 3 轮持久化 + USB/LAN SSH | `acceptance/m1a-2026-09-14.md`、`acceptance/m1b-2026-09-14.md` |
| M2 | 双向切换 5 轮零失败、中断电回 Android、自愈、TWRP 演练 | `acceptance/m2-2026-09-14.md` |
| Linux UX | 桌面/中文输入/快捷键/按键息屏 实机验证 | `acceptance/ux-2026-09-15.md` |
| M3 | userdata 107→91 GiB + `lnx` 16 GiB，rootfs 迁入并启动，Android 数据完好 | `acceptance/m3-2026-09-15.md` |
| 电源温控 | 充电挂起不影响 USB 数据、governor 生效、监控与面板可用 | `docs/m1b-thermal-charging.md` §6、`test-plan.md` T4 |

## 已知限制

1. **M2 往返只跑了 5 轮**（负责人基于时间成本提前结束），验收标准由 20 轮修订为 5 轮 + 全部故障演练通过。
2. 冷启动可能卡 Redmi logo 4–5 分钟（本机 aw8697 硬件问题，不可软件修复）；日常用"重启"。
3. `constant_charge_current_max` 写入返回 EPERM → **限流不可用**（已默认关闭并记录）；
   充电控制只能"挂起/恢复输入"，即 70–80 % 之间的锯齿。
4. 该 PMIC 的"停在 80 %"需要改 DT/内核（旁路/低浮充），本期**不做**（风险高，见温控文档 §5）。
5. 面板电量只在**桌面**模式显示（kiosk 模式无面板客户端）。
6. 内网面板无鉴权，勿暴露到公网；SSH 口令由构建时设置/生成，仓库不含口令，仅适用于 USB/受控网络。
7. G5（外部用户复现）**待完成** —— 欢迎按 [`docs/reproduce.md`](reproduce.md) 复现并回报。

## 升级 / 回滚

- 升级 Linux 侧：改 overlay → `tools/m1/rebuild-image-from-device.sh`（设备内）→ `dd` 到 `recovery`；
  下次 Linux 启动应用新 overlay（版本号驱动，见 `docs/handoff.md` §六 第 14 条）。
- 回 Android：任意重启即可；或 Magisk 模块 / `recovery-swap.sh`。
- 回滚到旧镜像：`dd` 旧 `boot-m1b-vNN.img` 回 `recovery`。
