# UX 第一批落地 + weston 服务健壮性 — 审查与实施计划

> 基线：`main @ dce034e`（2026-09-14，含 UX 审查提交 48de301 与 PNG 二进制修复）。
> 输入：`docs/linux-ux-audit-2026-09-14.md`、`docs/m1b-persistent.md`、`docs/m2-runbook.md`、
> `tools/m1/build-m1b-image.sh`、`tools/m1/mk-overlay.py`、`tools/m1/m1b-init.sh`、
> `tools/m1/recovery-swap.sh`、`tools/m1/m1b/**`、`tools/m1/patch-rootfs-image.sh`、
> `docs/test-plan.md`、`docs/handoff.md`、`tools/ci/checks.sh`。
> 本报告只读审查，未修改仓库、未连接设备。事实与仓库不符处均按"实测事实"标注。

## 0. 结论摘要

1. **A4（weston 重启竞态）根因确认**：`/usr/sbin/m1-weston` 只 `wait`、无 `trap`；
   OpenRC `command_background + pidfile` 的 `stop` 只 TERM wrapper。wrapper 死、weston 成孤儿
   并持续占用 DRM/seat → 再 start 时 `fatal: failed to create compositor backend`。
   修复 = wrapper 全面接管子进程生命周期（trap + 有界清理 + 受限重试/回退配置）
   + init 脚本 `stop()` 三级升级（TERM wrapper → 等 → KILL + 孤儿清扫）。见 §1。
2. **仓库缺口**：`/usr/sbin/m1-weston`、`/etc/init.d/m1-weston` 都不在 overlay 树
   （`tools/m1/m1b/` 下无对应文件）；仓库里的 `tools/m1/m1-weston.sh` 是 M1a RAM 引导副本，
   git mode `100644`（无执行位），且无 trap。必须统一为"单一权威副本 + CI 一致性检查"。
3. **第一批落地 = 一个新 boot 镜像（v8）+ 一个新 overlay（`m1b-ux-v3`）**，不动分区布局、
   不改 M2 切换语义；overlay 只增不改删（`mk-overlay.py` 设计），首启重放一次后按版本戳跳过。见 §2/§3。
4. **CJK 字体是唯一的体积变量**：≤16 MiB 走 overlay 一条路；超预算则必须派生出新的 rootfs
   master 镜像（TWRP 写入，风险与工时显著上升）。建议首选 wqy 系列/子集化字体。见 §2.1/§5。

## 1. A4 修复设计（可粘贴脚本）

### 1.1 设计原则

- **单一所有者**：wrapper 是 weston 及其所有客户端（terminal/editor、modetest/FIFO feeder）的唯一父进程；
  退出路径由 `trap ... EXIT` 保证（`TERM/INT/HUP` 先置 `STOPPING=1`，再走统一清理）。
- **有界等待**：所有 `kill/wait` 都有超时（1s 粒度），不出现无限阻塞；超出即升级 KILL。
- **幂等重启**：start 前"清扫残留 + 等 seatd/dri"；失败重试 3 次、退避 3s，第 2 次起可切
  `weston.ini.fallback`（防配置损坏导致死循环）。
- **不阻塞 SSH**：wrapper 以 `command_background` 运行，OpenRC start 立即返回；
  dropbear 与 m1-weston 无依赖关系（现状即如此），weston 崩溃不影响 SSH。
- **不引入新依赖**：仅用 busybox ash（`pgrep/pkill/kill/sleep` 分数秒均可用；`lmi-wifi-start`
  已在用 `pgrep`，视为可用）。全部 `set -u`，不 `set -e`（自行处理错误分支）。

### 1.2 草案 A：`tools/m1/m1b/usr/sbin/m1-weston`（部署到 `/usr/sbin/m1-weston`，mode 0755）

```sh
#!/bin/sh
# m1-weston — Weston launcher for lmi (M1b rootfs, weston 14.x, pixman/DSI-1).
# Owns every child; TERM/INT tears them down before exit so an OpenRC
# stop/restart can never race a leftover compositor for the DRM seat (audit A4).
set -u

CONF=/etc/xdg/weston/weston.ini
FALLBACK=/etc/xdg/weston/weston.ini.fallback
RUNDIR=/run/lmi-weston
SOCK=wayland-0
RETRIES=3; BACKOFF=3; SEAT_WAIT=15
[ -r /etc/conf.d/m1-weston ] && . /etc/conf.d/m1-weston

log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" "$*"; }

WPID=''; C1=''; C2=''; MTEST=''; FEEDER=''; WORK=''
STOPPING=0
trap 'STOPPING=1' TERM INT HUP

kill_wait() { # $1=pid $2=timeout_s
  _p=$1; _t=${2:-5}; _i=0
  [ -n "$_p" ] || return 0
  kill -TERM "$_p" 2>/dev/null
  while [ "$_i" -lt "$_t" ] && kill -0 "$_p" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
  kill -0 "$_p" 2>/dev/null && kill -KILL "$_p" 2>/dev/null
  return 0
}

cleanup() {
  kill_wait "$C1" 3; kill_wait "$C2" 3
  kill_wait "$MTEST" 3; kill_wait "$FEEDER" 3
  if [ -n "$WPID" ]; then kill_wait "$WPID" 8; wait "$WPID" 2>/dev/null; fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  rm -f "$RUNDIR/$SOCK"
  log "cleanup done"
}
trap cleanup EXIT

mkdir -p "$RUNDIR"; chmod 700 "$RUNDIR"

wait_seat() {
  i=0
  while [ "$i" -lt "$SEAT_WAIT" ]; do
    [ -S /run/seatd.sock ] && [ -e /dev/dri/card0 ] && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

sweep_stale() { # only a leftover weston from a killed/daemonized run
  pgrep -x weston >/dev/null 2>&1 || return 0
  log "stale weston detected; terminating"
  kill_wait "$(pgrep -x weston)" 8
  pgrep -x weston >/dev/null 2>&1 && { log "WARN: stale weston survived"; return 1; }
  return 0
}

splash_release() { # D80-proven modetest sequence, bounded
  WORK=$(mktemp -d /tmp/m1-weston.XXXXXX) || { WORK=''; return 0; }
  mkfifo "$WORK/input" || return 0
  tail -f /dev/null > "$WORK/input" & FEEDER=$!
  modetest -a -s '29@129:#0@XR24' -P '58@129:1080x2400@XR24' < "$WORK/input" & MTEST=$!
  sleep 3
  kill_wait "$FEEDER" 2; FEEDER=''
  kill_wait "$MTEST" 5; MTEST=''
  rm -rf "$WORK"; WORK=''
}

start_weston() { # $1=config file
  weston --config="$1" --backend=drm-backend.so --drm-device=card0 \
    --renderer=pixman --socket="$SOCK" --idle-time=0 \
    --continue-without-input --debug --log=/var/log/weston.log &
  WPID=$!
  i=0
  while [ "$i" -lt 20 ]; do
    [ -S "$RUNDIR/$SOCK" ] && return 0
    if ! kill -0 "$WPID" 2>/dev/null; then WPID=''; return 1; fi
    i=$((i+1)); sleep 1
  done
  return 1
}

attempt=0
while [ "$attempt" -lt "$RETRIES" ]; do
  attempt=$((attempt+1))
  wait_seat || log "WARN: seatd/dri not ready after ${SEAT_WAIT}s"
  sweep_stale || log "WARN: DRM seat may still be busy"
  splash_release
  conf=$CONF
  if [ "$attempt" -ge 2 ] && [ -f "$FALLBACK" ]; then
    conf=$FALLBACK; log "retry with fallback config: $FALLBACK"
  fi
  if start_weston "$conf"; then
    log "weston up (attempt $attempt)"
    WAYLAND_DISPLAY="$SOCK" weston-terminal --maximized --font-size=16 & C1=$!
    WAYLAND_DISPLAY="$SOCK" weston-editor & C2=$!
    wait "$WPID"; rc=$?; WPID=''
    [ "$STOPPING" = 1 ] && { log "stop requested"; exit 0; }
    log "weston exited rc=$rc"
  else
    log "weston failed to start (attempt $attempt)"
    kill_wait "$WPID" 3; WPID=''
  fi
  [ "$STOPPING" = 1 ] && exit 0
  sleep "$BACKOFF"
done
log "FATAL: weston not up after $RETRIES attempts"
exit 1
```

要点：`wait` 被信号打断后先查 `STOPPING` 再决定重试；`cleanup` 是唯一退出路径；
weston 名字精确匹配（`pkill -x`），不误伤 `weston-terminal`。

### 1.3 草案 B：`tools/m1/m1b/etc/init.d/m1-weston`（部署到 `/etc/init.d/m1-weston`，mode 0755）

```sh
#!/sbin/openrc-run
# m1-weston — OpenRC service. start uses the stock command_background+pidfile
# machinery (small diff vs device); stop() escalates because the pidfile points
# at the wrapper, which owns weston (audit A4).

description="Weston compositor on the DSI panel"
command="/usr/sbin/m1-weston"
command_background="yes"
pidfile="/run/m1-weston.pid"
output_log="/var/log/m1-weston.log"
error_log="/var/log/m1-weston.log"

depend() {
	need localmount
	after seatd
}

start_pre() {
	checkpath -d -m 0700 /run/lmi-weston
}

stop() {
	ebegin "Stopping ${RC_SVCNAME}"
	spid=''
	[ -r "$pidfile" ] && read -r spid < "$pidfile"
	if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
		kill -TERM "$spid" 2>/dev/null
		i=0
		while [ "$i" -lt 30 ] && kill -0 "$spid" 2>/dev/null; do
			sleep 0.2; i=$((i+1))
		done
		if kill -0 "$spid" 2>/dev/null; then
			ewarn "wrapper $spid ignored SIGTERM; SIGKILL"
			kill -KILL "$spid" 2>/dev/null
		fi
	fi
	# last-resort orphan sweep (wrapper normally reaped everything already)
	for p in weston weston-terminal weston-editor modetest; do
		pkill -x "$p" 2>/dev/null
	done
	sleep 1
	rm -f "$pidfile"
	eend 0
}

start_post() {
	i=0
	while [ "$i" -lt 25 ]; do
		[ -S /run/lmi-weston/wayland-0 ] && break
		i=$((i+1)); sleep 1
	done
	if [ -S /run/lmi-weston/wayland-0 ]; then
		printf 'weston: socket ready after %ss at %s\n' "$i" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /var/log/m1-weston.status
		return 0
	fi
	printf 'weston: socket NOT ready after %ss at %s\n' "$i" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /var/log/m1-weston.status
	ewarn "weston socket not ready (see /var/log/m1-weston.log, /var/log/weston.log)"
}
```

补充：`etc/conf.d/m1-weston`（mode 0644）放 `RETRIES/BACKOFF/SEAT_WAIT` 覆盖项；
`etc/xdg/weston/weston.ini.fallback`（mode 0644）为已知良好精简配置（ship 进 overlay，作救援源）。
若不想自定义 `stop()`，OpenRC ≥0.42 也可用 `supervisor=supervise-daemon` 自动重启，但其
stop 语义与 pidfile 交互更绕，**本批不采用**（保持最小变更）。

## 2. 第一批 UX 修改落地清单

### 2.1 文件归属

| 文件（源） | 去向 | 说明 |
|---|---|---|
| `tools/m1/m1b/etc/xdg/weston/weston.ini` | overlay | 已入仓（48de301/dce034e），缺 staged 树/overlay |
| `tools/m1/m1b/usr/share/lmi/term-icon.png` | overlay | 已入仓，同上 |
| `tools/m1/m1b/usr/sbin/m1-weston` | overlay（新增） | §1.2；与 `tools/m1/m1-weston.sh` 同步 + T0 `cmp` 检查 |
| `tools/m1/m1b/etc/init.d/m1-weston` | overlay（新增） | §1.3 |
| `tools/m1/m1b/etc/conf.d/m1-weston`、`etc/xdg/weston/weston.ini.fallback` | overlay（新增） | 可调参数 / 救援配置 |
| `tools/m1/m1b/etc/init.d/lmi-time`、`etc/conf.d/lmi-time`、`usr/sbin/lmi-time-sync` | overlay（新增） | NTP（busybox `ntpd -q` 或 chrony）→ `hwclock -w`；`depend() { after lmi-wifi }`；**不阻塞 SSH** |
| `etc/runlevels/default/lmi-time`（symlink） | overlay（新增） | 由手机侧（Linux）创建并提交；Windows 检出无法生成 symlink 时改用手工 `rc-update add lmi-time default` |
| `etc/localtime`（Asia/Shanghai，约 1–2 KB） | overlay | 由 tzdata 生成后拷入 staged 树 |
| CJK 字体（wqy-microhei/子集 Noto） | **决策门**：overlay ≤16 MiB 则进 overlay；否则进 rootfs 镜像 | 见 §5-风险 4 |
| `tools/m1/m1b-init.sh` | **initramfs** | 仅改 `OVERLAY_VERSION`（行 36）与 banner 文案（行 48） |
| 字体/fc-cache、`chrony` 等包 | rootfs 镜像 | 仅当字体超预算/无 busybox ntpd；走 `patch-rootfs-image.sh` 或 rootfs master 重建 |
| `weston-keyboard` 布局补丁、亮度/按键映射（B1/B3） | 第二批次单独 issue | 需要改动 weston 二进制/短期验证，不纳入第一批 |

### 2.2 overlay 版本与 `m1b-init.sh`

- 当前设备 `/etc/m1b-overlay-version` = `m1b-wifi-v2`；应用判据是**字符串相等**（`m1b-init.sh:161`），
  所以必须 bump 才能在已部署设备上重放：**改为 `m1b-ux-v3`**。
- `m1b-init.sh` 改动两点（仅此）：`OVERLAY_VERSION=m1b-ux-v3`；`echo "===== M1b init v8 ====="`
  （现为 v5，避免误导）。initramfs 其余逻辑（BCB 早清、NCM、救援 dropbear、ledger）不动。
- 唯一权威常量在 `tools/m1/m1b-init.sh`；`build-m1b-image.sh:95` 会把它拷进 initramfs
  → **必须重建 boot 镜像**，不能只发 overlay。

### 2.3 构建（手机本机 / Debian proot；路径照 handoff §四/§五）

```sh
cd /root/work/k30pro-linux-dualboot && git pull --ff-only
# 1) staged 树：以 v2 树为基线（勿用 --base-image：64 MiB 上限会直接拒绝）
cp -a /root/work/m1b2 /root/work/m1b-ux
# 2) 叠加仓库 overlay 文件并修 mode（tar 保留 mode，脚本必须 755）
tar -C tools/m1/m1b -cf - etc usr | tar -C /root/work/m1b-ux -xf -
chmod 755 /root/work/m1b-ux/usr/sbin/m1-weston /root/work/m1b-ux/etc/init.d/m1-weston \
          /root/work/m1b-ux/etc/init.d/lmi-time /root/work/m1b-ux/usr/sbin/lmi-time-sync
# 3) runlevel symlink（手机侧创建，随 staged 树进 overlay）
ln -sfn /etc/init.d/lmi-time /root/work/m1b-ux/etc/runlevels/default/lmi-time
# 4) 构建 v8（kernel/dtb/dtbo 路径以 v7 buildinfo 为准）
tools/m1/build-m1b-image.sh --tree /root/work/m1b-ux \
  --initramfs-dir /root/work/m1b-v5-initramfs \
  --kernel /root/work/lmi-m0/kernel/vmlinuz \
  --dtb /root/work/lmi-m0/kernel/kona-v2.1-lmi.dtb \
  --cmdline tools/m1/kernel-cmdline-m1b.txt \
  --base-tree /root/work/m1b2 --overlay-version m1b-ux-v3 \
  --recovery-dtbo /root/work/dtbo-new.img \
  --out /root/work/out/boot-m1b-v8.img
```

### 2.4 离线测试（不碰设备）

```sh
tar -tzf /root/work/out/boot-m1b-v8.img.overlay.tar.gz | sort   # 文件清单含 weston/m1-weston/lmi-time
tar -xzf /root/work/out/boot-m1b-v8.img.overlay.tar.gz -C /tmp/ov-check
cmp /tmp/ov-check/etc/xdg/weston/weston.ini tools/m1/m1b/etc/xdg/weston/weston.ini
debugfs -R "rdump / /tmp/base-v2" /sdcard/Download/phone-server/lmi-m1b/rootfs-live2.img
tar -xzf /root/work/out/boot-m1b-v8.img.overlay.tar.gz -C /tmp/base-v2   # 模拟首启重放
for f in $(tar -tzf /root/work/out/boot-m1b-v8.img.overlay.tar.gz | grep -v '/$'); do cmp /tmp/base-v2/$f /tmp/ov-check/$f; done
stat -c '%s %n' /root/work/out/boot-m1b-v8.img /root/work/out/boot-m1b-v8.img.overlay.tar.gz
sh tools/ci/checks.sh && for s in usr/sbin/m1-weston etc/init.d/m1-weston usr/sbin/lmi-time-sync; do sh -n tools/m1/m1b/$s; done
```

### 2.5 真机验证与部署

```sh
# 电脑侧（USB，方式 A）
fastboot boot boot-m1b-v8.img
# Linux 内检查（USB 172.16.42.1 / 局域网 192.168.1.x）
cat /etc/m1b-overlay-version; tail -3 /root/m1b-boots.log; pgrep -x weston; date
# 回 Android 后（root）：门禁 + 部署
sh recovery-swap.sh attest-ramboot /data/local/lmi-dualboot/boot-m1b-v8.img
sh recovery-swap.sh to-linux /data/local/lmi-dualboot/boot-m1b-v8.img
```

### 2.6 回滚

```sh
# Android：取消/回退（v7 的 attestation 与 sha 清单仍在 /data/local/lmi-dualboot/）
sh recovery-swap.sh bcb clear                                        # 未重启前
sh recovery-swap.sh to-linux /data/local/lmi-dualboot/boot-m1b-v7.img
sh recovery-swap.sh restore-twrp                                     # 彻底放弃 Linux
# Linux（SSH 可用）：配置级救援
cp /etc/xdg/weston/weston.ini.fallback /etc/xdg/weston/weston.ini && rc-service m1-weston restart
```

注意：overlay 不能删文件，回滚 v7 后 rootfs 里已应用的 UX 文件仍在（无害）；v7 内嵌 overlay v2
在版本戳不同时会重放一次（内容为已存在的 v2 文件，幂等）。

## 3. 对 M2 切换与既有验收的影响

- **机制零变化**：不动 super/分区/BCB 逻辑；`m1b-init.sh` 仍是"先清 BCB、后应用 overlay"
  → 即使 overlay 失败，BCB 已清、重启回 Android，不会造成 fastboot 残留循环。
- **门禁按设计收紧**：v8 是新 sha → `recovery-swap.sh` 强制要求新的 `attest-ramboot`（issue #1/#6
  的预期行为，不是缺陷）；部署前必须完成方式 A 真机验证。
- **首启一次重放，幂等性**：版本相等判据保证只重放一次；tar 覆盖 + 目录合并天然幂等；
  runlevel symlink / `rc-update add` 幂等；`lmi-time-sync`/fc-cache 用
  `/var/lib/lmi/.../<version>` 戳记防重复。第二启 ledger 应为 `overlay=skipped`。
- **已有验收仍然有效**：`docs/acceptance/m2-2026-09-14.md` 记录的是 v7 的切换机制行为；
  v8 部署后只需做**回归抽样**（T2-02 ×3、T2-04、TWRP restore 不动），并新增 UX1 记录；
  同时更新 `docs/m1b-persistent.md` 产物表、`docs/m1b-wifi-runbook.md` §1、`docs/handoff.md`、CHANGELOG。
- **启动时序**：wrapper 快速失败时重试最多 ~3×(15+3+20+3)s，但 `command_background` 不阻塞
  OpenRC；`lmi-wifi after m1-weston` 只是排序，不受影响；SSH 全程可用。

## 4. 验收清单（UX1，风格对齐 `docs/test-plan.md`）

| 编号 | 项目 | 通过标准 | 证据要求 |
|---|---|---|---|
| UX1-01 | overlay v3 应用 | 首启 ledger `overlay=applied` 且 `/etc/m1b-overlay-version`=`m1b-ux-v3`；第二启 `overlay=skipped` | `/root/m1b-boots.log` 两行原文 + `cat` 输出 |
| UX1-02 | weston stop/start ×3 | `rc-service m1-weston stop` 后 10 s 内 `pgrep -x weston` 为空；start 后 25 s 内 socket 就绪；3 轮零失败 | 带时间戳的命令转录、`/var/log/m1-weston.status` |
| UX1-03 | SSH 不中断 | stop/start 期间既有 SSH 会话不断、新连接 <5 s 可建立；dropbear PID 不变 | 转录 + `pgrep dropbear` 前后对照 |
| UX1-04 | 启动器 | 顶栏终端图标存在，点击开出终端（照片）；`weston.ini` 与仓库文件 sha256 一致 | 照片 + `sha256sum` |
| UX1-05 | 时间 | WiFi 连通后 ≤2 min `date` 年份=当年；`hwclock -r` 合理；断网重启后从 RTC 恢复（年份≥2026） | `date`、`hwclock -r`、lmi-time 日志、两次重启对照 |
| UX1-06 | CJK | `fc-list :lang=zh` 非空；终端显示"中文测试"无豆腐块（照片） | `fc-list` 输出 + 照片 |
| UX1-07 | 方式 A RAM 引导 | `fastboot boot v8` 后 UI+SSH 可用；未写任何分区 | 屏幕照片、启动日志、分区未变说明 |
| UX1-08 | 部署门禁与回读 | `to-linux` 通过 sha/attestation/size；recovery 回读 sha=镜像 sha；BCB 清空 | `switch.log`、`status` 输出 |
| UX1-09 | 双向回归抽样 | Android↔Linux 往返 3 次零失败；`boot` 分区 sha 前后一致 | `switch.log` + ledger + boot sha 对照 |
| UX1-10 | 黑屏救援演练 | 人为放坏 `weston.ini`：wrapper 第 2 次尝试自动用 fallback（或按 §2.6 手工救援）后 UI 恢复，SSH 全程在 | 操作转录 + `m1-weston.log` 中 fallback 行 |

## 5. 风险与回退

1. **weston.ini 损坏 → 黑屏/无输入**：SSH 仍可用（dropbear 独立）。救援：`ssh root@…`
   → `cp /etc/xdg/weston/weston.ini.fallback … && rc-service m1-weston restart`；
   wrapper 自身也会在重试时切 fallback（双保险）。
2. **完全失联（USB 枚举失败）**：电脑侧重插 USB；仍不行 → 长按电源/断电重启回 Android
   （init 已清 BCB），再用 `to-linux v7` 或 `restore-twrp`。
3. **overlay 提取失败/中断**：版本戳不写，下次开机重试（`/var/log/m1b-overlay.log`）；
   最坏情况是部分文件半新半旧 —— 因 BCB 已提前清除，不构成变砖路径。
4. **体积超限（最可能触发 rootfs 路径）**：overlay 硬上限 64 MiB（`mk-overlay.py`），
   boot 镜像须 < recovery 分区 128 MiB（v7=55 MB）。构建后立即 `stat` 断言；
   字体超 16 MiB 时在 rootfs master 上安装（TWRP 写入，须重新走 `patch-rootfs-image.sh`
   的 journal 顺序），overlay 只带配置/脚本。
5. **NTP 不可达**：时间保持 1970（与现状一致，无功能回归）；RTC 写入失败同样无害。
   上线前先验证 busybox 是否含 `ntpd`（`busybox ntpd --help`），否则用 chrony（rootfs 路径）。
6. **runlevel symlink 未生效**（Windows 检出把 symlink 存成文本文件）：T0 用 `git ls-files -s`
   验证 mode `120000`；失效则手工 `rc-update add lmi-time default` 并把启用动作移入
   `m1-weston` 的 `start_pre` 一次性钩子（备选方案，见 §6-8）。
7. **执行位丢失**（Windows 新增文件默认 100644）：`git ls-files -s` 必须显示 `100755`；
   必要时 `git update-index --chmod=+x`，或全部在手机侧提交。

## 6. 行动项（按顺序）

1. **作者（手机侧）**：把 §1.2/§1.3 草案落为 `tools/m1/m1b/usr/sbin/m1-weston`、
   `tools/m1/m1b/etc/init.d/m1-weston`（+conf.d/fallback），同步更新 `tools/m1/m1-weston.sh`，
   在 `tools/ci/checks.sh` 加两者 `cmp` 一致性检查；确保 git mode 100755。
   **验证**：`sh tools/ci/checks.sh` + shellcheck 全绿。
2. **作者**：新增 `lmi-time` 三件套 + `etc/localtime` + runlevel symlink；先真机确认
   `busybox ntpd/fc-cache/hwclock` 可用性再定实现分支。**验证**：`sh -n`、staged 树 mode 正确。
3. **作者**：改 `tools/m1/m1b-init.sh`（`m1b-ux-v3` + banner v8）并提交。
   **验证**：`git diff` 仅这两处 + 每次构建 buildinfo 记录 overlay 版本。
4. **作者**：按 §2.3 建 staged 树/构建 v8；按 §2.4 做离线清单、cmp、大小门禁。
   **验证**：overlay 尺寸 ≤16 MiB（否则转 rootfs 路径）、boot <128 MiB、sha256 记录。
5. **独立验证者（按 `docs/ai-protocol.md`）**：对上述提交做只读审查（POSIX/OpenRC 约定、
   trap 覆盖、CI 检查项），输出 `[VFY]` issue。**作者**以 `Resolved-by:` 回应。
6. **负责人 + 作者（电脑为 USB 工具）**：方式 A 真机跑 UX1-01…06/10，通过后
   `attest-ramboot v8` 并按 §2.5 部署。**验证**：UX1-07/08 证据归档。
7. **作者 + 负责人**：部署后回归 UX1-08/09（往返 ×3、boot 分区 sha 对照），归档
   `docs/acceptance/ux1-<日期>.md`，更新 `docs/m1b-persistent.md`、`docs/m1b-wifi-runbook.md`
   §1、`docs/handoff.md`、CHANGELOG。**验证**：CI 链接检查通过、文档 sha 与产物一致。
8. **作者（第二批次，另行开 issue）**：字体超预算时的 rootfs 路径（TWRP 写入 + 回归）、
   weston-keyboard 布局补丁（A2/A6）、亮度/音量键映射（B1/B3）、OSK 遮挡（B2）。
   **验证**：每项独立测试计划 + 真机证据。
