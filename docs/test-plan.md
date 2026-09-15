# 测试计划（骨架）

原则：**能非破坏验证的，绝不先做破坏性验证；能在测试机做的，绝不在主力机做。**

## T0 — 静态检查（每次提交，CI）

由 `tools/ci/checks.sh` 执行（CI job「Guard rails」），实现状态：

- `shellcheck` 全部 shell 脚本（含 `tools/m0/init`；`-e SC2187` 因 busybox shebang）
- Markdown **本地**链接检查（相对链接必须存在；外链不检查）
- 禁止硬编码设备节点：仅白名单文件允许（`tools/m0/init`、`tools/m1/m1-init.sh`
  的 `misc` 兜底节点，已注释说明）；`/dev/block/by-name/*` 为稳定符号链接，允许
- 破坏性脚本（含 `dd ... of=`）必须提供 `--dry-run`；ramboot init 豁免
  （其唯一写入是设计内的 BCB 清除，ADR-0001）

## T1 — 非破坏验证（主力机可执行）

| 编号 | 项目 | 通过标准 |
|---|---|---|
| T1-01 | `fastboot boot` 启动 Linux（阶段 A） | 显示、触屏、SSH 可用；未写任何分区 |
| T1-02 | 读取并归档分区表 / GPT / boot / recovery 备份 | 哈希校验通过 |
| T1-03 | BCB 行为试验：写 boot-recovery 进 TWRP | ✅ 2026-09-14 完成：ABL **不**清 BCB、Linux init 清除；且 recovery 引导要求镜像自带 `recovery_dtbo`（v6 缺 → fastboot；v7 修复）。见 `acceptance/m2-2026-09-14.md` |
| T1-04 | 正常重启回归 | 100 次重启全部回到 Android（可分批） |
| T1-05 | 方式 B 部署门禁（预检） | 无 attestation / SHA-256 缺失或不匹配时 `to-linux` 拒绝写入；`--dry-run` 不写任何分区。自动化：`tools/tests/m2-switch-test.sh`（CI 运行，含 BCB 写/清校验、`--force`、尺寸检查） |

## T2 — 受控破坏性验证（测试机优先）

> M2 v0.1 实现完成（2026-09-14）：命令与验收步骤见 `docs/m2-runbook.md`；
> 下表 T2-02/03/04 与 TWRP 恢复演练待实机执行并归档。

| 编号 | 项目 | 通过标准 |
|---|---|---|
| T2-01 | 阶段 B 安装（super 空闲空间 + recovery） | 30 次重启稳定；TWRP 可恢复 |
| T2-02 | 双向切换 | 各 20 次无失败。**2026-09-14 实机：5 轮零失败后由负责人决定提前结束（时间成本）；标准修订待定**（见 `acceptance/m2-2026-09-14.md`） |
| T2-03 | Linux 未清 BCB 时断电 | 重启能回到 Android 或自愈 |
| T2-04 | 切换命令执行中断电 | 重启回 Android |
| T2-05 | M3 扩容 dry-run | 输出与预期分区表一致；`tools/m3/lmi-repart.sh plan` + 离线测试 `tools/tests/m3-repart-test.sh`（CI 运行，2026-09-15 全绿）✅ |
| T2-06 | M3 扩容实做 + 回滚 | 回滚后数据完好、镜像一致。**2026-09-15 已在本机实做**：userdata 107→91 GiB、新建 `lnx` 16 GiB、rootfs 迁入并启动（`root=/dev/sda35`）；回滚路径 = super 内旧 rootfs 区保留 + `recovery` 可 dd 回旧镜像。证据 `acceptance/m3-2026-09-15.md` ✅ |
| T2-07 | 全量备份恢复演练 | TWRP 全量恢复后系统与数据可用（`docs/m3-repart-plan.md` §7）；M2 时已演练 TWRP 3.7.1 可恢复，M3 后 Android 侧已验证 `/data` 挂载与数据完整 ✅ |

## T3 — 发布回归（每个 Release）

- T1 全量
- T2 在至少一台已完成安装的设备上抽样（T2-01/02/04/07）
- 验收记录归档到 `docs/acceptance/`

## T4 — Linux 长期运行（电源/温控/监控，M4 新增）

| ID | 项目 | 通过标准 | 状态 |
|---|---|---|---|
| T4-01 | CPU 降温 | 开机后三簇 governor = `schedutil`；空闲频率 < 1 GHz | ✅ 2026-09-15（实测 844 MHz） |
| T4-02 | 充电 SOC 门限 | SOC ≥ 80 % 自动停充、≤ 70 % 自动恢复；USB 数据不受影响 | ✅ 2026-09-15（`input_suspend` 实测；状态从 100→99 % 下降） |
| T4-03 | 温度门限 | ≥42 °C 停充、≤38 °C 恢复（读数以 `battery/temp`/thermal zone 交叉校验） | ✅ 代码路径验证（当前 33–34 °C，未触门限） |
| T4-04 | 卡死保护 | SOC 持续下滑告警；≤ RECOVER_SOC 时写 BCB 并重启**回 Linux**（绝不去 Android） | ✅ 离线路径验证 + 24 h 安全阀 |
| T4-05 | 监控采样 | `lmi-monitor` 60 s 更新 `/run/lmi-monitor/latest`，10 min 落 CSV，累计高压 SOC 与 >40 °C 时长 | ✅ 2026-09-15（`lmi-status` 与 CSV 正常） |
| T4-06 | 内网面板 | 回退链可用，`:8080` 返回 200 且显示实时状态 | ✅ 2026-09-15（python3 回退，HTTP 200） |
| T4-07 | 长稳观察 | 连续运行 ≥72 h 无异常，充电锯齿与温度曲线符合预期 | ⬜ 观察中（v1.0 发布后回填） |

## T5 — M5 一键安装（离线可验证；真机待做）

> 设计 `docs/installer-design.md`，使用说明 `docs/install-guide.md`。
> 破坏性：会覆盖 `recovery`、写 `super` 空闲区；**不写 `boot`、不重分区**。

| 编号 | 项目 | 通过标准 | 状态 |
|---|---|---|---|
| T5-01 | LP 元数据解析 | 合成 super 的分区/组/空闲区正确、校验和通过；真机 super 核对 | ✅ `tools/tests/m5-lp-parse-test.sh`（真机 super 核对通过） |
| T5-02 | 偏移选择 + cmdline 修补 | 选中最优空闲区、报出 `lmi_root_off`，boot 镜像 cmdline 正确改写 | ✅ `tools/tests/m5-install-test.sh` |
| T5-03 | 完整安装模拟 | 假 adb/fastboot + 沙箱分区跑真路径：备份→写 super/recovery→写 BCB；rootfs 逐字节、BCB 正确、`boot` 未变 | ✅ `tools/tests/m5-install-sim-test.sh` |
| T5-04 | 回滚 | 恢复 recovery、清 BCB、`boot` 不写 | ✅ `tools/tests/m5-install-sim-test.sh` |
| T5-05 | 首次启动初始化 | 随机 root 口令 / 主机密钥 / machine-id、SSH 仅公钥、幂等 | ✅ `tools/tests/m5-firstboot-test.sh`（沙箱） |
| T5-06 | 体积/镜像/空闲区门禁 | >1.5 GiB、非 boot 镜像、无可用空闲区均拒绝 | ✅ `tools/tests/m5-install-test.sh` |
| T5-07 | 通用镜像零凭据 | 含 WiFi/可用 root 口令/非空 machine-id/预置密钥即拒绝构建 | ✅ `tools/install/build-generic-image.sh` 门禁 |
| T5-08 | **真机端到端** | 测试机/已备份设备跑通 `check→plan→install`；安装后 Android 正常、Linux 可启动、可回滚；记录到 `docs/acceptance/` | ⬜ **未做**（破坏性，需负责人 + 测试机） |

## 验收记录模板

```
日期 / 设备 / ROM / 内核 / 操作人
前置条件：
执行步骤：
结果（含日志 / 截图哈希）：
结论：PASS / FAIL
遗留问题：
```

## 异常场景清单

- 切换中断电 / 拔线
- Linux 内核 panic、initramfs 卡死
- BCB 残留导致 fastboot 循环（方式 B 救援：`fastboot erase misc`，见 m0-runbook §5）
- Android 侧 root 丢失（Magisk 被覆盖）
- recovery 分区被系统 OTA 恢复成官方镜像
- 存储写满导致 boot 镜像复制不完整（写入前必须校验空间与哈希）
