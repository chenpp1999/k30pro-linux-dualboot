# M1b 温控 / 充电 / 长期监控（lmi 常插电服务器）

> 2026-09-15 实机落地。目标：手机长期插 USB 当服务器时**别把电池充爆/烤坏**，
> 以及**能看到长期运行状态**。全部基于设备实测的 sysfs 节点，缺失即优雅降级。

## 1. 背景与风险

- 常插电 + 满电 + 温热是锂电最坏的组合：BU-808 给出终止电压 4.20 V → 约 300–500
  次循环，4.00 V（≈80 %）→ 约 850–1500 次；长期停在 4.20 V 顶还会加剧鼓包。
- 本机出厂 rootfs 的 CPU governor 是 `performance`：三簇（1.8/2.4/2.84 GHz）**长期
  钉在最高频**，对服务器纯属发热。

## 2. 实测控制的节点（lmi SMB5 + qcom 电池驱动）

| 节点 | 读到的值 | 可写 | 用途 |
|---|---|---|---|
| `battery/input_suspend` | 0 | 是 | **主开关**：挂起 USB 充电输入（内核 USB_ICL=0，带 0 值 override），**不影响 USB 数据**（实测 usb0/adb 正常） |
| `battery/capacity` | 100 | 只读 | SOC |
| `battery/temp` | 337 | 只读 | **单位 0.1 °C**（337 = 33.7 °C）；`thermal_zone*` 里 type=`battery` 的是毫度 |
| `battery/status` | Charging/Discharging/Full | 只读 | 交叉校验 JEITA/内核是否也在挂起 |
| `battery/constant_charge_current_max` | -22 | 名义可写 | **实测 EPERM**：本驱动拒绝，限流功能因此默认关闭（`CHARGE_CURRENT_MAX_UA=0`） |
| `battery/sw_jeita_enabled` | 1 | 是 | **保持 1**：过温安全网（它也会挂 USB 输入，与我们的开关共用 VOTE_MIN） |
| `cpufreq/policy*/scaling_governor` | performance | 是 | 改为 `schedutil` 降空闲发热 |

## 3. 交付组件（overlay `m1b-ux-v7`）

| 组件 | 作用 |
|---|---|
| `usr/sbin/lmi-power` + `etc/init.d/lmi-power` | 开机应用 `schedutil`（`-p` 一键切回 performance，`-S` 看状态） |
| `usr/sbin/lmi-chargectl` + `etc/init.d/lmi-chargectl` | SOC/温度控制：**停充 80 % / 恢复 70 %**（10 % 迟滞）、**停充 42 °C / 恢复 38 °C**；最小驻留 300 s；日志 `/var/log/lmi-chargectl.log`；状态 `/run/lmi-chargectl.state`；**卡死保护**（SOC 持续下滑 → 告警，≤25 % 时写 BCB + 重启回 Linux，绝不去 Android）；**24 h 安全阀** |
| `usr/sbin/lmi-monitor` + `etc/init.d/lmi-monitor` | 每 60 s 采样 → `/run/lmi-monitor/latest` + 生成 `/run/lmi-monitor/www/index.html`；每 10 min 落盘 `/var/log/lmi-monitor/YYYY-MM-DD.csv`（保留 60 天）；累计**高压 SOC 时长 / >40 °C 时长**（真实的电池应力指标） |
| `usr/sbin/lmi-status` | 一屏摘要（`-j` 原始、`-w` 一行，适合 SSH 横幅） |
| LAN 面板 | 回退链：`darkhttpd` → `busybox httpd` → `python3 -m http.server`（本机当前用 python3，端口 8080）；仅限 USB/WiFi 内网，无鉴权，勿暴露公网 |

## 4. 关键参数（`/etc/conf.d/lmi-power`）

```
CHARGE_STOP_SOC=80      # 停充
CHARGE_RESUME_SOC=70    # 恢复（10% 迟滞，别用 5%：约 1.25 h 就走完一段）
TEMP_STOP_C=42          # 停充（45 °C 交给内核 sw_jeita，≥55 °C 属急停）
TEMP_RESUME_C=38
POLL_SECONDS=30
MIN_DWELL_SECONDS=300
RECOVER_SOC=25          # 卡死保护触发
GOVERNOR=schedutil
CHARGE_CURRENT_MAX_UA=0 # 本驱动拒绝写入，保持 0
DASHBOARD=1 / DASHBOARD_PORT=8080
```

## 5. 设计取舍（为什么是"锯齿"）

`input_suspend` 挂的是**充电输入**，因此挂起期间系统由电池供电（实测约 160 mA），
SOC 缓慢下降，到 70 % 再恢复充电 —— 即 70–80 % 之间的锯齿。这是该类 PMIC 上
不依赖 DT 改动的可行做法（ACC 的 "idle/emulated" 模式同理）。

- 对电池最好的是"降低浮充电压把电池稳在 ~80 %"，但那要改 DT/内核，风险高，
  本期不做（`lmi-repart` 式的谨慎原则）。
- 挂起期间若 USB 掉电：系统照常由电池运行，不中断；只影响续航。
- 我们不关 `sw_jeita`：它会和自己抢 USB_ICL，任何一方挂起都生效，所以监控里
  始终记录 `status`/`current_now`/`temp` 做交叉校验，而不是相信自己的最后一次写。

## 6. 验证记录（2026-09-15）

- `input_suspend=1` → `status=Discharging`（约 160 mA 系统电流），**usb0/adb 仍正常**；
  `=0` → `status=Charging`（约 -248 mA）。
- chargectl 起服务后按 SOC=100 ≥ 80 挂起并写状态文件（`soc=100 temp_c=33 suspended=1`）。
- `lmi-power -a` 后三簇 governor = `schedutil`（空闲 freq 844 MHz）。
- 监控采样与 `lmi-status` 正常，`/run/lmi-monitor/www/index.html` 由 monitor 生成，
  python3 回退服务器返回 200。
- 温度读数单位坑：`battery/temp` 是 0.1 °C，`thermal_zone<type=battery>/temp` 是毫度，
  monitor/chargectl 优先用 thermal zone。

## 7. 风险与后续

1. **PMIC 卡死**（ACC 记录过小米机型）：靠 10 % 迟滞、最小驻留、RECOVER_SOC 与
   24 h 安全阀兜底；`input_suspend` 重启即复位，**永不设为开机默认**。
2. `sw_jeita` 竞争：保持开启 + 交叉校验（见 §5）。
3. 面板电量只在**桌面**上显示（weston 面板客户端补丁 0011）；kiosk 模式下无面板。
4. 后续可选：评估"低 ICL 限流"（需驱动允许）、把 monitor 采样写成 SQLite/`vnstat`
   式的日聚合、以及给 `lmi-status` 加 SSH 登录横幅。
