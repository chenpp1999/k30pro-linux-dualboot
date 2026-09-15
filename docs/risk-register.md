# 风险台账（Risk Register）v1

评分：概率 P / 影响 I，H/M/L；状态：Open / Mitigating / Closed。

| ID | 风险 | P | I | 缓解措施 | 触发条件 / 备注 | 状态 |
|---|---|---|---|---|---|---|
| R1 | 重分区（M3）失败导致 Android 数据丢失 | M | H | 测试机先行演练；全量备份；dry-run；回滚脚本（`lmi-repart.sh backup/verify/restore`）；EDL 救援预案；独立子代理审计 | **2026-09-15 已在本机执行成功**：userdata 107→91 GiB（PARTUUID 保留、数据完好）、新建 `lnx` 16 GiB、rootfs 迁入并启动；审计拦下三个数据丢失级坑（`resize.f2fs -s`、PARTUUID、rootfs 相对偏移）；证据 `docs/acceptance/m3-2026-09-15.md` | Closed |
| R2 | f2fs 缩容在 metadata 加密场景不兼容 | M | H | 测试机验证 resize 流程；失败则放弃 M3，退回阶段 B | 实际执行前 `fsck.f2fs -f` ×2 均干净；`resize.f2fs -s -t 23856641` 成功；Android 侧挂载验证 `/data` 91 GiB 且数据完整（含加密 userdata 现状） | Closed |
| R3 | BCB 未清除导致回不到 Android | H | H | Linux 早期清 BCB；runbook §5 救援流程（`fastboot erase misc` 唯一 erase 例外）；方式 B 部署门禁（attestation） | 2026-09-13 真机方式 B 实测触发（issue #1）：recovery→fastboot 循环；见 test-plan T1-05/T2-03 | Mitigating |
| R4 | recovery 被 Linux 镜像覆盖，TWRP 不可用 | L | M | TWRP 镜像双份备份；Android/Linux 均可 dd 回刷（`recovery-swap.sh restore-twrp`） | 已演练：TWRP 3.7.1 可恢复 | Mitigating |
| R5 | Linux 电源/热管理不足导致长期运行不稳 | M | M | **2026-09-15 已落地**：`lmi-power`（governor→schedutil 降温）、`lmi-chargectl`（停充 80 %/恢复 70 %、42/38 °C、卡死保护 + 24 h 安全阀）、`lmi-monitor`（采样/CSV/内网面板，跟踪 `charge_full`、`cycle_count`、高压 SOC 与 >40 °C 累计时长） | 见 `docs/m1b-thermal-charging.md`；限流节点写入 EPERM（已记录为不可用） | Mitigating |
| R6 | 上游依赖个人 fork（kernel/firmware）消失 | M | M | 本地与镜像缓存；fork 到本项目组织账号；推动上游化 | yuweiyuan8/linux | Open |
| R7 | 主力机单点：实验毁掉现有服务器 | M | H | M0–M2 低风险先行；M3 起使用测试机；全量备份 | 见 charter §7；M3 在测试机执行 | Mitigating |
| R8 | 文档/流程错误导致误导操作 | M | M | PR 强制 review；测试计划先行；复现清单 | 2026-09-15 两次真事故：payload CRLF 损坏脚本（`tr` 误删字母 r）、overlay 版本未 bump 导致不重放；均已定位根因并入流程 | Mitigating |
| R9 | Android 重刷/OTA 覆盖分区表或引导 | M | M | 文档说明；恢复脚本；重刷前先导出分区表 | 用户侧操作 | Open |
| R10 | 无 SIM/硬件限制被误当作 bug 消耗时间 | H | L | feasibility 清单标注已知限制 | GPS/震动/modem | Closed（已记录） |
| R6 | 上游依赖个人 fork（kernel/firmware）消失 | M | M | 本地与镜像缓存；fork 到本项目组织账号；推动上游化 | yuweiyuan8/linux | Open |
| R7 | 主力机单点：实验毁掉现有服务器 | M | H | M0–M2 低风险先行；M3 起使用测试机；全量备份 | 见 charter §7 | Mitigating |
| R8 | 文档/流程错误导致误导操作 | M | M | PR 强制 review；测试计划先行；复现清单 | — | Open |
| R9 | Android 重刷/OTA 覆盖分区表或引导 | M | M | 文档说明；恢复脚本；重刷前先导出分区表 | 用户侧操作 | Open |
| R10 | 无 SIM/硬件限制被误当作 bug 消耗时间 | H | L | feasibility 清单标注已知限制 | GPS/震动/modem | Closed（已记录） |
