# 系统时钟同步（NTP/RTC/时区）+ 中文字体 + 本地化 — 落地配置方案

> 设备：Redmi K30 Pro（lmi），Alpine 3.23.5 + OpenRC 0.63 + musl 1.2.5，rootfs 1.5 GiB ext4（已用 323 MB，余 ~1.0 GB），无 systemd。
> 依据：`docs/linux-ux-audit-2026-09-14.md`（A1/A5/B9、§0、§4）+ Alpine v3.23 aarch64 APKINDEX/包内文件实测（2026-09-14）。
> 追踪：A1（时间）、A5（CJK 字体）、A3/§0（weston.ini 合并）。

---

## 0. 结论速览（TL;DR）

| 事项 | 推荐 | 体积成本 | 备注 |
|---|---|---|---|
| NTP 客户端 | **busybox ntpd**（本轮落地） | **0 新增二进制**（`busybox-openrc` 已是 `alpine-base` 依赖） | 偏移 >1 s 自动 step；DNS 失败自动重试；可选升级 chrony |
| NTP 升级项 | chrony + chrony-openrc | ~0.4 MB 包体 + ~6–8 MB TLS 依赖（视已装情况） | 有 driftfile、`rtcsync` 周期回写 RTC、`chronyc` 可观测 |
| RTC | OpenRC `hwclock` 服务（`/etc/init.d/hwclock` 由 openrc 包提供） | 0 | 开机 `--hctosys`、关机 `--systohc`；与 busybox ntpd `-S` 脚本配合周期回写 |
| 时区 | `tzdata` + `/etc/localtime`→`Asia/Shanghai` | 0.44 MB（安装后） | 不用整包时只拷 zone 文件（~2 KB）即可 |
| weston 面板时钟 | `weston.ini` `[shell] clock-format=minutes-24h` | 0 | 现已实测：默认是 `%a %b %d, %I:%M %p`（12 小时制带 AM/PM） |
| 中文字体 | **`font-wqy-zenhei`**（文泉驿正黑 TTC） | 下载 8.81 MB / 安装 16.29 MB | 对比：`font-noto-cjk` 88.8 MB、`font-noto-cjk-extra` 209 MB、`font-unifont` 36.5 MB 位图（均不推荐） |
| 本地化 | `/etc/profile.d/00-lmi-locale.sh`：`LANG=C.UTF-8` | 0 | musl ≥1.2.4 原生支持 `C.UTF-8`；无需 locale-gen；`musl-locales` 可选但不含中文 |
| 落地方式 | 配置文件/脚本入 `tools/m1/m1b/**` overlay 树；字体与 tzdata 随 overlay v3 或预置进 rootfs 镜像 | overlay 增量 ~9 MB | recovery 分区 128 MB，v7 镜像 55 MB，头部空间充足 |

**一句话**：先按 §9.A 在运行中的 Linux 上把时间/时区/字体/24 小时面板全部验证通过；再按 §8 把文件收进仓库、字体作为构建资产、升 overlay 版本重建 `boot-m1b-v8`。

---

## 1. 现状与根因判定（基于实测数据）

- `date` = 1970-02-05，`/dev/rtc0` 的 `since_epoch≈3,057,515 s`（≈35.4 天）**正好对应 1970-02-05**：RTC 自身就停在 1970 年区间、只是在走。由此判断：内核 hctosys 生效（system time 初值来自 RTC，不是没有 RTC）；RTC 从未被正确时间写过；这**不是**“RTC 掉电丢时间”的直接证据（见 §4.4）。
- 无 `/etc/localtime`、无 tzdata → `date`/weston 用 C/UTC；`fc-list :lang=zh` 为空 → 只有 `font-dejavu`，无 CJK。
- 无 NTP 进程、`/etc/init.d/ntpd` 未启用（`syslog` 服务存在 ⇒ `busybox-openrc` 已装，见 §3.1）；面板 `Thu Feb 05 AM` 的原因见 §5.2。

---

## 2. 三种 NTP 实现调研结论

### 2.1 对比（Alpine v3.23 / aarch64，体积为安装后大小）

| 维度 | busybox ntpd | chrony 4.8-r2 | openntpd 6.8_p1-r11 |
|---|---|---|---|
| 新增包 | **无**（`busybox-openrc` 1.37.0-r30 已随 `alpine-base` 安装，内含 `/etc/init.d/ntpd`） | `chrony`（0.38 MB）+`chrony-openrc`（~1.6 KB） | `openntpd`（0.13 MB）+`openntpd-openrc`（~0.3 KB） |
| 依赖 | 无 | gnutls 1.95 + p11-kit 1.75 + nettle 0.63 + libunistring 1.88 + gmp 0.44 + libtasn1 0.06 + libidn2 0.19 + libseccomp 0.25 + libcap（约 6–8 MB，视已装情况） | 仅 musl |
| 大步进（1970→2026） | **内建**：`STEP_THRESHOLD=1 s`，初始采样后 offset>1 s 即 `settimeofday`（busybox 源码已核对） | 需 `makestep 1.0 3`（文档推荐写法） | **默认绝不立即设置时间**（`-S` 是默认）；`-s` 时也只在前台等 15 s 内有效 |
| 网络/DNS 晚到 | 解析失败按 `4 s × dns_errors` 退避重试（上限 ~252 s），适合 WiFi 60 s 后才就绪 | 周期性重解析；Alpine 打补丁把 `MAX_RESOLVE_INTERVAL` 从 512 s 降到 **64 s**（补丁名即 “when network is not available at bootup”） | 依赖启动时网络；DNS 失败重试能力弱 |
| RTC 回写 | 无内建；用 `-S PROG` 回调（step/stratum/每 11 min 调用）或关机时 `hwclock` 服务 | `rtcsync`（内核支持时周期同步系统时间→RTC） | 无 |
| 观测 | `logread`、`ps` | `chronyc tracking/sources/ntpdata` | `ntpctl` |
| 结论 | **首选**（零体积、行为正确、满足本项目“极简 rootfs”原则） | 需要长期漂移补偿/可观测性时升级 | 不适合：WiFi 就绪晚，`-s` 的 15 s 窗口必然错过 |

### 2.2 busybox ntpd 关键行为（据 1.37 源码与 Alpine 构建配置）

- Alpine 的 busybox 编译开关：`CONFIG_NTPD=y`、`CONFIG_FEATURE_NTPD_SERVER=y`、`CONFIG_FEATURE_NTPD_CONF=y`（**会读 `/etc/ntp.conf` 的 `server` 行，但仅当命令行未给 `-p`**）、`CONFIG_HWCLOCK=y`、`CONFIG_UNICODE_SUPPORT=y`。
- 算法要点（`networking/ntpd.c`）：`STEP_THRESHOLD 1`（偏移超 1 s 直接步进）、`SLEW_THRESHOLD 0.5`、步进后 `clamp_pollexp_and_set_MAXSTRAT`；`-S PROG` 会在 **step、stratum 变化、每 11 分钟**执行一次（官方示例正是用它跑 `hwclock --systohc`）。
- `busybox-openrc` 自带服务：`/etc/init.d/ntpd` 默认 `NTPD_OPTS="-N -p pool.ntp.org"`，以用户 `ntp` 运行（`/etc/passwd` 由 `alpine-baselayout` 提供 uid 123），`pidfile=/run/ntpd.pid`。

### 2.3 chrony 关键配置（升级路线）

默认 `chrony.conf`（4.8-r2 包内实测）= `pool pool.ntp.org iburst` + `initstepslew 10 pool.ntp.org` + `driftfile /var/lib/chrony/chrony.drift` + `rtcsync` + `cmdport 0`。建议替换为（把大步进显式化、去掉已废弃的 initstepslew）：

```
pool cn.pool.ntp.org iburst
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/chrony.drift
cmdport 0
```

`makestep 1.0 3`：只要获得第 1~3 次真实时钟更新（无论发生在开机后 1 分钟还是 1 小时），偏移超 1 s 就 step，之后只 slew。openntpd 不采纳的理由：Debian `ntpd(8)`（6.8p1）明确 `-S`（不立即设置时间）**是默认**，`-s` 才“启动时尝试立即设置、前台最多等 15 秒”；本项目 WiFi 开机 60 s 后才就绪，`-s` 必然超时（Alpine 的 openntpd 服务默认也不传 `-s`）。

---

## 3. NTP 服务的 OpenRC 集成（本项目特有，必读）

### 3.1 根因：`need net` 无法满足

- `busybox-openrc:/etc/init.d/ntpd` 与 `chrony-openrc:/etc/init.d/chronyd`、`openntpd-openrc:/etc/init.d/openntpd` 全部声明 `need net`；
- 本 rootfs **没有运行 `networking` 服务**，`lmi-wifi` 目前也**不提供 `net`**（`provide` 为空），因此 `need net` 会让 OpenRC 直接拒绝启动（与 `dropbear` 当年的问题同源，见 `tools/m1/m1b/README.md` Pitfalls）。
- 两种修复，任选其一（推荐 A，改动小且与 dropbear 先例一致）：

**A. 覆盖 `/etc/init.d/ntpd`（或 chronyd），把 `need net` 改为 `use net` + `after lmi-wifi`**

```sh
#!/sbin/openrc-run
# 本设备覆盖：rootfs 无 networking 服务且 lmi-wifi 负责联网，沿用 dropbear 的 use net 方案
name="busybox ntpd"
command="/usr/sbin/ntpd"
command_args="${NTPD_OPTS:--N -p pool.ntp.org} -n"
command_user="ntp"
pidfile="/run/ntpd.pid"
command_background=true
capabilities="^cap_sys_time,^cap_net_bind_service"

depend() {
	use net
	after lmi-wifi
	provide ntp-client
	use dns
}
```

**B. 给 `lmi-wifi` 增加 `provide net`**（可保留 stock 服务脚本）

```diff
 depend() {
 	need localmount
 	after m1-weston
+	provide net
 }
```

注意：`lmi-wifi` 是 `command_background` 服务，fork 后即视为 started；`net` 只保证“顺序”，不保证 DHCP 已完成。busybox ntpd 会自行重试 DNS，chrony 会周期重解析，所以两者都可接受。

### 3.2 启用与配置

```
rc-update add ntpd default        # 与 lmi-wifi 同在 default；after lmi-wifi 生效
rc-service ntpd start
```

`/etc/conf.d/ntpd`（覆盖 stock 默认，含国内可达服务器与 RTC 回写脚本）：

```sh
# 中国可达的 NTP；可重复 -p。自定义 NTPD_OPTS 后默认 pool.ntp.org 不再生效。
NTPD_OPTS="-N -p cn.pool.ntp.org -p ntp.aliyun.com -S /usr/sbin/lmi-hwclock-save"
```

`/usr/sbin/lmi-hwclock-save`（busybox ntpd `-S` 回调；参数为 `step|stratum|periodic|unsync`）：

```sh
#!/bin/sh
# busybox ntpd -S 回调：在首次步进/层级变化/每 11 分钟把系统时间写回 RTC。
# 手机经常被强制断电，不能只依赖关机时的 hwclock 服务。
case "$1" in
	step|stratum|periodic) /sbin/hwclock -w -u 2>/dev/null ;;
esac
exit 0
```

（若不用 `-S`，则仅在干净的 `reboot`/`halt` 时由 OpenRC `hwclock` 的 `stop()` 回写。）

### 3.3 离线回退

1. **RTC 回读**：启用 `hwclock` 服务（§4）后，每次开机系统时间≈RTC 时间，不会回到 1970。
2. **swclock**（RTC 不可用时的兜底）：`rc-update add swclock boot`（与 hwclock 互斥——两者都 `provide clock`；关机时间存 `/var/lib/misc/openrc-shutdowntime`）。时间单调但可能滞后，好过 1970；联网后由 NTP 校正。
3. **手动**：`date -s '2026-09-14 12:00:00'` + `hwclock -w -u`；Android 联网时也会给共享的 PMIC RTC 设时，双系统互有增益。

---

## 4. RTC：OpenRC 的 hwclock / swclock 行为与配置

### 4.1 谁提供什么（openrc 0.63-r1 包内实测）

| 路径 | 提供者 | 说明 |
|---|---|---|
| `/etc/init.d/hwclock`、`/etc/conf.d/hwclock` | `openrc` | `start()`=`hwclock --systz`+`--hctosys`；`stop()`=`--systohc`；额外命令 `save`/`show` |
| `/etc/init.d/swclock`、`/etc/conf.d/swclock`、`/usr/libexec/rc/sbin/swclock` | `openrc` | 用文件 mtime 恢复/保存时间，`provide clock`（与 hwclock 互斥） |
| `/sbin/hwclock` | **busybox**（applet 符号链接）；若装 `util-linux-misc` 则为其二进制 | 两者都按 `/dev/rtc` → `/dev/rtc0` → `/dev/misc/rtc` 顺序探测（已用二进制字符串核对） |
| `/etc/adjtime` | 运行时生成 | UTC 判定与漂移调整；busybox 构建用 FHS `/var/lib/hwclock/adjtime` |

### 4.2 `/etc/conf.d/hwclock` 默认值（Alpine stock，已正确）

```sh
clock="UTC"              # 与 Android/Linux 双系统约定：RTC 存 UTC（不要改 local）
#clock_hctosys="YES"     # 默认 YES：开机用 RTC 设置系统时间
#clock_systohc="YES"     # 默认 YES：关机把系统时间写回 RTC
#clock_args=""           # 无需 -f：hwclock 自动退回 /dev/rtc0
```

启用：`rc-update add hwclock boot`（当前很可能未启用——这就是“无 RTC 初始化”的直接原因之一）。
手动操作与验证：

```
rc-service hwclock show        # 显示 RTC（等价 hwclock -r -u）
rc-service hwclock save        # 立即把系统时间写回 RTC（等价 hwclock -w -u）
cat /sys/class/rtc/rtc0/date   # 2026-09-14
cat /sys/class/rtc/rtc0/time   # 12:34:56
cat /sys/class/rtc/rtc0/since_epoch
```

### 4.3 hwclock vs swclock

两者都 `provide clock`，**不能同时启用**（OpenRC 会冲突）。本设备有 `/dev/rtc0` 完整驱动节点，选 `hwclock`；仅当实测 RTC 写失败或掉电不保持时，改用 `swclock`。

### 4.4 PMIC RTC 保持性的一般结论与本机验证

- lmi 的 RTC 在 PMIC（Qualcomm PM8150 系，`rtc-pm8xxx`/下游 `qpnp-rtc`）的常供电域内：只要电池在机内（正常关机也含），RTC 持续走时；**拔电池/彻底放空/PMIC 复位**才可能回到默认。当前 `since_epoch≈35 天` 说明它“在走但从未被正确设置”，并非掉电。
- 已知硬件差异：部分 Qualcomm 平台 RTC 时间寄存器对 AP 只读，需 offset 机制（主线 `allow_set_time`/UEFI-offset 补丁即为此）。**必须先用 `hwclock -w -u` 实测本机可写性**：写成功→重启后 `date`（WiFi 起来前）应正确；写失败（EINVAL/EPERM）→退回 swclock + 每次开机 NTP 校正，并把结论记录进仓库。
- 验证：`date; hwclock -w -u && echo OK || echo FAILED; hwclock -r -u`，随后 `reboot` 并立刻 `date` 检查（WiFi 未连时也应有正确时间）。

---

## 5. 时区与 weston 面板时钟

### 5.1 tzdata 与 /etc/localtime

- `tzdata`（2026c-r0，main，下载 186 KB/安装 444 KB）提供 `/usr/share/zoneinfo/**`；推荐 `apk add tzdata` + `setup-timezone -i Asia/Shanghai`（-i：保留 tzdata 并把 `/etc/localtime` symlink 过去）。手工等价（不装 tzdata 也可：拷一个 zone 文件即自包含 DST 规则）：
  ```
  cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  echo Asia/Shanghai > /etc/timezone    # 可选：musl 不读；给 glibc 系工具/脚本用，建议保留
  ```
- musl 解析顺序：`TZ` 环境变量 > `/etc/localtime`；`/etc/timezone` 不被 musl 使用。内核的时间概念永远是无时区的 UTC，RTC 存 UTC 与 `clock="UTC"` 配套。

### 5.2 weston 面板时钟（weston 14.0.2，二进制实测）

- `weston.ini(5)`（14.0.2）`[shell] clock-format` 合法值：`none | minutes | seconds | minutes-24h | seconds-24h`，默认 `minutes`；
- 本机 weston 14.0.2-r4 的 `weston-desktop-shell` 中实际格式字符串：

| clock-format | strftime 模板 | 示例 |
|---|---|---|
| minutes（默认） | `%a %b %d, %I:%M %p` | `Sun Sep 14, 03:09 PM` |
| **minutes-24h** | `%a %b %d, %H:%M` | `Sun Sep 14, 15:09` |

（`seconds`/`seconds-24h` 只是模板再加 `:%S`；面板上限=星期+月+日+时:分（秒），不能显示年份或自定义格式。）

修改（同时把审查报告 §0 的 launcher 修复合并回仓库版本）：

```ini
[shell]
panel-position=top
clock-format=minutes-24h

[launcher]
icon=/usr/share/lmi/term-icon.png
path=/usr/bin/weston-terminal --maximized --font-size=16
```

生效：`rc-service m1-weston restart`（注意 A4 重启竞态，先保 SSH；或直接重启设备）。英文星期/月名可接受；要显示“周一”等中文需 musl 的 zh_CN locale 定义（Alpine `musl-locales` 不含，属可选 DIY，不建议本轮做）。

---

## 6. 中文字体

### 6.1 Alpine v3.23 可选 CJK 字体（aarch64，APKINDEX 实测）

| 包 | 版本 | 下载 | 安装后 | 评价 |
|---|---|---|---|---|
| **font-wqy-zenhei** | 0.9.46-r0 | 8.81 MB | **16.29 MB** | 文泉驿正黑 TTC（含 Zen Hei / Zen Hei Mono / Zen Hei Sharp 三个 family），GB18030 覆盖，黑体风格，**首选** |
| font-noto-cjk | 0_git20220127-r1 | 71.58 MB | 88.81 MB | 质量最好但体积为本机剩余空间的 ~9%，不推荐 |
| font-noto-cjk-extra | 0_git20220127-r1 | 167.78 MB | 208.98 MB | 直接排除（超出 rootfs 余量 1/5） |
| font-unifont | 17.0.03-r0 | 9.24 MB | 36.47 MB | 位图点阵，中文可读性差，不推荐 |
| font-wqy-microhei | — | — | — | v3.23 无此包（上游有，需自行携带文件） |

### 6.2 安装与启用（live 命令）

```
apk add font-wqy-zenhei        # 包内 /usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc（17,083,583 B）
fc-cache --system-only         # fontconfig 的 apk trigger 已监听 /usr/share/fonts/*，通常自动执行
fc-list :lang=zh | head        # 应出现 WenQuanYi Zen Hei / Mono / Sharp
fc-match -s :lang=zh | head -3 # 中文首选应为 WQY
```

可选（推荐）：启用包内的 fontconfig 规则，改善等宽与渲染细节：

```
ln -s /etc/fonts/conf.avail/44-wqy-zenhei.conf /etc/fonts/conf.d/
ln -s /etc/fonts/conf.avail/91-wqy-zenhei.conf  /etc/fonts/conf.d/
# 43-wqy-zenhei-sharp.conf 仅在偏好 Sharp 字形时启用
```

- `44-…`：把 WQY 追加到 serif/sans-serif/monospace 回退链（拉丁仍优先 DejaVu，CJK 落到 WQY）；
- `91-…`：对 WQY 关闭 hint/bitmap、修正 `globaladvance/spacing`，避免终端里 CJK 宽度异常。

### 6.3 weston-terminal 中的效果

weston-terminal 通过 Pango/fontconfig 自动做缺失字形回退，装包后 `printf '中文测试：你好，世界\n'` 即应显示；
如需“等宽对齐”，可在 `weston.ini` 指定 `[terminal] font=WenQuanYi Zen Hei Mono`（或保持默认 `DejaVu Sans Mono` + 回退，两者都可用）。

### 6.4 体积优化备选（不建议本轮）

可用 fonttools `pyftsubset` 把 WQY 裁到常用 6500 字（~4–6 MB），或以非包管理方式自带 wqy-microhei.ttc（~4.5 MB）；两者都引入额外构建资产/生僻字缺失。当前 rootfs 余量 ~1 GB，16 MB 的完整 WQY 完全可接受，优先稳定方案。

---

## 7. 本地化（musl 下的最小配置）

- **musl 的能力边界**：无 glibc 式 locale archive，无 `locale-gen`；`LC_*` 基本只影响字符宽度/`MB_CUR_MAX` 与少量 `strftime`/`gettext`；不改变文件编码。**UTF-8 是直通的字节流**，终端中文显示只取决于字体与终端（Pango），不依赖 locale。
- **musl ≥1.2.4 原生支持 `C.UTF-8`**（本机 musl 1.2.5）：置 `LANG=C.UTF-8` 后 `MB_CUR_MAX=4`，`wc`、`awk`、`sed` 等对多字节更友好。
- `musl-locales`（0.1.0-r1，0.19 MB）：提供 `locale` 命令 + `/etc/profile.d/00locale.sh`（仅 `export MUSL_LOCPATH=/usr/share/i18n/locales/musl`）+ 16 个 locale 定义（en_US/de_DE/fr_FR/…），**不含 zh_CN**。装它的意义仅在于兼容 `locale` 命令和英式时间格式；非必需。
- **最小落地配置**（新登录生效）：写入 `/etc/profile.d/00-lmi-locale.sh` 一行 `export LANG=C.UTF-8`。如偏好 `en_US.UTF-8`：`apk add musl-locales` 后设同名变量（定义由 MUSL_LOCPATH 提供）。不要设置 `LC_ALL`（会强制覆盖其它 LC_*）。
- 控制台（VT/串口）Unicode：`/etc/rc.conf` 里 `unicode="YES"`（Alpine wiki 的 Locale 页），仅影响 Linux 控制台，weston 不需要。
- 中文**输入法**不在本方案范围（weston 无 input-method-v2，见审查 C2）；终端中文“乱码”若是编码问题，排查顺序：`echo $LANG` → `printf '中文\n' | od -c`（应见 UTF-8 三字节序列）→ 终端是否 Pango（weston-terminal 是）。

---

## 8. 变更如何落地到项目（overlay vs 重建 rootfs）

### 8.1 原则

- **配置/脚本/小文件**：走 `tools/m1/m1b/**` → `mk-overlay.py` 生成的 overlay（当前版本常量 `m1b-wifi-v2` 在 `tools/m1/m1b-init.sh`）。
- **大体积二进制（字体）**：recovery 分区 128 MB、v7 镜像 55 MB，余量足够，二选一——（1）把 `.ttc` 放进 staged 树随 overlay v3 带走（overlay 默认上限 64 MB，8.8 MB/gz 无压力）；（2）重建 rootfs 镜像时预置（`apk add`/解包 apk），overlay 只带配置。
- **注意**：`mk-overlay.py` 只做新增/内容变化、**不支持删除**，且按版本号只应用一次——任何改动必须 bump `m1b-init.sh` 的 `OVERLAY_VERSION`，否则设备不会应用。
- **字体缓存**：overlay 解包不触发 apk trigger，`fc-cache` 不会自动跑。二选一：overlay 应用后在 initramfs 执行 `chroot /newroot /usr/bin/fc-cache --system-only`（m1b-init.sh 加 1 行），或用 boot oneshot 服务 `lmi-fontcache`（见下表）。不处理也能用，仅首次渲染前现场扫字体。

### 8.2 文件清单（repo → rootfs）

| repo 路径（staged 树内） | rootfs 路径 | 内容/来源 | 体积 |
|---|---|---|---|
| `tools/m1/m1b/etc/init.d/ntpd` | `/etc/init.d/ntpd` | §3.1 覆盖脚本 | ~0.5 KB |
| `tools/m1/m1b/etc/conf.d/ntpd` | `/etc/conf.d/ntpd` | §3.2 NTPD_OPTS | ~0.2 KB |
| `tools/m1/m1b/usr/sbin/lmi-hwclock-save` | `/usr/sbin/lmi-hwclock-save` | §3.2 -S 回调 | ~0.2 KB |
| `tools/m1/m1b/etc/conf.d/hwclock` | `/etc/conf.d/hwclock` | `clock="UTC"`（与 stock 相同，显式存档） | 0.6 KB |
| `tools/m1/m1b/etc/init.d/lmi-fontcache` | `/etc/init.d/lmi-fontcache` | boot oneshot：`fc-cache --system-only` | ~0.5 KB |
| `tools/m1/m1b/etc/localtime` | `/etc/localtime` | `Asia/Shanghai` zone 文件拷贝 | ~1.9 KB |
| `tools/m1/m1b/etc/timezone` | `/etc/timezone` | 文本 `Asia/Shanghai` | 15 B |
| `tools/m1/m1b/etc/profile.d/00-lmi-locale.sh` | 同左 | `LANG=C.UTF-8` | ~0.1 KB |
| `tools/m1/m1b/etc/xdg/weston/weston.ini` | 同左 | +`clock-format=minutes-24h`，并合并 launcher 修复 | 编辑 |
| `tools/m1/m1b/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc` | 同左 | 从 `font-wqy-zenhei-0.9.46-r0.apk` 解出（**建议不入 git**，见下） | 16.3 MB |
| （可选）`.../etc/fonts/conf.d/44,91-wqy-zenhei.conf` | 同左 | 软链等价物 | 小 |

字体资产建议仿照 `tools/m1/m1b/README.md` 的“Firmware not committed”惯例：仓库只存 **获取脚本 + sha256**，构建时下载：

```sh
# tools/m1/fetch-fonts.sh（建议新建；示例）
url=https://dl-cdn.alpinelinux.org/alpine/v3.23/community/aarch64/font-wqy-zenhei-0.9.46-r0.apk
# 校验 sha256 后解包 data 段到 staged 树（APK 为多段 gzip，建议用 Python tarfile 或 apk --root）
```

（在构建机（Debian）上可用 Python `tarfile.open(apk, "r:gz")` 解出，本地已验证可行。）

### 8.3 构建/发布

- bump `tools/m1/m1b-init.sh`：`OVERLAY_VERSION=m1b-ux-v3`；用 `build-m1b-image.sh --tree <staged> --base-tree /root/work/m1b-old --overlay-version m1b-ux-v3 --recovery-dtbo <dtbo.img> ...` 重建（沿用 2026-09-14 收官做法，勿用 `--base-image`，见 handoff §五）。
- 部署走 M2 工作流（`recovery-swap.sh to-linux`），产物命名 `boot-m1b-v8`；验收见 §9.C。

---

## 9. 可直接执行的步骤

### A. 现在就能在运行中的 Linux 上验证（root，不必重建镜像）

```sh
# --- 0) 前置检查 ---
rc-status | grep -E 'hwclock|ntpd'     # 确认两服务当前状态
ls -l /dev/rtc0 /dev/rtc 2>&1          # /dev/rtc 可能不存在；hwclock 会自动用 rtc0
cat /sys/class/rtc/rtc0/name /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/since_epoch
# --- 1) 时区 ---
apk add tzdata
setup-timezone -i Asia/Shanghai
date; readlink -f /etc/localtime       # 应立即显示 CST(+8)
# --- 2) NTP（busybox；先落 §3.2 的 conf.d/ntpd 与 lmi-hwclock-save）---
chmod +x /usr/sbin/lmi-hwclock-save
rc-update add ntpd default
rc-update add hwclock boot
# 若 ntpd 因 need net 起不来，先落 §3.1 的 /etc/init.d/ntpd 覆盖
rc-service ntpd start
sleep 15
date; logread -e ntpd | tail -n 5     # 期望出现 "setting time to ..." 或正常轮询
# --- 3) RTC 写回与保持性 ---
hwclock -w -u && echo "RTC write OK" || echo "RTC write FAILED (改走 swclock)"
hwclock -r -u
reboot            # 重启后（WiFi 未连前）执行：date; hwclock -r -u  —— 应仍正确
# --- 4) 字体 ---
apk add font-wqy-zenhei
fc-cache --system-only
fc-list :lang=zh | head
ln -sf /etc/fonts/conf.avail/44-wqy-zenhei.conf /etc/fonts/conf.d/44-wqy-zenhei.conf
ln -sf /etc/fonts/conf.avail/91-wqy-zenhei.conf  /etc/fonts/conf.d/91-wqy-zenhei.conf
fc-match -s :lang=zh | head -3
# 终端显示：重开 weston-terminal，输入：printf '中文测试：你好，世界\n'
# --- 5) locale 与面板时钟 ---
printf 'export LANG=C.UTF-8\n' > /etc/profile.d/00-lmi-locale.sh
vi /etc/xdg/weston/weston.ini          # [shell] 加 clock-format=minutes-24h（并保留 launcher 段）
rc-service m1-weston restart           # 注意 A4 竞态；保 SSH 通道
```

### B. 需要重建镜像固化（overlay v3 / boot-m1b-v8）

1. 按 §8.2 把配置/脚本加入 `tools/m1/m1b/**`（weston.ini 合并 launcher 修复）；`font-wqy-zenhei.ttc` 放入 staged 树（或写 `tools/m1/fetch-fonts.sh` 下载校验）；`Asia/Shanghai` zone 拷为 `tools/m1/m1b/etc/localtime`。
2. `m1b-init.sh`：`OVERLAY_VERSION=m1b-ux-v3`，overlay 应用成功后追加 `[ "$OVERLAY_RESULT" = applied ] && chroot /newroot /usr/bin/fc-cache --system-only || true`（或用 lmi-fontcache 服务，二选一）。
3. `build-m1b-image.sh` 重建（务必带 `--recovery-dtbo`）→ `recovery-swap.sh to-linux` 部署 → 跑 §C 验收，并回归 M2 往返至少 2 轮。

### C. 验收判据

| # | 命令 | 通过标准 |
|---|---|---|
| 1 | `date; date -u` | 本地 CST(+8)/UTC 都正确；与手机 Android 时间差 < 2 s |
| 2 | `rc-service ntpd status` / `chronyc tracking` | started/synchronized；`logread` 无持续失败 |
| 3 | 冷启动（拔电重启）后立刻 `date` | 正确（不依赖 WiFi/NTP） |
| 4 | `cat /sys/class/rtc/rtc0/date` | 与 `date -u` 一致 |
| 5 | `fc-list :lang=zh \| wc -l` | ≥ 1（期望 3 个 WQY family） |
| 6 | weston 面板 | 24 小时制 + 正确日期，无 AM/PM |
| 7 | `echo $LANG` / 新终端 `printf 中文` | `C.UTF-8`，无乱码 |

---

## 10. 来源

1. Alpine v3.23 aarch64 包索引（本报告所有包版本/体积的实测基础）：https://dl-cdn.alpinelinux.org/alpine/v3.23/main/aarch64/APKINDEX.tar.gz 、https://dl-cdn.alpinelinux.org/alpine/v3.23/community/aarch64/APKINDEX.tar.gz
2. 包页/内容：chrony https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/chrony ；openrc（hwclock/swclock 脚本）https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/openrc ；busybox-openrc（/etc/init.d/ntpd）https://pkgs.alpinelinux.org/contents?file=ntpd&branch=v3.23&arch=aarch64 ；alpine-base https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/alpine-base ；tzdata https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/tzdata ；alpine-conf（setup-timezone）https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/alpine-conf
3. 源码/构建配置：chrony APKBUILD 与 `max_resolve_interval.patch`（512→64 s）https://raw.githubusercontent.com/alpinelinux/aports/3.23-stable/main/chrony/APKBUILD ；busybox 配置 https://raw.githubusercontent.com/alpinelinux/aports/3.23-stable/main/busybox/busyboxconfig ；busybox `ntpd.c`/`hwclock.c` https://raw.githubusercontent.com/mirror/busybox/master/networking/ntpd.c 、https://raw.githubusercontent.com/mirror/busybox/master/util-linux/hwclock.c
4. openntpd `ntpd(8)`（`-S` 默认不立即设时；`-s` 前台最多 15 s）：https://manpages.debian.org/bookworm/openntpd/ntpd.8.en.html
5. weston：`weston.ini(5)` 14.0.2 https://manpages.debian.org/trixie/weston/weston.ini.5.en.html ；weston 14.0.2-r4 包 https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/weston
6. 字体/locale：font-wqy-zenhei https://pkgs.alpinelinux.org/package/v3.23/community/aarch64/font-wqy-zenhei ；fontconfig trigger（`fc-cache --system-only`）https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.23-stable/main/fontconfig/fontconfig.trigger ；musl-locales https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/musl-locales （上游 https://git.adelielinux.org/adelie/musl-locales ）；Alpine wiki Locale https://wiki.alpinelinux.org/wiki/Locale
7. PMIC RTC 可写性背景：https://lkml.org/lkml/2025/1/20/724 、https://github.com/torvalds/linux/blob/master/drivers/rtc/rtc-pm8xxx.c
8. 项目内文档：`docs/linux-ux-audit-2026-09-14.md`、`docs/handoff.md`、`tools/m1/m1b/README.md`、`tools/m1/mk-overlay.py`、`docs/architecture.md`（recovery 128 MB）

> 备注：Alpine wiki `Setting_up_a_NTP_client`（https://wiki.alpinelinux.org/wiki/Setting_up_a_NTP_client）本次抓取被 403 拦截，未直接引用其正文；本报告的 NTP 结论均来自上列包内文件与源码。
