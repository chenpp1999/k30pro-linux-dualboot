# 使用说明书（Linux 侧日常操作）

> 面向"已经把 Linux 装好、想日常用"的人。**一键安装见
> [`install-guide.md`](install-guide.md)**；手工/分阶段复现见 [`reproduce.md`](reproduce.md)，
> 底层原理与坑见 [`handoff.md`](handoff.md)、[`m1b-persistent.md`](m1b-persistent.md)。
>
> 约定：`$` 表示在手机 Linux 的终端/SSH 里执行；USB 网络的固定地址是 **`172.16.42.1`**
> （主机侧 `172.16.42.2`）。

## 0. 一屏上手

| 想做的事 | 命令 / 操作 |
|---|---|
| Android → Linux | Android 上打开 **Magisk → 模块 `lmi-dualboot-switch` → 操作（Action）**，按提示确认 |
| Linux → Android | **重启**即可（普通重启永远回 Android） |
| 看设备健康状况 | `lmi-status`（网页面板：浏览器开 `http://172.16.42.1:8080/`） |
| 连 WiFi | `lmi-wifi-scan` → `lmi-wifi-join <SSID> <密码>` |
| 改充电/温度策略 | 编辑 `/etc/conf.d/lmi-power` → `rc-service lmi-chargectl restart` |
| 降低发热 | `lmi-power -s`（默认已是 `schedutil`；`-p` 切回满频） |
| 打中文 | 点任何输入框 → 屏幕键盘弹出 → 输拼音 → 点候选字 |
| 开手电筒 | 面板上的**手电图标**（再点一次关）；或终端 `lmi-torch toggle` |

## 1. 切换系统

### Android → Linux（一键）
Magisk 模块 `lmi-dualboot-switch`：

1. Android 上打开 Magisk，进 **模块**，点 `lmi-dualboot-switch` 的 **操作** 按钮；
2. 模块按优先级决定动作：
   - **`recovery` 里已经是 Linux**（装好之后的常态）→ **FAST**：只写引导标记（BCB）
     并重启，不挑镜像、不动任何镜像数据；
   - 想装/换别的镜像：设 `LMI_SWITCH_IMG=<路径>`，或不一致时走完整流程
     （**FULL**：写 recovery + 校验 + 写 BCB，需要该镜像的 attestation）；
3. 手机重启后进入 Linux（首次进入会比 Android 慢，USB 网络枚举最长可能几分钟）。

> 排障：如果点 **操作** 后像"没反应"，先看 Magisk 弹出窗口里的文本（v0.3 起脚本
> 会把子命令的报错也显示出来）；也可以先只读预演：
> ```sh
> adb shell su -c 'LMI_SWITCH_DRY=1 /data/adb/modules/lmi-dualboot-switch/action.sh'
> ```
> 模块更新后需在 Magisk 里重装 zip 并**重启一次**才生效。

预演 / 排障用的环境变量（在模块 action 或终端里）：

```sh
LMI_SWITCH_DRY=1    # 只打印计划，不写任何分区、不重启
LMI_SWITCH_IMG=...  # 指定要部署的镜像
LMI_SWITCH_FORCE=1  # 跳过 attestation 门禁（确认过镜像来源才用，仅救援）
```

### Linux → Android
**在 Linux 里"重启"就会回 Android**：init 会清掉 BCB，`boot` 分区自始至终没被改动。

```sh
lmi-reboot        # 推荐：干净重启（等于 reboot），几秒就回 Android
reboot            # 一样的效果
```

> ⚠️ **不要靠长按电源键硬复位**。长按会让 PMIC 做硬复位、下一次变成**冷启动**，
> 引导器会去初始化这个机器上已损坏的 AW8697 震动芯片（i2c 重试 549 次）→
> **卡在 Redmi logo 约 4.5 分钟**。系统内 `reboot`/`lmi-reboot` 走的是热复位
> （PS_HOLD），约 3 秒。`lmi-keys` 现在也把"**长按电源键 3 秒**"变成一次干净重启，
> 所以在桌面上按住电源键同样安全（短按仍是息屏/唤醒）。

### 命令行方式（不用 Magisk UI）
```sh
# 在 Android（root shell）里，最轻量：只写 BCB，然后重启进 Linux（recovery 里已是 Linux 时）
sh /data/adb/modules/lmi-dualboot-switch/recovery-swap.sh bcb boot-recovery && reboot

# 或直接跑模块入口（与点 Action 等价）：
sh /data/adb/modules/lmi-dualboot-switch/action.sh
```

### 救援
- Linux 起不来：进 `fastboot` → `fastboot erase misc`（唯一的 erase 例外）→ 重启回 Android；
- 想恢复 TWRP：`recovery-swap.sh restore-twrp`；
- 想零写入试运行 Linux：`fastboot boot boot-m0.img`（RAM 引导，不写任何分区）。

## 2. WiFi

```sh
lmi-wifi-status                  # 一行状态（接口/SSID/IP）
lmi-wifi-scan                    # 扫描可见网络（SSID/信号/加密）
lmi-wifi-join MySSID 'my-password'   # 连接（会重写配置并重启服务）
lmi-wifi-join MyOpenSSID -           # 开放网络（- 表示无密码）
rc-service lmi-wifi restart      # 只重启服务
tail -f /var/log/lmi-wifi.log    # 看 bring-up 过程
```

- 配置文件：`/etc/wpa_supplicant/wpa_supplicant.conf`
  （模板 `…conf.template` 保留其它已知网络；`lmi-wifi-join` 把新网络放在最前面）。
- **凭据不入仓库**：模板里是占位符，真实 PSK 在构建镜像时注入；换网络用上面的 `lmi-wifi-join` 即可，不必重建镜像。
- USB 网络（NCM）与 WiFi **同时可用**：USB 固定 `172.16.42.1`，WiFi 地址由路由器分配。
- `lmi-wifi-join` **在现有配置上增删网络**（通过运行中的 `wpa_cli` + `save_config`），
  不会动其它网络；旧实现按占位符模板重建、会把已有网络清成占位条目，已在 overlay v16 修掉。
- **开机不再等 WiFi**：bring-up 会先扫一下，若配置里的网络一个都不在范围内，就立刻
  以 `status=idle` 结束（`wpa_supplicant` 仍在后台，等网络出现会自动连上）——
  以前会白等 60 秒并把后面的服务一起拖慢。`lmi-wifi-status` 此时显示 `state=up`
  但没有 IP。
- 已知问题：长时间运行后 `wlan0` 可能消失（`lmi-wifi-status` 报 *interface wlan0 missing*），
  重启 Linux 可恢复；重启服务通常不够。监测器会把这个过程记进 CSV。

## 3. SSH 登录

```sh
ssh root@172.16.42.1        # USB 网（固定地址）
ssh root@<wlan0 的 IP>      # 同一个局域网（IP 见 lmi-wifi-status）
```

- **口令来源**：构建镜像时设置或随机生成（仓库/发布物里没有任何口令）。
  装机后看 `/root/lmi-root-password.txt`（mode 600）或构建时打印的那一行。
- **改口令**：`passwd`（改完记得更新你自己的记录）。
- **更安全：只用公钥**
  ```sh
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  cat >> /root/.ssh/authorized_keys <<'EOF'
  ssh-ed25519 AAAA...你的公钥...
  EOF
  chmod 600 /root/.ssh/authorized_keys
  rc-service dropbear restart
  ```
- 调试期可直接用手机屏幕上的终端，不依赖网络。

## 4. 监测台（看健康状况）

### 命令行
```sh
lmi-status        # 一屏摘要（人读）
lmi-status -j     # 原始 key=value（同 /run/lmi-monitor/latest）
lmi-status -w     # 单行，适合放进 SSH 登录横幅
```

### 网页面板
浏览器打开 **`http://172.16.42.1:8080/`**（USB 网）；WiFi 侧用 `http://<wlan0 IP>:8080/`。
页面由 `lmi-monitor` 每 60 秒重新生成（静态 HTML），HTTP 服务按
`darkhttpd → busybox httpd → python3 -m http.server` 的顺序自动选一个。

```sh
rc-service lmi-monitor status|restart|stop    # 管理采样 + 面板
cat /run/lmi-monitor/latest                   # 最新快照
ls /var/log/lmi-monitor/                      # 按天 CSV（保留 60 天）
```

> ⚠️ 面板**没有鉴权、没有 TLS**，只适合 USB/家用内网。**不要**把它映射到公网。

### 指标怎么读

| 字段 | 含义 / 参考 |
|---|---|
| `soc`, `status`, `temp_c` | 电量 %、Charging/Discharging/Full、电池温度 |
| `current_ua` | 系统电流（µA）：正=放电，负=充电 |
| `voltage_uv` | 电池电压（µV，3.7 V ≈ 3700000） |
| `charge_full` / `cycle_count` | 满充容量 / 循环数 —— 长期看容量衰减（`charge_full_design` 本机为 0，不可用） |
| `load1`, `mem_used_kb`, `disk_use_pct`, `uptime_s` | 负载 / 内存 / 磁盘 / 运行时长 |
| `cpu_mhz` | 当前 CPU 频率（`schedutil` 下空闲会掉到 ~800 MHz） |
| CSV 里的 `soc_high_s`, `temp_high_s` | 累计"高电量时间"和">40 °C 时间"——比 `health` 更能反映电池压力 |

## 5. 充电与温控

默认策略（`/etc/conf.d/lmi-power`）：

| 项 | 默认 | 说明 |
|---|---|---|
| `CHARGE_STOP_SOC` / `CHARGE_RESUME_SOC` | 80 / 70 | 电量到 80 % 停充，掉到 70 % 恢复（10 % 迟滞） |
| `TEMP_STOP_C` / `TEMP_RESUME_C` | 42 / 38 | 电池温度门限（内核 `sw_jeita` 仍作为 45 °C 安全网） |
| `MIN_DWELL_SECONDS` | 300 | 两次切换的最小间隔，避免 PMIC 频繁动作 |
| `RECOVER_SOC` | 25 | **卡死保护**：一直掉电却充不进时，写 BCB 并重启回 Linux（绝不去 Android） |

- **为什么电量会"锯齿"**：挂起的是**充电输入**（`battery/input_suspend`），挂起期间系统由电池供电
  （约 160–330 mA），降到恢复线再充。USB **数据不受影响**（SSH/adb 照常）。
- 想让它长期满电：把 `CHARGE_STOP_SOC` 设成 100（或停服务 `rc-service lmi-chargectl stop`）——
  代价是电池寿命，不建议。
- 查看状态/日志：
  ```sh
  cat /run/lmi-chargectl.state     # soc/temp/status/suspended/last_toggle
  tail -20 /var/log/lmi-chargectl.log
  ```
- 改完配置：`rc-service lmi-chargectl restart`。
- 本机驱动**不支持**限流（`constant_charge_current_max` 写入返回 EPERM），故 `CHARGE_CURRENT_MAX_UA=0`。

## 6. CPU 频率 / 降温

```sh
lmi-power          # 按 /etc/conf.d/lmi-power 应用（开机自动执行）
lmi-power -s       # 切 schedutil（省电、低热；默认）
lmi-power -p       # 切 performance（满频最快，最热）
lmi-power -S       # 看三簇当前/最高频率
```
出厂 rootfs 默认是 `performance`（三簇钉在 1.8/2.4/2.84 GHz），对常开服务器纯发热，
所以我们开机改成 `schedutil`（空闲 ~800 MHz）。

## 7. 桌面、输入法、按键

| 功能 | 用法 |
|---|---|
| 终端 / 编辑器 | 桌面上的终端、`weston-editor`；终端已是 256 色 + 彩色 `ls` |
| 中文输入 | 点输入框 → 屏幕键盘上屏 → 输拼音（如 `nihao`）→ 点候选条选字；`←/→` 翻页 |
| 终端滚动 | **手指在终端里上下拖动 = 翻历史**（键盘弹出时内容会自动上移，提示行不会被挡住） |
| 多个终端 | 面板上的终端图标可以再开窗口，每个都会先打印说明书 |
| 命令速查 | `lmi-help`（**每个**新开的终端都会自动打印；SSH 登录也会打印一次；`LMI_NO_MOTD=1` 跳过） |
| 快捷键栏 | `Esc Tab Ctrl Alt ← ↑ ↓ → Home End PgUp PgDn`；**单击 Ctrl/Alt = 锁定一次，双击 = 常锁**（再点解除） |
| 音量键 | 调屏幕背光（含 0%/10% 档） |
| 电源键 | 开关屏 |
| 空闲 | 300 秒无操作自动灭背光（触碰/按键唤醒） |
| 单应用全屏（kiosk） | `/etc/conf.d/m1-weston` 里 `KIOSK=1` → `rc-service m1-weston restart`（改回 `0` 恢复桌面） |

## 8. 服务与日志速查

```sh
rc-status                 # 所有服务状态
rc-service <名字> status|restart|stop|start
```

| 服务 | 作用 | 日志 |
|---|---|---|
| `m1-weston` | 桌面合成器 + 客户端 | `/var/log/weston.log` |
| `lmi-wifi` | QCA6390 WiFi bring-up | `/var/log/lmi-wifi.log` |
| `lmi-keys` | 音量/电源键、空闲灭屏 | `/var/log/lmi-keys.log` |
| `lmi-chargectl` | 充电/温度控制 | `/var/log/lmi-chargectl.log` |
| `lmi-monitor` | 采样 + 面板 + CSV | `/var/log/lmi-monitor.out.log`、`/var/log/lmi-dashboard.log` |
| `lmi-power` | 开机应用 governor（一次性） | `/var/log/lmi-power.log` |
| `dropbear` | SSH | `/var/log/dropbear.log` |
| `ntpd` | 时间同步（RTC 只读，靠网络校时） | `/var/log/ntpd.log`（`logread` 亦可） |

其他有用位置：引导账本 `/root/m1b-boots.log`（每次 Linux 启动记
`boot=N … overlay=applied root=/dev/…`）、内核日志 `dmesg`。

## 9. 常见问题

| 现象 | 处理 |
|---|---|
| 黑屏 / 桌面没起来 | `tail -50 /var/log/weston.log`；`rc-service m1-weston restart`（wrapper 会一直重试，不会自弃） |
| 中文显示成方块 | 冷启动早期字体缓存重建导致，重启桌面服务即可（现在启动前会自动 `fc-cache`） |
| WiFi 连不上 | `lmi-wifi-status`、`tail -30 /var/log/lmi-wifi.log`；若 `wlan0 missing` → 重启 Linux |
| SSH 连不上（USB） | 拔插 USB 重新枚举；NCM 起来最慢可能 6–10 分钟；确认主机侧网卡是 `172.16.42.2/24` |
| 充电一直不停 | `cat /run/lmi-chargectl.state`；确认 `lmi-chargectl` 在跑（`rc-status`） |
| 电量掉到很低 | 卡死保护会在 ≤25 % 时重启回 Linux 重置 PMIC 状态；也可以手动 `rc-service lmi-chargectl restart` |
| 想彻底恢复 Android | 重启；或 `fastboot erase misc` 后重启 |
| WiFi 掉了（`wlan0` 消失） | `lmi-netwatch` 会自动重启 bring-up；手动看 `cat /run/lmi-netwatch.state` |
| 终端里想看被键盘挡住的输出 | 手指向下拖动终端即可翻到更早的内容（键盘高度可用 `KEYBOARD_INSET` 调） |
| 网页面板打不开 | `rc-service lmi-monitor restart`；`tail /var/log/lmi-dashboard.log`（无 http 服务时会提示） |

## 10. 安全提醒

1. **改掉默认/构建口令**，能用 SSH 公钥就别用口令（见 §3）。
2. 内网面板无鉴权：**不要**暴露到公网，也不要把 USB 网络桥接到不可信网络。
3. 镜像里含你的 WiFi 凭据与 SSH 配置：**不要**把 rootfs/引导镜像公开分发。
4. 长期插电请保持 `lmi-chargectl` 开启（默认开）：它是电池寿命的主要保护。
